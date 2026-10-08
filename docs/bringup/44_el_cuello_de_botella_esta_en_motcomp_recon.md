# El cuello de botella está en motcomp_recon, no en memoria ni en el clock

Continúa [43]: con el árbitro de memoria idle 90% del tiempo, había dos
hipótesis de bajo riesgo para probar en paralelo antes de tocar el núcleo
licenciado del decoder (`vld.v`/`idct.v`/`motcomp*.v`): subir el clock, o
instrumentar exactamente qué señal de `vld_en` está bloqueando al VLD.
Ambas se probaron. Ninguna de las dos "arregla" nada por sí sola, pero
juntas señalan con precisión dónde está el techo real.

## Intento 1: subir el clock de 108 a 162 MHz — resultado negativo

El PLL (`PF_CCC_C0.tcl`) tiene margen de timing de sobra (confirmado:
`VERIFY_TIMING` cierra limpio a 162 MHz, hold-repair en la misma clase de
slack que siempre). Si el límite fuera de *cantidad de ciclos*, 1.5x más
clock debería traducirse directamente en más fps.

No lo hizo. fps se mantuvo plano (~20.7-21 vs ~22.6 a 108 MHz, dentro del
ruido de medición). `framecmp` confirmó cero regresión de corrección —
los mismos MAD/PSNR bit-idénticos de siempre.

**Conclusión:** el cuello de botella tiene un componente de **tiempo real
(latencia física)**, no de conteo de ciclos. Revertido a 108 MHz (no hay
ninguna razón para quedarse en un punto de operación más agresivo sin
beneficio).

## Intento 2: desglosar vld_en — primero una trampa de direccionamiento

`getbits.v` gatea el avance del VLD con:

```verilog
vld_en = (next==STATE_READY) && ~wait_state && ~rld_wr_almost_full
         && ~mvec_wr_almost_full && ~motcomp_busy
```

Se agregaron contadores (`vld_en_cnt`, `vld_stall_rld_cnt`,
`vld_stall_motcomp_cnt`) para medir exactamente cuál de esas condiciones
bloquea. Resultado en hardware real:

```
vld_en_cnt              1.7%
vld_stall_rld_cnt      42.9%
vld_stall_motcomp_cnt  33.1%
```

VLD activo solo 1.7% del tiempo. Para separar "motcomp busy" en algo más
accionable, se agregaron cuatro contadores más (`fwd_addr_empty_cnt`,
`fwd_dta_stall_cnt`, `bwd_addr_empty_cnt`, `bwd_dta_stall_cnt`) apuntando
a dos hipótesis distintas: ¿no hay direcciones de referencia en cola
(generación de direcciones lenta), o las direcciones están pero el fifo
de datos de retorno está lleno (motcomp no drena)?

**Los cuatro leyeron exactamente cero.** No porque la condición nunca
ocurriera — sino porque esas direcciones APB (0x40-0x45) **nunca llegan
al bridge**. La ventana APB real del periférico está fija en 256 bytes
(0x00-0x3f) por dos lugares independientes: el pin bif de
`FIC_3_PERIPHERALS.tcl` (literalmente llamado `FIC_3_0x4000_04xx`) y
ambos overlays de device tree (`mpeg2fpga.dts`/`mpeg2fpga-uio.dts`,
`reg = <... 0x100>`). `PSEL` nunca se activa para direcciones fuera de
ese rango — lectura en falso, no dato real.

Corregido reubicando los seis contadores dentro de la ventana real
(0x31-0x36), reciclando seis de las ocho palabras de debug de
`SCFIFO_DBG` (ese bug de port-sharing de `xfifo_sc` está RESUELTO, ver
[38]). Ensanchar la ventana real habría significado tocar el decodificador
de direcciones de `FIC_3_ADDRESS_GENERATION` + ambos overlays — un cambio
de mapa de direcciones a nivel de sistema, fuera de alcance acá.

## Con el direccionamiento corregido: el verdadero gate es el tag fifo

Repetida la medición con las direcciones correctas:

```
fwd_addr_empty_cnt      64%    (no es esto)
fwd_dta_stall_cnt        3%    (no es esto)
bwd_addr_empty_cnt      68%    (no es esto)
bwd_dta_stall_cnt        0%    (no es esto)
mem_req_almost_full_cnt  1.6%  (no es esto)
tag_almost_full_cnt     76.9%  (ESTO)
```

`tag_wr_almost_full` — el flag de casi-lleno de `mem_tag_fifo`, que
bloquea *toda* lectura nueva (disp/vbr/fwd/bwd, no solo motion comp) —
estaba asertado 77% del tiempo. `mem_req_wr_almost_full` (la cola de
salida hacia `mem2axi_bridge`), en cambio, casi nunca.

Causa raíz: `MEMTAG_THRESHOLD` reutilizaba la misma constante
`MEM_THRESHOLD=16` que usa `MEMREQ_THRESHOLD`, pero `mem_tag_fifo` tiene
la mitad de profundidad que `mem_request_fifo` (32 vs 64 entradas) — la
misma reserva de "16 lugares libres" dispara el casi-lleno al 50% de
ocupación en vez del 75% para el que la constante estaba pensada.

## Intento 3: corregir el threshold del tag fifo — también resultado negativo

Se subió `MEMTAG_THRESHOLD` a 8 (mismo margen proporcional que
`OSD_THRESHOLD` ya usa para otro fifo de 32 entradas en el mismo
archivo), permitiendo hasta 24 pedidos en vuelo en vez de 16. Seguro
porque la invariante real (`DTA_THRESHOLD > 2**MEMTAG_DEPTH`) no depende
del threshold sino de la profundidad, que no se tocó.

Medido en hardware: `tag_almost_full_cnt` bajó de 77% a ~66%. **fps no se
movió**, y `vld_stall_rld_cnt`/`vld_stall_motcomp_cnt` quedaron en el
mismo orden de magnitud combinado (~75-80%).

**Conclusión:** la plumbing de memoria tenía margen de sobra todo este
tiempo. Aliviarla no mueve la aguja — el límite está más abajo en la
cadena.

## El hallazgo que sí conecta las piezas: predict_err_fifo

`rld.v` ya cablea internamente `idct_fifo_almost_full` (el `prog_full`
de `predict_err_fifo`, la salida de IDCT / entrada de `motcomp_recon`)
hacia su propia lógica de stall — nunca estuvo instrumentado. Se agregó
`predict_err_almost_full_cnt` (expone esa señal) y
`rld_stall_predict_err_cnt` (mide la superposición exacta: `~vld_en &&
rld_wr_almost_full && idct_fifo_almost_full`).

```
rld_stall_predict_err_cnt / vld_stall_rld_cnt = 78-81%
```

**78 a 81% del tiempo que VLD está bloqueado por `rld_fifo` lleno
coincide con que `predict_err_fifo` también está casi lleno.** Esto
conecta los dos stalls dominantes de VLD (juntos ~75-80%) al mismo
origen: `motcomp_recon` no drena lo suficientemente rápido, lo cual
retropropaga presión tanto a su propia entrada (`motcomp_busy`, medido
directo) como, vía `predict_err_fifo`, hasta bloquear a `rld_fifo` y de
ahí a VLD mismo.

## Conclusión

El techo real de decode rate está **dentro de `motcomp_recon.v`/
`motcomp.v`** — su propio ritmo de reconstrucción, no:

- el clock (probado, sin efecto)
- la memoria / el árbitro (idle 90%+, con amplio margen incluso después
  de aliviar el tag fifo)
- la generación de direcciones de referencia (fwd/bwd address fifos
  rara vez vacíos)
- el fifo de pedidos salientes hacia `mem2axi_bridge` (`mem_req_wr_almost_full`
  casi nunca asertado)

El propio comentario de cabecera de `motcomp_recon.v` dice "puede producir
una fila de 8 píxeles cada dos ciclos... en la práctica esto significa que
la velocidad está limitada por cuán rápido el subsistema de memoria puede
alimentarlo con píxeles" — hoy queda claro que esa frase apunta a algo
distinto de lo que decía literalmente: no es la memoria la que no puede
alimentarlo (tiene margen de sobra), es el propio motor de reconstrucción
el que no drena lo que ya tiene.

## Siguiente paso, no tomado todavía

`motcomp_recon.v`/`motcomp.v` son IP licenciada de terceros
(`rtl/mpeg2/LICENSE-MPEG2`) — `CLAUDE.md` pide mantenerse cerca del
upstream ahí. Cualquier instrumentación futura debería ser un tap de
solo lectura, sin tocar su lógica interna. Terreno de otra categoría de
riesgo que `mem2axi_bridge.v`/`framestore_request.v` (nuestro propio
código de wrapper, sin restricción de licencia).

## Decisión sobre el clock

Placa dejada en 108 MHz (el bump a 162 MHz no mostró ningún beneficio
que justifique el punto de operación más agresivo).

## Cómo reproducir

```sh
# en la placa, con el core ya habilitado (echo 1 > .../enable):
python3 profile_decode.py tek60.bits
```

Los contadores relevantes de este doc:
`vld_en_cnt`, `vld_stall_rld_cnt`, `vld_stall_motcomp_cnt`,
`fwd_addr_empty_cnt`, `fwd_dta_stall_cnt`, `bwd_addr_empty_cnt`,
`bwd_dta_stall_cnt`, `mem_req_almost_full_cnt`, `tag_almost_full_cnt`,
`predict_err_almost_full_cnt`, `rld_stall_predict_err_cnt` — todos vía
`perf_counters` sysfs (driver `firmware_development`), direcciones
0x31-0x3f de `apb3_mpeg2fpga_bridge.v` (`hardware_development`).

Ver [[decode_rate_bottleneck]] y [[plan_general_action_items]] (memorias
de sesión, actualizadas con este resultado), y [43] para el punto de
partida de esta investigación.
