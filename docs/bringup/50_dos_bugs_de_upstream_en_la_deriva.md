# La deriva que quedaba eran dos bugs del RTL de upstream

**Fecha:** 2026-10-17 a 2026-10-22
**Placa:** PolarFire SoC FPGA Discovery Kit, bitstream `0.1.0+8a6d847` (antes) y `0.1.0+918dde0` (después)
**Commits:** hardware_development `57dfd86` (corte por campos en framecmp), `86ad0d8` (los dos
arreglos de RTL), `918dde0` (binario de mpeg2decode), `ecdf05d` (baseline); firmware_development
`3c3d8da` (manifest y baseline e2e)

## Punto de partida

Después de la bitácora 49 quedaban cinco flujos MPEG-2 con deriva: sony-ct1, hhi-burst-long,
nokia6-60, tcela-10 y tcela-14. La tabla 2.3 de `doc/mpeg2fpga.txt` los da a todos por aprobados.

## sony-ct1 y hhi-burst-long: el corte

`framecmp cut` corta el flujo después de N imágenes. En flujos con imágenes de campo, la imagen
N podía ser el primer campo de un cuadro: el hardware y la referencia tratan distinto un cuadro
al que le falta el segundo campo. Ahora el corte mira `picture_structure` en la extensión de
codificación de imagen y, si terminaría en un primer campo, se lleva también el segundo
(`57dfd86`). Con el corte nuevo, los dos flujos quedan en "cercano" (MAD ≤ 0,39).

## ¿Pasaba en el original? Simulación

La simulación Icarus del RTL sin modificar da **el mismo volcado, bit a bit**, que la placa en
los tres buffers que alcanzó a terminar de tcela-10 (unas dos horas de simulación por volcado).
La deriva no la introdujo el port; estaba en el diseño original.

Simular hasta las imágenes B no es práctico. El método que funcionó fue otro: **modificar una
copia de `mpeg2decode` para que se comporte como se sospecha que se comporta el hardware**, y
ver si los volcados de la placa coinciden con esa referencia. Si coinciden al nivel de ruido de
la IDCT (MAD ~0,005), la hipótesis queda confirmada sin simular nada.

## Bug 1: redondeo del promedio adelante/atrás (`motcomp_recon.v`)

nokia6-60 y tcela-14 tenían un sesgo puro: media con signo ≈ −MAD, creciendo en cada imagen P.
Ambos usan predicción dual prime, que promedia dos predicciones dentro de una imagen P (que
después es referencia).

```verilog
wire signed [9:0]fwd_bwd_prediction_pixel_round_5 = {9'b0, ~fwd_bwd_prediction_pixel_5[9]};
2'b11: prediction_pixel_6 <= (fwd_bwd_prediction_pixel_5 + fwd_bwd_prediction_pixel_round_5) >>> 1;
```

Los píxeles se guardan con signo (offset −128). El redondeo dependía del signo de la suma: para
píxeles por debajo de 128 redondeaba hacia abajo. La norma (7.6.7) pide `(a + b + 1) >> 1` en
el dominio sin signo, que en el dominio con signo es sumar siempre 1.

Prueba: `recon.c` de la copia con `(v>=256?1:0)` en lugar de `+1`.

| flujo | MAD contra la referencia | MAD contra la referencia con redondeo del hardware |
|---|---|---|
| nokia6-60 | 1,79 | 0,024 |
| tcela-14 | 1,62 | 0,023 |

El mismo bug explica los ~0,26 de MAD en las imágenes B de casi todos los flujos "cercanos"
(ffmpeg contra la referencia con redondeo del hardware da 0,257).

Arreglo: `fwd_bwd_prediction_pixel_round_5 = 10'sd1`.

## Bug 2: matrices de cuantización con el scan de la imagen anterior (`iquant.v`)

tcela-10 no mejoraba con el arreglo del redondeo. Para saber si el que fallaba era el hardware o
la referencia, se decodificó el corte con ffmpeg, un decodificador independiente: ffmpeg y
`mpeg2decode` coinciden (MAD 0,021); el hardware se aparta (2,40).

El error empieza en el campo I superior de la segunda imagen de referencia (tr 59). Firma:

- DC exacto, solo AC; nada de mezcla de campos, desenfoque ni corrimiento.
- Con la DCT de cada bloque, la ganancia hardware/referencia **por posición de coeficiente** era
  exactamente 1,000 en muchas posiciones y en otras un cociente de valores de la matriz:
  22/19, 16/19, 19/16, 26/22.

Esos cocientes salen si la matriz se ubica con el **scan alternativo** en vez del zigzag.
El flujo tiene una segunda cabecera de secuencia que recarga las matrices, y llega después de
una imagen con `alternate_scan=1`. En `iquant.v`:

```verilog
STATE_RUN:   iquant_wr_addr <= scan_reverse(alternate_scan, wr_addr);
```

`alternate_scan` es el de la imagen anterior. La norma (6.3.11) transmite las matrices siempre en
orden zigzag; el propio comentario de upstream lo dice ("so here we un-zigzag it using
scan0_reverse"). La primera cabecera llega antes de cualquier imagen (`alternate_scan` en 0),
por eso la primera I salía bien.

Prueba: la copia de `mpeg2decode` cargando las matrices con `scan[ld->alternate_scan]` (más el
redondeo del bug 1). tcela-10 queda en MAD 0,005–0,009 en los cuatro buffers.

Arreglo: `scan_reverse(1'b0, wr_addr)` en `intra_quant_matrix` y `non_intra_quant_matrix`.

## Resultado

Bitstream `0.1.0+918dde0`: temporización sin violaciones en las tres esquinas (setup peor
mem_clk +1,22 ns, clk +0,95 ns; hold todo positivo), mismos recursos (35 427 LUT).

| | antes (8a6d847) | después (918dde0) |
|---|---|---|
| bit-exacto | 3 | 3 |
| cercano | 29 | 34 (3 dentro de la holgura de la IDCT) |
| deriva | 5 | 0 |
| sin escritura (MPEG-1) | 2 | 2 |

El peor buffer de toda la batería tiene MAD 0,038 (att-mismatch); 30 de los 34 cercanos están
por debajo de 0,02. Antes, tek60 daba 0,986 con pico 22; ahora 0,010 con pico 2.

`qualify.sh 0.1.0-rc4`: conformidad sin regresiones, determinismo y robustez OK, decodificación
igual que antes (tek60 23,6 fps, clip CIF 53,7 fps), punta a punta 19,0–19,5 fps (piso 18).
El clip de la demo contra `mpeg2decode`: MAD medio 0,073 → 0,0096, PSNR-Y mínimo 55,8 → 64,8 dB.

Dos tropiezos en el camino:

- El primer bitstream salió con sello `-dirty`: el árbol tenía el binario `mpeg2decode`
  reconstruido sin commitear, y el sello mira todo `trunk/mpeg2fpga`. Se commiteó y se
  resintetizó (918dde0).
- tcela-14-short dio "no-decode": el corte en `work/` era texto. Al preparar las simulaciones,
  un glob `tcela-14-*` agarró también ese archivo y la salida de `xxd` lo pisó. Borrado el
  caché, cercano. Ningún otro corte estaba dañado.

## Lecciones

- Cuando la simulación y la placa coinciden bit a bit, el bug es del diseño, no del port.
- Una referencia "con el bug" es un experimento barato: si el hardware coincide con ella, la
  hipótesis está confirmada sin horas de simulación.
- Un tercer decodificador independiente desempata entre el hardware y la referencia.
- La firma del error en el dominio de la DCT (qué coeficientes, qué cocientes) apunta directo al
  bloque responsable.
