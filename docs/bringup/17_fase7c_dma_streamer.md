# Fase 7c — DMA streamer: diseño, TDD, hardware, y un bug abierto

**Fecha:** 2026-08-17
**Ramas:** `hardware_development` (`stream_dma.v` + wiring), `firmware_development` (`dma_push.py`)
**Contexto:** con el servidor web validado (Fase 7b) y el push manual por APB probado pero lento
(~177 KB/s, Fase 7a), tocaba reemplazar ese camino byte-a-byte por un streamer de hardware autónomo:
software escribe el stream completo en un staging buffer en DDR de una sola vez, y el hardware lo lee
solo, sin la CPU en el loop.

## Diseño acordado con el usuario

Se presentó el diseño completo con dos diagramas (bloque y secuencia) antes de implementar — ver el
artifact publicado en esa conversación. Dos decisiones confirmadas explícitamente:

1. **`stream_dma.v` obtiene su propio master AXI4 independiente**, vía `MSS_WRAPPER_0:FIC_2_AXI4_TARGET`
   — libre desde la Fase 6b (solo FIC_0 lo usa en el diseño de referencia base, para
   `DMA_CONTROLLER`/`DMA_INITIATOR`) — en vez de arbitrar el puerto que ya usa `mem2axi_bridge`
   (FIC_1). Evita construir un árbitro nuevo.
2. **Ráfagas de 16 beats de 64 bits (128 bytes)**, balance entre throughput y complejidad del FSM.

El staging buffer es `/dev/udmabuf-ddr-c0` (0x88000000, cacheada) — la tercera región reservada de la
placa base, sin usar hasta esta fase (framestore y patrón de prueba ya ocupan las otras dos). Al ser
cacheada, `dma_push.py` hace el flush explícito vía el par de sysfs `sync_size`/`sync_for_device` que
expone `u-dma-buf` antes de disparar la transferencia.

## Por qué `core_clk`, no un segundo dominio

A diferencia de `mem2axi_bridge` (que **debe** correr en `mem_clk`, porque traduce el protocolo interno
de `mem_req_rd`/`mem_res_wr` que ya vive en ese dominio — ver Fase 6a), `stream_dma.v` es una fuente de
transacciones AXI4 completamente nueva, sin ninguna atadura previa de dominio. Se eligió `core_clk`
(promovido como `clk_out` desde `mpeg2video.v`, ya existente desde la Fase 5b) porque es el MISMO
dominio donde vive `stream_data`/`stream_valid` — evita una segunda cruzada de reloj por completo. Solo
queda una CDC real en todo el diseño: PCLK↔core_clk, resuelta por el toggle-handshake que
`apb3_mpeg2fpga_bridge.v` ya tenía desde la Fase 5a, ahora reutilizado también para los 4 registros
nuevos (`DMA_ADDR`/`DMA_LEN`/`DMA_CTRL`/`DMA_STATUS`, índices 0x11-0x14) sin lógica de CDC adicional.

## Mux con el push manual

`mpeg2fpga_apb_peripheral.v` selecciona entre el `stream_data`/`stream_valid` del push manual
(Fase 7a) y el de `stream_dma` usando el propio `busy` de `stream_dma` como señal de selección — sin
interlock adicional en hardware, apoyado en el mismo tipo de contrato de software que ya rige el orden
`DMA_ADDR`/`DMA_LEN` antes de `DMA_CTRL`: no escribir `STREAM_PUSH_ADDR` mientras una transferencia DMA
está en curso.

## TDD: dos testbenches, un hueco entre ellos

- `bench/stream_dma/` (nuevo): `fake_axi_ddr_ro.v`, un slave AXI4 de solo lectura que sí honra `ARLEN`
  (a diferencia de `fake_axi_ddr.v` de la Fase 6a, que siempre responde con un único beat) — necesario
  porque `stream_dma.v` sí arma ráfagas reales. 20 checks: transferencia de longitud cero, un beat
  parcial, una ráfaga completa, múltiples ráfagas con cola no múltiplo de 8, backpressure sin pérdida
  ni duplicación de bytes, y un segundo `start` ignorado mientras hay una transferencia en curso.
- `bench/apb_bridge/testbench.v` (extendido): los 4 registros nuevos, incluyendo el bit sticky de
  `DMA_STATUS.done` y que se limpia con el siguiente `start`. 25 checks en total.

**Ninguno de los dos prueba la integración completa** (bridge + stream_dma juntos, exactamente como
vive en `mpeg2fpga_apb_peripheral.v`) — cada uno prueba su propio módulo con el otro lado simulado por
un BFM. Este hueco de cobertura resultó ser exactamente donde terminó viviendo el bug real (ver más
abajo) — una lección concreta para la próxima fase con múltiples módulos nuevos interactuando.

## Bugs encontrados y corregidos antes de tocar hardware

- **NBA same-cycle read-before-write** en la primera versión de `stream_dma.v`: el latch de
  `m_axi_araddr`/`ARLEN` para la ráfaga inicial (transición `S_IDLE`→`S_AR`) leía `addr_r`/`bytes_left`
  en el MISMO ciclo en que otro bloque los estaba actualizando por primera vez — leería el valor viejo
  (reset), no el recién escrito. Corregido con `eff_addr`/`eff_bytes_left`, que sustituyen las entradas
  de arranque solo en esa transición puntual.
- **Latch de `ARVALID` incompleto**: la primera versión solo armaba `ARVALID`/`ARADDR`/`ARLEN` en la
  transición `S_DRAIN`→`S_AR` (ráfagas subsiguientes), pero no en `S_IDLE`→`S_AR` (la primera ráfaga) —
  el primer burst de cualquier transferencia nunca hubiera arrancado. Unificado en una sola condición
  `(state != S_AR) && (next == S_AR)` que cubre ambos orígenes.
- **`sd_mark_pins_unused` rechazado por Libero** en las señales de respuesta del canal de escritura de
  `FIC_2_AXI4_TARGET` (`AWREADY`/`WREADY`/`BID`/`BRESP`/`BVALID`) — "Cannot mark pin to unused when it
  belongs to Bus Interface Pin", ya que `FIC_2_AXI4_TARGET` es un bif completo (a diferencia de
  `sd_connect_pins_to_constant`, que sí funciona sobre sub-pines de un bif, usado sin problema para las
  entradas del canal AW/W que si necesitaban un valor fijo). Solución: dejarlos simplemente
  desconectados — solo generan un warning de "floating output", no un error, igual que
  `m_axi_awregion`/`m_axi_aruser` ya lo hacían.

## Hardware: síntesis y P&R limpios, mecanismo funcionando parcialmente

Pipeline completo (SYNTHESIZE → PLACEROUTE → VERIFY_TIMING → GENERATE_PROGRAMMING_DATA → EXPORT_FPE →
PROGRAM) corrido dos veces — una para la primera versión completa, otra agregando un registro de debug
(ver abajo) — ambas limpias: 0 errores de síntesis, pin-lock 55/55 intacto, **0 violaciones de
timing** ("Timing constraints have been met"), programación por JTAG exitosa.

Confirmado en hardware real:

- El staging buffer + `sync_for_device` funcionan correctamente.
- `DMA_CTRL` dispara transferencias de forma confiable (bit de start, ignorado correctamente si ya hay
  una transferencia en curso — probado explícitamente).
- `DMA_STATUS` reporta `busy`/`done`/`bytes_done` de forma coherente y consistente con el
  comportamiento real observado.
- El camino completo (staging buffer → AXI4 → `stream_data`) funciona de punta a punta **para el
  padding de `sequence_end_code`** (32 bytes, generado internamente por `stream_dma.v`) — confirmado
  por `bytes_done=32` tras cada transferencia — a una velocidad ~18× la del push manual (3.2 MB/s vs
  177 KB/s, aunque esa comparación es sobre todo indicativa dado que el "ganado" es solo 32 bytes).

## El bug abierto: `DMA_LEN` no llega a `dma_len_r`

`DMA_ADDR`/`DMA_LEN` se escriben (32 bits) pero **nunca aparecen en las transferencias reales** —
probado con 4 tamaños distintos (0, 1024, 10240, 12599 bytes): en los cuatro casos `bytes_done` cierra
en exactamente 32 (solo el padding), como si `len` fuera 0 en el momento en que `stream_dma` arranca.

Se agregó un registro de debug (readback de `DMA_ADDR`/`DMA_LEN`, antes solo de escritura) y se corrió
un tercer ciclo completo de síntesis/P&R/programación para confirmarlo directamente: **escribir 42 y
12599 en `DMA_ADDR`/`DMA_LEN` y leerlos de vuelta devuelve 0 — incluso en un proceso Python separado,
con un `mmap` nuevo**, descartando cualquier problema del lado del cliente. Se descartó explícitamente:

- **Race/timing**: 50 ms de delay entre cada escritura no cambia nada.
- **Alias de dirección**: escribir un valor impar en `DMA_LEN` (que dispararía un `start` espurio si
  la dirección se confundiera con `DMA_CTRL`) no dispara nada mientras `DMA_CTRL` nunca se toca.
- **Registro optimizado por síntesis**: se confirmó en el netlist post-síntesis
  (`MPFS_DISCOVERY_KIT.vm`) que `dma_len_r` existe como 32 flip-flops reales (`SLE \dma_len_r[N]`), no
  fue eliminado por propagación de constantes.
- **Lógica RTL incorrecta**: revisada carácter por carácter, y el mismo patrón (`is_dma_len`,
  estructuralmente idéntico a `is_dma_ctrl`, que sí funciona) ya está cubierto por
  `bench/apb_bridge/testbench.v`, que pasa en simulación (incluyendo el nuevo checkeo de readback).

Lo que queda acotado: el problema vive específicamente en el camino de escritura hacia
`dma_addr_r`/`dma_len_r` en hardware real, en un lugar que ni la simulación del bridge en aislamiento
ni la simulación de `stream_dma.v` en aislamiento pueden reproducir — y que las herramientas
disponibles en este entorno (sin acceso interactivo a SmartDebug/JTAG en vivo) no permiten seguir
acotando. Acordado con el usuario: **queda documentado como bug abierto, con toda la evidencia
reunida**, mismo tratamiento que la investigación de `SIZE=0` de la Fase 7a — el usuario continúa esa
investigación puntual con SmartDebug directamente.

## Estado al cierre

Infraestructura de la Fase 7c (staging buffer, registros DMA_ADDR/DMA_LEN/DMA_CTRL/DMA_STATUS, mux con
el push manual, `dma_push.py`) construida, documentada y con la mayor parte verificada en hardware
real. El mecanismo de streaming en sí (staging buffer → AXI4 → `stream_data`) está probado
end-to-end, aunque todavía sin poder mover el largo real de un stream por el bug de `DMA_LEN` abierto.
