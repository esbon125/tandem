# Pipelinear lecturas en mem2axi_bridge: de 7.2 a ~19-20 fps

Cierra el primer lever que anotaba [decode_rate_bottleneck] (memoria de sesión,
no un doc de esta serie): `mem2axi_bridge.v` era single-outstanding,
single-beat AXI4 y pagaba el round-trip completo a DDR (~300 ns) en serie por
cada uno de los 358 accesos a memoria por macrobloque. El propio comentario de
cabecera del módulo ya nombraba "pipelining múltiples transacciones
outstanding" como el próximo paso.

## Resumen

**Ganancia de velocidad pura, sin regresión de corrección**, confirmada en
hardware real (MPFS_DISCOVERY_KIT):

| | baseline (`c069e3b`) | con pipelining de lecturas |
|---|---|---|
| decode `tek60` (60 imágenes, 704x480) | 7.2 fps (8.0 s) | **~19-20 fps** (3.05-3.17 s) |
| DMA-a-asentado (`capture_framestore.py`, mismo stream) | 4.8 s | 1.6 s |
| `framecmp` — buffer 0 (MAD/PSNR/peak) | 0.004 / 71.70 / 1 | 0.004 / 71.70 / 1 |
| `framecmp` — buffer 1 | 1.098 / 41.93 / 26 | 1.098 / 41.93 / 26 |
| `framecmp` — buffer 2 | 0.661 / 45.85 / 17 | 0.661 / 45.85 / 17 |
| `framecmp` — buffer 3 | 1.069 / 42.58 / 23 | 1.069 / 42.58 / 23 |

Los cuatro buffers dan **exactamente los mismos números a 3 decimales** entre
baseline y optimizado. Los dos que superan el umbral de MAD 1.0 (buffers 1 y
3) son el error de predicción ya documentado como defecto diferido y
upstream (ver `plan_general_action_items`, item 1) — no algo introducido por
este cambio. `error`/`watchdog` en `0` en todas las corridas.

También se corrió un stream 4x más largo (`tek60` concatenado x4, 240
imágenes, ~15 MB — el máximo que entra en el staging buffer de 16 MB de
`stream_dma.v` a esta resolución): 11.8-12.2 s, `complete: true`,
`error`/`watchdog` en `0` en dos corridas — el pipelining sostiene el mismo
ritmo (~20 fps) en una carga 4x más larga.

## El cambio (rtl/mpeg2/mem2axi_bridge.v, hardware_development)

El diseño anterior poppeaba un request de `mem_request_fifo`, emitía la
transacción AXI4 (AR+RDATA o AW+W+BRESP) y **esperaba la respuesta completa**
antes de poppear el siguiente — un único id, un único beat, totalmente en
serie, tal como documentaba su propio comentario de cabecera.

Ahora, para una lectura: en cuanto el canal AR es aceptado (`arready`),
`state` vuelve directo a `S_IDLE` — ya no espera a `RDATA` — así que el
siguiente request puede poppearse de inmediato. Esto no necesitó ids AXI
distintos ni tocar `mem_tag_fifo`/`framestore.v` (la sospecha original en el
comentario de cabecera): todas las lecturas siguen usando id 0, y AXI4
garantiza que las transacciones que comparten id se completan en el orden en
que fueron emitidas — o sea, `RDATA` siempre vuelve en el mismo orden en que
se pidió, que es exactamente el orden que `mem_res_wr` tiene que reproducir,
sin necesidad de llevar cuenta de qué transacción es cuál.

Piezas nuevas:

- `rd_outstanding` (3 bits): ARs aceptados menos RDATA ya recibidos.
- `resp_buf` (4 entradas, `RESP_DEPTH`): FIFO circular local que separa la
  llegada de `RDATA` de la contrapresión de `mem_res_wr_almost_full` — antes,
  con una sola lectura outstanding, un resultado ya leído se guardaba en un
  solo registro (`S_RESP`) hasta que hubiera lugar; ahora pueden llegar varios
  resultados mientras el de más atrás sigue esperando lugar, así que hace
  falta una cola de verdad. `m_axi_rready` pasa de estar atado en alto a
  depender de si `resp_buf` tiene lugar — bajarlo simplemente hace que el
  esclavo AXI4 sostenga `RVALID`, comportamiento legal del protocolo.

Las escrituras **siguen totalmente serializadas**, a propósito: AXI4 no
garantiza ningún orden relativo entre una lectura y una escritura que
comparten id (la garantía de orden es solo entre transacciones del mismo
*tipo*). Un WRITE ahora espera a `rd_outstanding == 0` — es decir, que cada
lectura anterior ya haya sido *respondida* por la memoria, no solo emitida —
antes de tocar `AW`/`W`. Dos lecturas entre sí nunca tienen este problema:
ninguna modifica memoria, así que not importa en qué orden vuelvan sus datos
entre ellas (y el id compartido ya lo prohíbe de todos modos).

`RESP_DEPTH=4` es un primer corte, no un límite de hardware — es un
`localparam`, fácil de subir si vale la pena medirlo.

## Verificación en simulación (bench/mem_axi_bridge)

`testbench.v` ganó un caso de 4 lecturas consecutivas sin esperar la
respuesta de ninguna entre medio, y otro que mezcla lecturas pipelineadas con
una escritura al medio (para probar que el WRITE efectivamente espera a que
drenen). El primer intento de este test **falló** — pero el bug estaba en el
test, no en el diseño: `wait_res()` sondeaba `mem_res_wr_en` recién cuando el
llamador lo pedía, y con las lecturas pipelineadas una respuesta puede llegar
*antes* de que el test termine de emitir todos los requests. Se resolvió
grabando cada push de `mem_res_wr` en una cola de fondo apenas ocurre, y
`wait_res()` ahora la vacía en orden FIFO en vez de sondear en el momento —
exactamente lo que hace el consumidor real (`mem_response_fifo` de
`framestore.v`).

`fake_axi_ddr.v` (el esclavo AXI4 de prueba) resultó ser **accidentalmente
single-outstanding** él mismo — su canal AR no aceptaba una nueva dirección
hasta que el canal R de la lectura anterior volvía a estar libre. Eso
enmascaraba justo el escenario que este cambio apunta a mejorar (dos lecturas
genuinamente en vuelo a la vez). Se lo separó en un canal AR con su propia
cola de direcciones (profundidad igual a `RESP_DEPTH`) independiente del canal
R, para que el test ejercite overlap real.

`testbench_wedge.v` (reset de watchdog a mitad de transacción) tenía un
escenario D que comparaba contra `S_RDATA`, un encoding de `state` que ya no
existe tras este cambio — con el pipelining, `state` vuelve a `S_IDLE` apenas
se acepta el AR, así que esa ventana ya no tiene su propio valor de `state`.
Se corrigió para engancharse a `rd_outstanding != 0`, que es exactamente lo
que `in_axi_obligation` usa ahora para decidir si diferir el reset. Antes del
fix, el escenario caía en el timeout de 1000 ciclos sin encontrar nunca la
condición — pasaba igual, pero sin probar lo que decía probar.

## Procedimiento de build y comparación en hardware

1. **Fallback primero.** Antes de tocar nada, se exportó el `.job` del build
   ya andando (`c069e3b`) vía `EXPORT_FPE` sobre el proyecto Libero existente
   (no hacía falta resintetizar — el proyecto ya estaba placed & routed).
   Guardado fuera de `soc_build/MPEG2FPGA_SOC/` (que el próximo paso borra).
2. **Cualquier edición de RTL en un proyecto Libero existente exige
   `rm -rf soc_build/MPEG2FPGA_SOC`** antes de reconstruir — de lo contrario
   Synplify sigue sintetizando la copia vieja en `hdl/`, sin ningún error que
   lo delate (ver memoria `libero_build_script_gotchas`). Se repitió esto en
   cada uno de los tres builds de esta sesión (optimizado, baseline,
   optimizado de nuevo).
3. Pipeline completo: `SYNTHESIZE` → `PLACEROUTE` → `VERIFY_TIMING` →
   `GENERATE_PROGRAMMING_DATA` → `EXPORT_FPE`/`PROGRAM`, cada uno como una
   invocación `SCRIPT_ARGS:` separada (el build script encadena
   `GENERATE_PROGRAMMING_DATA`/`PROGRAM`/`EXPORT_FPE` como `if/elseif`, no
   como flags independientes).
4. **Comparación a ciegas (A/B real):** se hizo `git stash` de los cambios de
   RTL para volver exactamente a `c069e3b`, se reconstruyó y programó ese
   baseline, se corrió `framecmp` contra la misma referencia ya generada, y
   recién ahí `git stash pop` + reconstruir de nuevo para dejar la placa en
   la versión optimizada. Dos ciclos de build completos (~40 min cada uno)
   solo para la comparación, porque no había una forma confiable de programar
   un `.job` ya exportado sin pasar por el proyecto Designer — ver más abajo.

### Gotcha nuevo: detectar error real vs. ruido en los logs de Libero

Un chequeo ingenuo de `grep -qi error` sobre el log de `SYNTHESIZE` da falso
positivo con un nombre de archivo (`coreaxi4dmacontroller_int_error_ctrl_
fsm.v`). Y el propio `PLACEROUTE` emite dos `Error: SDC0025` reales pero ya
documentados como ruido no fatal (ver memoria `libero_sdc0025_derive_
constraints_blocker`) — el paso igual termina con "The Execute Script command
succeeded". El chequeo que terminó siendo confiable: exigir la línea "The
Execute Script command succeeded" Y que ningún `^Error:`/`ERROR:` que no sea
`SDC0025` aparezca en el log.

### Gotcha confirmado: no hay forma headless resuelta de programar desde un
`.job` ya exportado

La memoria `libero_build_script_gotchas` ya marcaba esto como abierto para
lectura de Active Probes vía `FPExpress`; esta sesión confirma que el mismo
problema aplica al caso más simple de **programar** (no solo leer probes)
desde un `.job` guardado. `create_job_project`/`run_selected_actions` existen
en el Tcl de FPExpress y en teoría alcanzan, pero construir esa secuencia a
ciegas contra hardware real —sin poder verificar visualmente si programó bien
o directamente falló a mitad de camino— se consideró demasiado riesgoso para
intentar sin la GUI. Mientras tanto, la única vía probada para volver a un
build anterior es reconstruirlo desde el commit correspondiente y programar
vía el propio proyecto Designer (`run_tool -name {PROGRAMDEVICE}`). Si esto
llega a importar (por ejemplo, para un demo que necesite alternar bitstreams
rápido), vale la pena resolverlo con la GUI presente al menos una vez para
capturar la secuencia exacta.

## Nota para cuando haya streaming en tiempo real

Quedó afuera del alcance de esta sesión, pero surgió en la conversación: para
empujar un stream por pedazos (no de una sola vez como hoy) hace falta un
cambio chico en `stream_dma.v`, no en el core licenciado. Hoy agrega un
`sequence_end_code` de 32 bytes al final de **cada** transferencia DMA (para
que el push de una sola vez funcione bien) — eso es exactamente lo que
rompería el streaming por pedazos, porque cada pedazo parecería el fin de la
secuencia. El core ya soporta encadenar streams sin resetear
(`flush_vbuf`/trick-mode, confirmado en hardware — ver memoria
`trick_mode_continuous_operation`), así que el corte real sería solo en
cambios de secuencia (canal, fin de transmisión), no entre cada pedazo. Falta
un bit de control tipo "no agregues padding" en `stream_dma.v`.

Además: incluso con este pipelining, ~19-20 fps sigue por debajo de los
29.97 fps que pide `tek60` en tiempo real a 704x480 — el próximo lever
documentado (bursts, `arlen > 0`) sigue pendiente si el objetivo es alcanzar
tiempo real a esta resolución.

## Cómo reproducir

```sh
cd trunk/mpeg2fpga/bench/mem_axi_bridge
make clean test          # regresión + los nuevos casos de pipelining

# en la placa, con el bitstream que corresponda ya programado:
python3 tools/framecmp/framecmp.py ref tek60.bits -o /tmp/ref
# (en la placa) python3 capture_framestore.py tek60.bits -o hw.bin
python3 tools/framecmp/framecmp.py compare hw.bin /tmp/ref
```

Ver también [[decode_rate_bottleneck]] y [[plan_general_action_items]]
(memorias de sesión) para el contexto del profiling que identificó este
lever.
