# Fase 7a — Registro de push de stream por APB

**Fecha:** 2026-08-16
**Ramas:** `hardware_development` (registro + bridge), `firmware_development` (herramienta de prueba)
**Contexto:** con la DDR ya cableada (Fase 6), quedaba un vacío real: `stream_data`/`stream_valid` —
el puerto por donde entra el bitstream MPEG-2 al decoder — seguía atado a constantes desde la Fase 5.
Sin eso, nada de lo construido en Fase 6 tiene forma de recibir un archivo real. Se decidió con el
usuario resolverlo con la opción más simple: un registro más en el bridge APB existente, alimentado por
software, dejando el DMA/streamer desde DDR (la alternativa de mayor throughput) para la Fase 7c.

## Diseño: por qué no se tocó `regfile.v` ni `mpeg2video.v`

`stream_data`/`stream_valid` son un par de puertos de nivel superior de `mpeg2video`, completamente
aparte del banco de 16 registros que expone `regfile.v` vía `reg_addr`/`reg_wr_en`/`reg_rd_en` — nunca
pasan por el register file. Los 16 índices de ese banco ya están todos asignados
(`regfile_codes.v`), así que aunque se quisiera reusar uno no alcanzaría: haría falta agregarle un caso
nuevo a `regfile.v` y además nueva lógica a `mpeg2video.v` para que ese caso llegue hasta
`stream_data`. Ambos son IP de terceros licenciado (`rtl/mpeg2/LICENSE-MPEG2`) que CLAUDE.md pide
mantener lo más cerca posible del upstream.

En cambio, se extendió `apb3_mpeg2fpga_bridge.v` (nuestro archivo, de la Fase 5a) con una 17ª
dirección — `STREAM_PUSH_ADDR`, índice `0x10`, un paso más allá de los 16 registros — que en vez de
tocar `reg_wr_en`/`reg_addr`, pulsa `stream_data`/`stream_valid` directamente. `PADDR` se ensanchó de 6
a 7 bits para que ese índice entre.

## Backpressure gratis: `busy` como wait-state de APB

`mpeg2video` ya expone `busy` ("assert busy when input fifo risks overflow"), en el mismo dominio
`core_clk` que el bridge. La escritura a `STREAM_PUSH_ADDR` solo completa (solo levanta `PREADY`) una
vez que `busy` está en bajo — si está ocupado, el nuevo estado `C_STREAM_WAIT` simplemente no avanza.
Para el software esto es transparente: una escritura APB común y corriente que a veces tarda más, sin
necesidad de un registro de polling separado ni de que el firmware sepa nada sobre FIFOs internas.

## TDD: Icarus primero

`bench/apb_bridge/testbench.v` (Fase 5a) se extendió con casos nuevos: push simple (byte capturado
correctamente, banco de regfile intacto), backpressure real (`busy=1` mantiene `PREADY` en bajo,
usando `fork`/`join` para levantar `busy` de forma concurrente y confirmar que la escritura se
completa recién después), y que un acceso a un registro normal sigue funcionando bien inmediatamente
después de un push. 15 checks, todos en verde, antes de tocar Libero.

## Libero: cero cambios de TCL

A diferencia de la Fase 6b (donde el AXI4 nuevo exigió cablear medio archivo de TCL a mano), ensanchar
`PADDR` no necesitó ningún cambio de script: `PADDR` ya era un bus ancho compartido a nivel de
SmartDesign (la señal genérica que Libero etiqueta con el nombre de un slot cualquiera, ver Fase 5b), y
Libero ajustó automáticamente el ancho del slice conectado a nuestro módulo — confirmado contra el
Verilog generado (`PADDR_4_6to0 = ...PADDR[6:0]`, antes `[4:0]`).

## Hardware: síntesis limpia, timing cerrado, sin regresión

Mismo pipeline que la Fase 6c: síntesis sin errores, P&R con pin-lock intacto (55/55), **Verify Timing
sin ninguna violación** contra el SDC completo (el CDC del toggle-handshake ya estaba exceptuado desde
la Fase 5c/5a, y esta extensión reusa exactamente los mismos registros, solo un bit más ancho).
Programado por JTAG, placa arrancó normal, SSH funcionando.

## Prueba en hardware real — y un bug encontrado en la herramienta, no en el RTL

Se armó `push_stream.py` (rama `firmware_development`, `driver/mpeg2fpga/tools/`): un mapeo UIO crudo
que escribe un stream elemental real (`tools/streams/tcela/tcela-17-dots/tcela-17.bits`, 12599 bytes,
identificado por `file` como una secuencia MPEG-2 v2 SP@ML válida) byte a byte contra
`STREAM_PUSH_ADDR`, deliberadamente por UIO y no por el driver de kernel (que todavía no expone un
camino de escritura para esto).

La primera corrida mostró `VERSION = 0x00000008` en vez del `0x0000000c` ya confirmado en Fases 5d/6d
— una señal de alarma real. Antes de sospechar del RTL, se verificó el mismo bitstream con el camino
YA confiable (el driver de kernel, `insmod` + `dev_info`): reportó `hw version 0x000c` correctamente.
Eso descartó al hardware y apuntó a la herramienta nueva. La causa: UIO mapea la **página completa**
que contiene el rango `reg` del dispositivo (confirmado en
`/sys/class/uio/uioN/maps/map0/{addr,size,offset}`: `addr=0x40000000`, `offset=0x400`), no el rango en
sí — los offsets de registro tienen que sumar ese offset de página (`0x400` acá) para caer en la
dirección real. Sin eso, cada lectura/escritura caía silenciosamente en cualquier cosa que viva al
principio de esa página física — sin crash, sin error, solo datos con pinta de válidos pero
incorrectos. Corregido (`PAGE_OFFSET` en el script) y confirmado: `VERSION` vuelve a leer `0x0000000c`
de forma estable.

## Lo que se confirmó y lo que queda abierto

Confirmado en hardware real: la escritura a `STREAM_PUSH_ADDR` no cuelga la placa (12599 bytes + padding
de `sequence_end_code` en ~71 ms, ~177 KB/s), el mecanismo de `busy`/backpressure no rompe nada, y el
resto del regfile sigue accesible con normalidad después de un push.

**No confirmado todavía**: `SIZE`/`DISP_SIZE` siguieron en `0x00000000` después de empujar el stream
completo — el decoder no dio señales de haber parseado el sequence header (que debería poblar esos
registros apenas los encuentra). Se descartaron dos hipótesis rápidas por revisión de código
(`watchdog_interval` default de 127 da un timeout de más de un segundo, mucho más que los ~71 ms de la
prueba; `source_select` solo afecta el mux de salida de video, no el parseo). La causa real queda sin
identificar — no se siguió investigando porque excede el alcance que se acordó para esta fase (el
usuario ya planificó la validación end-to-end completa para la Fase 7d, una vez que el server web esté
armado).

## Conclusión

Cierra la Fase 7a: el mecanismo de push por APB existe, está verificado en simulación y en hardware
real, y no daña nada del camino ya probado. Sigue la Fase 7b: diseñar en conjunto las características
del servidor web antes de implementarlo.
