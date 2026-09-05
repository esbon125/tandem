# Baseline post-fix y action items hasta el producto

Estado medido después del fix de `uram` ([38](38_fase7a_RESUELTO_uram.md)).
Reemplaza cualquier lista de pendientes anterior.

## Lo que funciona, verificado en hardware

Push de `sony-ct1.bits` (690.906 bytes, 352×224, 60 frames):

| capa | estado | evidencia |
|---|---|---|
| DMA de entrada | ✅ | 690.938 bytes en 17 ms |
| memoria (DDR, AXI, VBUF) | ✅ | palabra correcta en los 4 puntos del camino de retorno |
| parseo de headers | ✅ | `SIZE=352x224`, `FRAME_RATE=0x2005`, coinciden con el archivo |
| VLD completo | ✅ | visitó `SLICE`, `NEXT_MACROBLOCK`, `BLOCK`; **11.023 start codes** |
| sin errores | ✅ | `error=0`, `watchdog=0`, nunca entró a `ERROR` ni `DCT_ERROR` |
| escritura de frames | ✅ | los 4 buffers con datos, cero relleno `0x80` |
| geometría | ✅ | stride **352** confirmado por barrido fino (352: 12.7 vs 353: 13.4 vs 354: 22.3) |
| camino de display | ✅ | `disp_service_cnt` = **2.405.597** (era **0**) |

Ese último punto **confirma la predicción falsable** que había quedado del fix
de CDC de `pixel_queue` (commit `90e1a9a`, doc 32): el arbiter nunca servía al
display y ahora sí.

## CORRECCIÓN: la comparación de frames no era concluyente

Una versión anterior de este doc afirmaba que los píxeles reconstruidos no
coinciden con un decode de referencia, midiendo MAD contra `tools/mpeg2dec`.
**Esa conclusión se retira.** Corriendo la misma comparación contra la
**simulación** -- el diseño upstream, que decodifica bien -- salió MAD ~94,
prácticamente lo mismo que el hardware (121). Si el known-good tampoco pasa la
comparación, el método está mal.

Dos defectos encontrados y corregidos sin que alcanzara:
`mem_ctl.v write_mb` escribe una fila blanca separadora **antes** de cada
plano, y el plano de salida de la referencia es `frame_NN_out_`, no `aux`.
Queda sin resolver que el stream es *field picture*: el frame store guarda
campos y la referencia emite frames, así que comparar requiere conocer el
entrelazado.

**La comparación de frames completos no es una herramienta de validación
confiable acá.** Depende del layout, del entrelazado y de qué buffer se lee.

## Lo que SÍ está validado: IEEE 1180

`bench/ieee1180` (nuevo, commit `f35efa0`) corre el test de precisión de IDCT
IEEE 1180-1990 contra el `rtl/mpeg2/idct.v` real. **Pasa las seis condiciones**,
coincidiendo con la corrida publicada por Koen
(`tools/ieee1180/ieee-1180-results`) hasta el cuarto decimal:

| métrica | nosotros | Koen | límite |
|---|---|---|---|
| peak error | 1 | 1 | 1 |
| worst pmse | 0.0052 | 0.0049 | 0.06 |
| overall mse | 0.003619 | 0.003627 | 0.02 |
| worst mean error | 0.0016 | 0.0014 | 0.015 |
| overall mean error | 0.000031 | 0.000052 | 0.0015 |
| IDCT(0) no-cero | 0 | 0 | 0 |

Es el único test numérico e inequívoco del proyecto: pasa o falla contra
límites publicados, sin depender de layout ni entrelazado. Ojo con el alcance:
valida el IDCT **en simulación**, no el hardware sintetizado, y no habría
atrapado ninguno de los bugs de la Fase 7a.

## Lo que sigue sin verificarse

**Si la imagen que sale del hardware es correcta.**

Comparando contra `tools/mpeg2dec` compilado y corrido sobre el mismo stream
(plano `frame_NN_out_.y.ppm`, el de salida real -- no `aux`, que es el frame
auxiliar):

| | |
|---|---|
| media hardware | 187.5 |
| media referencia | 79.3 |
| MAD mejor caso, los 4 buffers × 60 frames | **~121** |

Y no discrimina entre frames, así que no es "está decodificando la frame
equivocada": es contenido distinto. Tampoco lo explica ninguna transformación
simple de valores (invertido 61.8, offset +108 → 41.6, ×2 → 71.4; ninguna cerca
de 0).

Pero **la imagen es estructuralmente coherente**: stride correcto, filas
correlacionadas, ~215 valores distintos, diferencia media entre píxeles
adyacentes de 16 -- es una imagen suave, no ruido.

Otros dos síntomas menores anotados:

- `DISP_SIZE = 120 x 120`, que no corresponde a nada del stream.
- `vbr_starved = 37.409` -- el VLD se queda esperando datos con cierta
  frecuencia. No genera error, pero conviene entender si degrada algo.

## Action items

### A. Corrección de la reconstrucción (bloqueante)

0. **Encontrar una forma confiable de comparar imágenes.** Es prerequisito de
   todo lo demás: hoy no tenemos manera de decir si un frame del hardware está
   bien. Opciones: usar un stream *frame picture* (no field) para eliminar el
   entrelazado, sincronizar la captura con `frame_end`, y validar el método
   primero contra la simulación -- si el sim no da MAD ≈ 0, el método sigue
   mal, sin importar lo que diga el hardware.
1. **Bisecar la cadena de reconstrucción.** El VLD entrega bien; hay que ver
   dónde se rompe entre ahí y el frame store. En orden de sospecha:
   `iquant` → `idct` → `predict_err_fifo` → `motcomp_recon`. La instrumentación
   sticky ya probada (primer valor + contadores) aplica igual: capturar el
   primer bloque de coeficientes tras `iquant`, la primera salida del `idct`, y
   el primer macrobloque escrito por `motcomp_recon`, y comparar contra el
   decoder de referencia, que ya está compilado en `tools/mpeg2dec`.
2. **Empezar por un stream I-frame-only** si hay alguno en `tools/streams`.
   Elimina motion compensation de la ecuación y aísla iquant/IDCT.
3. **Comparar también los planos de croma** (`FRAME_0_CR`/`CB`), que tienen su
   propio camino de direccionamiento.
4. Revisar `DISP_SIZE = 120x120` -- puede ser un síntoma del mismo problema o
   una pista independiente sobre `resample`/`syncgen`.

### B. Salida de video

5. Con `disp_service_cnt` moviéndose, verificar si hay **señal real en el
   conector**. Es la primera vez que el camino de display corre.
6. Confirmar `dot_clk` y los timings de `syncgen` contra el modeline elegido.

### C. Producto

7. **Mover la configuración de registros al driver de kernel TDD**, que sigue
   siendo la intención original y hoy vive en scripts ad-hoc del webserver.
8. Decidir qué hacer con los registros de debug (0x21-0x38): son baratos y muy
   útiles, probablemente convenga dejarlos y documentarlos como interfaz.
9. **El overlay UIO no sobrevive el reboot** -- automatizarlo si el producto lo
   necesita.

### D. Verificación

10. `bench/iverilog` no detectó **ninguno** de los bugs de esta fase (alias de
    memoria, CDC, reparto de puertos de RAM). Todos eran de hardware o de
    mapeo. Vale evaluar qué cobertura adicional tiene sentido, sabiendo que una
    simulación conductual verde no dice nada sobre esta clase de problemas.
11. Ahora que hay un decoder de referencia compilado y un camino para volcar
    frames del hardware, **armar una comparación automatizada** hardware vs
    referencia es barato y sería el test de regresión que falta.

## Herramientas nuevas disponibles

- `tools/mpeg2dec/mpeg2decode` compilado; `-o0 <prefijo>` escribe
  `frame_NN_out_.{y,u,v}.ppm` (PGM ASCII) además de los planos fwd/bwd/aux.
- Volcado de frames del hardware por `/dev/udmabuf-ddr-nc0` con el mapa de
  `mem_codes.v` (`WIDTH_Y=18`, `WIDTH_C=16`); stride de luma 352 confirmado.
- Registros de debug 0x21-0x38: estado del VLD, ventana de `getbits`, las tres
  sondas del camino de retorno y los internos de `xfifo_sc`.
