# El "bug de matrices de cuantización" estaba en la referencia

**Fecha:** 2026-10-17
**Placa:** PolarFire SoC FPGA Discovery Kit, bitstream `0.1.0+8a6d847`
**Commits:** hardware_development `d91aecd` (arreglo de `tools/mpeg2dec`), `3c47b67` (baseline);
firmware_development `4e7a67f` (manifest con 8a6d847)

## Antes: calificar 8a6d847

Programada la placa con 8a6d847 (`SCRIPT_ARGS:PROGRAM` sobre el proyecto existente, que ya era
8a6d847) y corrido `release/qualify.sh 0.1.0-rc3`: conformidad idéntica al baseline, determinismo
y robustez OK, punta a punta 19,3–19,5 fps (piso 18). Fijado en `release/manifest.json`.

## El síntoma

Desde la primera regresión completa (bitácora 45), los 11 flujos que cargan una matriz intra en la
cabecera de secuencia (gi4/6/7/from-tape, lep-11, ntr, tceh-conf2, tcela-6..10) daban MAD 12–18
desde la imagen intra. La mayoría carga la matriz **por defecto**, así que se concluyó que el
camino de carga del núcleo estaba mal (plan, ítem 1b).

## Lo que lo desmintió

1. **Simulación con un monitor jerárquico** sobre `intra_quantiser_matrix` (sin tocar el RTL):
   las 64 escrituras de gi4 caen en la dirección raster correcta con el valor correcto, y 200 000
   lecturas posteriores coinciden con `default_intra_quant()`.
2. **La tabla 2.3 de `doc/mpeg2fpga.txt`** (la señaló el autor): upstream declara aprobados todos
   esos flujos MP@ML. Solo marca tcela-9 "1 bit off" y mei-16* como MPEG-1 no soportado.
3. **Mirar las imágenes**: el buffer 0 del hardware es nítido; `frame_00_out_` de la referencia es
   una imagen en bloques.

## La causa

`tools/mpeg2dec/gethdr.c`, `sequence_header()`: los `Get_Bits(8)` de las dos matrices estaban
dentro de `if (Trace_Flag)` (modificación de depuración en la copia de upstream). `framecmp`
corre `mpeg2decode` sin `-t`: la referencia no cargaba la matriz ni consumía los 512 bits.
`quant_matrix_extension()` sí lee siempre; por eso solo fallaban las cargas en la cabecera de
secuencia.

## Resultado

Las 39 capturas del hardware son idénticas (mismo sha1) antes y después; cambian solo los
puntajes:

| | antes | después |
|---|---|---|
| bit-exacto | 1 | 2 (mcp10ccett, tcela-17) |
| cercano | 12 | 29 |
| deriva | 23 | 5 |
| sin escritura | 3 | 3 |

gi4: MAD 17,9 → 0,005 (pico 1) en la intra. También se fue casi toda la "deriva P/B" del ítem 1
(toshiba, ti-c1-2, mei-2, nokia6/7 cargan matriz non-intra).

Quedan:
- **sony-ct1, hhi-burst-long**: dos buffers ~bit-exactos, dos con MAD 7–13 y pico ~140–226 →
  probablemente emparejamiento buffer↔cuadro en el flujo cortado, no decodificación.
- **nokia6-60, tcela-10, tcela-14**: deriva chica en P/B (MAD 1,6–2,4).
- **mei-16-long, mei-16v2**: MPEG-1 (ningún `00 00 01 B5`), fuera de alcance del núcleo.
- **tcela-15** (stuffing): MPEG-2, upstream lo da por aprobado; sin investigar.

## Lección

Cuando la documentación de un núcleo de terceros dice que un flujo pasa y nuestra medición dice
que no, sospechar primero de la referencia y de la comparación, y mirar las dos imágenes antes de
leer el RTL.

## Adenda (mismo día): tcela-15 tampoco estaba roto

**Commits:** hardware_development `1f80151` (framecmp), `f8cb047` (baseline)

tcela-15 (stuffing) daba "sin escritura". Estructura: cada imagen son ~280 bytes de slices
(30 de 180 bytes en la I) seguidos de 57–62 KB de ceros hasta el próximo start code. Su
referencia es **gris 128 uniforme** en todos los planos y cuadros.

- La simulación recorre los 1350 macrobloques y vuelca el framestore; `framecmp` igual decía
  "never written".
- Por el daemon, el hardware entrega 8 cuadros completos, todos Y = U = V = 128.
- Causa: `framecmp.is_blank()` llamaba vacío a todo buffer uniforme. El gris 128 se guarda como
  ceros (offset −128), uniforme. Los buffers de verdad vacíos tienen el byte crudo `0x80` con que
  `framestore_request.v` limpia la memoria al arrancar (0 tras el `^0x80`) o el veneno `0xEE`
  de `capture_framestore.py` (110). Ahora solo esos dos valores cuentan como vacío.

Resultado: tcela-15 bit-exacto; los otros 38 sin cambios. Conformidad final: **3 bit-exactos,
29 cercanos, 5 con deriva, 2 sin escritura (los dos MPEG-1)**.
