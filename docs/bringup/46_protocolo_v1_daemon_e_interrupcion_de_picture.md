# Protocolo v1: bitstream nuevo, daemon y verificación de punta a punta

Continúa [45]. Con la regresión y los benchmarks armados, el foco pasó a tratar
el sistema como producto: un protocolo de red versionado
(`api/PROTOCOL-v1.md`, firmware_development), una librería cliente en Python
con release automatizado (`api/python`, GitHub Action) y el servidor en la
placa (`daemon/mpeg2fpgad`). Este documento registra lo que hizo falta en
hardware para eso y lo que se midió.

## Una síntesis, tres cambios (hardware_development 07e318a / 8004bc9)

Todo en nuestros wrappers; el core licenciado sólo gana un tap de lectura.

- **DMA por chunks** (`stream_dma.v`, bit `no_pad` en `DMA_CTRL`): un chunk
  que no es el último no lleva el `sequence_end_code`. Permite clips de largo
  ilimitado con un buffer de staging fijo (era el ítem 9 del plan).
- **Build id** (bridge 0x2b `BUILD_VERSION`, 0x2c `BUILD_GIT`): versión del
  release y hash del commit, con bit de "sucio". El script de build estampa
  `build_id.v` en la copia del proyecto Libero; el árbol no se toca. En la
  placa el driver lee `0.1.0+8004bc9`, el commit exacto.
- **Interrupción de picture lista** (bridge 0x2d): ninguna interrupción del
  core significa "hay una picture en el framestore" (`picture_hdr` salta en el
  VLD antes de reconstruir, `frame_end` es el sincronismo vertical del
  display). Se toma el flanco de subida de `output_frame_valid` de
  `motcomp_picbuf`, que es cuando el core entrega un frame terminado al
  display, ya en orden de presentación, con el número de buffer.

Regresión completa con el bitstream nuevo: los 39 streams dan pictures
idénticas al baseline, determinismo y robustez pasan, perf sin cambios
(tek60 23.7 fps).

## La interrupción, verificada contra la referencia

`webserver/picture_events.py` lee cada buffer apenas llega su evento;
`tools/regress/check_picture_events.py` compara cada picture contra todos
los frames de `tools/mpeg2dec`. Con tek60: 60 eventos para 60 pictures, sin
huecos en el contador, y **el evento i coincide con el frame i de
presentación en los 60 casos** (intra MAD 0.004; el resto ≤ 1.1, la deriva
conocida de upstream). El error en las últimas filas es igual al del resto
de la imagen: cuando llega la interrupción la picture ya está entera en DRAM.

## El DMA por chunks y un falso positivo del testbench

Con bordes de chunk arbitrarios, tek60 en 37 chunks dio 36 pictures malas.
`stream_dma` lee palabras AXI de 64 bits enteras y emite desde el byte 0 de
la primera: un chunk que empieza en una dirección no múltiplo de 8 reenvía
los bytes anteriores. Con bordes alineados, 4 y 37 chunks dan pictures
**bit-idénticas** al push único. No requirió resintetizar: el driver rechaza
direcciones desalineadas (`-EINVAL`).

El testbench de `stream_dma` había pasado con un chunk desalineado porque su
modelo de DDR (`fake_axi_ddr_ro.v`) devolvía los bytes exactos de la
dirección pedida. Ahora alinea como un esclavo AXI de 64 bits real, y una
copia del test viejo falla igual que el hardware. Segundo caso de la misma
lección: un doble de prueba tiene que modelar las reglas de la interfaz, no
sólo los datos.

## Costo de TLS en la placa

Medido de punta a punta con el mismo stack que usa el daemon (`ssl` de
Python sobre OpenSSL 3.2, un core U54 sin extensiones criptográficas):

| modo | MB/s | frames 704x480/s |
|---|---|---|
| HTTP plano | 29.0 | ~57 |
| TLS 1.2 ChaCha20-Poly1305 | 7.6 | ~15 |
| TLS 1.2 AES-128-GCM | 4.5 | ~9 |

El core queda al 100% en los tres. Por eso TLS es opcional en el protocolo y,
cuando se usa, el daemon sólo ofrece ChaCha20.

## El daemon: de 12 a 20 fps de punta a punta

Primera versión funcional: 60 frames correctos, pero 12–14 fps contra ~23 del
decoder. Con contadores de tiempo por etapa en el resumen de cada decode:

1. La conversión a I420 en Python retiene el GIL ~24 ms por frame y frena a
   los demás hilos (el envío llegó a 53 ms por frame). Un pool de procesos no
   ayudó: pasar 1 MB por frame entre procesos se comió la ganancia.
2. Conversión en C (`daemon/native/m2fconv.c`, por `ctypes`, que suelta el
   GIL), leyendo directo del framestore mapeado: 32 ms por frame.
3. El compilador intercalaba cada lectura de memoria no cacheada con su uso,
   y el core in-order esperaba cada una: agrupar 8 lecturas detrás de una
   barrera de compilador, 23 ms.
4. Midiendo por separado, convertir desde caché tardaba 15 ms: el costo eran
   los stores byte a byte (~17 ciclos por byte). Con un store de 64 bits por
   cada 8 pixels: **17 ms**.

La librería se compila freestanding con el gcc de cross del kernel; sin la
extensión Zbb, `__builtin_bswap64` se vuelve una llamada a libgcc que el
`.so` no puede resolver en la placa, así que la inversión de bytes se hace con
máscaras. Se verifica byte a byte contra la versión Python, que queda como
respaldo.

Resultado, desde el host con la librería cliente: **tek60 a 20 fps, Tek-5-long
(150 frames) a 19.2 fps**, ~85% del techo del decoder, con todos los frames
coincidiendo con la referencia en orden y la captura nunca más de una picture
atrasada. El margen restante está en el envío por socket desde Python.

## Updates de campo: limitación de la Discovery Kit

El bitstream de PolarFire SoC se puede actualizar en campo con Auto Update o
IAP, que necesitan una flash SPI conectada al System Controller. La Discovery
Kit no la tiene (no figura en el user guide, y el driver `mpfs-auto-update`
del kernel no registra ningún dispositivo): en esta placa el bitstream sólo
se actualiza por JTAG. Linux, el driver y el daemon sí se pueden actualizar
en campo. Una placa de producto debería llevar esa flash.
