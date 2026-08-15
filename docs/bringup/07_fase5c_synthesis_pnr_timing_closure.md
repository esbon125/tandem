# Fase 5c — Síntesis, Place & Route y cierre de timing

**Fecha:** 2026-08-14/15
**Rama:** `hardware_development`
**Contexto:** con mpeg2fpga ya integrado como esclavo APB3 dentro del diseño de la MSS (Fase 5b,
`docs/bringup/06_mss_integration_fase5b.md`), esta fase lleva ese diseño hasta bitstream: síntesis,
place & route, y — el grueso de esta fase — cerrar timing en los paths que cruzan de dominio de reloj
en `apb3_mpeg2fpga_bridge.v`.

## Objetivo

Producir un P&R limpio (cero violaciones de timing) y, a partir de ahí, un bitstream listo para
programar la Discovery Kit.

## El problema: violaciones de timing en los paths de CDC del bridge

`apb3_mpeg2fpga_bridge.v` (Fase 5a) cruza señales entre el dominio `PCLK` (bus APB de `FIC_3`) y el
dominio `core_clk` (reloj interno de `mpeg2video`, derivado de su propio `PF_CCC_C0`) usando un
handshake de dos fases (`req_toggle`/`ack_toggle`) con sincronizadores de 2 flip-flops — el patrón
estándar para cruces de baja frecuencia. Pero **no todas** las señales del bridge pasan por ese
sincronizador: `apb_addr_r`, `apb_wdata_r`, `apb_write_r` (capturadas en `PCLK`) y `rdata_hold`
(capturada en `core_clk`) se leen directamente desde el otro dominio, sin sincronizador propio.

Esto es intencional, no un descuido: estas señales quedan **estables durante toda la transacción**
(muchos ciclos), y el handshake `req_toggle`/`ack_toggle` — que sí está correctamente sincronizado —
garantiza que el lado receptor nunca las muestree antes de que el flanco sincronizado del toggle le
avise que el dato ya está estable. Es una garantía a nivel de protocolo, no a nivel de señal individual.

El problema es que **STA (Static Timing Analysis) no puede ver esa garantía de protocolo**. Sin
ninguna excepción, la herramienta analiza `apb_addr_r → regfile` como si fuera un path normal de un
solo ciclo entre dos relojes no relacionados — algo que, por definición, no puede cerrar timing (los
dos relojes no tienen relación de fase conocida). El resultado, visto en cada corrida de P&R antes del
fix: violaciones de **~-5.5 a -5.9 ns** de slack, siempre con el mismo origen:

```
From: FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_bridge/apb_addr_r[1]:CLK
To:   FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_mpeg2/regfile/osd_frame[0]:EN
Slack (ns):             -5.755
```

**Por qué se waivean y no se rediseñan**: no es un timing closure real que falte cerrar — es un
falso positivo de la herramienta sobre un cruce de dominio que el diseño ya protege correctamente a
nivel de protocolo. La alternativa (agregar un sincronizador de 2FF a cada bit de `apb_addr_r`/
`apb_wdata_r`/`rdata_hold`) no solo es innecesaria sino que introduciría un problema real: esas señales
son buses de varios bits que deben llegar **todos juntos, en el mismo ciclo**, al otro dominio — un 2FF
por bit sin ningún control de correlación entre bits arriesgaría que distintos bits del mismo bus
crucen en ciclos distintos (bus skew), corrompiendo direcciones/datos en vez de solo timing. El
handshake ya resuelve ese problema correctamente. La herramienta de STA se corrige con
`set_false_path`, que es exactamente para esto: declarar explícitamente que un path, aunque
topológicamente existe, no representa un requisito de timing real porque el diseño garantiza su
estabilidad por otro medio (protocolo, no timing).

Este mismo patrón (excepción por protocolo, no por timing real) ya está usado en el propio diseño de
referencia de Microchip para las FIFOs COREFIFO del framestore (`set_false_path -to [...]shift_reg*`
en `MPFS_DISCOVERY_KIT_derived_constraints.sdc`, auto-generado por Libero) — no es una técnica ad-hoc
de este proyecto.

## El archivo de excepciones: `apb3_mpeg2fpga_bridge_cdc.sdc`

`trunk/mpeg2fpga/soc_build/script_support/hdl/apb3_mpeg2fpga_bridge_cdc.sdc`:

```tcl
set_false_path -from [ get_cells { FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_bridge/apb_addr_r* } ]
set_false_path -from [ get_cells { FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_bridge/apb_wdata_r* } ]
set_false_path -from [ get_cells { FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_bridge/apb_write_r } ]
set_false_path -from [ get_cells { FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_bridge/rdata_hold* } ]
```

Cuatro `set_false_path -from`, uno por señal/bus fuente. `apb_write_r` es escalar (sin `*`); los demás
son buses.

Escribir este archivo correcto y hacer que realmente tomara efecto tomó **tres intentos**, cada uno
descartando una causa distinta — documentados abajo porque cada uno es un hallazgo reusable sobre cómo
Libero maneja SDC de usuario, no un error trivial.

## Intento 1: el archivo no estaba registrado para ninguna herramienta

`import_files -sdc <path>` copia el archivo dentro del proyecto (a `constraint/`) pero **no** lo agrega
al conjunto de restricciones activo de ninguna herramienta. Sin un `organize_tool_files` explícito, el
archivo existe en el proyecto pero P&R nunca lo lee. Se agregó:

```tcl
organize_tool_files \
    -tool {PLACEROUTE} \
    -file "${project_dir}/constraint/apb3_mpeg2fpga_bridge_cdc.sdc" \
    -module {MPFS_DISCOVERY_KIT::work} \
    -input_type {constraint}
```

Resultado: **sin cambios**. El reporte de violaciones siguió mostrando exactamente los mismos paths
`u_bridge/apb_addr_r[N]` con la misma magnitud de slack.

## Intento 2: bug de sintaxis Tcl-glob en el patrón de `get_cells`

La primera versión del archivo usaba `apb_addr_r[*]` (asterisco **dentro** de corchetes), pensando en
"cualquier índice de bus". Pero en la sintaxis Tcl-glob que usa `get_cells`, `[...]` es una **clase de
caracteres**, no un comodín de índice — `[*]` matchea literalmente el carácter `*`, no ningún bit real
de `apb_addr_r[0]`, `apb_addr_r[1]`, etc. El patrón matcheaba **cero celdas**.

Esto era invisible en el log porque `project_settings -abort_flow_on_sdc_errors {FALSE}` ya estaba
activado (desde un ajuste anterior, no relacionado, para tolerar un patrón COREFIFO que también
matchea cero celdas en instancias más chicas de FIFO por una optimización de síntesis benigna) — sin
esa protección, Libero habría tirado `SDC0023` inmediatamente y el problema se habría visto en el
primer intento.

Se corrigió comparando contra el patrón ya usado por el propio `derived_constraints.sdc` de Libero para
COREFIFO (`.../shift_reg*`, sin corchetes) — la convención correcta es un asterisco suelto:
`apb_addr_r*`. Confirmado directamente con un diagnóstico ad-hoc: se agregaron líneas `puts` al `.sdc`
imprimiendo `llength [get_cells {...}]`, y con el patrón corregido el resultado (visible indirectamente
por un error de parseo de listas Tcl al intentar imprimir la colección — ver más abajo) confirmó que sí
había celdas matcheando.

Resultado: **sin cambios, otra vez**. Mismos paths, misma magnitud de slack, a pesar de que esta vez el
patrón sí matcheaba celdas reales.

## Intento 3 (el real): el archivo nunca se registró para `VERIFYTIMING`

Este fue el hallazgo que realmente resolvió el problema. Investigando el reference-design de Microchip
(`~/Proyectos/polarfire-soc-discovery-kit-reference-design/MPFS_DISCOVERY_KIT_REFERENCE_DESIGN.tcl`),
se encontró que **cada** archivo de restricciones de usuario se registra ahí con **tres**
`organize_tool_files` independientes — uno por herramienta:

```tcl
organize_tool_files -tool {SYNTHESIZE}   -file ... -input_type {constraint}
organize_tool_files -tool {PLACEROUTE}   -file ... -input_type {constraint}
organize_tool_files -tool {VERIFYTIMING} -file ... -input_type {constraint}
```

Nuestro script solo tenía el de `PLACEROUTE}`. La razón por la que esto importa: P&R consolida las
restricciones que conoce en `designer/MPFS_DISCOVERY_KIT/place_route.sdc` — y ahí `apb3_mpeg2fpga_bridge_cdc.sdc`
sí aparecía, correctamente, con el patrón ya corregido. Pero el paso de Verify Timing (el que realmente
genera los reportes de violaciones que se venían revisando) usa un archivo consolidado **separado**,
`designer/MPFS_DISCOVERY_KIT/timing_analysis.sdc` — y ese archivo se arma a partir de un conjunto de
restricciones registrado independientemente. Sin el `organize_tool_files -tool {VERIFYTIMING}`,
`timing_analysis.sdc` se generaba únicamente a partir de `MPFS_DISCOVERY_KIT_derived_constraints.sdc`
(el auto-generado por Libero) — nuestras excepciones de CDC nunca estaban ahí, sin importar cuán
correcto fuera el archivo en sí ni que P&R "supiera" de ellas para sus propias decisiones de
optimización.

Esto se confirmó de forma directa, no por deducción: `grep -l apb3_mpeg2fpga_bridge_cdc.sdc
designer/MPFS_DISCOVERY_KIT/*.sdc` encontraba el archivo en `place_route.sdc` pero no en
`timing_analysis.sdc`.

Se agregaron las tres registraciones (`SYNTHESIZE`, `PLACEROUTE`, `VERIFYTIMING`) en
`trunk/mpeg2fpga/soc_build/build_mpeg2fpga_soc.tcl`, fuera del bloque `if {[file exists
$project_dir/$project_name.prjx]} {...} else {...}` de creación de proyecto, para que también tomen
efecto en corridas posteriores sobre un proyecto ya existente (no solo en un build desde cero).

**Efecto colateral #1**: registrar el archivo para `SYNTHESIZE` invalida el resultado de síntesis
cacheado por Libero (`Error: SYNTHESIZE Tool inputs are out of date`) — hubo que resintetizar una vez
más antes de poder correr P&R de nuevo.

**Efecto colateral #2**: con las tres restricciones ya bien registradas, la primera corrida de
verificación devolvió timing limpio (`No Path` en el reporte de violaciones) en la primera semilla del
multi-pass — pero el propio wrapper de multi-pass de Libero (`extended_run_lib.tcl`) falló al intentar
comparar ese reporte vacío contra las otras semillas (`Multi-Pass: Analysis using specified comparison
criteria failed`), marcando la herramienta como fallida aunque el placement en sí había sido exitoso.
Como ya no hace falta buscar entre 5 semillas si una sola cierra timing, se desactivó
`MULTI_PASS_LAYOUT` (quedó en `false`) para la corrida de producción, evitando ese wrapper por completo.

### Resultado final verificado

```
Timing Violation Report Max Delay Analysis
...
Multi Corner Report Operating Conditions: slow_lv_lt,fast_hv_lt,slow_lv_ht

No Path
```

Confirmado además en el archivo de estado interno de Libero (`MPFS_DISCOVERY_KIT_has_violations`):

```
_max_timing_violations_multi_corner met
_min_timing_violations_multi_corner met
```

Cero violaciones de timing, en las tres esquinas de operación (`slow_lv_lt`, `fast_hv_lt`,
`slow_lv_ht`), contra el placement realmente guardado en el proyecto (no un resultado descartado por
el bug del wrapper de multi-pass).

Utilización de recursos (consistente entre todos los intentos de P&R de esta fase, con o sin las
violaciones):

| Recurso        | Usado  | Total  | %     |
|----------------|--------|--------|-------|
| 4LUT           | 19960  | 93516  | 21.34 |
| DFF            | 14633  | 93516  | 15.65 |
| Logic Element  | 23133  | 93516  | 24.74 |

Amplio margen de fabric libre.

## Lección general: un `.sdc` de usuario necesita registrarse por herramienta, no una sola vez

El hallazgo central de esta fase, generalizable a cualquier constraint de usuario futuro en este
proyecto: **`organize_tool_files` no es una operación "de una vez por archivo"** — Libero mantiene
conjuntos de restricciones independientes por herramienta (`SYNTHESIZE`, `PLACEROUTE`,
`VERIFYTIMING`, y los `io_pdc`/`fp_pdc` de PDC tienen su propio mecanismo aparte todavía). Registrar un
archivo para una herramienta no lo hace visible para las demás, y cada una puede "saber" de una
restricción sin que eso se refleje en el reporte que genera otra. Antes de dar por buena una excepción
de timing, conviene verificar directamente en qué archivo `.sdc` consolidado terminó (`grep -l <archivo>
designer/<top>/*.sdc`) en vez de confiar en que P&R la haya leído sin error.

## Conclusión

Fase 5c cerrada: síntesis y P&R producen un diseño con cero violaciones de timing, verificado contra el
placement efectivamente guardado en el proyecto. Los cuatro `set_false_path` del bridge son excepciones
legítimas sobre un cruce de dominio ya protegido por protocolo (handshake de dos fases sincronizado),
no un timing closure real pendiente. Próximo paso: generar el bitstream
(`GENERATE_PROGRAMMING_DATA:1`) y programar la Discovery Kit — la primera vez que este diseño (MSS +
mpeg2fpga integrado) toca silicio real. Con eso resuelto queda pendiente, como ya estaba delimitado en
el plan, la Fase 5d: overlay de device tree real con la dirección/IRQ que resultaron de la Fase 5b, y
repetición de la prueba de `insmod`/`probe()` de la Fase 4d contra hardware real.
