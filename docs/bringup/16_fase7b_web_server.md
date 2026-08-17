# Fase 7b — Servidor web: patrón de prueba, canvas y push por APB

**Fecha:** 2026-08-16/17
**Rama:** `firmware_development`
**Contexto:** con el push por APB probado en la Fase 7a (mecanismo confirmado, pero `SIZE`/`DISP_SIZE`
en 0 sin causa identificada dentro del presupuesto de 2 iteraciones acordado), tocaba la capa de
aplicación: un servidor web que sirva una página con upload de archivo y un canvas que muestre la
salida decodificada. El usuario pidió explícitamente alinear las características del servidor *antes*
de implementar.

## Alineación previa con el usuario

Dos decisiones de diseño, confirmadas antes de escribir código:

1. **Validar primero con un patrón sintético.** En vez de intentar conectar el pipeline completo
   (browser → servidor → decoder real → framestore) de una sola vez — con la Fase 7a todavía sin
   resolver, cualquier falla sería ambigua entre "el servidor está mal" y "el decoder no decodifica" —
   se separó el problema en dos: primero probar browser ↔ servidor ↔ WebSocket ↔ canvas contra un
   patrón animado escrito directamente en DDR por software, sin tocar el decoder. Recién después,
   conectar la fuente real.
2. **UI minimalista.** Sin barras de progreso, sin estado elaborado: un `<input type=file>`, un botón,
   un `<canvas>`, y una línea de texto de estado. Suficiente para demostrar el pipeline sin invertir
   tiempo en frontend que no aporta a la tesis.

## Arquitectura

Dos regiones DDR ya reservadas por el árbol de dispositivos base (`u-dma-buf`, sin overlay necesario,
`dmesg`: `buffer@c8000000`, `buffer@d8000000`, 32 MiB cada una, no cacheadas), deliberadamente separadas
para que la validación del patrón de prueba no pueda confundirse con el camino de decode real:

| Dispositivo                  | Física       | Uso                                                          |
|-------------------------------|--------------|---------------------------------------------------------------|
| `/dev/udmabuf-ddr-nc0`         | `0xc8000000` | `DDR_BASE` de `mem2axi_bridge` (Fase 6b) — framestore/vbuf real |
| `/dev/udmabuf-ddr-nc-wcb0`     | `0xd8000000` | patrón de prueba sintético, enteramente software              |

`webserver/ddr_region.py` envuelve cualquiera de las dos con `mmap` (`DDRRegion`, lectura/escritura por
offset). `webserver/server.py` corre dos listeners independientes, deliberadamente sin multiplexar en
un solo puerto (la librería `websockets` puede servir HTTP plano vía `process_request`, pero mezclar
eso con upload de archivo sin multipart era más complejidad de la que hacía falta):

- **HTTP (`:8080`)**: `GET /` sirve `static/index.html`; `POST /upload` guarda el cuerpo crudo y (ver
  más abajo) lo empuja al decoder por APB.
- **WebSocket (`:8081`)**: en loop, lee `FRAME_SOURCE` (hoy `TEST_PATTERN_DEVICE`) y manda cada frame
  como *header* de 8 bytes little-endian (`width`, `height`) + RGBA crudo — así el browser nunca
  necesita una resolución hardcodeada.

El HTTP server corre en un thread aparte (`ThreadingHTTPServer`), el WebSocket en el loop `asyncio`
principal — un upload lento (push byte a byte, ver más abajo) no bloquea el streaming de frames a
clientes ya conectados.

## `write_test_pattern.py`: patrón animado sin numpy

La placa no tiene `numpy` disponible (sin wheel prearmada para riscv64, sin compilador on-device para
construir una — ver notas de la Fase 4/7a). Generar 320×240×4 bytes por frame con un loop Python puro
por píxel habría sido demasiado lento para 15 fps. En cambio: se precomputa **una sola vez** al arrancar
una tira de gradiente de hue + checkerboard de `2×WIDTH` píxeles de ancho, y cada frame después es pura
copia por slicing (`bytes[a:b]`) de una ventana de `WIDTH` píxeles que se desliza sobre esa tira — sin
recalcular ningún píxel en el loop de animación. El checkerboard superpuesto (no solo un gradiente liso)
fue deliberado: hace evidente a simple vista cualquier corrimiento de un píxel o corrupción de datos, algo
que un gradiente liso podría esconder.

## Bug encontrado: `.gitignore` de allowlist no incluía `webserver/`

`firmware_development` usa un `.gitignore` de tipo *allowlist* (`*` seguido de `!driver`, `!renode`,
etc.) en vez de denylist — cualquier directorio nuevo queda ignorado por defecto hasta que se agrega
explícitamente. Los primeros archivos de `webserver/` (`ddr_region.py`, etc.) se escribieron a disco
pero `git status` los mostraba como árbol limpio — silenciosamente ignorados. Se agregó `!webserver` /
`!webserver/**` al `.gitignore`, siguiendo el mismo patrón que las entradas existentes.

## Validación en hardware real

**Patrón de prueba (sin decoder):** confirmado en dos niveles. (1) Un cliente WebSocket propio (sin
depender de un browser) hizo el handshake, recibió frames de exactamente `8 + 320*240*4 = 307208`
bytes, y confirmó que dos frames consecutivos difieren (la animación efectivamente llega por red). (2)
El usuario abrió `http://192.168.18.5:8080/` en un browser real y confirmó visualmente el canvas
animado — la primera confirmación de un pipeline completo browser-en-el-loop de todo el proyecto.

**Upload básico:** `POST /upload` con un archivo de prueba de 5000 bytes devolvió `200` y el archivo
apareció íntegro en `/tmp/uploaded_stream.m2v` en la placa.

## Cableado del push por APB en `/upload`

Con el patrón de prueba validado, se conectó `/upload` al mecanismo de la Fase 7a: `decoder_push.py`
(nuevo, `webserver/`) factoriza la lógica de `driver/mpeg2fpga/tools/push_stream.py` — mismo layout de
registros, mismo fix de `PAGE_OFFSET` de UIO, mismo padding de `sequence_end_code` — en una clase
reutilizable que descubre el dispositivo UIO por nombre (`mpeg2fpga_diag`, vía
`/sys/class/uio/uioN/name`) en vez de asumir un índice fijo. `do_POST` ahora guarda el archivo *y* lo
empuja al decoder, devolviendo el banco de registros antes/después como JSON — que la página muestra en
la línea de estado.

Requiere que el overlay `mpeg2fpga-uio.dts` (Fase 7a) esté aplicado en la placa; si no lo está,
`decoder_push.find_uio_device()` lanza `OverlayNotApplied` con un mensaje claro y el servidor responde
`{"status": "saved_only", ...}` en vez de fallar oscuramente.

**Prueba con un stream MPEG-2 real:** se subió `tools/streams/tcela/tcela-17-dots/tcela-17.bits` (12599
bytes, el mismo stream de la Fase 7a) vía `curl --data-binary` contra `/upload`. El push completó sin
colgar la placa y devolvió:

```json
{"status": "ok", "bytes": 12599,
 "regs_before": {"version": 12, "status": 4, "size": 0, "disp_size": 0},
 "regs_after":  {"version": 12, "status": 4, "size": 0, "disp_size": 0}}
```

Reproduce exactamente el mismo síntoma ya documentado en la Fase 7a (`15_fase7a_size_zero_investigation.md`)
— pero ahora en una sola request HTTP en vez de una sesión manual por SSH + `scp`. Este resultado es un
dato útil en sí mismo: descarta que el síntoma fuera un artefacto del método de prueba manual anterior
(la nueva vía de push es independiente y llega al mismo resultado), reforzando que la causa está más
abajo en el pipeline (`vbuf`/`vld`) y no en el mecanismo de entrega de bytes.

## Estado al cierre

Confirmado: pipeline completo browser ↔ servidor ↔ WebSocket ↔ canvas funcionando con un patrón
sintético (incluida confirmación visual del usuario); upload de archivo funcionando; push por APB desde
el servidor web funcionando sin regresión sobre lo probado en Fase 7a.

**Sigue abierto:** la causa raíz de `SIZE`/`DISP_SIZE` en 0. El servidor web ya es el harness de prueba
más directo planeado para retomar esa investigación — el próximo paso ahí, según lo ya anotado en la
Fase 7a, es instrumentar con `SmartDebug`/logic analyzer sobre `probe.v` en vez de sondeo por registro.

**Pendiente de esta fase:** cambiar `FRAME_SOURCE` de `TEST_PATTERN_DEVICE` a `FRAMESTORE_DEVICE` una
vez que haya datos reales de framestore que mostrar. Sigue la Fase 7c: DMA/streamer con staging buffer
en DDR (mejor throughput que push byte a byte por APB), con diagramas de funcionamiento.
