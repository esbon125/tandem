# Fase 7a (seguimiento) — Investigación acotada del SIZE en 0

**Fecha:** 2026-08-16
**Rama:** `hardware_development`
**Contexto:** la Fase 7a (`docs/bringup/14_fase7a_stream_push_register.md`) cerró con el mecanismo de
push por APB verificado, pero `SIZE`/`DISP_SIZE` seguían en `0x00000000` después de empujar un stream
real. Se acordó con el usuario cazar la causa con un presupuesto acotado: **2 iteraciones de hardware**,
y si no aparecía, seguir con la Fase 7b y retomar esto con el servidor web ya levantado.

## Iteración 1 — diagnóstico con `probe.v`, sin recompilar

Antes de gastar una iteración de hardware, se revisó código para descartar hipótesis baratas:

- **Watchdog**: descartado por lectura de `watchdog.v` — el timer solo corre mientras `busy` está en
  alto sostenido (definición: `decoder_active <= ~busy || ...`), y con nuestro push lento (~178 KB/s)
  `busy` casi no se activa, así que el watchdog prácticamente nunca sale de `STATE_CLEAR`. No es la
  causa.
- **`source_select`**: descartado — solo afecta el mux de salida de video (trick modes), no el camino
  de parseo/entrada.
- **`clk_en` de `vbuf_write`**: descartado — está atado a `1'b1` fijo en `mpeg2video.v`, siempre
  habilitado.
- **`REG_RD_SIZE`**: confirmado que lee `horizontal_size`/`vertical_size` de `vld.v` de forma
  combinacional y directa (sin gating por evento) — si `vld.v` alguna vez parsea el sequence header,
  `SIZE` debería reflejarlo en la siguiente lectura, sin necesitar nada adicional.

Se aprovechó el mecanismo de `testpoint` que ya existe en el diseño (`probe.v`, el mismo que resolvió
la Fase 5d) para observar `stream_data`/`stream_valid`/`vbr_rd_dta` sin recompilar: seleccionar
testpoint 0 ("incoming video") vía `REG_WR_TESTPOINT` y leer `REG_RD_TESTPOINT` repetidas veces
mientras se empuja un byte distintivo (`0xAA`) en loop. Resultado: solo 2 valores distintos en 64
muestras, y `0xAA` nunca apareció en el campo que debería corresponder a `stream_data`.

**Limitación real de este método, no necesariamente evidencia de un bug**: `stream_valid` es un pulso
de un solo ciclo de `core_clk` (~9 ns) entre transacciones APB que tardan cientos de ciclos — la
probabilidad de que una lectura de registro *posterior y lenta* justo capture ese pulso es
prácticamente cero por construcción. El testpoint no sirvió para confirmar ni descartar el mecanismo de
push en sí, pero sí aportó una pista real: `vbr_rd_dta[63:48]` (los últimos 16 bits del último word de
64 bits leído del buffer circular en DDR) tampoco mostró nunca contenido reconocible — y revisando el
mapa de memoria real de la placa (`cat /proc/iomem`) apareció algo concreto: **`DDR_BASE=0` (el
placeholder de la Fase 6b) apunta a una dirección física que casi seguro no es DDR real** — el
`System RAM` de Linux en esta placa arranca en `0x80000000`.

## Iteración 2 — `DDR_BASE` real, resíntesis completa

Se encontraron tres regiones de 32 MB ya reservadas en el árbol de dispositivos base (`u-dma-buf`,
`dmesg`: `buffer@88000000`, `buffer@c8000000`, `buffer@d8000000`), pensadas exactamente para este tipo
de uso — memoria visible tanto a fabric como, más adelante, a Linux vía `mmap`. Se fijó
`DDR_BASE = 38'hc8000000` (`udmabuf-ddr-nc0`, no cacheada, ya expuesta como `/dev/udmabuf-ddr-nc0`,
exactamente 32 MiB, alineada). Síntesis, P&R (pin-lock 55/55 intacto) y Verify Timing (sin violaciones)
todos limpios; programado en hardware.

**Resultado: `SIZE`/`DISP_SIZE` siguieron en `0x00000000`.** El fix de `DDR_BASE` era necesario de
todos modos (`0x0` nunca iba a ser correcto en cuanto algo dependiera de que los datos lleguen a algún
lado real), así que se mantiene, pero no era la causa raíz de este síntoma puntual.

## Estado al cierre de las 2 iteraciones

Confirmado: el mecanismo de push por APB entrega bytes sin colgar la placa (Fase 7a), y ahora
`mem2axi_bridge` apunta a una región de DDR real y reservada. **No confirmado**: si esos bytes
efectivamente llegan a `vbuf`/`vld` y se parsean — la evidencia indirecta (testpoint sin actividad
reconocible) es consistente tanto con "no llega nada" como con "llega pero mi método de sondeo lento no
lo puede ver". No se identificó la causa raíz dentro del presupuesto de 2 iteraciones acordado.

**Próximo paso, según lo acordado con el usuario**: seguir con la Fase 7b (diseño del servidor web).
Cuando haya una forma más directa de alimentar el stream y observar resultados (en vez de una prueba
manual por SSH con un archivo copiado por `scp`), retomar esta investigación — probablemente entonces
convenga instrumentar con una captura real (SmartDebug/logic analyzer sobre el propio `testpoint`, que
ya está pensado para eso) en lugar de sondeo por registro.
