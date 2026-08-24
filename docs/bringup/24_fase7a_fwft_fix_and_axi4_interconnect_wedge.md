# Fase 7a — Fix de FWFT en las CoreFIFO y confirmación del wedge a nivel AXI4/interconnect

Continúa directamente donde cerró `23_fase7a_axi4_fix_confirmed_and_post_watchdog_stall.md`:
el stream real `tcela-17.bits` (decodifica limpio en simulación) sigue trabando el
decoder en hardware real después de ~1385 bytes, con `mem_req_wr_almost_full`
pegado en `1` y el arbiter atascado en `STATE_CLEAR`. Esta sesión cubre cuatro
líneas de trabajo: el bug #1 (aparte, `watchdog_interval`), la validación de la
hipótesis de reset-domain de `stream_dma.v` que dejó abierta el doc 23, una
investigación en simulación con latencia de memoria realista, y una auditoría del
RTL real de CoreFIFO pedida explícitamente por el usuario — que terminó en un fix
real pero insuficiente.

## Bug #1 (aparte, parqueado): generalización del fix de PSTRB

Antes de retomar el stall real, se generalizó el fix de PSTRB de
`apb3_mpeg2fpga_bridge.v` (hasta ahora sólo aplicado a `DMA_ADDR`/`DMA_LEN`) a
**todos** los registros del bridge: el merge por byte-lane ahora ocurre en el
punto de captura de `apb_wdata_r` mismo (estados `A_IDLE` y `A_SETTLE`),
calificado por `PSEL && PENABLE` en cada ciclo, en vez de resamplear `PWDATA`
ciegamente. Testbench (`bench/apb_bridge/testbench.v`) extendido con un write
reensamblado desde 4 beats angostos de PSTRB y una prueba de inmunidad a ruido de
bus inyectado durante la ventana de settle — 41/41 checks OK.

**Resultado en hardware real: el síntoma de `watchdog_interval` (reset espurio al
escribir ese registro) persiste idéntico.** El fix es real y estructuralmente
correcto (confirmado por testbench), pero no es la causa de ese síntoma — que
sigue sin diagnosticar. Ver [[false_positive_testbench_confidence]]: se presentó
inicialmente como posible solución sin confirmar contra hardware primero, lo cual
fue una corrección explícita del usuario sobre esta sesión. Bug #1 queda
parqueado; el foco vuelve al stall real (bug #2).

## Validación de la hipótesis de reset-domain de `stream_dma.v` (doc 23)

El doc 23 dejó como hipótesis sin confirmar que una transacción AXI4 de lectura
huérfana en `stream_dma.v` (su propio master de lectura, independiente del
master de escritura de `mem2axi_bridge`) podía ser la causa del stall
post-watchdog. Antes de llegar ahí, surgió una pregunta más básica del usuario:
*¿cómo estábamos comprobando realmente que la placa estaba "limpia" antes de
cada prueba?* La respuesta reveló el gap: el chequeo de estado limpio
(`diag_check.py`) sólo leía registros de `framestore_request.v`/`mem2axi_bridge.v`,
nunca el estado propio de `stream_dma.v` — que no tenía ni siquiera un registro
de debug expuesto.

Se agregó ese registro (`stream_dma.v`: nuevo puerto `dbg_state` exponiendo el FSM
interno S_IDLE/S_AR/S_RDATA/S_DRAIN/S_PAD/S_DONE) y, al revisar el reset del
módulo, se encontró el bug real: `u_stream_dma` estaba conectado al `rst_n`
crudo (reset de power-on solamente), **no** al reset sincronizado que incluye al
watchdog (`sync_rst`, ahora expuesto desde `mpeg2video.v` como `core_rst_out`).
Es decir: cuando el watchdog disparaba, `stream_dma.v` nunca se enteraba —
quedaba corriendo con el estado que tuviera en ese momento.

**Fix**: `mpeg2fpga_apb_peripheral.v` ahora conecta `u_stream_dma.rst_n` a
`core_rst_internal` (el nuevo `core_rst_out` de `mpeg2video.v`) en vez de al
`rst_n` externo. Commit `250b64c`.

**Confirmado en hardware real**: tras un reset por watchdog, `dma_state_dbg`
ahora sí vuelve correctamente a `S_IDLE` — el módulo se resetea como se espera.
**Pero el síntoma raíz no cambia**: se agregaron también `dma_axi_arvalid` y
`dma_axi_rvalid` como bits de debug (`arbiter_flags` bits 22/23), y
`dma_axi_rvalid` queda pegado en `1` para siempre después del reset, aunque el
FSM del módulo ya esté en `S_IDLE`. Esto confirma exactamente la hipótesis del
doc 23: el problema no es que `stream_dma.v` no se resetee (eso ya está
arreglado) — es que el **interconnect/fabric compartido** (`FIC_2`) queda con un
`RVALID` huérfano, sin que ningún master lo consuma nunca, porque el reset del
watchdog abandonó la ráfaga AXI4 a mitad de camino sin completarla
protocolarmente. El reset local de un master no puede, por diseño, limpiar el
estado de un recurso compartido del lado de la MSS.

## Investigación en simulación con latencia de memoria realista

Se descartó primero, con evidencia directa, la hipótesis de starvation por
prioridad fija del arbiter (`disp_service_cnt` se mantuvo en 0 durante todo el
stall real, lo que descarta que el refresh de display esté monopolizando el
arbitraje). Se descartó también que el stream fuera MPEG-1 o 4:2:2 (decodificado
a mano bit a bit: es MPEG-2 SP@ML, 4:2:0 genuino).

Se construyó `bench/iverilog/mem_ctl_latency.v`, un modelo de memoria con
latencia realista (24 ciclos de `mem_clk`, sin pipeline, single-outstanding —
igual estructura de FSM que `mem2axi_bridge.v` real: S_IDLE/S_LATCH/S_BUSY/S_RESP)
para reemplazar el `mem_ctl.v` idealizado de respuesta instantánea que usa el
testbench por defecto. Con este modelo, **se logró reproducir el mismo tipo de
stall en simulación pura**: el VLD se desincroniza exactamente al cargar las
matrices de cuantización custom de `tcela-17.bits` (byte 384 del stream, 48
entradas de `vbuf`), leyendo bits basura/X del `getbits` window en pleno punto
de decisión (`vld.v` línea 578, `STATE_SEQUENCE_HEADER3`). Rastreado hasta datos
`X` acompañados de un pulso de `valid`, dentro de `mem_response_fifo`.

**Advertencia importante, ya señalada al usuario en su momento**: `wrappers.v`
local de `bench/iverilog/` usa incondicionalmente `generic_fifo_dc` (fallback de
simulación tipo OpenCores) — **nunca** ejercita el CoreFIFO real. Con presupuesto
acotado (1-2 chequeos, según indicación explícita del usuario), se revisaron
`generic_fifo_dc.v` y `generic_dpram.v` sin encontrar un bug evidente en ese
modelo de simulación. Este hallazgo quedó como **específico del modelo de
simulación**, sin confirmar que aplique a hardware real — lo cual llevó
directamente al siguiente punto.

## Auditoría del RTL real de CoreFIFO (pedido explícito del usuario)

El usuario pidió revisar si las tres instancias de CoreFIFO (`corefifo.v`, cuya
lógica de control/sync SÍ está disponible sin encriptar — sólo el bloque RAM1K20
es vendor-blackbox) estaban bien conectadas, ya que el cableado se hizo a mano.

**Pines: correctos.** Se comparó `xfifo_dc.v` contra el listado de puertos del
wrapper generado (`fifo_mem_rsp_dc_64x128.v` y análogos) — coinciden
exactamente.

**Configuración: bug real encontrado.** Las tres instancias
(`fifo_pixel_stream_dc_35x1024`, `fifo_mem_req_dc_88x64`,
`fifo_mem_rsp_dc_64x128`, definidas en
`soc_build/script_support/components/MPEG2FPGA_FIFOS.tcl`) estaban configuradas
`FWFT:true` (First-Word-Fall-Through). Se leyó el RTL real y sin encriptar de
`corefifo_fwft.v` (bajo
`soc_build/MPEG2FPGA_SOC/component/work/.../rtl/vlog/core/`): en modo FWFT,
`dvld`/`DVLD` sigue a un registro `dout_valid` que se **limpia el mismo ciclo**
en que se asertea `RE`, salvo refresh inmediato — el protocolo opuesto al que
asumen `framestore_response.v` y `mem2axi_bridge.v` (assert `RE`, dato válido
registrado un ciclo después). Se confirmó por contraste que ese es exactamente
el protocolo que sí implementa `xfifo_sc.v` (el FIFO de `mem_tag_fifo`,
hand-written, no basado en CoreFIFO). Y se confirmó en `COREFIFO.v` que
`FWFT==0 && PREFETCH==0` selecciona el datapath estándar (sin instanciar
`corefifo_fwft` en absoluto) — exactamente el timing que el resto del RTL
espera. `CTRL_TYPE:2` no participa de esto (sólo selecciona la primitiva RAM
RAM1K18, según el propio comentario del archivo).

### Fix aplicado y ciclo completo de rebuild

`MPEG2FPGA_FIFOS.tcl`: `FWFT:true` → `FWFT:false` en las tres instancias
(`PREFETCH`, `READ_DVALID`, `CTRL_TYPE` sin cambios). Sin tocar ningún archivo
de `rtl/mpeg2/*.v`.

Por el gotcha ya conocido de reuso de proyecto stale (ver
[[libero_build_script_gotchas]]), se borró `soc_build/MPEG2FPGA_SOC` completo
antes de reconstruir. Ciclo completo:
`SYNTHESIZE → PLACEROUTE → VERIFY_TIMING → GENERATE_PROGRAMMING_DATA → EXPORT_FPE → PROGRAM`,
todos pasaron sin errores (`VERIFY_TIMING`: "No errors or warnings found...
Timing constraints have been met" — el mismo patrón ya visto antes de un
residual de -8.2xxns en el log del optimizador de PLACEROUTE que `VERIFY_TIMING`,
la herramienta de signoff, no considera una violación real). `PROGRAM`:
"Executing action PROGRAM PASSED. Chain programming PASSED."

### Retest en hardware real: el stall persiste, sin cambios

Reboot de la placa (se reinició sola tras el `PROGRAM`), overlay UIO
(`mpeg2fpga_diag`) reaplicado vía configfs, estado limpio confirmado
(`STATE_IDLE`, `vbuf_empty: True`), push de `tcela-17.bits` con trace completo
(`diag_full_trace.py`).

**La firma del stall es idéntica a la de antes del fix**: `bytes_done` se
congela en 1385, `mem_req_wr_almost_full` queda en `True`, `arbiter_state`
queda en `STATE_CLEAR`, el watchdog dispara en loop cada ~0.8s sin recuperarse
nunca, y — el dato clave — `stream_dma_rvalid` (`dma_axi_rvalid`) queda pegado
en `True` para siempre aunque `stream_dma_state` sí vuelva a `S_IDLE`.

**Conclusión**: el fix de FWFT es real y correcto (verificado contra RTL real,
no contra un modelo de simulación) y vale la pena mantenerlo — pero **no es la
causa del stall**, o no la única. La firma post-fix es exactamente la misma que
predijo la hipótesis del doc 23: el wedge vive en el interconnect/fabric
compartido (`FIC_2`), no dentro de la lógica del core ni de sus CoreFIFO. El
reset de `stream_dma.v` (ya corregido) resetea el módulo correctamente, pero no
puede limpiar un `RVALID` huérfano del lado de la MSS que quedó abandonado a
mitad de ráfaga.

## Estado al cierre

- **Confirmado en hardware real, durable**: fix de reset-domain de
  `stream_dma.v` (`250b64c`) — el módulo se resetea correctamente ante watchdog.
- **Confirmado en hardware real, durable pero insuficiente por sí solo**: fix
  de FWFT en las tres CoreFIFO (pendiente de commit) — corrige un mismatch de
  protocolo real, no resuelve el stall.
- **Hipótesis actual, con evidencia consistente en dos sesiones**: el stall es
  un deadlock a nivel de protocolo AXI4 en el interconnect compartido (`FIC_2`),
  no un bug de la lógica del decoder. Algo (probablemente backpressure genuina
  de `mem_req_fifo`/vbuf bajo latencia real de memoria) hace que `stream_dma`
  deje de aceptar `RREADY` a mitad de una ráfaga; si el watchdog dispara en ese
  momento, la ráfaga queda abandonada sin drenarse, dejando el interconnect con
  `RVALID` trabado en alto indefinidamente — viola el invariante de AXI4 de que
  una ráfaga iniciada debe completarse antes de que el master consumidor se
  desentienda.
- **Próxima sesión**: investigar el estado a nivel `FIC_2`/interconnect
  directamente (no más adentro de las CoreFIFO), y reproducir en simulación
  — con `mem_ctl_latency.v`, ya construido y capaz de inducir el mismo tipo de
  stall — por qué se corta el `RREADY` bajo latencia real, antes de decidir si
  el fix correcto es evitar que el watchdog resetee `stream_dma` a mitad de
  ráfaga, o hacer que `stream_dma` drene cualquier ráfaga en vuelo antes de
  aceptar el reset.
- Bug #1 (`watchdog_interval`) sigue abierto y parqueado, sin relación aparente
  con el bug #2.

## Acceso a la placa (para continuidad)

SSH: `192.168.18.5`, key `~/.ssh/mpfs_disco_kit`, user `root`. El overlay UIO
(`mpeg2fpga_diag`) no sobrevive un reboot; reaplicar con:
```
mkdir -p /sys/kernel/config/device-tree/overlays/mpeg2fpga_uio
cp /root/webserver/mpeg2fpga-uio.dtbo /sys/kernel/config/device-tree/overlays/mpeg2fpga_uio/dtbo
```
Scripts de diagnóstico en `/root/webserver/` en la placa (coinciden con la rama
`firmware_development`): `decoder_push.py`, `dma_push.py`, `ddr_region.py`,
`diag_check.py`, `diag_full_trace.py`, entre otros acumulados en sesiones
anteriores.
