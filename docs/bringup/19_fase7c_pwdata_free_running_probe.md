# Fase 7c (continuación) — captura libre de PWDATA, y un gotcha de build serio

**Fecha:** 2026-08-19 (madrugada)
**Rama:** `hardware_development`
**Contexto:** el doc anterior (`18_fase7c_pwdata_investigation.md`) cerró con dos experimentos de
timing en hardware real (ambos negativos) y dos próximos pasos acordados: el jumper físico de
mikroBUS (no disponible esta noche, sin cables) y una captura libre de `PWDATA` sin ningún gating de
protocolo. Esta sesión implementó la captura libre y, en el proceso, encontró y corrigió un bug de
build serio que probablemente afectó *builds anteriores* de este proyecto también.

## Lo que se agregó: `pwdata_free_r` / `pwdata_sticky_r`

En `apb3_mpeg2fpga_bridge.v`, dos registros nuevos en el dominio `PCLK`, sin ninguna condición de
`PSEL`/`PENABLE`:

- `pwdata_free_r`: espejo directo de `PWDATA` en cada ciclo de `PCLK`.
- `pwdata_sticky_r`: acumulador OR de `PWDATA` — nunca se limpia salvo por reset, así que un glitch
  de un solo ciclo (invisible a una lectura puntual) deja marca.

Ninguno de los dos tiene fan-out real (nada los lee) — son puramente para inspección directa vía
SmartDebug Active Probes, igual que se hizo antes con `apb_wdata_r`.

## Gotcha #1: la síntesis eliminó los registros (dos veces, por dos causas distintas)

**Causa real (la que importa, no obvia): `hdl_source.tcl` sólo se re-ejecuta en un proyecto nuevo.**

El mismo problema ya documentado en `libero_build_script_gotchas` para los TCL de SmartDesign
(`safe_source MPFS_DISCOVERY_KIT_recursive.tcl` sólo corre dentro del branch `else` de
`if {[file exists $project_dir/$project_name.prjx]}`) resultó aplicar también a
`script_support/hdl_source.tcl` — el archivo que hace `import_files -hdl_source
../../rtl/mpeg2/*.v` para copiar el RTL real a `soc_build/MPEG2FPGA_SOC/hdl/`. Como ese archivo se
`source`ea desde `MPFS_DISCOVERY_KIT_recursive.tcl`, **cualquier edición de RTL puro en un proyecto
ya existente se ignora silenciosamente** — Libero sigue sintetizando la copia vieja en `hdl/`, sin
ningún error ni warning que lo delate.

Se confirmó con `diff` directo entre `rtl/mpeg2/apb3_mpeg2fpga_bridge.v` y
`soc_build/MPEG2FPGA_SOC/hdl/apb3_mpeg2fpga_bridge.v`: la copia del proyecto no tenía ninguno de los
cambios de esta noche, ni siquiera después de una síntesis "exitosa" completa (0 errores).

**Esto es más grave que el gotcha ya documentado**, porque ese hablaba específicamente de cambios a
los `.tcl` de SmartDesign (nuevos puertos, nuevo wiring) — pero éste aplica a *cualquier* edición de
`.v` en un proyecto existente. Toda esta sesión (y potencialmente sesiones anteriores) asumió que
"como es RTL puro, no hace falta `rm -rf`" — esa asunción era **incorrecta**. La única forma
confiable de que un cambio de RTL llegue al hardware, sobre un proyecto ya existente, es borrar
`soc_build/MPEG2FPGA_SOC` y reconstruir desde cero.

**Corrección aplicada esta noche**: se actualizó `libero_build_script_gotchas` (memoria) para
reflejar que el gotcha #1 (staleness) aplica también a `hdl_source.tcl`, no sólo a los `.tcl` de
SmartDesign — la regla pasa a ser "antes de CUALQUIER cambio a `rtl/mpeg2/*.v` o a los `.tcl` de
SmartDesign, sobre un proyecto existente, `rm -rf soc_build/MPEG2FPGA_SOC` primero".

## Gotcha #2 (menor, ya corregido en el camino): alcance del atributo `syn_keep`

Antes de encontrar la causa real (arriba), se sospechó que el problema era el atributo de síntesis
usado para evitar que Synplify elimine los registros por dead-code (no tienen fan-out real). El
patrón ya usado en `mpeg2video.v` para `cnt_clk` (contador de prueba, mismo caso: sin fan-out) es:

```verilog
(* syn_keep = 1, syn_preserve = 1, syn_noprune = 1 *)
reg [31:0] cnt_clk;
reg [31:0] cnt_mem;
reg [31:0] cnt_dot;
```

Grepeando el netlist post-síntesis se confirmó que **sólo `cnt_clk` sobrevive** — `cnt_mem`/`cnt_dot`,
declarados en líneas separadas sin repetir el atributo, se eliminan igual. La primera versión de
`pwdata_free_r`/`pwdata_sticky_r` los declaraba juntos (`reg [31:0] pwdata_free_r, pwdata_sticky_r;`)
bajo un solo bloque de atributo — mismo error. Se corrigió separando cada declaración con su propio
atributo. Esto **no era la causa raíz real** (gotcha #1 lo tapaba igual), pero es una corrección
válida y ya committeada, necesaria una vez resuelto el problema de fondo.

## Estado real, confirmado en el netlist

Después de `rm -rf soc_build/MPEG2FPGA_SOC` + reconstrucción completa (`SYNTHESIZE` →
`PLACEROUTE` → `GENERATEDEBUGDATA` → `VERIFY_TIMING` → `GENERATE_PROGRAMMING_DATA` → `EXPORT_FPE` →
`PROGRAM`), se confirmó por `diff` que `hdl/apb3_mpeg2fpga_bridge.v` ahora coincide exactamente con
el RTL real, y por grep del netlist (`MPFS_DISCOVERY_KIT.vm`) que **los 32 bits de `pwdata_free_r` y
los 32 bits de `pwdata_sticky_r` están presentes** (antes: 0 apariciones, ninguno de los dos). Timing
limpio (`VERIFY_TIMING`: 0 violaciones), programación JTAG exitosa (`Chain programming PASSED`).

Se dejó `DMA_LEN=12599` (`0x3137`) escrito en el hardware (vía `diag_write_then_pause.py`, con el
overlay `mpeg2fpga_uio` reaplicado a mano después del reset que dispara la reprogramación —
se pierde en cada `PROGRAM`, hay que reaplicarlo con `mkdir
/sys/kernel/config/device-tree/overlays/mpeg2fpga_uio && cp mpeg2fpga-uio.dtbo .../dtbo`).

## `GENERATEDEBUGDATA`: el paso que faltaba para que SmartDebug vea el netlist nuevo

El usuario encontró (fuera de esta sesión) un export de registros del MSS vía SmartDebug
(`registers_mss.csv`, ~3900 líneas) que llevó a confirmar `run_tool -name {GENERATEDEBUGDATA}` como
el paso Tcl soportado explícitamente para PolarFire (`Supported Families: PolarFire`, a diferencia
de la mayoría de comandos Tcl de SmartDebug documentados sólo para SmartFusion2/IGLOO2/RTG4) que
genera los archivos que SmartDebug necesita para relacionar el netlist colocado y ruteado con los
nombres de señal del RTL. Se agregó como paso extra del pipeline (script standalone, no forma parte
de `build_mpeg2fpga_soc.tcl`) después de `PLACEROUTE` y antes de `VERIFY_TIMING`.

## Intento de leer los Active Probes sin la GUI (parcialmente investigado, no logrado)

Se investigó si se podía leer `pwdata_free_r`/`pwdata_sticky_r` por Tcl headless, sin abrir la GUI:

- `select_active_probe`/`read_active_probe` **no existen** en el intérprete Tcl de `libero_bin`
  (Designer) — error `invalid command name "select_active_probe"`. Son comandos de SmartDebug/
  FlashPro Express, no de Designer.
- `FPExpress` (el binario separado en `Designer/bin/FPExpress`) sí reconoce `SCRIPT:archivo.tcl` y sí
  tiene esos comandos, pero su `open_project` espera un **"job project" propio de FlashPro Express**
  (un `.pro`, creado con `create_job` dentro de una sesión de FPExpress ya conectada a un programador),
  no el `.prjx` de Libero ni el `.job` de bitstream directamente — se probó apuntarlo directo al
  `.job` (`MPEG2FPGA_SOC.job`) y falló (`Failed to open the project file`).
- Seguir este camino requeriría reconstruir el flujo completo de FPExpress (`create_job` +
  configuración de programador + selección de dispositivo) sin poder verificar visualmente el
  resultado — se decidió no seguir insistiendo por el riesgo de manipular un flujo de programación
  mal entendido sobre hardware real sin supervisión. **Este es el punto donde se necesita la GUI.**

## Qué queda para cuando el usuario abra Libero/SmartDebug

1. Abrir `soc_build/MPEG2FPGA_SOC/MPEG2FPGA_SOC.prjx` en Libero (proyecto reconstruido de cero esta
   noche, no necesita nada especial para abrir).
2. SmartDebug → Active Probes → buscar `pwdata_free_r` y `pwdata_sticky_r` dentro de
   `FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_bridge` — ahora sí deberían aparecer en la lista
   (antes no aparecían porque no existían en el netlist, no por un problema de proyecto viejo/GUI).
3. `DMA_LEN=12599` ya está escrito en el hardware, esperando lectura — no hace falta volver a escribir
   nada antes de la primera captura.
4. Si `pwdata_sticky_r` da `0x00000000`: el bus nunca tuvo un `1` en `PWDATA` en ningún momento,
   confirmando que el problema es estructural/físico aguas arriba de esta lógica de captura, no de
   timing de muestreo (ya descartado en la sesión anterior).
5. Si da cualquier valor distinto de cero: hay datos reales llegando al bus que se están perdiendo en
   algún punto entre el pin físico y `apb_wdata_r` —653 replantea la investigación hacia esa ventana
   específica.

## Commits de esta sesión

- `hardware_development` `df327da`: agrega `pwdata_free_r`/`pwdata_sticky_r` (versión inicial, atributo
  combinado — no sobrevivió a síntesis por gotcha #1, corregido después).
- `hardware_development` `a761538`: separa el atributo `syn_keep`/`syn_preserve`/`syn_noprune` en una
  línea por registro (gotcha #2).
