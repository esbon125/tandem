# Fase 7a — el fix de AXI4 funciona en hardware real (primera escritura completada del proyecto), y un bug nuevo: el reset por watchdog deja el fabric trabado

**Fecha:** 2026-08-23
**Rama:** `hardware_development` (sin cambios de RTL en esta sesión, sólo verificación e investigación)

Continuación inmediata de `22_fase7a_xfifo_multidriver_and_axi4_bif_fix.md`. Con
los commits `2efc5eb` (fix de `xfifo_dc.v`) y `7e97458` (fix del wiring AXI4/bif de
SmartDesign) ya en `hardware_development`, esta sesión hizo el ciclo completo de
PLACEROUTE→PROGRAM y probó en hardware real.

## El fix del bif funciona: primera escritura AXI4 completada del proyecto

En un boot limpio (recién programado, sin ningún push todavía), los registros de
debug mostraron:

- `dbg_last_write_addr_from_fifo = 0x1efffe` (= `VBUF_END`)
- `dbg_last_write_awaddr_issued = 0xc8f7fff0`
- `arbiter_flags`'s `state = 4` (`STATE_IDLE`)

`0xc8f7fff0` es exactamente `DDR_BASE (0xc8000000) + VBUF_END (0x1efffe) * 8` —
coincidencia exacta. Esto no es inferencia por contadores: es una dirección AXI
real, aceptada (`awvalid && awready`), coincidiendo con la última palabra del
barrido de `STATE_CLEAR`. **`STATE_CLEAR` completó el barrido de toda la memoria
`VBUF` y el arbiter llegó limpio a `STATE_IDLE` — la primera vez que esto pasa en
la historia del proyecto**, hasta donde se pudo determinar (la evidencia previa
de "las escrituras andan" sólo probaba que el contador interno de
`framestore_request.v` avanzaba, no que `mem2axi_bridge` completaba transacciones
AXI reales — ver `22_...md`).

## Bug nuevo: un reset por watchdog dentro de un push activo deja el path de escritura trabado para siempre

Con la placa recién booteada y limpia, se intentó un push real de stream
(`sony-ct1.bits`, vía `dma_push.py`). El push se traba a los 1385 bytes (mismo
punto de antes) y `STATUS` muestra `watchdog_status=True` — el watchdog se
disparó (el VLD sigue trabándose en algún punto — la pregunta *original*, más
vieja, de esta investigación Fase 7a, recién alcanzable ahora que la capa de
memoria funciona).

Un watchdog dispara un reset del decoder, que vuelve el arbiter a
`STATE_INIT`→`STATE_CLEAR` — pero **esta vez, a diferencia del barrido limpio del
boot, `mem_req_wr_almost_full` queda pegado en `1` y `state` queda pegado en `2`
(`STATE_CLEAR`) por 30+ segundos seguidos, sin ningún movimiento** (confirmado
con polling cada 0.5s — no es lentitud, es un stall real).

### Teoría descartada: ancho del pulso de `watchdog_rst`

`watchdog_rst` (`watchdog.v`) es un pulso de un solo ciclo de clock, a diferencia
del reset de power-on (`async_rst`), sostenido mucho más tiempo. La hipótesis
inicial fue que ese pulso corto no alcanza para resetear del todo los
sincronizadores internos de CoreFIFO (la misma zona del bug de `xfifo_dc.v`
arreglado ayer). **Descartada al leer `reset.v`**: el diseño upstream (sin tocar)
ya combina el reset por watchdog con el de power-on y lo hace pasar por **tres
etapas** de un `sync_reset` (`synchronizer.v`) que garantiza un mínimo de 4
ciclos cada una, por cada dominio de reloj — machinery legítima, documentada
explícitamente para este propósito exacto ("reset must be high for at least
three read clock and three write clock cycles", citando el spec de las FIFO18/36
de Xilinx). No es un problema de ancho de pulso.

### Hipótesis actual, sin confirmar: transacción AXI4 huérfana en `stream_dma.v`

`stream_dma.v` tiene su propio master AXI4 de **lectura**, completamente
independiente del master de **escritura** de `mem2axi_bridge` (`FIC_1_AXI4_TARGET`
vs `FIC_2_AXI4_TARGET` de la MSS). Si el watchdog dispara mientras `stream_dma`
tiene una transacción de lectura en vuelo (`state==S_RDATA`, ya con `ARREADY`
recibido y a mitad de un burst de `RVALID`/`RDATA`), el FSM de `stream_dma`
vuelve a `S_IDLE` (mismo dominio `clk_rst`, sí se resetea) — pero el
interconnect/controlador de DDR del lado de la MSS podría seguir esperando que
ese master termine de consumir el burst. Si `FIC_1` y `FIC_2` comparten
arbitraje u orden dentro del mismo puerto de controlador DDR en la MSS (plausible,
no confirmado), una lectura abandonada a mitad de burst en `FIC_2` podría trabar
el recurso compartido indefinidamente, bloqueando también las escrituras de
`FIC_1` — explicando exactamente lo observado (las escrituras no avanzan nada
después de este tipo específico de reset, pero sí después de un reset de
power-on limpio que nunca tuvo una transacción DMA en vuelo para abandonar).

**Experimento pendiente, no hecho todavía**: empujar el stream por el path
byte-a-byte (`decoder_push.py`, que nunca toca `stream_dma.v`/`FIC_2`) y dejar
que el watchdog dispare solo, para ver si el stall post-watchdog en
`STATE_CLEAR` se reproduce SIN que `stream_dma` haya estado nunca activo. Es el
experimento aislante limpio — barato (no hace falta rebuild ni reprogramar, sólo
la placa en estado limpio).

## Hallazgo operativo útil: `reboot` por Linux resetea el fabric

Un simple `ssh ... reboot` (reinicio de Linux, no reprogramación de la FPGA)
**sí** resetea el decoder/fabric a un estado limpio — confirmado: después del
reboot, `state=4` (`STATE_IDLE`), `watchdog_status=False`,
`mem_req_wr_almost_full=False`, igual que un boot recién programado. Mucho más
barato que un ciclo completo de reprogramación de Libero para volver a un estado
limpio entre experimentos, mientras el bitstream no cambie.

## Estado al cierre

- Ambos fixes de esta investigación (`2efc5eb`, `7e97458`) están **confirmados
  funcionando en hardware real** — progreso real y durable.
- Bug nuevo, distinto, todavía sin RTL tocado: el stall post-reset-por-watchdog
  en `STATE_CLEAR`. Próxima sesión: correr el experimento aislante
  (`decoder_push.py`, sin DMA) antes de asumir que la hipótesis de
  `stream_dma`/FIC_2 es correcta.
