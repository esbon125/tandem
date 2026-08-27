# Fase 7a — Ground truth vía SmartDebug Active Probes: el stall real es un `BVALID` que nunca llega

Continúa directamente donde cerró `27_fase7a_mem2axi_audit_and_reset_domain_bug.md`. Ese
doc quedó con la investigación de `mem_rst`/`dot_clk` "abierta pero prometedora" y con una
advertencia explícita de no confiar en los bits de debug de `arbiter_flags[31:27]` del build
`7c69891` sin re-verificarlos. Esta sesión hace exactamente esa re-verificación — con una
herramienta mucho más confiable que los bits de debug caseros — y encuentra que la hipótesis
de `mem_rst`/`dot_clk` estaba **equivocada**: el reset está bien. El verdadero bloqueo es
otra cosa completamente distinta, encontrada recién ahora.

## Los bits de debug propios eran poco confiables — SmartDebug Active Probes es la fuente de verdad

El usuario, con SmartDebug abierto en paralelo, ofreció usar **Active Probes** (lectura
directa de flip-flops reales vía JTAG, sin pasar por el RTL de debug agregado esta noche) en
vez de seguir confiando en los bits `arbiter_flags[31:27]`. Resultado de la primera captura
(`reset_and_wdt`, sobre el build `7c69891`+`1fd4a7a`):

- `reset/clk_rst_1` = **1**
- `reset/mem_rst_1` = **1**
- `reset/dot_rst_1` = **1**
- `clk_sreset_2/syncrst` (= `clk_rst` final) = **1**
- `dot_sreset_2/syncrst` (= `dot_rst` final) = **1**
- `mem_sreset_2/syncrst` (= `mem_rst` final, el que le importa a `mem_request_fifo`/
  `mem_response_fifo`) = **1**

**Todo el reset está liberado, ahora mismo, en hardware real.** Esto contradice directamente
lo que mostraban los bits `arbiter_flags[30]` (`mem_rst`)/`[29]` (`dot_rst`)/`[31]`
(`dot_heartbeat`), que leían `0` de forma estable en todas las pruebas. La causa más probable:
los registros `dot_heartbeat_meta/sync`, `mem_rst_dbg_meta/sync`, etc. agregados en
`mpeg2video.v` (commits `5c8f29d`/`7c69891`) no tienen los atributos `syn_keep`/
`syn_preserve`/`syn_noprune` que sí tienen `cnt_clk`/`cnt_mem`/`cnt_dot` — es plausible que el
sintetizador haya optimizado esa lógica de forma incorrecta. **No investigado más a fondo**
porque dejó de ser relevante una vez que apareció la causa real (ver abajo) — si se vuelve a
necesitar instrumentación de debug agregada al RTL, agregar esos atributos primero.

**Conclusión: el fix de `reset.v` (`clkmem_rst`, decouplar `mem_rst`/`clk_rst` de
`dot_rst_1`, commit `1fd4a7a`) sigue siendo arquitectónicamente correcto y vale la pena
mantenerlo** (la dependencia de reset entre dominios lógicamente independientes —
decodificación/memoria vs. salida de video — sigue siendo mala práctica heredada de los
FIFOs Xilinx que ya no se usan), **pero no es la causa del stall.** Se retira esa hipótesis.

## El hallazgo real: `mem2axi_bridge` está permanentemente trabado en `S_BRESP`

Segunda captura del usuario (`probes_mem`, mismo build), esta vez apuntando directo a
`u_mem_bridge` (`mem2axi_bridge.v`):

- `state[3]` = **1**, con nombre alternativo `MIRROREDSLAVE_BREADY` — el sintetizador
  colapsó `assign m_axi_bready = (state == S_BRESP)` directamente al bit one-hot de
  `S_BRESP` (`state==3`), así que el propio nombre del neto confirma la codificación.
- `state[5]` (`S_RDATA`, alias `MIRROREDSLAVE_RREADY`) = 0, y todos los demás bits de
  `state[6:1]` = 0 (confirmado también en la tercera captura, `mem_bridge_dump`,
  `state_Z[6:1]` = `6'h04` = solo el bit 3 en 1).
- `m_axi_awvalid` = 0, `m_axi_wvalid` = 0 — AW y W ya se completaron (el slave los aceptó).
- `mem_req_rd_en` = 0, `mem_req_rd_valid` = 0 — correctos: `mem_req_rd_en` solo se activa
  con `next == S_IDLE`, y el FSM nunca vuelve a `S_IDLE` porque nunca sale de `S_BRESP`.
- `mem_req_rd_empty` (alias del `empty_r` interno de `mem_request_fifo`'s CoreFIFO) = **0**
  — el FIFO **nunca estuvo vacío**: `wptr`=0x3C=60, `rptr`=0. 60 pedidos reales encolados,
  cero jamás sacados. No es un bug del lado de la lectura del FIFO.
- `mem_req_wr_almost_full` (`afull_r`) = 1, `mem_req_wr_full` (`full_r`) = 0 — casi lleno,
  no desbordado, consistente con 60 escrituras acumuladas.

Tercera captura (`mem_bridge_dump`), confirmando el resto del estado interno:

- `aw_done` = **1**, `w_done` = **1** — ambos canales realmente terminaron su handshake.
- `abort_pending` = **1** — la lógica de abort grácil (`stream_dma.v`/`mem2axi_bridge.v`,
  Fase 7a anterior) vio un watchdog y quiere resetear el FSM, pero no puede: mientras
  `state == S_BRESP`, `in_axi_obligation` es verdadero, así que `abort_pending &&
  !in_axi_obligation` nunca se cumple. **La lógica de abort grácil funciona exactamente
  como se diseñó — el problema es que la transacción que está protegiendo nunca termina.**
- `addr_r` = `22'h1C0000` (dirección de palabra), `cmd_r` = `2'h3` (`CMD_WRITE`), `dta_r` =
  `64'h1B32D01E024` — el pedido en curso es real y legítimo (la primera palabra de `vbuf`).
  `axi_addr = DDR_BASE + addr_r*8 = 0xc8000000 + 0xE00000 = 0xc8e00000`, que coincide
  exactamente con `dbg_last_write_awaddr_issued` leído por APB en paralelo.

**Conclusión: `mem2axi_bridge` emite AW+W correctamente, el slave los acepta, y después
`m_axi_bvalid` nunca llega.** No es un bug de `mem_req_rd_en`/`mem_rst`/CDC — todo eso está
confirmado sano. El bloqueo real está en el canal de respuesta de escritura AXI4, del lado
del slave (controlador de DDR / interconnect `FIC_1`).

## Intento de fix: `BREADY`/`RREADY` sostenidos en alto (no funcionó)

Hipótesis: `m_axi_bready = (state == S_BRESP)` se activa recién un ciclo después de que
AW/W realmente terminan (`next` decide `S_BRESP` combinacionalmente, `state` lo registra
el ciclo siguiente) — si el slave presenta `BVALID` apenas termina W y lo sostiene solo
brevemente, un master AXI4 estrictamente compatible con el spec no debería verse afectado
(el spec exige que el slave sostenga `VALID` hasta ver `READY`), pero de todos modos era un
cambio de bajo riesgo y cero costo: este bridge no tiene ningún motivo para no sostener
`BREADY`/`RREADY` en alto todo el tiempo (single-outstanding, sin otro consumidor).

**Fix aplicado** (commit `085ce2a`): `m_axi_bready`/`m_axi_rready` pasan de
`(state == S_ESTADO)` a `1'b1` constante. Sin regresiones en `bench/mem_axi_bridge`
(9/9 + 4/4 escenarios) ni en `bench/mem_response_corefifo` (mismo patrón esperado de 5
fallos preexistentes/control negativo, `e2e_fix_test` sigue 60/60).

**Resultado en hardware real: sin cambios.** Mismo `bytes_done=1385`, mismo `pop_cnt=0`,
mismo `dbg_last_write_awaddr_issued=0xc8e00000`. Esto descarta la hipótesis de timing:
`BVALID` genuinamente nunca se genera, no es que lo perdamos por estar tarde.

## Búsqueda de configuración de ruteo/segmentos de `FIC_1` — sin resultado

Se revisó exhaustivamente si `FIC_1_AXI4_TARGET` necesita una tabla de segmentos/ventanas de
dirección adicional (más allá de `FIC_1_AXI4_TARGET_USED true` en
`MPFS_DISCOVERY_KIT_MSS.cfg`) para rutear hacia el controlador de DDR:

- `MPFS_DISCOVERY_KIT_MSS.cfg` no tiene ninguna clave `SEG`/`_BASE`/`ADDR_MAP` asociada a
  ningún `FIC` — solo parámetros de `DDR3_*` (timing, drive, ODT, etc.), nada de
  address-decode por fabric interface.
- `MPFS_DISCOVERY_KIT_MSS_mss_cfg.xml` tampoco tiene entradas de `FIC1`/`FIC_1` con
  `seg`/`enable`/`route`/`target`.
- El conexionado `MEM_AXI_MIRROREDSLAVE` → `FIC_1_AXI4_TARGET` (Fase 7a, 2026-08-23,
  `MPFS_DISCOVERY_KIT.tcl`) usa `sd_connect_pins` bif-a-bif (la versión CON chequeo de
  compatibilidad, no la que bypasea el chequeo por señal individual — ver
  [[libero_smartdesign_bif_gotchas]]), y ese conexionado pasó por 5 builds completos esta
  noche sin ningún error de Libero.
- `AWID`/`ARID` de 4 bits coinciden con el ancho real de `FIC_1_AXI4_TARGET_FIC_1_AXI4_S_AWID`
  (`MSS_WRAPPER.tcl`). `AWSIZE=3'b011` (8 bytes, coincide con datos de 64 bits),
  `AWBURST=2'b01` (INCR), `AWLEN=0` (1 beat), `WSTRB=8'hff`, `AWCACHE=4'b0000` (Device,
  no-bufferable — la opción más conservadora, cualquier target AXI4 compliant debe
  soportarla) — nada fuera de lo normal en los sideband signals.

**Conclusión provisional: la tabla de ruteo/segmentos por fabric-interface del MSS de
PolarFire SoC (si existe como concepto separado del `_USED true` a nivel de puerto) no está
expuesta en texto plano en ningún archivo de este repo** — vive, si existe, en el hard IP
de la MSS o en la configuración interna del MSS Configurator de Libero, no accesible por
grep. Este es el techo de lo que se puede diagnosticar por lectura de RTL/config.

## Por qué `FIC_0` sí funciona y `FIC_1` no (dato a favor de "estado, no config")

La propia DMA que empuja el stream (`DMA_CONTROLLER`/`FIC_0_AXI4_TARGET`, usada por
`dma_push.py`) completa escrituras reales a la **misma** región de DDR (`0xc8000000`,
`bytes_done` avanza, la transferencia se marca `done`) en el **mismo boot fresco** en el que
`FIC_1` se cuelga. Esto descarta que sea un problema genérico de DDR/MSS post-reprogram (p.
ej. calibración de DDR no re-entrenada en un reset "tibio" vía JTAG, a diferencia de un power
cycle real) — si fuera eso, `FIC_0` debería fallar también. Apunta más específicamente a algo
propio de `FIC_1` (menos ejercitado — el diseño de referencia original lo dejaba
`_USED true` pero sin tráfico real por ese puerto antes de este proyecto, ver el comentario
de cabecera de `mem2axi_bridge.v` sobre por qué se eligió `FIC_1` — "a free resource").

Sigue sin poder descartarse del todo que sea estado específico de `FIC_1`/su tramo del
crossbar que sí sobrevive a un reset vía JTAG aunque `FIC_0`/DDR en general no se vean
afectados — de ahí que la prueba pendiente (power cycle real) siga siendo la más
informativa: si el problema desaparece con power cycle real, es estado stale de FIC_1
específicamente; si persiste, es config/protocolo genuino, no estado.

## Qué queda probado sólido vs. abierto, yendo a la próxima sesión

**Confirmado sólido, hardware real, mantener:**
- Graceful-abort reset fix (`stream_dma.v`/`mem2axi_bridge.v`).
- CoreFIFO dual-clock reset CDC fix (`wr_rst`/`rd_rst` split).
- `mem2axi_bridge.v`: `mem_req_rd_empty` gating + double-pop self-gate — confirmados
  correctos por lógica (SmartDebug: `mem_req_rd_empty=0`, FIFO nunca vacío, 60/60 en la
  cola) aunque no son la causa del stall actual.
- `reset.v`: `clkmem_rst` (decouplar `mem_rst`/`clk_rst` de `dot_rst_1`) — arquitectónicamente
  correcto, **pero confirmado (SmartDebug) que el reset ya estaba liberado incluso sin este
  fix en el momento medido** — no se puede afirmar que haya cambiado el comportamiento real.
  Mantenerlo de todos modos: es la corrección correcta independientemente.
- `m_axi_bready`/`m_axi_rready` sostenidos en alto — cambio correcto y de costo cero, pero
  confirmado que **no** resuelve el stall.

**Refutado esta sesión (no repetir sin nueva evidencia):**
- "`mem_rst` se queda pegado por depender de `dot_clk` muerto" — **refutado por SmartDebug
  Active Probes**: `mem_rst`/`clk_rst`/`dot_rst` leen liberados (1) en el momento medido.
  Los bits de debug caseros que sugerían lo contrario (`arbiter_flags[31:27]`, commits
  `5c8f29d`/`7c69891`) no son confiables — probablemente por falta de `syn_keep` en los
  sincronizadores agregados.
- "`BREADY`/`RREADY` tardíos hacen perder una ventana de `BVALID`" — probado directamente en
  hardware (commit `085ce2a`), sin cambio en el síntoma.

**Abierto, sin pista RTL adicional identificada:**
- Por qué `m_axi_bvalid` nunca llega para la primera escritura AXI4 real de
  `mem2axi_bridge` vía `FIC_1_AXI4_TARGET`, mientras `FIC_0` (otra AXI4 target de la misma
  MSS, mismo boot) sí completa escrituras a la misma región de DDR sin problema.
- No se encontró tabla de segmentos/ruteo de `FIC_1` en ningún archivo de texto del repo —
  si existe, vive en el hard IP de la MSS / MSS Configurator de Libero, no en este árbol.

## Próximo paso acordado con el usuario

**Power cycle real de la Discovery Kit** (desconectar/reconectar alimentación física, no
solo dejar que Libero reprograme vía JTAG) — la prueba más barata y decisiva que queda para
distinguir "estado de `FIC_1`/DDR que sobrevive a un reset JTAG tibio" de "bug de
config/protocolo genuino que un power cycle no cambiaría". El usuario avisará cuando esté
listo para repetir el test de push de `tcela-17.bits` después del power cycle. **No hacer
otro rebuild+reprogram hasta entonces** — el hardware ya tiene programado el build con todos
los fixes de esta noche (commit `085ce2a`), listo para reintentar apenas se haga el power
cycle.
