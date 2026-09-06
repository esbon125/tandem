# Una forma confiable de comparar frames, y lo que dice del hardware

Cierra el **action item 0** de [39](39_baseline_post_uram_y_action_items.md): no
teníamos manera de decir si un frame del hardware estaba bien. Ahora sí, y la
respuesta es mucho mejor de lo que sugería el doc anterior.

## Resumen

**El hardware decodifica bien.** En cuatro streams distintos los frames intra
salen con MAD **0.004–0.005** y error pico **1** contra el decoder de
referencia, en luma y en las dos crominancias — o sea, la única diferencia es el
último bit que IEEE 1180 permite entre dos IDCT conformes. Eso incluye imágenes
de contenido real: el frame intra de `Tek-5.2` tiene desviación estándar 60.8 y
254 valores de luma distintos.

Y el port **reproduce la simulación upstream byte por byte**: en `tcela-17`,
corrido entero por los dos caminos, los dos frame stores son idénticos.

El famoso "MAD ~121" del doc 39 era enteramente un artefacto del método. El
error dominante: **el frame store guarda los píxeles como enteros con signo
desplazados en −128**, y se los estaba leyendo sin signo. Eso solo ya produce un
MAD cercano a 128.

Lo que queda roto es más chico y más preciso de lo que se creía: la
**compensación de movimiento** con movimiento real.

## El método

`trunk/mpeg2fpga/tools/framecmp/framecmp.py` (rama `hardware_development`).

La decisión de diseño que importa: **simulación y hardware se comparan con el
mismo código**. `bench/iverilog/mem_ctl.v` ahora vuelca el frame store como
palabras crudas de 64 bits little-endian — byte por byte lo mismo que un volcado
de esa región de DDR en la placa — así que el extractor existe una sola vez, se
valida contra la referencia en simulación, y después se reusa tal cual en
hardware. Las reglas de extracción eran justamente la parte que estaba mal; no
tiene sentido escribirlas dos veces.

### Las trampas, una por una

| trampa | qué pasa si se ignora |
|---|---|
| píxeles **con signo, offset −128** (`motcomp_recon.v`) | todo desplazado 128 → MAD ~128 |
| el píxel izquierdo de una palabra es el bit [63:56] | en un volcado little-endian los 8 píxeles salen **al revés** |
| 4 buffers rotativos, orden de decodificación ≠ orden de display | no hay mapeo fijo buffer→frame; hay que buscar el mejor match |
| el plano de salida de la referencia es `frame_NN_out_` | `aux` es un buffer de scratch |
| `COMP_CR`/`COMP_CB` llevan los bloques 4/5, o sea **Cb/Cr** | los nombres internos están cruzados respecto del estándar |
| cortar el stream en un byte cualquiera | el hardware escribe una imagen parcial encima de un buffer que sí estaba bien, y la referencia no emite frame para esa imagen |
| volcar mientras la reconstrucción sigue en vuelo | frame roto a la mitad, que se lee como bug del decoder |

Las dos últimas se resuelven con `framecmp.py cut` (corta en frontera de imagen
y agrega un `sequence_end_code`) y con una espera de asentamiento: en `mem_ctl.v`
`update_picture_buffers` solo **arma** el volcado, que ocurre cuando el frame
store lleva 20000 ciclos sin escrituras; en la placa se espera a que el
contenido deje de cambiar.

En vez de adivinar qué buffer corresponde a qué frame, se puntúa **cada buffer
contra cada frame de referencia** y se reporta el mejor. Un decode correcto da
un único puntaje casi cero por buffer, y la separación es enorme: en el stream
`att` el match correcto da 0.007 y el segundo mejor 11.7.

### Criterio de aceptación: primero la simulación

Como pedía el doc 39. Con `att_mismatch` (32×32, frame pictures) la simulación
da:

| buffer | frame | MAD(Y) | pico | MAD croma |
|---|---|---|---|---|
| 0 | 00 | **0.007** | 1 | 0.000 / 0.000 |
| 1 | 01 | **0.013** | 1 | 0.000 / 0.000 |

Error pico 1 es exactamente la discrepancia que IEEE 1180 permite entre dos
IDCT conformes. El método pasa.

### Y algo mejor: el port reproduce la simulación bit a bit

Corriendo `tcela-17` completo por los dos caminos y comparando **la simulación
contra el hardware directamente**, sin la referencia en el medio:

| buffer | Y | Cr | Cb |
|---|---|---|---|
| 0 | MAD 0.0000, pico 0 | 0.0000, 0 | 0.0000, 0 |
| 1 | MAD 0.0000, pico 0 | 0.0000, 0 | 0.0000, 0 |

**El frame store del hardware es byte por byte el de la simulación.** Lo mismo
para el frame intra de `Tek-5.2` (704×480) y para el buffer 1 de `toshiba`
(720×480, mismo corte de stream por los dos lados). Eso es más fuerte que
cualquier MAD contra la referencia: dice que el port a PolarFire no introduce
ninguna diferencia respecto del diseño upstream.

## Lo que mide en hardware

Todas las corridas: stream cortado en frontera de imagen, empujado por DMA,
frame store de 12 MiB volcado de `/dev/udmabuf-ddr-nc0`, `error=0`,
`watchdog=0`. Cada corrida tarda unos 4 segundos.

| stream | tamaño | estructura | intra | predichos | movimiento¹ |
|---|---|---|---|---|---|
| `mcp10ccett` | 720×576 | I P B B | **0.000** | **0.000 / 0.000 / 0.000** | 0.4 |
| `att_mismatch` | 32×32 | I P | — | **0.016 / 0.018** | 62 |
| `Tek-5.2` | 704×480 | I P B B | **0.004** | 0.56 / 0.45 / 0.48 | 23–31 |
| `TI_c1_2` | 704×480 | I P B B | **0.004** | 5.96 / 4.38 / 5.21 | 15–20 |
| `sony-ct1` | 352×224 | field | **0.005** | 7.22 / 0.27 / 4.56 | 4–9 |
| `toshiba_DPall-0` | 720×480 | I P P P | — | 8.26 / 8.90 | 14–23 |
| `gi4` | 704×480 | I P B B | **17.9** | 15.7 / 14.4 / 14.6 | 12–20 |

¹ MAD entre el frame 0 y los siguientes en la referencia: cuánto se mueve la
escena, o sea cuánto ejercita realmente la compensación de movimiento.

Cuidado con leer el 0.000 de `mcp10ccett` como la mejor evidencia: su imagen es
casi plana (desviación estándar 3.5, 10 valores de luma distintos) y su escena
es casi estática. Es una prueba fuerte del camino residual y del
direccionamiento, no de la predicción. La evidencia de contenido real son los
frames intra de `Tek-5.2` y `TI_c1_2`.

Y la simulación en el mismo stream de 32×32 da 0.007/0.013 donde el hardware da
0.016/0.018: coinciden entre sí y con la referencia.

Nota al pasar: `DISP_SIZE = 120×120` con `sony-ct1` **no es un bug**. El stream
declara `display_horizontal_size=120, display_vertical_size=120`. El action item
3 del doc 39 se puede cerrar. En streams sin `sequence_display_extension` el
registro lee 0×0, que también es correcto.

## Lo que esto prueba, y lo que no

**Prueba** que la cadena residual completa es exacta en silicio: VLD → RLD →
`iquant` → `idct` → `predict_err_fifo` → `motcomp_recon` → frame store, con el
direccionamiento de los tres planos y de los cuatro buffers. Los frames intra de
contenido real dan pico 1, y `mcp10ccett` sale bit a bit idéntico en los cuatro
buffers. Eso vuelve innecesaria buena parte de la bisección que planteaba el
action item 1, y cierra el action item 2 (croma): las crominancias siguen a la
luma en todos los casos, 0.001–0.003 donde la luma da 0.004.

**Prueba también** que el port no cambió nada respecto del diseño original: en
`tcela-17`, corrido entero por los dos caminos, el frame store del hardware es
byte por byte el de la simulación.

**No prueba** que la compensación de movimiento esté bien, y de hecho ahí está
el problema.

## El defecto que queda: predicción con movimiento real, y **no es del port**

Esto es lo primero que hay que fijar, porque cambia a quién hay que ir a buscar.
La simulación upstream, corrida sobre los mismos streams, da **los mismos
números** que el hardware:

| stream | buffer | simulación | hardware |
|---|---|---|---|
| `tcela-17` | 0 | 0.136 | 0.136 |
| `tcela-17` | 1 | 61.242 | 61.242 |
| `Tek-5.2` | intra | 0.004 | 0.004 |
| `toshiba` | 1 | 2.308 | 2.308 |

O sea que el error en las imágenes predichas **ya está en `bench/iverilog`**, con
el `mem_ctl.v` de referencia y sin nada de PolarFire en el medio. No es un bug
del port: es una diferencia entre mpeg2fpga y el decoder de referencia. Buscarla
en Libero, en el AXI o en los FIFOs sería perder el tiempo; se bisecta en
simulación, que es mucho más barato de instrumentar.

### Dónde está

`mcp10ccett` sale perfecto pero es una escena casi estática — la diferencia
entre su frame 0 y su frame 3 es de MAD 0.37. O sea que sus imágenes P y B
apenas ejercitan la compensación de movimiento. Los streams que **sí** tienen
movimiento (`Tek-5.2` 23–31, `TI_c1_2` 15–20, `toshiba` 14–23 de diferencia
entre frames) son exactamente los que fallan en las imágenes predichas.

El error no está concentrado: en la imagen P de `TI_c1_2`, 1187 de 1320
macrobloques difieren, y la distribución de error es ancha (34% de los píxeles
exactos, 31% con error 3–8, 3.4% con error mayor a 33). No es redondeo, y no es
un modo de codificación raro que aparece de a ratos.

Con una excepción que vale oro para bisecar: **`att_mismatch` decodifica bien
sus imágenes P** (MAD 0.016, pico 1) **y tiene muchísimo movimiento** (MAD 62
entre frames). Su diferencia con los demás es el tamaño: 32×32, o sea
`mb_width = 2` contra 44–45. Eso apunta a la aritmética de direcciones de
`mem_addr.v` — el multiplicador `address_7 <= pixel_y_6 * mb_width_6` y lo que
sigue — o a algo que solo se ejerce cuando un vector de movimiento cruza filas
de macrobloques. Es una hipótesis falsable barata: sintetizar o simular con un
stream angosto y otro ancho, mismo contenido.

Aparte, **`gi4` falla ya en la imagen intra** (MAD 17.9, todos los macrobloques;
medido solo en hardware, todavía no en simulación), lo cual es un defecto
distinto. Sus rasgos propios son `intra_dc_precision=2` y
`concealment_motion_vectors=1`; `alternate_scan=1` queda descartado porque
`Tek-5.2` también lo usa y su intra sale exacta. `intra_dc_precision` es el
sospechoso: un DC mal escalado corre un bloque 8×8 entero de forma uniforme, que
es el patrón observado. Ver `rld.v` alrededor del `case (intra_dc_precision)`.

## Cómo usarlo

```sh
cd trunk/mpeg2fpga
make -C tools/mpeg2dec

# stream cortado en frontera de imagen + frames de referencia
python3 tools/framecmp/framecmp.py cut \
    tools/streams/ccett/mcp10ccett/mcp10ccett.bits 4 -o /tmp/s.bits
python3 tools/framecmp/framecmp.py ref /tmp/s.bits -o /tmp/ref

# hardware
scp /tmp/s.bits root@192.168.18.5:/root/webserver/
ssh root@192.168.18.5 'cd /root/webserver && python3 capture_framestore.py s.bits -o /tmp/hw.bin'
scp root@192.168.18.5:/tmp/hw.bin root@192.168.18.5:/tmp/hw.txt /tmp/
python3 tools/framecmp/framecmp.py compare /tmp/hw.bin /tmp/ref -d

# simulación: apuntar bench/iverilog al mismo stream y comparar fs_NNNN.bin
```

`-d` imprime el mapa de qué macrobloques difieren, que es lo primero que
conviene mirar: error parejo es deriva, error concentrado es un modo de
codificación mal implementado.

El código de salida es 0 si todos los buffers escritos matchean dentro del
umbral, así que sirve como test de regresión — el que faltaba desde el
principio de la Fase 7a (action item 11 del doc 39).

## Alcance

Esto compara el **frame store**, no la salida de video. El camino de display
(`resample`, `yuv2rgb`, `pixel_queue`, `syncgen`) queda igual de sin verificar
que antes.
