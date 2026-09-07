# Pipelinear escrituras en mem2axi_bridge, y un bug real que encontró el propio proceso

Continúa [41]: con las lecturas ya pipelinadas, el profiling mostró que
`mem_res_valid_cnt` (todo el tráfico de lectura combinado) era solo ~10-11%
de los ciclos — las lecturas ya no eran, ni de cerca, el cuello de botella
dominante. Las escrituras seguían totalmente serializadas desde antes de la
Fase 8a, y no había ningún contador para medirlas. Esta sesión agrega ese
contador **y** pipelinea las escrituras en la misma tanda de build, a pedido
explícito de economizar ciclos de rebuild — con la salvedad de que la
correlación contador↔mejora iba a ser circunstancial, no una medición
aislada de causa y efecto.

## Resumen

**Otra ganancia de velocidad real, de nuevo sin regresión de corrección:**

| | lecturas pipelinadas (doc 41) | + escrituras pipelinadas |
|---|---|---|
| decode `tek60` (60 imágenes, 704x480) | ~19.3 fps (3.05-3.19 s) | **~22-23 fps** (2.56-2.88 s) |
| decode `tek240` (240 imágenes) | — | **~21.4-22.0 fps** (10.89-11.19 s), sostenido |
| `framecmp` vs referencia | bit-idéntico al baseline | **bit-idéntico** a los dos anteriores |
| `error` / `watchdog` | false / false | false / false, todas las corridas |

Contra el baseline original (7.2 fps): **~3.1x** en total. Contra el target
de tiempo real de `tek60` (29.97 fps): todavía falta ~1.36x (era ~1.54x
después de la fase anterior).

## El contador de escrituras no explica la ganancia tan limpio como esperaba

`write_service_cnt` (ciclos con `state==STATE_VBW/RECON/OSD` en el árbitro
de `framestore_request.v`) salió **2.5%** de la ventana — un número chico,
que en un primer vistazo parecería contradecir la hipótesis de que las
escrituras eran el cuello de botella. La explicación: ese contador mide
cuánto tiempo el **árbitro** pasa activamente atendiendo una escritura (básicamente,
empujarla a `mem_req_wr_fifo`), que es rápido por diseño — **no** mide
cuánto tiempo el puente AXI tarda en darle vuelta a esa escritura contra la
DDR real, que es exactamente lo que Fase 8b optimiza. Son dos etapas
distintas del mismo camino, y el contador nuevo instrumenta la que no era
la lenta.

La confirmación real de que las escrituras SÍ importaban no viene del
contador sino de la medición directa: pipelinear escrituras dio **otro
~15-20%** de mejora medible (19.3 → 22-23 fps), sobre un diseño donde las
lecturas ya estaban lejos de saturar el puerto de memoria. Si las escrituras
no hubieran costado nada, esa ganancia no debería haber aparecido.

Sigue habiendo un **~75%** de los ciclos sin explicar por ningún contador
existente — candidatos: el árbitro atendiendo FWD/BWD (lecturas de
referencia de compensación de movimiento; sus respuestas SÍ están en
`mem_res_valid_cnt`, pero su propio tiempo de servicio en el árbitro no
tiene contador dedicado, a diferencia de DISP/VBR) o simplemente ciclos
`STATE_IDLE` genuinos. Si se quiere seguir midiendo en vez de adivinar, esos
dos contadores nuevos (`fwd_service_cnt`/`bwd_service_cnt`, o un
`idle_cnt`) son el próximo paso obvio — mismo patrón exacto que
`disp_service_cnt`.

## El cambio (rtl/mpeg2/mem2axi_bridge.v, Fase 8b)

Mismo truco que Fase 8a, aplicado a escrituras: una vez que AW **y** W son
aceptados, `state` vuelve a `S_IDLE` en vez de esperar BRESP — hasta
`WR_DEPTH` (4) escrituras pueden quedar outstanding a la vez. Igual
razonamiento que las lecturas: todas usan id 0, y AXI4 garantiza que las
transacciones del mismo tipo y mismo id se completan en el orden emitido,
así que dos escrituras nunca pueden aplicarse a memoria fuera de orden entre
sí. A diferencia de las lecturas, no hace falta un buffer: una escritura ya
aceptada no tiene datos para reenviarle a nadie, solo un BRESP pendiente de
contar (`wr_outstanding`).

El hazard read/write de la Fase 8a ahora es simétrico: una escritura sigue
esperando `rd_outstanding==0`, y una lectura **también** espera
`wr_outstanding==0` antes de emitir su AR — si no, una lectura pipelinada
detrás de una escritura todavía no confirmada podría adelantársele. Lecturas
pipelinan libremente entre sí, escrituras pipelinan libremente entre sí; los
dos tipos siguen sin superponerse nunca entre ellos.

## El bug real que encontró el propio testbench, antes de tocar hardware

La primera versión de este cambio pasó los 23 checks de
`bench/mem_axi_bridge/testbench.v` (incluidos los nuevos, de escrituras
pipelinadas) — pero `testbench_wedge.v` (el que prueba el watchdog
disparando a mitad de una transacción AXI) reveló algo real: el mecanismo de
"abort diferido" heredado de antes de toda esta serie de optimizaciones
asumía que `state` representaba, todo el tiempo, la transacción que disparó
el watchdog. Eso era cierto en el diseño single-outstanding original, pero
deja de serlo con lecturas y escrituras pipelinadas: `state` puede estar
perfectamente en medio de un `S_LATCH` para un pedido nuevo y no relacionado
en el mismo ciclo en que el `rd_outstanding`/`wr_outstanding` de un pedido
**anterior** drena a 0.

El mecanismo viejo forzaba `state <= S_IDLE` en ese momento — pero los
bloques que emiten AR/AW (`m_axi_arvalid`/`m_axi_awvalid`) leen `next`
directamente, no ese forzado, así que en el mismo ciclo podían emitir una
transacción real mientras `state` decía que estaba idle: `ARVALID` (o
`AWVALID`) se levantaba y se retiraba un ciclo después **sin haber visto
`ARREADY`/`AWREADY` nunca** — una violación lisa y llana de AXI4 (VALID no
se puede retirar antes de READY), que ningún interconnect real está
obligado a tolerar bien. Se reprodujo exactamente así contra
`fake_axi_ddr.v`: el modelo de esclavo, al ver el pulso de ARVALID
retirado tarde, igual latcheaba la dirección internamente y producía un
RDATA fantasma más adelante — `rd_outstanding` (0 - 1) desbordaba a
`3'b111`, y quedaba trabado ahí para siempre, bloqueando cualquier escritura
futura (`rd_outstanding==0` nunca se volvía a cumplir).

**El arreglo real no fue parchear ese forzado, fue eliminarlo.** En vez de
forzar `state`/`next` a S_IDLE cuando el `abort_pending` se resuelve,
`mem_req_rd_en` (el pop de la fifo de pedidos) ahora se gatea también con
`!abort_pending` — mientras un abort está pendiente, no entra **ningún**
pedido nuevo al pipeline, sin importar lo que calculen `state`/`next`. La
transacción que disparó el watchdog drena solita, sin que nadie la toque; una
vez que drena, `state` ya está naturalmente en S_IDLE (nunca se movió,
porque nada nuevo se latcheó) y el sistema retoma sin nada que perder ni
contra qué competir.

La lección general, más allá de este caso puntual: **un mecanismo de reset
diferido que fuerza `state` directamente deja de ser seguro en cuanto otro
bloque combinacional lee `next` de forma independiente** — hay que gatear la
*entrada* de trabajo nuevo, no parchear la salida del registro de estado.

## Cómo se encontró (antes de gastar un ciclo de build en hardware)

`testbench_wedge.v`'s escenario B (watchdog a mitad de la espera de BRESP)
y D (a mitad de la espera de RDATA) ya no tenían un encoding de `state`
propio para esperar (la Fase 8a/8b ya habían vuelto `state` a S_IDLE
apenas se acepta AR/AW+W) — corregirlos para esperar
`wr_outstanding`/`rd_outstanding` en vez de un `state` viejo fue lo que
expuso el timeout real. El primer intento de arreglo (forzar el override
directamente en `next` en vez de solo en `state`) **también falló** —
scenario A y C empezaron a colgarse por una razón distinta (la propia
recuperación del escenario podía perder su pedido si coincidía con el ciclo
de drenaje) — confirmando que el problema no era "olvidarse de un lugar
donde aplicar el forzado" sino que el forzado en sí era la estrategia
equivocada una vez que hay pipelining.

## Cómo reproducir

```sh
cd trunk/mpeg2fpga/bench/mem_axi_bridge
make clean test              # 23 checks, incluye escrituras pipelinadas
iverilog -g2005 -o testbench_wedge.vvp -I../../rtl/mpeg2 \
  testbench_wedge.v fake_axi_ddr.v ../../rtl/mpeg2/mem2axi_bridge.v
vvp testbench_wedge.vvp      # 4/4 escenarios recuperan sin timeout

# en la placa (perf_counters ya expuesto vía sysfs, firmware_development):
python3 profile_decode.py tek60.bits
```

Ver [[decode_rate_bottleneck]] y [[plan_general_action_items]] (memorias de
sesión) y [40]/[41] para el resto de la serie.
