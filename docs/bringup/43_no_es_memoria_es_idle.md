# No es FWD/BWD: el árbitro está idle el 90% del tiempo

Cierra la pregunta que dejó abierta [42]: después de pipelinear lecturas
**y** escrituras, ~75-80% de los ciclos seguían sin explicación de ningún
contador existente. Los candidatos eran dos, y solo dos, porque los estados
del árbitro de `framestore_request.v` son *one-hot* y mutuamente
excluyentes: FWD/BWD (lecturas de referencia de compensación de
movimiento) o `STATE_IDLE` genuino.

## El resultado

```
disp_service_cnt    8.0%
vbr_service_cnt     0.2%
write_service_cnt   2.6%
fwd_service_cnt     1.8%
bwd_service_cnt     1.2%
idle_cnt           90.0%
--------------------------------
suma              103.7%  (de un total estimado por wall-clock -- el 3.7%
                            de más es holgura normal de la medición, no
                            una señal de alarma)
```

**No es FWD/BWD.** Combinados son apenas 3% de los ciclos. El árbitro
directamente **no tiene nada para atender el 90% del tiempo**.

## Qué significa

La memoria dejó de ser el cuello de botella. Con las dos fases de
pipelining (lecturas en [41], escrituras en [42]) el puerto de memoria
tiene margen de sobra — el árbitro se queda esperando porque **nadie le
está pidiendo servicio**, no porque no pueda atender los pedidos rápido.
El límite ahora está *antes* del árbitro: en el pipeline de cómputo del
decoder (VLD parseando el bitstream, cálculo de vectores de movimiento,
IDCT, o el propio motor de reconstrucción) generando trabajo más lento de
lo que la memoria, ya optimizada, puede absorber.

Esto encaja con el profiling original (antes de tocar nada en Fase 8):
"VLD starved solo 0.2% del tiempo" — el VLD casi nunca esperaba *mucho*
por datos, porque `vbuf` lo amortiguaba bien incluso con memoria lenta. Lo
que esa lentitud de memoria tapaba era el costo fijo por macrobloque del
cómputo mismo, que ahora, con la memoria fuera del camino, quedó expuesto
como el nuevo techo.

## Consecuencia para el próximo paso

**Bursts (`arlen>0`, el "lever 3" que se venía barajando) no daría casi
nada.** Con el árbitro idle 90% del tiempo, no hay suficientes
transacciones en cola esperando ser agrupadas — agruparlas más no ayuda
si el problema ya no es cuántas transacciones de memoria hay, sino cuánto
tarda el decoder en *generar* la próxima.

Cualquier mejora real de acá en más necesita tocar el núcleo de
decodificación/reconstrucción en sí (`vld.v`, `idct.v`, `motcomp*.v`) —
IP licenciada de terceros (ver `rtl/mpeg2/LICENSE-MPEG2`), que
`CLAUDE.md` pide mantener lo más cerca posible del upstream salvo cambios
específicos del port. Es un terreno bastante más delicado que
`mem2axi_bridge.v` (nuestro propio wrapper, sin restricción de licencia) —
tocar el núcleo del decoder es un cambio de otra categoría de riesgo, no
una continuación directa de las dos fases anteriores.

## Números finales de la serie completa (Fase 8, docs 41-43)

| | fps (`tek60`, 704x480) |
|---|---|
| baseline | 7.2 |
| + lecturas pipelinadas | ~19.3 |
| + escrituras pipelinadas | **~22-23** |

~3.1x sobre el baseline, `framecmp` bit-idéntico contra la referencia en
cada paso. El árbitro de memoria, que era el cuello de botella original
(97% idle *esperando* la memoria, según el profiling de Fase 8 original),
ahora está idle 90% del tiempo por la razón opuesta: le sobra capacidad.

## Cómo reproducir

```sh
# en la placa, después de al menos un decode previo (el core necesita
# reset=True una vez tras programar; profile_decode.py siempre usa
# reset=False, así que hace falta un warm-up primero, p.ej. bench_decode.py):
python3 bench_decode.py tek60.bits
python3 profile_decode.py tek60.bits
```

Ver [[decode_rate_bottleneck]] y [[plan_general_action_items]] (memorias
de sesión), y [41]/[42] para el resto de la serie.
