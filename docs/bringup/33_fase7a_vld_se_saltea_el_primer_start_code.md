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

## Corrige el modelo de la hipótesis 3

El doc 32 descartó "se come el arranque del stream" porque anteponer stuffing
de ceros (8 a 1024 bytes) no cambiaba la tasa. El descarte era correcto pero el
modelo estaba mal: **no se saltea una cantidad fija de bytes, se saltea el
primer start code, esté donde esté.** Con 1024 ceros adelante el VLD igual cae
en el `b5`, porque el `b3` sigue siendo el primer start code y sigue siendo el
que se pierde. Por eso el padding no podía ayudar.

Es una carrera de arranque: el FSM no está en condiciones de procesar el primer
start code cuando llega.

## Qué queda por determinar

Por qué se pierde ese primer despacho. Candidatos, en orden de lo que sugiere
la evidencia:

1. `getbits_fifo` necesita **dos** palabras antes de pasar de `STATE_INIT` a
   `STATE_READY` (`cursor` arranca en 128 y baja de a 64 por palabra). El
   primer start code está en la palabra 0. Si `vld` empieza a buscar antes de
   que la ventana esté válida, o si `getbits_valid` llega tarde respecto del
   arranque del FSM de `vld`, el primer 00 00 01 pasa sin ser despachado.
2. Algo en el arranque de `vbr_rd_valid` desde el `vbuf_read_fifo` (`fifo_sc`,
   mono-reloj, así que **no** es CDC).

La instrumentación para el paso siguiente es barata y del mismo tipo: capturar
de forma sticky el primer valor de `getbits` **al salir de `STATE_INIT`**, y el
`state` de `vld` en el ciclo en que `getbits_valid` sube por primera vez. Eso
distingue "la ventana arrancó desalineada" de "la ventana estaba bien pero el
FSM llegó tarde".

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
