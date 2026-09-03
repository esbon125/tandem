# Fase 7a: los tres udmabuf son UN solo buffer (y la L2 memory-side lo escondía)

**La "anomalía viva" del doc 30 está resuelta, y era la causa raíz del `SIZE=0`
de toda la Fase 7a.** Continuación de
[30_fase7a_ROOT_CAUSE_ddr_base_sign_extension.md](30_fase7a_ROOT_CAUSE_ddr_base_sign_extension.md).

## Lo que quedaba abierto

El doc 30 dejó una sola pista viva: `FRAME_0_Y` (word 0, byte `0xc8000000`)
contenía una **copia literal del stream** en orden plano de CPU, apareciendo
unos segundos *después* de que el push terminaba. El VBUF, en cambio, estaba
perfecto. Se había descartado el orden de bytes, y se había descartado el
aliasing de direcciones con `diag_alias_check.py`.

Ese descarte del aliasing era falso.

## La causa raíz

Los tres nodos `u-dma-buf` que expone el reference design **no son tres
regiones distintas**. Son **una sola de 32 MB de DRAM física**, vista a través
de las tres ventanas de atributo de caché del MSS:

| device | dirección | ventana |
|---|---|---|
| `/dev/udmabuf-ddr-c0` | `0x88000000` | cached |
| `/dev/udmabuf-ddr-nc0` | `0xc8000000` | non-cached |
| `/dev/udmabuf-ddr-nc-wcb0` | `0xd8000000` | non-cached write-combining |

Es decir: el `STAGING_BASE` de `stream_dma.v` y el `DDR_BASE` de
`mpeg2fpga_apb_peripheral.v` **siempre apuntaron a los mismos bytes**.

`ddr_region.py` afirmaba lo contrario en su docstring —"three regions
deliberately kept separate"— y todo el software se construyó sobre esa premisa
equivocada.

### Por qué explica el `SIZE=0`

Stagear el stream en offset 0 lo escribía **encima de `FRAME_0_Y`**. Y el
barrido `STATE_CLEAR` de `framestore_request.v` escribía su relleno `0x80` de
vuelta encima del stream stageado. Las dos cosas competían en cada push:

- el stream que el DMA leía estaba parcialmente destrozado,
- el VBUF recibía una copia corrupta (2890/4096 contra el archivo real),
- `vld.v` nunca encontraba un sequence header válido → `SIZE=0`.

Y el "aparece tarde" del doc 30 también cierra: el CPU escribe el stream por
la ventana **cached**, las líneas quedan sucias en L2 y se vuelcan a DRAM
segundos después, pisando el relleno `0x80` que el decoder ya había puesto.

## Por qué el test anterior dijo "independent"

`diag_alias_check.py` hacía lo obvio: escribir en `0x88000000` y leer
`0xc8000000`, y viceversa. Dio "independent" en ambas direcciones. Era un
**falso negativo**, y el motivo es la razón por la que este bug sobrevivió
tanto:

> La L2 de PolarFire SoC es una caché **memory-side**, seleccionada por
> **ventana de direcciones**, no por el atributo de la page table. Los accesos
> a `0x8xxxxxxx` pasan por la L2; los de `0xCxxxxxxx`/`0xDxxxxxxx` la saltean.

Con eso, el alias es invisible en las dos direcciones:

```
escribo 0x88000000 -> queda sucio en L2;  leo 0xc8000000 -> DRAM, valor viejo
escribo 0xc8000000 -> va a DRAM;          leo 0x88000000 -> hit de línea vieja en L2
```

**Mapear con `O_SYNC` no alcanza** (el script viejo lo hacía), y **tampoco
alcanzan `sync_for_cpu`/`sync_for_device` de u-dma-buf**: esos operan sobre
las cachés propias del core, no sobre la L2 memory-side. Una segunda versión
del test que usaba ese dance siguió reportando "independent".

Dos cosas sí funcionan, y el test definitivo usa ambas:

1. **Comparar las dos ventanas non-cached entre sí** (`nc0` vs `wcb0`): ninguna
   pasa por la L2, así que no hay nada que pueda esconder el alias. Dio
   `ALIASED` de entrada.
2. **Forzar desalojo real**: barrer >2 MB (el tamaño de la L2) de *otras*
   direcciones cached entre la escritura y la lectura. Con eso `c0` ↔ `nc0`
   también dio `ALIASED` en ambas direcciones.

El dato más elocuente: al desalojar, **los magics de la corrida anterior
aparecieron retroactivamente** en la otra ventana. Siempre habían aliaseado;
solo estaban escondidos en la L2.

### El device tree lo corroboraba desde el principio

```
region@84000000   0x04000000  (reservado, ventana cached)
buffer@88000000   0x02000000  (reservado, ventana cached)
memory@c4000000   0x06000000  (RAM usable, ventana non-cached)
buffer@c8000000   0x02000000  (reservado, ventana non-cached)
```

64 MB + 32 MB reservados del lado cached = exactamente los 96 MB que
`memory@c4000000` le entrega a Linux del lado non-cached. Cada ventana tiene
reservado en la otra lo que la otra usa. Es un mapa aliaseado **por diseño**;
no hay nada roto en el reference design, solo una suposición nuestra.

## El fix

Puramente de software, sin tocar RTL ni rebuildear:

`mem_codes.v` con `MP_AT_HL` termina el framestore en
`END_OF_MEM = 22'h1effff` words × 8 = `0xf7fff8` ≈ **15.5 MB** de los 32 MB.
La mitad superior está libre. `DMA_ADDR` ya está definido como offset de bytes
dentro de `STAGING_BASE`, así que alcanza con stagear en **+16 MB**:

```python
STAGE_OFFSET = 0x1000000   # 16 MB
FRAMESTORE_END = 0xF7FFF8

assert STAGE_OFFSET > FRAMESTORE_END, \
    "staging would land inside the decoder's framestore -- they share DRAM"
```

(Ese assert se ganó el sueldo en el acto: atrapó un dígito de más que yo había
puesto al calcular `END_OF_MEM`.)

## Resultado en hardware

A/B directo, mismo stream, misma sesión, solo cambiando el offset de staging:

| | staging @0 (como estaba) | staging @16 MB |
|---|---|---|
| `SIZE` | 0 x 0 | **720 x 480** |
| VBUF vs archivo | 2890/4096 | **4096/4096** |
| `FRAME_0_Y` | mezcla de stream + `0x80` | `0x80` limpio, 4096/4096 |

Y con un segundo stream, `sony-ct1.bits`: **`SIZE` = 352 x 224**, que es
exactamente lo que dice su sequence header (`000001b3 1600e0…` →
`horizontal_size=0x160=352`, `vertical_size=0x0e0=224`). El de `tcela-17`
también coincide con el suyo (`2d01e0` → 720 × 480).

En la mejor corrida el decoder quedó **estable 10 segundos** con
`SIZE=720x480`, `error=0`, `watchdog=0`, `picture_hdr` visto y `frame_end`
pulsando en cada lectura — o sea el display path barriendo frames.

## Lo que NO quedó arreglado

**`SIZE` sigue siendo intermitente entre resets.** Seis corridas de
`tcela-17`, cada una con reset limpio del core:

```
trial0: SIZE=    0x0     VBUF match=4096/4096
trial1: SIZE=    0x0     VBUF match=4096/4096
trial2: SIZE=  720x480   VBUF match=4096/4096
trial3: SIZE=    0x0     VBUF match=4096/4096
trial4: SIZE=    0x0     VBUF match=4096/4096
trial5: SIZE=  720x480   VBUF match=4096/4096
```

Con `sony-ct1` aparecen además valores de basura (`4448x8416`, `1157x3437`).

Pero la bisección es limpia y es el resultado más útil de la sesión: **el VBUF
sale byte-perfecto en las seis, incluidas las cinco que fallan.** El camino de
memoria quedó correcto y determinista. Lo que queda está **aguas abajo del
VBUF**: en la relectura `vbuf → getbits → vld`, no en DRAM ni en el bridge.

Ahí arranca la próxima fase, y por primera vez sobre una base de memoria
confiable.

## Cambios

Rama `firmware_development` (commit `74b3a4c`):

- `webserver/dma_push.py` — `STAGE_OFFSET = 0x1000000`, assert contra
  `FRAMESTORE_END`, chequeo de overflow del buffer, `sync_for_device` con
  offset y redondeo a página.
- `webserver/ddr_region.py` — el docstring decía justo lo contrario de la
  realidad; reescrito con el mapa real, la trampa de la L2 y las consecuencias
  para cualquiera que escriba en estas regiones.
- `webserver/check_ddr_alias.py` — **nuevo**, el test correcto, dejado
  ejecutable para re-verificar después de cualquier cambio de device tree,
  configuración de segmentos DDR del MSS, o `DDR_BASE`/`STAGING_BASE`.
- `webserver/write_test_pattern.py` — aviso: `nc-wcb0` no es scratch, es el
  framestore con otro nombre.

## Pendiente de decidir

El fix vive en software, sostenido por una convención de offset. La alternativa
más robusta es mover `STAGING_BASE` en RTL fuera del rango del framestore, para
que el hardware no pueda pisarse a sí mismo aunque el software se equivoque.
Ojo si se hace: `STAGING_BASE` es un `parameter` y `0x89000000` no entra en un
int de 32 bits con signo — es exactamente la trampa de Libero del doc 30. Usar
`localparam` si queda en el borde de un core HDL+, y verificar en el `.srr`.

## Lecciones

1. **Un test de aliasing de memoria que no controla la caché no prueba nada.**
   Y en una arquitectura con caché memory-side, "controlar la caché" no
   significa las APIs de mantenimiento del CPU: significa desalojo real, o
   elegir dos ventanas que no pasen por la caché.

2. **Un docstring equivocado es peor que ausente.** "Three regions deliberately
   kept separate" se leyó como hecho verificado durante toda la Fase 7a, y
   sacó el alias de la lista de sospechosos justo cuando era el culpable.
   Se cruza con [08](08_fase5c_pin_lock_bootloop_fix.md) y con el doc 30: dos
   veces ya, el bug no estuvo en la lógica sino en algo que dábamos por sabido.

3. **El device tree ya tenía la respuesta.** La aritmética de
   `region@84000000` + `buffer@88000000` = `memory@c4000000` estaba a un `od`
   de distancia y no se miró hasta el final. Antes de sondear el hardware,
   leer lo que el sistema ya declara sobre sí mismo.
