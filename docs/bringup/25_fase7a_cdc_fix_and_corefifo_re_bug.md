# Fase 7a: fix de drenaje gracioso confirmado en hardware, bug de reset CDC en CoreFIFO encontrado y arreglado, y causa raíz real aislada y reproducida en simulación

Continuación directa de `24_fase7a_fwft_fix_and_axi4_interconnect_wedge.md`. Ese documento cerraba
con la hipótesis de que el watchdog, al resetear `stream_dma.v` a mitad de una ráfaga AXI4, abandonaba
la transacción y dejaba el interconnect FIC_2 wedgeado. Esta sesión confirma esa hipótesis, la arregla,
encuentra un segundo bug real (esta vez en el reset de las CoreFIFO dual-clock), lo arregla también, y
finalmente aísla y reproduce en simulación rápida la causa raíz real del stall de DMA — que resulta ser
una tercera cosa distinta a ambas hipótesis anteriores.

## 1. Fix de drenaje gracioso en `stream_dma.v` y `mem2axi_bridge.v`

Reproducido primero en simulación barata (`bench/stream_dma/testbench_wedge.v`,
`bench/mem_axi_bridge/testbench_wedge.v`): resetear el módulo a mitad de una transacción AXI4 en curso
(`stream_dma`: `S_AR`/`S_RDATA`; `mem2axi_bridge`: `S_WRITE`/`S_BRESP`/`S_ARADDR`/`S_RDATA`) abandona
esa transacción — el slave queda esperando un `RREADY`/`BREADY` que nunca más llega, wedgeado para
siempre (o, en el caso de escritura, el slave del testbench queda desincronizado con el master).
Confirmado con el modelo de DDR fake (`fake_axi_ddr_ro.v`/`fake_axi_ddr.v`) sin resetear junto al DUT
— igual que en hardware real, donde FIC_1/FIC_2 y el controlador DDR no están en el dominio de reset
del watchdog.

**Fix**: ambos módulos ganaron un puerto `watchdog_rst` separado del reset externo crudo (`rst_n`/
`rst`). Cuando el watchdog dispara mientras hay una transacción AXI4 comprometida, el FSM sigue
sirviendo el protocolo (termina el handshake pendiente, drena el resto de la ráfaga descartando los
datos e ignorando `mpeg_busy`/backpressure) en vez de resetearse de inmediato, y recién entonces va a
idle sin pulsar `done`. `mem2axi_bridge.v` corre en `mem_clk`, no en el mismo clock que `watchdog.v`
(`clk`), así que `reset.v` ganó dos salidas nuevas — `mem_hard_rst` (reset externo puro, sincronizado
a `mem_clk`) y `mem_watchdog_rst` (pulso del watchdog, sincronizado a `mem_clk`) — espejando el patrón
que ya existía para `hard_rst` en dominio `clk`.

**Verificado en simulación**: `stream_dma`: 2 escenarios (mid-`S_RDATA`, mid-`S_AR`), ambos recuperan.
`mem2axi_bridge`: 4 escenarios (mid-`S_WRITE`, mid-`S_BRESP`, mid-`S_ARADDR`, mid-`S_RDATA`), los 4
recuperan.

**Verificado en hardware real** (rebuild completo, PROGRAM PASSED, reboot limpio, `diag_full_trace.py`
con `tcela-17.bits`): `stream_dma_rvalid` ya no queda pegado en `True` tras el watchdog — vuelve a
`False` la misma iteración en que `stream_dma_state` vuelve a `S_IDLE`. `dbg_last_write_awaddr_issued`/
`dbg_last_write_addr_from_fifo` ya no muestran el patrón de corrupción ("lee un `0` aritméticamente
imposible dado `DDR_BASE=0xc8000000`") que antes probaba que `mem2axi_bridge` se reseteaba de nuevo sin
drenar.

**Pero el stall de DMA sigue exactamente igual**: `bytes_done` se congela en 1385, `mem_req_wr_almost_full`
queda en `True` para siempre, `arbiter_state` en `STATE_CLEAR`, el watchdog dispara en loop cada ~0.8s
sin recuperar nunca. El wedge de AXI4 era real y ahora está arreglado, pero era un síntoma río abajo
que el watchdog exponía al disparar repetidamente — no la causa del stall en sí.

## 2. Bug de reset CDC en las CoreFIFO dual-clock

El usuario, viendo que el fix anterior no resolvía nada, pidió revisar específicamente la lógica de
`CoreFIFO.v` y su interfaz con `framestore_request` — "es lo único que cambia respecto al diseño
original" (el puerto de Xilinx a CoreFIFO).

Revisando `corefifo_async.v` (el controlador dual-clock real, generado con nuestros parámetros
`SYNC:0`/`SYNC_RESET:1`): el write pointer se resetea síncronamente con `sresetn_wclk` (muestreado en
`WCLOCK`), el read pointer con `sresetn_rclk` (muestreado en `RCLOCK`). En esta configuración de
parámetros **no hay ningún resincronizador interno** entre esas dos señales — el submódulo que lo
haría (`corefifo_resetsync`) está comentado/muerto en el `COREFIFO.v` generado. CoreFIFO asume que
quien lo instancia ya entrega cada reset sincronizado a su propio clock.

`framestore.v`'s dos FIFOs dual-clock (`mem_request_fifo`: `wr_clk=clk`/`rd_clk=mem_clk`;
`mem_response_fifo`: al revés) recibían **una sola señal `rst`** (el `sync_rst` de mpeg2video,
sincronizado solo a `clk`) para `WRESET_N` *y* `RRESET_N` a la vez, vía `xfifo_dc.v`. Para
`mem_request_fifo`, eso significa que el read pointer del lado `mem_clk` recibía un reset cuyo
momento de liberación no tiene relación de timing definida con `mem_clk` — una violación de CDC
clásica que podría dejar ese pointer (o su versión sincronizada hacia el lado de escritura, que
alimenta el comparador de `AFULL`) en un estado inconsistente al liberar el reset.

Nota: `dpram_dc` (la RAM dual-clock del proyecto, usada en `osd.v`) ya tenía el split `wr_rst`/`rd_rst`
correcto desde antes — `fifo_dc`/`xfifo_dc` (agregado después) no seguía la misma disciplina.

**Fix**: `wrappers.v` y `xfifo_dc.v` separan el puerto único `rst` en `wr_rst`/`rd_rst`. `framestore.v`
ganó un puerto real `mem_rst` (el reset combinado de mpeg2video ya sincronizado a `mem_clk`, que
existía internamente pero nunca se pasaba a este módulo) y ambas FIFOs reciben el reset correcto en
cada lado según qué reloj tienen ahí. `pixel_queue.v` (cruce `clk`↔`dot_clk`, mismo tipo de bug
probablemente, no investigado) se actualizó mecánicamente a los nuevos nombres de puerto sin cambiar
su comportamiento — queda fuera de alcance para una próxima sesión.

## 3. Instrumentación: ¿la FIFO está realmente llena?

Pedido explícito del usuario: agregar visibilidad de la ocupación real de `mem_request_fifo`,
independiente de lo que CoreFIFO reporte internamente, para distinguir "el flag miente" de "el flag
dice la verdad".

Dos contadores libres en `framestore.v`: `dbg_mem_req_wr_push_cnt` (dominio `clk`, cuenta cada
`mem_req_wr_en`) y `dbg_mem_req_rd_pop_cnt` (dominio `mem_clk`, cuenta cada `mem_req_rd_en &&
mem_req_rd_valid` aceptado). Empaquetados en los bits altos antes sin usar de `VBUF_WR_ADDR`/
`VBUF_RD_ADDR` (no hay lugar para un registro APB nuevo — el espacio de direcciones `PADDR[6:2]` ya
está completo, 0x00–0x1f), con sincronizador 2-FF para el de `mem_clk` en `apb3_mpeg2fpga_bridge.v`
(mismo patrón liviano que ya usa `dbg_last_write_awaddr_issued`).

**Resultado en hardware real** (post-fix de CDC, reboot limpio, `tcela-17.bits`):

```
push_cnt=60, pop_cnt=0, occupancy=60
```

Congelado así los ~20 segundos completos de la observación, sobreviviendo decenas de ciclos de
watchdog. Esto **descarta** la hipótesis del flag corrupto: 60 requests reales se empujaron (coincide
exacto con `MEMREQ_THRESHOLD:60`, el propio backpressure de `framestore_request.v` frena ahí
correctamente) y `mem2axi_bridge` genuinamente nunca hizo pop de casi ninguno. `mem_req_wr_almost_full`
decía la verdad.

## 4. Causa raíz aislada y reproducida en simulación rápida

Con el flag de AFULL descartado como sospechoso, la pregunta cambia a: ¿por qué `mem2axi_bridge` deja
de hacer pop si la FIFO tiene 60 elementos reales esperando?

`bench/mem_response_corefifo/testbench.v` (de la investigación de FWFT, instancia el control real de
CoreFIFO generado por Libero, con la RAM reemplazada por un stand-in conductual verificado-equivalente)
ya existía. Se agregó una tercera instancia (`mem_request_fifo_test2`/`req_fifo_test2`) con la
orientación REAL de `framestore.v` (`wr_clk=clk`, `rd_clk=mem_clk` — la instancia preexistente
`mem_request_fifo_test` los tenía invertidos) y el uso REAL de `RE` que hace `mem2axi_bridge.v`:
**sostenido en alto continuamente** (`mem_req_rd_en <= (next == S_IDLE)`, nunca gateado por el estado
de `empty`) — a diferencia de las dos instancias preexistentes en el mismo testbench, que gatean
`rd_en` con `rst & ~empty`.

Se empujaron 60 palabras (igual que la ocupación real observada en placa).

**Reproducido de inmediato**: el checker interno de CoreFIFO empieza a reportar "Reading when FIFO is
Empty" y solo 3 de 60 palabras se entregan antes de que `EMPTY` quede pegado en alto para siempre
(con `FULL=0` — las otras 57 palabras están genuinamente ahí, nunca entregadas). Corrida completa en
~39 microsegundos de tiempo de simulación. Las otras dos instancias del mismo testbench, que gatean
`rd_en` con `~empty`, funcionan perfecto (todos los checks pasan, incluyendo un stress test de 16
lecturas consecutivas) — aislando el disparador limpiamente a "`RE` sostenido en alto durante un
período idle", no a nada relacionado con reset/CDC.

**Esta es la causa raíz real del stall de DMA**, distinta de (y encontrada solo después de descartar)
las hipótesis del wedge AXI4 y del reset CDC — ambas eran bugs reales que valía la pena arreglar, pero
ninguna era la causa de este síntoma específico.

### Fix propuesto (no implementado ni probado en hardware esta sesión)

`mem2axi_bridge.v` hoy no tiene ninguna visibilidad del flag `empty` de `mem_request_fifo` —
`framestore.v` lo absorbe internamente y solo expone `mem_req_rd_valid` hacia afuera. El fix:

1. Exponer `empty` (o `prog_empty`) de `mem_request_fifo` como salida nueva de `framestore.v`.
2. Pasarlo a `mem2axi_bridge.v` como entrada nueva.
3. Gatear `mem_req_rd_en` con `~empty` en vez de mantenerlo incondicional en `S_IDLE` — el mismo
   patrón que ya usan (y con el que ya funcionan) las otras dos instancias de `fifo_dc` en el
   testbench, y presumiblemente todo el resto de FIFOs en este código que sí andan bien en producción.

**Advertencia**: `bench/mem_response_corefifo/testbench.v` tiene 4 checks preexistentes fallando
("back-to-back reads through real fifo", direcciones 0x200/0x201/0x202) que no se investigaron esta
noche — no está claro si son anteriores a los cambios de hoy o una regresión separada. Revisar antes
de confiar en ese bloque específico.

## 5. Estado al cierre

**Confirmado y arreglado, con evidencia de hardware real:**
- Drenaje gracioso en reset (`stream_dma.v`, `mem2axi_bridge.v`) — el wedge AXI4 ya no ocurre.
- Reset CDC en CoreFIFO dual-clock (`wrappers.v`, `xfifo_dc.v`, `framestore.v`, `mpeg2video.v`,
  `reset.v`) — bug real, corrección arquitectónicamente correcta, pero no era la causa del stall.

**Aislado y reproducido en simulación, no implementado ni probado en hardware:**
- CoreFIFO rompe su generación de `EMPTY`/`DVLD` cuando `RE` se sostiene en alto continuamente sin
  gatear por `empty` — el patrón real que usa `mem2axi_bridge.v` en `S_IDLE`. Este es el candidato
  fuerte a causa raíz real del stall de DMA que viene arrastrándose desde Fase 7a.

**Próximo paso para la siguiente sesión**: implementar el fix de la sección 4 (exponer `empty`,
gatear `mem_req_rd_en`), rebuild completo, probar en hardware real con `tcela-17.bits` y confirmar
que el push de DMA finalmente completa. Si funciona, también revisar si el mismo patrón de "RE
sostenido en alto" existe en algún otro consumidor de `fifo_dc` en el diseño real (no solo en el
testbench) — `mem_response_fifo`'s propio consumidor en `framestore_response.v` sería el primer lugar
para chequear.

## Acceso a la placa (para continuidad)

SSH: `192.168.18.5`, key `~/.ssh/mpfs_disco_kit`, user `root`. El overlay UIO (`mpeg2fpga_diag`) no
sobrevive un reboot; reaplicar con:
```
mkdir -p /sys/kernel/config/device-tree/overlays/mpeg2fpga_uio
cp /root/webserver/mpeg2fpga-uio.dtbo /sys/kernel/config/device-tree/overlays/mpeg2fpga_uio/dtbo
```
Scripts de diagnóstico en `/root/webserver/` en la placa. Nuevo esta sesión: `diag_mem_req_cnt.py`
(lee `dbg_mem_req_wr_push_cnt`/`dbg_mem_req_rd_pop_cnt` empaquetados en `VBUF_WR_ADDR`/`VBUF_RD_ADDR`).
