# Fase 7a: el VLD se saltea el primer start code

Continuación de
[32_fase7a_que_cambia_cuando_no_decodifica.md](32_fase7a_que_cambia_cuando_no_decodifica.md).
Ese doc cerró todo lo externo y concluyó que faltaba observabilidad dentro de
`vld.v`. Esto la construye, y la respuesta salió en la primera medición.

## Por qué `vld_err` no podía responder esto

Duda razonable: si el VLD falla, ¿no debería ponerse el bit `error`? El RTL
dice que no:

```verilog
if (~rst) vld_err <= 1'b0;
else if (clk_en && (state == STATE_NEXT_START_CODE)) vld_err <= 1'b0;   // se limpia en CADA start code
else if (clk_en && ((state == STATE_ERROR) || (state == STATE_DCT_ERROR))) vld_err <= 1'b1;
```

`vld_err` solo se pone en 1 en `STATE_ERROR`/`STATE_DCT_ERROR` -- errores de
slice/DCT, que el propio header describe como "self-repairing" -- y se **borra
en cada pasada por `STATE_NEXT_START_CODE`**. No existe un estado de error para
"nunca encontré un sequence header": el FSM simplemente sigue buscando. Así que
`error=0` siempre fue compatible con `SIZE=0` y no probaba nada. Las lecturas
previas de "error=0, el VLD está bien" eran demasiado optimistas.

## La instrumentación

Cuatro palabras leíbles por APB (bridge 0x21-0x24), dominio `clk`, sin CDC,
reseteadas por `sync_rst` para que describan la sesión actual del core:

| reg | contenido |
|---|---|
| `VLD_DBG0` | `state` actual, cuántos start codes se capturaron, y un **bitmap sticky de todos los estados del FSM alguna vez visitados** (16) |
| `VLD_DBG1` | los **primeros cuatro bytes de start code** sobre los que despachó `STATE_START_CODE` |
| `VLD_DBG2` | el **`getbits` crudo capturado al primer ingreso a `STATE_SEQUENCE_HEADER`** -- los bits exactos con los que carga `horizontal_size` |
| `VLD_DBG3` | contador de start codes, y los flags `sequence_header_seen`/`sequence_extension_seen`/`picture_header_seen`/`vld_err` |

Todo aditivo: registros nuevos que alimentan una salida, nada realimenta al
FSM.

## El resultado

20 corridas de `tcela-17.bits`, cada una con reset limpio. **Discriminador
perfecto:**

```
PASS  SIZE=720x480   start codes: b3 00 f5 b5     getbits@seq_hdr = 0x2d01e0
PASS  SIZE=720x480   start codes: b3 b5 00 b5     getbits@seq_hdr = 0x2d01e0
FAIL  SIZE=0x0       start codes: b5 b2 b5 68     getbits@seq_hdr = (nunca)
FAIL  SIZE=0x0       start codes: b5 02 07 09     getbits@seq_hdr = (nunca)
...
```

| | primer start code despachado | `getbits` @ `STATE_SEQUENCE_HEADER` |
|---|---|---|
| **PASS** 10/10 | `b3` -- el primer byte real del stream | `0x2d01e0` exacto = 720 x 480 |
| **FAIL** 10/10 | `b5` (×9), `68` (×1) -- **nunca `b3`** | nunca capturado |

`b5` es `CODE_EXTENSION_START`: el **sequence extension**, que es el *segundo*
start code del stream (`000001b3 …` seguido de `000001b5 …`).

**En un push que falla, el VLD se saltea el primer start code y arranca en el
siguiente.** Nunca entra a `STATE_SEQUENCE_HEADER`, así que `horizontal_size`
nunca se carga y `SIZE` queda en su valor de reset. Y todo lo demás sigue
idéntico: `vbuf_rd` consume las mismas 1578 palabras, el VBUF en DRAM está
byte-perfecto, sin watchdog, sin `vld_err`.

## Corrige el modelo de la hipótesis 3, y luego se corrige a sí mismo

El doc 32 descartó "se come el arranque del stream" porque anteponer stuffing
de ceros no cambiaba la tasa. Primera lectura de este hallazgo: el descarte era
correcto pero el modelo estaba mal -- no se saltea una cantidad fija de bytes
sino *el primer start code, esté donde esté*, así que el padding nunca podía
ayudar.

**Esa segunda explicación tampoco sobrevive.** Repitiendo el experimento de
padding ahora que hay instrumentación (mismo bitstream, sin rebuild):

```
--- 1024 bytes de padding ---
  PASS  start codes = 10 10 b3 b5    b3 presente=si
  PASS  start codes = 10 10 10 b3    b3 presente=si
  FAIL  start codes = 10 b5 a3 a3    b3 presente=NO
  FAIL  start codes = 10 10 10 b2    b3 presente=NO
  FAIL  start codes = 10 10 b5 b5    b3 presente=NO
```

Con padding, el **primer** despacho es `10` tanto en PASS como en FAIL (9 de 10
corridas), así que el primer start code ya no discrimina nada. La divergencia
ocurre más adelante, e incluso el número de despachos previos difiere
(`10 10 10 b3` contra `10 10 b5`).

Lo que sí es exacto en las 10 corridas con padding y en las 20 sin padding:

> **PASS ⟺ el VLD despacha sobre `b3`. FAIL ⟺ nunca lo hace, y en su lugar
> aparece `b5`.**

Sin padding esa ley se ve como "se saltea el primer start code" simplemente
porque ahí `b3` *es* el primero.

### Medido contra la secuencia real del archivo

`tcela-17.bits` tiene 74 start codes; los primeros son
`b3`(0), `b5`(140), `b2`(150), `b5`(225), `b8`(237), `00`(245).

- Un PASS despachó `b3 b5 b2 b5` = start codes **#1 #2 #3 #4**.
- Un FAIL despachó `b5 b2 b5 b8` = start codes **#2 #3 #4 #5**.

O sea, en el caso limpio el FAIL sigue la secuencia real del stream
correctamente, salvo que **omite exactamente el #1**.

### Lo que queda sin explicar del caso con padding

De dónde sale `10` como primer código despachado. El padding es todo ceros y el
primer bit en 1 del stream es el del `0x01` del prefijo, así que la búsqueda de
23 ceros + 1 debería aterrizar en `b3`. Que aparezca `10` (y `a3`, `28`, `f5`,
`68`, `70` más adelante, que no son start codes válidos en esas posiciones)
indica que el VLD atraviesa tramos desalineados. No está explicado y conviene
no construir sobre eso todavía.

## Qué queda por determinar

Por qué el despacho sobre `b3` se pierde.

La hipótesis del arranque de `getbits` (necesita **dos** palabras antes de
pasar de `STATE_INIT` a `STATE_READY`, `cursor` arranca en 128 y baja de a 64)
explicaría el caso sin padding, donde `b3` está en la palabra 0. **Pero no
explica el caso con padding**, donde `b3` cae 1024 bytes adentro, muchísimo
después de cualquier ventana de arranque, y aun así se pierde la mitad de las
veces. Así que hay algo que desalinea al VLD de forma recurrente, no solo al
arrancar -- consistente con los códigos espurios (`10`, `a3`, `f5`, `68`) que
aparecen en ambas clases.

La instrumentación siguiente, entonces, ya no debería mirar solo el arranque.
Lo que hace falta, todo del mismo estilo sticky y barato:

1. El primer `getbits` **al salir de `STATE_INIT`** (se captura en PASS y en
   FAIL, a diferencia del actual `VLD_DBG2` que solo se llena si se llega al
   sequence header): dice si la ventana arranca alineada.
2. El `state` de `vld` en el ciclo en que `getbits_valid` sube por primera vez:
   separa "ventana desalineada" de "el FSM llegó tarde".
3. Un contador de cuántas veces el FSM entra en `STATE_NEXT_START_CODE`
   comparado con cuántas llega a `STATE_START_CODE`: si difieren, la búsqueda
   está encontrando patrones que después descarta, que es lo que sugieren los
   códigos espurios.

## Cambios

Rama `hardware_development`:

- `e02f9e8` -- los cuatro registros de debug (`vld.v`, `mpeg2video.v`,
  `mpeg2fpga_apb_peripheral.v`, `apb3_mpeg2fpga_bridge.v`), más 5 checks nuevos
  en `bench/apb_bridge/testbench.v` (51/51), incluido uno que verifica que
  `0x22` ahora lo decodifica el bridge en vez de aliasear a `reg_addr 2`.
- `90e1a9a` -- el fix de CDC de `pixel_queue` (ver doc 32).

Pipeline completo desde proyecto limpio (`rm -rf soc_build/MPEG2FPGA_SOC`
primero, ver [[libero_build_script_gotchas]]): SYNTHESIZE, PLACEROUTE (29.6
min, "Router completed successfully"), VERIFY_TIMING ("Timing constraints have
been met"), GENERATE_PROGRAMMING_DATA, PROGRAM ("Chain programming PASSED").
Verificado que los registros llegaron al netlist: 146 apariciones de
`dbg_visited` en `MPFS_DISCOVERY_KIT.vm`.

`bench/iverilog` sigue reconstruyendo 8 frames, igual que antes del cambio.

## Nota operativa

El overlay UIO (`mpeg2fpga-uio.dtbo`) **no sobrevive un reboot**. Después de
reprogramar y rebootear hay que reaplicarlo antes de que cualquier script
encuentre el device:

```sh
mkdir -p /sys/kernel/config/device-tree/overlays/mpeg2fpga
cat /root/webserver/mpeg2fpga-uio.dtbo > /sys/kernel/config/device-tree/overlays/mpeg2fpga/dtbo
```
