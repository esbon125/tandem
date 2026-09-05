# Fase 7a RESUELTO: `syn_ramstyle = "uram"` en `xfifo_sc.v`

Cierre de la cadena que empieza en
[31](31_fase7a_udmabuf_alias_y_l2_memory_side.md) y pasa por
[37](37_fase7a_CAUSA_RAIZ_la_ram_del_fifo_comparte_puertos.md).

## El fix

Una línea en `rtl/mpeg2/xfifo_sc.v`:

```verilog
reg [dta_width-1:0]ram[(1 << addr_width)-1:0] /* synthesis syn_ramstyle = "uram" */;
```

## Resultado en hardware

| | antes | después |
|---|---|---|
| `tcela-17` | ~50% | **20/20** |
| `sony-ct1` | ~66% | **6/6**, `SIZE=352x224`, `FRAME_RATE=0x2005` |
| primera palabra del VBUF | corrupta en cada fallo | **`din` = `dout` en 10/10** |

26 de 26 corridas. La corrupción desapareció.

## Por qué el default estaba mal, en palabras de la propia herramienta

De la descripción de `block_ram` en `microchip_attribute_reference.pdf`:

> *"By default, the software uses **deep block RAM configurations instead of
> wide configurations** to get better timing results. Using deeper RAMs reduces
> the output data delay timing by reducing the MUX logic at the output of the
> RAMs."*

Esa heurística **ganchó los dos puertos de cada RAM1K20** para llegar a 40 bits
de ancho: dos bloques para una memoria de 64×256, con `rd_addr` en un puerto y
`wr_addr` en el otro y los datos repartidos entre ambos. Un FIFO necesita leer y
escribir en direcciones distintas al mismo tiempo, así que las tajadas de bits
que caían en el puerto compartido perdían su escritura.

No es un bug de la herramienta: es una optimización de timing documentada, que
rompe en una memoria con lectura y escritura simultáneas.

## Por qué `uram` lo arregla

uSRAM (`RAM64x12`) tiene puertos de escritura y lectura **dedicados**, así que
ensanchar agrega bloques en paralelo en vez de ganchar puertos:

```
.W_CLK(clk_out),  .W_ADDR(wr_addr_Z[5:0]),  .W_EN(...),  .W_DATA(din[11:0]),
.R_CLK(clk_out),  .R_ADDR(rd_addr_0_8[5:0]),             .R_DATA(...)
```

Buses separados, sin compartir nada. Verificado en el netlist: **24 × RAM64x12
y cero RAM1K20** en `xfifo_sc_64_8_32` (4 de profundidad × 6 de ancho para
256×64), y el reporte de RAM dice `64X12 ... Inferring instance using URAM`.

## Costo

| recurso | antes | después | disponible |
|---|---|---|---|
| uSRAM | 97 | 319 | 876 (36%) |
| LSRAM | 51 | 30 | 308 (10%) |

Cubre las **13** instancias `fifo_sc` del diseño de una sola vez. Timing cumple
(`VERIFY_TIMING`: "Timing constraints have been met"), P&R 27.5 min limpio.

## Los dos valores que se probaron y fallaron

Quedan documentados en el propio archivo para que nadie los repita:

- **`"rw_check"`** -- aceptado, **silenció el aviso FX107** para esta RAM (41
  avisos → 23) y dejó el netlist **byte por byte idéntico**. Un falso arreglo
  que además destruye la señal que apuntaba al problema. El manual explica por
  qué no podía servir: inserta bypass para lecturas y escrituras a la **misma**
  dirección, que no es nuestro caso. Y advierte que puede generar glitches en
  RAMs con relojes de lectura y escritura asíncronos.
- **`"distributed"`** -- no es un valor válido para este target (`FX344
  Unrecognized syn_ramstyle`), se ignoró entero.

Los valores válidos, de la documentación de la herramienta: `block_ram`
(default), `registers`, `no_rw_check`, `rw_check`, `lsram`, `uram`.

## La lección

**El criterio de éxito nunca fue "compila" ni "desapareció el warning".** Fue
abrir el netlist y comprobar que `wr_addr` y `rd_addr` dejaran de compartir
puerto. `rw_check` habría pasado los dos primeros criterios y habría dejado el
bug intacto -- y encima sin la advertencia que lo delataba.

Herramientas útiles descubiertas en el camino, para la próxima:

- `synthesis/<impl>_ram_rpt.txt` -- reporte dedicado con la configuración
  inferida de cada RAM: `DEPTH_X_WIDTH(A/B)`, `WRITE_MODE(A/B)`, atributo
  aplicado y el motivo de la decisión. Mucho más directo que leer el netlist.
- `designer/<impl>/*_compile_netlist_resources.rpt` -- uso y disponibilidad de
  uSRAM/LSRAM, para dimensionar antes de gastar una corrida.
- Los ejemplos y PDFs bajo `Libero_SoC/Synplify_Pro/` traen la lista real de
  valores válidos por atributo; adivinarlos cuesta una síntesis por intento.

## Qué queda

El decoder ahora parsea el sequence header de forma **determinista**. Falta ver
qué tan lejos llega el decode completo: `FRAME_0_Y` seguía con el relleno del
`STATE_CLEAR` incluso en las corridas que acertaban, y `disp_service_cnt` daba 0
(ver [32](32_fase7a_que_cambia_cuando_no_decodifica.md)). Esa es la próxima
pregunta, y ahora se puede atacar sobre una base determinista.

También conviene revisar si el fix de CDC de `pixel_queue` (commit `90e1a9a`)
movió `disp_service_cnt`, que era su predicción falsable.

Y ahora sí vale contarle a Koen: no es un bug de su RTL, es que su FIFO no
sobrevive la heurística deep-over-wide de Synplify sobre LSRAM de PolarFire.
