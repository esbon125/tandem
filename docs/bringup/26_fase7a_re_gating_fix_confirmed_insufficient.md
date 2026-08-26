# Fase 7a: fix de gating de RE implementado, confirmado en simulación end-to-end, pero NO resuelve el stall real — hallazgo nuevo: `mem_req_rd_empty` parece atascado en hardware real independientemente de RE

Continuación directa de `25_fase7a_cdc_fix_and_corefifo_re_bug.md`, misma noche. Ese documento cerraba
proponiendo un fix concreto (exponer `empty` de `mem_request_fifo`, gatear `mem_req_rd_en` con eso en
vez de mantenerlo incondicional en `S_IDLE`) pero sin implementar ni probar. El usuario autorizó
explícitamente antes de dormir: "probalo en sim y si anda todo bien mandalo al hardware". Esto se hizo.

## Implementación

- `framestore.v`: el `empty` de `mem_request_fifo` (antes sin conectar, `.empty()`) ahora se expone
  como puerto nuevo `mem_req_rd_empty`.
- `mpeg2video.v` / `mpeg2fpga_apb_peripheral.v`: threadeado hacia `mem2axi_bridge.v` (todo en dominio
  `mem_clk`, sin necesidad de CDC).
- `mem2axi_bridge.v`: `mem_req_rd_en <= (next == S_IDLE)` pasa a ser
  `mem_req_rd_en <= (next == S_IDLE) && !mem_req_rd_empty`.

## Verificación end-to-end en simulación (con lógica de control CoreFIFO real)

Se agregó `e2e_fix_test` a `bench/mem_response_corefifo/testbench.v`: una instancia real de
`mem2axi_bridge` (`dut2`) drenando una instancia real de la misma FIFO (solo la celda de RAM está
reemplazada por un stand-in conductual verificado-equivalente; toda la lógica de control —
comparadores de punteros, sincronizadores Gray-code, generación de `EMPTY`/`DVLD`/`AFULL` — es la
real generada por Libero).

Resultado: **las 60 requests `CMD_WRITE` empujadas completan como escrituras AXI4 reales en ~3.4ms**
de tiempo de simulación — contra el patrón sin arreglar (`req_fifo_test2`, mantenido como control
negativo, `RE` sostenido en alto) que solo entrega 3/60 antes de agotar el timeout a los 39ms. También
se re-corrió toda la suite existente (`bench/mem_axi_bridge`: 9+4 checks, `bench/stream_dma`: 20
checks, el decoder completo en `bench/iverilog`) — nada se rompió.

Nota al margen: la primera versión del test tenía un bug propio de packing en la concatenación de
Verilog (`22'h001000 + i` con `i` como `integer` sin ancho fijo se auto-determina en 32 bits dentro de
`{...}`, no en los 22 bits del literal, corriendo todos los campos siguientes) — corregido con
variables locales de ancho explícito antes de confiar en el resultado.

## Rebuild completo y prueba en hardware real

`rm -rf soc_build/MPEG2FPGA_SOC` (proyecto stale) → SYNTHESIZE → PLACEROUTE (SDC0025 falso positivo de
siempre, no bloquea) → VERIFY_TIMING (limpio) → GENERATE_PROGRAMMING_DATA → EXPORT_FPE → PROGRAM,
todo PASSED. Reboot limpio de la placa, overlay UIO reaplicado, retest con `tcela-17.bits`.

**Resultado: el stall sigue exactamente igual.** `bytes_done` congelado en 1385, `mem_req_wr_almost_full`
en `True` para siempre, `arbiter_state` en `STATE_CLEAR`, watchdog en loop indefinido — firma idéntica
a todos los intentos anteriores.

**Dato más específico y más revelador**: `dbg_mem_req_rd_pop_cnt` lee **exactamente 0** — ni un solo
pop ocurre nunca, ni siquiera con el gating correcto en su lugar y ocupación real conocida
(`push_cnt=60`). Esto es una conclusión más fuerte que "el fix no ayudó": significa que
`mem_req_rd_empty` en sí debe estar leyendo atascado en verdadero (reportando "vacío" incorrectamente)
en el silicio real, **independientemente** de si `RE` se sostiene en alto o se gatea correctamente —
el disparador de "RE sostenido en alto" que reprodujo tan limpio en simulación evidentemente no es el
(o no es el único) disparador real en hardware.

## Por qué esto importa: brecha entre simulación y hardware real, no entendida todavía

La simulación usa la lógica de control real de `corefifo_async.v` — solo la celda de RAM (RAM1K20) está
sustituida por un modelo conductual verificado-equivalente (ver el comentario de cabecera de
`ram_wrapper.v` bajo `bench/mem_response_corefifo/corefifo*/`). Que la simulación confirme el fix
perfectamente pero el hardware real muestre un comportamiento PEOR (pop_cnt=0 en vez de progreso
parcial) sugiere que hay algo específico del silicio real en este camino que el modelo de simulación no
captura — no necesariamente la sustitución de RAM en sí, pero es la única diferencia conocida entre
ambos entornos en esta ruta exacta, y por eso es la primera sospechosa.

## Estado al cierre (tres fixes reales, ninguno resuelve el stall)

Esta noche se implementaron y confirmaron en hardware real **tres correcciones genuinas y verificadas**
sobre este camino de FIFO/reset, ninguna de las cuales resolvió el stall de DMA:

1. Drenaje gracioso en reset (`stream_dma.v`, `mem2axi_bridge.v`) — el wedge AXI4 ya no ocurre.
2. Fix de CDC de reset en CoreFIFO dual-clock (`wr_rst`/`rd_rst` separados) — arquitectónicamente
   correcto, pero `mem_req_wr_almost_full` ya reflejaba la ocupación real, no estaba corrupto.
3. Gating de `mem_req_rd_en` con `~empty` — funciona perfecto en simulación con la lógica real de
   CoreFIFO, pero en hardware real `pop_cnt` sigue en 0 absoluto.

**No reintentar el fix de gating de RE como hipótesis principal en la próxima sesión** — es una mejora
real y vale la pena mantenerla (coincide con el patrón que ya usan, y con el que funcionan, todas las
demás FIFOs de este diseño), pero la evidencia de hardware la descarta como suficiente.

### Próximos pasos a considerar

1. **Visibilidad directa de `mem_req_rd_empty`** — hoy solo se infiere indirectamente (vía
   `pop_cnt` nunca incrementando). Exponerlo como su propio bit de debug y leerlo en el momento exacto
   en que `push_cnt` ya es conocido-distinto-de-cero, para confirmar directamente la teoría de "empty
   atascado" en vez de por inferencia.
2. **Investigar si la sustitución RAM1K20→modelo conductual en el harness de simulación
   (`bench/mem_response_corefifo`) podría estar enmascarando un modo de falla exclusivo del hardware
   real** — vale la pena intentar instanciar la primitiva RAM1K20 real/encriptada si la licencia de
   simulación de Libero lo permite, o buscar otra forma de cerrar esta brecha sim/hw.
3. **Revisar una vez más, con ojos frescos, los caminos de reset del sincronizador Gray-code interno de
   `corefifo_async.v`** — dos fixes independientes sobre esta misma instancia de FIFO (CDC de reset,
   luego gating de RE) fueron ambos mejoras reales y verificadas que no resolvieron el síntoma real.
   Podría haber un tercer problema en esta misma vecindad de lógica todavía no identificado.

## Acceso a la placa (para continuidad)

Sin cambios respecto a `25_fase7a_cdc_fix_and_corefifo_re_bug.md`. SSH: `192.168.18.5`, key
`~/.ssh/mpfs_disco_kit`, user `root`. Overlay UIO no sobrevive reboot, reaplicar con:
```
mkdir -p /sys/kernel/config/device-tree/overlays/mpeg2fpga_uio
cp /root/webserver/mpeg2fpga-uio.dtbo /sys/kernel/config/device-tree/overlays/mpeg2fpga_uio/dtbo
```
