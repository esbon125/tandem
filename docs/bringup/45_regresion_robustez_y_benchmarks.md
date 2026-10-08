# Regresión, robustez y benchmarks en hardware (ítem 7)

Hasta acá cada medición de corrección o de velocidad se hacía a mano, un
stream a la vez. `trunk/mpeg2fpga/tools/regress/regress.py`
(hardware_development) las junta en cuatro suites que corren desde el host
contra la placa por ssh, en ~16 minutos, y comparan contra un baseline
versionado (`tools/regress/baseline.json`). Del lado placa usa
`webserver/capture_framestore.py --json [--no-reset]` y el nuevo
`webserver/bench_decode.py` (firmware_development).

```sh
cd trunk/mpeg2fpga/tools/regress
python3 regress.py all              # o conformance | determinism | robustness | perf
```

## Qué mide cada suite

- **conformance**: 38 streams de conformidad cortados a 8 pictures, contra
  `tools/mpeg2dec` con `framecmp`. Veredicto absoluto (bit-exact /
  idct-slack / close / drift / nothing-written) y veredicto contra el
  baseline. El baseline se compara por un digest de las pictures
  *invariante a la rotación de buffers*, así la deriva conocida de upstream
  no falla pero cualquier cambio sí (probado: un buffer que pasa de MAD 0 a
  0.4 da REGRESSION; un stream que deja de decodificar, también).
- **determinism**: el mismo stream 5 veces con reset del core y 5 con
  `flush_vbuf` (sin reset); todas tienen que dar las mismas pictures, y las
  de ambos modos entre sí.
- **robustness**: tres entradas dañadas (cortada a mitad de picture sin
  sequence_end, 200 bit flips en slice data, 256 KiB de bytes aleatorios),
  y después de cada una `mcp10ccett` cambiado con `flush_vbuf`, **sin
  reset**. Tiene que salir bit-exact.
- **perf**: `bench_decode.py` envenena el framestore, arranca el DMA y mide
  hasta la última escritura en el framestore. 5 corridas por stream después
  de un warm-up, streams de ≥24 frames.

## Dos trampas de medición encontradas armándolo

1. **El sha1 del dump crudo no es estable entre cambios de stream.** Con
   `flush_vbuf` el stream siguiente arranca en el buffer que le toque a la
   rotación, así que las mismas cuatro pictures quedan en otro orden: la
   primera corrida dio dos hashes alternados A,B,A,B,A y parecía
   no-determinismo. No lo es; se compara un digest de los buffers ordenado.
2. **`capture_seconds` de `decode_stream` no es una medida de decode
   rate.** Cuenta una picture cuando un buffer *cambia*; decodificar el
   mismo stream de nuevo sin envenenar reescribe buffers con pictures
   idénticas, no ve nada y termina en el give-up de 3 s (0.6 fps en
   tek-5.2). Con streams de 4 frames, además, domina la latencia de
   arranque. De ahí `bench_decode.py` y streams largos.

## Resultados (60d512a, 2026-10-08)

### Conformance (cut streams vs tools/mpeg2dec)

| stream | pictures | size | verdict | vs baseline | worst MAD(Y) | peak | error | watchdog |
|---|---|---|---|---|---|---|---|---|
| mcp10ccett | 4 | 720x576 | bit-exact | within-tolerance | 0.000 | 0 | False | False |
| tek60 | 8 | 704x480 | close | new | 0.986 | 22 | False | False |
| tek-5.2 | 4 | 704x480 | close | within-tolerance | 0.562 | 21 | False | False |
| tek-5-long | 8 | 704x480 | close | within-tolerance | 0.986 | 22 | False | False |
| att-mismatch | 8 | 32x32 | close | within-tolerance | 0.038 | 1 | False | False |
| ti-c1-2 | 4 | 704x480 | drift | within-tolerance | 5.956 | 155 | False | False |
| toshiba-dpall | 4 | 720x480 | drift | within-tolerance | 8.904 | 220 | False | False |
| sony-ct1 | 8 | 352x224 | drift | within-tolerance | 7.224 | 141 | False | False |
| sony-ct2 | 8 | 704x480 | close | within-tolerance | 0.328 | 8 | False | False |
| sony-ct3 | 8 | 720x480 | close | within-tolerance | 0.474 | 12 | False | False |
| gi4 | 4 | 704x480 | drift | within-tolerance | 17.912 | 197 | False | False |
| gi6 | 4 | 720x480 | drift | within-tolerance | 17.663 | 197 | False | False |
| gi7 | 4 | 720x480 | drift | within-tolerance | 17.664 | 197 | False | False |
| gi9 | 8 | 720x480 | close | within-tolerance | 0.235 | 3 | False | False |
| gi-from-tape | 8 | 720x480 | drift | within-tolerance | 13.909 | 179 | False | False |
| hhi-burst-short | 5 | 720x576 | close | within-tolerance | 0.265 | 2 | False | False |
| hhi-burst-long | 8 | 720x576 | drift | within-tolerance | 13.719 | 226 | False | False |
| ibm-bw | 8 | 720x480 | close | within-tolerance | 0.157 | 1 | False | False |
| lep-11 | 3 | 720x576 | drift | within-tolerance | 18.393 | 188 | False | False |
| mei-16-long | 8 | 352x240 | nothing-written | within-tolerance |  |  | False | False |
| mei-16v2 | 4 | 352x240 | nothing-written | within-tolerance |  |  | False | False |
| mei-2-4f | 4 | 704x480 | drift | within-tolerance | 8.828 | 234 | False | False |
| mei-2-60f | 8 | 704x480 | drift | within-tolerance | 12.543 | 229 | False | False |
| nokia6 | 4 | 720x576 | drift | within-tolerance | 9.835 | 202 | False | False |
| nokia6-60 | 8 | 720x576 | drift | within-tolerance | 14.635 | 211 | False | False |
| nokia7 | 4 | 720x576 | drift | within-tolerance | 25.612 | 255 | False | False |
| ntr-skipped | 8 | 720x576 | drift | within-tolerance | 14.829 | 182 | False | False |
| tceh-conf2 | 8 | 720x576 | drift | within-tolerance | 16.684 | 212 | False | False |
| tcela-6 | 4 | 720x480 | drift | within-tolerance | 18.769 | 193 | False | False |
| tcela-7 | 8 | 720x480 | drift | within-tolerance | 17.298 | 191 | False | False |
| tcela-8 | 8 | 720x480 | drift | within-tolerance | 16.989 | 174 | False | False |
| tcela-9 | 8 | 720x480 | drift | within-tolerance | 16.965 | 174 | False | False |
| tcela-10 | 8 | 720x480 | drift | within-tolerance | 20.463 | 202 | False | False |
| tcela-14-short | 4 | 720x480 | close | within-tolerance | 0.791 | 4 | False | False |
| tcela-14 | 8 | 720x480 | drift | within-tolerance | 1.907 | 6 | False | False |
| tcela-15 | 8 | 720x480 | nothing-written | within-tolerance |  |  | False | False |
| tcela-17 | 2 | 720x480 | drift | within-tolerance | 61.242 | 141 | False | False |
| teracom-vlc4 | 8 | 720x576 | close | within-tolerance | 0.433 | 49 | False | False |
| greyramp | 8 | 720x576 | close | within-tolerance | 0.097 | 2 | False | False |

Verdicts: bit-exact 1, close 12, drift 23, nothing-written 3

### Determinism (tek-5.2, 5 runs per mode)

- reset: 1 distinct picture hash(es) -> OK
- flush_vbuf: 1 distinct picture hash(es) -> OK

### Robustness (damaged stream, then mcp10ccett via flush_vbuf, no reset)

| case | error | watchdog | settled | recovery without reset |
|---|---|---|---|---|
| bitflips | True | False | True | bit-exact |
| random | False | False | True | bit-exact |
| truncated | True | False | True | bit-exact |

### Decode rate (5 timed runs per stream, after a warm-up)

Decode time is DMA start to the last framestore write (webserver/bench_decode.py).

| stream | size | frames | fps mean | sd | min | max | Mpix/s | x real time |
|---|---|---|---|---|---|---|---|---|
| tek60 | 704x480 | 60 | 22.91 | 0.62 | 22.27 | 23.61 | 7.74 | 0.76 |
| tek-5-long | 704x480 | 150 | 22.97 | 0.76 | 21.85 | 23.70 | 7.76 | 0.77 |
| mei-2-60f | 704x480 | 61 | 20.88 | 0.45 | 20.44 | 21.52 | 7.06 | 0.70 |
| nokia6-60 | 720x576 | 60 | 12.08 | 0.63 | 11.33 | 12.62 | 5.01 | 0.48 |
| tcela-7 | 720x480 | 61 | 20.07 | 0.55 | 19.51 | 20.75 | 6.93 | 0.67 |
| hhi-burst-long | 720x576 | 46 | 13.52 | 0.73 | 12.83 | 14.68 | 5.61 | 0.54 |
| sony-ct2 | 704x480 | 24 | 19.90 | 0.79 | 18.73 | 20.77 | 6.72 | 0.66 |
| att-mismatch | 32x32 | 132 | 87.27 | 11.64 | 74.81 | 105.78 | 0.09 | 2.91 |

### Result

No regressions.

(`tek60` figura como `new` porque se agregó al manifiesto después de la
primera corrida; ya está en el baseline.)

## Lectura

**Robustez y determinismo: sin observaciones.** El decoder es determinista
con y sin reset, y ninguna de las tres entradas dañadas lo deja trabado: el
stream limpio siguiente decodifica bit-exact sólo con `flush_vbuf`. El bit
de `error` se levanta en los casos truncado y bit flips; con bytes
aleatorios no (no hay ningún start code para que el VLD se queje). El
watchdog no salta en ningún caso.

**Decode rate.** 20–23 fps en 704/720x480 y 12–13.5 fps en 720x576, con
desvío < 1 fps: entre 0.5x y 0.77x tiempo real. Consistente con Fase 8
(22–23 fps en tek60) y con [44] (el techo está en motcomp_recon). El caso de
32x32 (4 macrobloques por picture) da ~90 fps, o sea ~11 ms por picture
casi sin pixels: hay un costo fijo por picture grande, que vale la pena
entender si se retoma la optimización.

**Conformance: 13 de 36 streams MPEG-2 bien o casi, 23 con deriva, y una
pista fuerte nueva.** Los 11 streams que cargan una matriz intra **no
simétrica** en el sequence header (gi4/6/7/from-tape, lep-11, ntr,
tceh-conf2, tcela-6..10) están mal *desde la picture intra*, MAD 12–18 en
todos los buffers. La mayoría carga literalmente la matriz *por defecto*,
que debería ser un no-op: el camino de valores por defecto anda, el de
**carga** no. Los que cargan matrices simétricas o casi planas (tcela-17
8,1,1…; teracom 8,16,16…; sony-ct3 8,17,17,18…) salen bien o cerca.
`intra_dc_precision=2` no es la causa (gi9 tiene dc=2 y sale bien), ni las
field pictures (sony-ct2/3 son field y salen bien). Esto reemplaza la
hipótesis anterior del ítem 1b.

Descartado leyendo el código: la tabla `scan_reverse` (zigzag→raster) es
correcta y `dpram_sc` tiene la misma latencia que el camino por defecto.
Queda por distinguir si la matriz cargada se aplica transpuesta o corrida
en una posición (la carga en `vld.v:1005-1017` o el traspaso por
`rld_fifo`). Y una segunda desviación de la norma, independiente:
`iquant.v:85/294` des-escanean una matriz descargada usando
`alternate_scan`, cuando §6.3.11 dice que siempre llega en zigzag; afecta a
los sony (alternate_scan=1 + quant_matrix_extension).

Los streams que cargan sólo la non-intra (toshiba, nokia6/7, mei-2,
ti-c1-2) muestran la deriva en P/B del ítem 1: es posible que el ítem 1
sea el mismo bug y no motion compensation. El próximo paso es simular gi4
en Icarus con el trace `$display` de `iquant.v` (líneas 219-228).

`mei-16-long`/`mei-16v2` son MPEG-1 (sin picture coding extension): fuera
de alcance de un core MPEG-2. `tcela-15` (stuffing) parsea el tamaño pero
no escribe ninguna picture: pendiente.
