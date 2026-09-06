# Fase 7c — push end-to-end real, y un hallazgo nuevo: el VLD se traba (watchdog reset)

**Fecha:** 2026-08-20
**Rama:** `hardware_development` (sin cambios de RTL en esta sesión, sólo investigación)

Continuación inmediata de `20_fase7c_pwdata_root_cause_fix.md`. Con el fix de PSTRB
confirmado, esta sesión hizo la prueba que faltaba: un push real de un elementary
stream completo por el path de DMA, para ver si el decoder al menos corre (aunque
sea mal) — y encontró una pista concreta para la investigación de Fase 7a
("SIZE=0"), que estaba parada desde hace varias sesiones.

## Push end-to-end: el control DMA funciona perfecto

`python3 dma_push.py greyramp.mpg` (621965 bytes, stream sintético ya usado en
sesiones anteriores):

```
antes:    {'version': 12, 'status': 4, 'size': 0, 'disp_size': 0}
después:  {'version': 12, 'status': 4, 'size': 0, 'disp_size': 0, 'dma_bytes_done': 621997}
transferidos 621965 bytes en 0.0186s (32.7 MB/s)
```

`dma_bytes_done` coincide con el stream + el padding de `sequence_end_code` que
`stream_dma.v` agrega solo (igual que hacía `decoder_push.py` en software) — el
control DMA (`DMA_ADDR`/`DMA_LEN`/`DMA_CTRL`/`DMA_STATUS`) está confirmado
funcionando end-to-end, a ~185x el throughput del push byte-a-byte de Fase 7a
(177 KB/s). Esto era el objetivo de esta sesión y quedó validado.

`size`/`disp_size` siguen en `0` tanto antes como después (reconfirmado con 1s
extra de espera, no es una carrera de timing) — la investigación "SIZE=0" de
Fase 7a, parada por decisión explícita del usuario en una sesión anterior, sigue
abierta. Lo nuevo de hoy es que se investigó un poco más, con resultado concreto.

## ¿Llegan los bytes al decoder? Sí — confirmado con testpoint 0

`mpeg2video`/`probe.v` ya trae un mecanismo de "logic analyzer" propio del
upstream (`testpoint[33:0]`, seleccionable por software escribiendo el registro
15 del regfile — `REG_WR_TESTPOINT`, `reg_dta_in[31:28]` selecciona cuál de 14
"testpoints" predefinidos se expone; se lee con `REG_RD_TESTPOINT`, mismo
índice 15). No hizo falta ningún cambio de RTL para esto — ya estaba expuesto.

Testpoint 0 ("incoming video") trae `stream_data`/`stream_valid`/`busy` entre
otras señales. Seleccionándolo y haciendo 2000 lecturas rápidas por APB durante
un push:

- 349 valores únicos de 2000 muestras, **ninguna en cero** — actividad real y
  variada, no un valor estático/idle.

**Advertencia importante sobre `testpoint`**: no es un snapshot estable. El
`case` en `probe.v` rota el valor 1 bit por ciclo (`testpoint_0_7 <= {testpoint_0[0], testpoint_0[32:1]}`)
— está diseñado para que un analizador lógico externo capture muchos ciclos
*consecutivos* de `clk` y reconstruya el word original por correlación, no para
que una lectura APB aislada (que ocurre en una fase de rotación arbitraria,
sin relación con `core_clk`) muestre un campo específico de forma confiable.
Sirve como señal cualitativa de "hay actividad" pero no para aislar bits
individuales (como `stream_valid`) sin instrumentación nueva.

## La pista real: STATUS muestra watchdog_status=1 tras el push

`regfile.v`'s `STATUS` (dirección 1) tiene varios bits *sticky hasta que se lee*:
`picture_hdr`, `frame_end`, `video_ch`, `error`, `watchdog_status`, entre otros.
Se confirmó el comportamiento sticky-clear con una doble lectura limpia antes del
push (`0x4` → `0x0`), y después del push:

```
status = 0x84
  watchdog_status = 1   (bit 7)
  frame_end       = 1   (bit 2)
  picture_hdr      = 0   (bit 3)
  video_ch         = 0   (bit 1)
  error            = 0   (bit 0)
```

`watchdog_status` prendido significa que **el watchdog timer expiró y reseteó el
decoder** (`watchdog.v`, comentario de cabecera):

> "The decoder is reset if the variable length decoding is inactive for
> 256\*256\*16\*(repeat_frame+1)\*(watchdog_interval+1) clock cycles. The watchdog
> timer begins to run if the decoder asserts busy."

Con los valores por defecto (`repeat_frame=0`, `watchdog_interval=0`) eso es
~1,048,576 ciclos de `core_clk` — a las decenas de MHz típicas de este diseño,
del orden de 20-30 ms. El push completo (DMA + margen de sobra, se esperó 500ms
antes de leer `STATUS`) deja tiempo más que suficiente para que el watchdog ya
haya disparado si el VLD se trabó.

**Interpretación**: el decoder sí arranca (`busy` se activa — de hecho el
watchdog sólo corre si `busy` está alto, así que su expiración por sí sola ya
confirma que `busy` se activó), pero el **VLD (variable-length decoding, el
parser del bitstream MPEG-2) deja de hacer progreso y nunca se recupera**, hasta
que el watchdog lo resetea. Esto explica por qué `SIZE`/`DISP_SIZE` quedan en 0:
el reset borra cualquier estado parcial antes de que el software llegue a
leerlo. También explica por qué ni siquiera `picture_hdr` se prende — sugiere
que el trabe ocurre muy temprano, posiblemente durante el parseo del
`sequence_header` mismo, antes de llegar a un picture header.

(`frame_end` prendido probablemente no es señal de éxito: el comentario dice
"set when displaying pixel 0 de line 0", que muy probablemente lo genera el
generador de timing de video (`syncgen.v`) de forma periódica en cuanto
`dot_clk` está corriendo, independientemente de si hay contenido decodificado
real — no se investigó a fondo, marcado como probable falso positivo.)

## Qué queda para la próxima sesión

El foco de la investigación de Fase 7a cambia de "¿llegan los bytes?" (confirmado
que sí) a **"¿dónde exactamente se traba el VLD, y por qué?"**. Ideas para la
próxima sesión, sin haberlas intentado todavía:

1. Instrumentar `getbits.v`/`vld.v` con un registro sticky dedicado (mismo patrón
   que `pwdata_sticky_r` de la sesión anterior) en vez de depender del
   `testpoint` rotativo — por ejemplo, capturar el primer valor de
   `getbits`/`vld_en`/`dct_coeff_wr_*` que se quede "pegado" (sin cambiar) una
   vez que `busy` lleva mucho tiempo alto sin que `picture_hdr` se prenda.
2. Revisar si `greyramp.mpg` específicamente tiene algo atípico en su
   `sequence_header` (probarlo contra otro stream, como
   `toshiba_DPall-0.mpg` o alguno de los streams de conformidad en
   `tools/streams/`, para descartar un problema específico del archivo).
3. Correr el mismo stream contra la simulación Icarus Verilog
   (`bench/iverilog`, ya validada en el flujo de este repo) para ver si el
   MISMO trabe reproduce en simulación — si sí, es mucho más fácil de depurar
   con acceso completo a señales internas sin pasar por SmartDebug/testpoint.
4. Revisar `watchdog_interval` -- está en su valor por defecto (0, el timeout
   más corto posible); subirlo temporalmente (vía `REG_WR_STREAM`,
   `reg_dta_in[15:8]`) daría más margen para descartar que el trabe sea
   simplemente "más lento de lo que el watchdog tolera" en vez de un stall real
   sin progreso.

## Comandos usados esta sesión (referencia rápida)

```python
# seleccionar testpoint 0 y ver actividad de stream_data/stream_valid/busy
REG_TESTPOINT = 0x400 + 0x3C  # dirección 15
p._write_reg(REG_TESTPOINT, 0x00000000)  # selecciona testpoint 0

# limpiar y leer STATUS de forma confiable
REG_STATUS = 0x400 + 0x04
p._read_reg(REG_STATUS)  # primera lectura: limpia sticky bits viejos
p._read_reg(REG_STATUS)  # segunda lectura: debería dar 0 si el clear funcionó
```
