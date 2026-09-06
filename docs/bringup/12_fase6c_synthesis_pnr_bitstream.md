# Fase 6c — Síntesis, P&R y generación de bitstream con el bridge DDR real

**Fecha:** 2026-08-16
**Rama:** `hardware_development`
**Contexto:** con `mem2axi_bridge` ya cableado hasta `MSS_WRAPPER:FIC_1_AXI4_TARGET` en el diseño
SmartDesign (Fase 6b, verificado por build headless limpio + inspección del Verilog generado), toca la
primera vez que este cableado pasa por síntesis y place & route de verdad — la primera vez que la ruta
completa hacia la DDR toca herramientas de implementación, no solo generación de jerarquía.

## Objetivo

Llevar el diseño hasta un `.job` de FlashPro programable, con timing cerrado, sin repetir ninguno de
los bugs de la Fase 5c (pin-lock) ni de la 5d (pin sin conectar silenciosamente atado a GND).

## Comando

Mismo script de siempre, con `SCRIPT_ARGS` (formato `ARG1+ARG2`, separado por `+`, confirmado contra
`README.md` del reference-design):

```sh
cd trunk/mpeg2fpga/soc_build
libero SCRIPT:build_mpeg2fpga_soc.tcl SCRIPT_ARGS:SYNTHESIZE
libero SCRIPT:build_mpeg2fpga_soc.tcl SCRIPT_ARGS:PLACEROUTE
libero SCRIPT:build_mpeg2fpga_soc.tcl SCRIPT_ARGS:VERIFY_TIMING
libero SCRIPT:build_mpeg2fpga_soc.tcl SCRIPT_ARGS:GENERATE_PROGRAMMING_DATA
libero SCRIPT:build_mpeg2fpga_soc.tcl SCRIPT_ARGS:EXPORT_FPE
```

Cada paso reabre el mismo proyecto (`MPEG2FPGA_SOC.prjx` ya existe tras la Fase 6b) y corre solo la
herramienta pedida, igual que documenta el propio `build_mpeg2fpga_soc.tcl`.

## Síntesis

Limpia, sin errores. Los únicos `@W` en el reporte (`MPFS_DISCOVERY_KIT.srr`) son: macros
`` `undef ``-de-algo-nunca-definido (patrón preexistente en todo el árbol, dispara siempre que se
sintetiza sin `__IVERILOG__`), warnings internos de IP de catálogo (`COREAXI4INTERCONNECT`,
`CoreAXI4SRAM` — ajenos, del camino `FIC_0`/`DMA_CONTROLLER`/`MSS_LSRAM` que ya existía), y dos
categorías nuevas pero esperadas de `mem2axi_bridge.v`:

- **Poda de bits de `m_axi_awaddr`/`m_axi_araddr`**: con `DDR_BASE = 38'h0` (el placeholder actual),
  Synplify nota correctamente que solo los bits `[24:3]` cargan información real (`{addr_r[21:0],
  3'b000}` solo llena hasta el bit 24; `DDR_BASE=0` no aporta nada arriba de eso) y poda el resto como
  constante. Esperado — cambiará (menos poda) cuando el offset real de DDR reemplace el placeholder.
- **Colapso de instancias "equivalentes"** (`aw_done`≡`w_done`, `m_axi_awaddr_1[24:3]`≡
  `m_axi_araddr_1[24:3]`, `state[4]`≡`state[2]`): mismo tipo de mensaje `BN132` que ya se documentó
  como inofensivo en la Fase 5c (para el sincronizador Gray-code de COREFIFO) — el motor de equivalencia
  de Synplify es sound (solo fusiona registros que prueba idénticos bajo toda combinación de entradas
  alcanzable), así que es puro ahorro de área, no un riesgo de correctitud.

Uso de recursos: 24842 LUTs, 21301 SLEs, 37/308 RAM1K20 (12%), 89/876 RAM64x12 (10%), 20/292 DSP (6%) —
cómodo dentro del MPFS095T.

## Place & Route

`Locked: 55 (100.00%), Placed: 0` — confirma que el fix de pin-lock de la Fase 5c sigue vigente, sin
regresión.

Durante la mejora incremental de *hold timing* el placer reportó una serie de violaciones que fue
resolviendo iteración a iteración (`-7.245 ns → -3.78 ns → -2.367 ns → -1.628 ns → -1.022 ns`), sin
llegar a 0 dentro del propio P&R. Esto por sí solo no es la palabra final — el placer usa su propio
análisis interno de timing durante la mejora incremental, no necesariamente el mismo conjunto de
excepciones (`apb3_mpeg2fpga_bridge_cdc.sdc`) que sí aplica el paso de verificación real.

## Verify Timing: cierre limpio

```
No errors or warnings found.
Info: Timing constraints have been met.
```

Cero violaciones contra el conjunto de restricciones real y completo (incluyendo las excepciones de
CDC ya registradas desde la Fase 5c). El número residual que dejó el P&R no representa una violación
real una vez aplicado el SDC completo — no hizo falta agregar ninguna excepción nueva para el camino de
`mem2axi_bridge`, que corre enteramente en el dominio `mem_clk` sin cruces de reloj propios (a
diferencia del bridge APB, que sí necesitó su propio SDC de falso camino en la Fase 5a/5c).

## Bitstream

`GENERATE_PROGRAMMING_DATA` + `EXPORT_FPE` produjeron `MPEG2FPGA_SOC.job` (5.7 MB, componentes
`FABRIC` + `SNVM` — sin `ENVM`, no hizo falta `HSS_UPDATE` esta vez porque el emparejamiento HSS/eNVM ya
quedó resuelto en la Fase 5c y no cambió). Digests:

```
Fabric component bitstream digest: d741bf6a88eaa92140ecd0d9bb9e3bcf38cd34c5c2b1e55f2d60bd6201ace104
sNVM component bitstream digest:   b0a9e2be29f47fa951a6a131a8dd9a9016e5ba87de5833c742b7f654428ea6e7
Entire bitstream digest:           f3a1e24cf4001369eb77445c714ca98d2077a619341a8b56ab66c97be737b7d7
```

## Conclusión y próximo paso

Queda cerrada la Fase 6c a nivel de implementación: síntesis limpia, P&R con pin-lock intacto, timing
cerrado sin excepciones nuevas, bitstream exportado. **Deliberadamente no se programó la placa todavía**
— es la primera vez que este cableado (bridge + AXI4 hasta la MSS) toca silicio real, y dado el
historial de sorpresas silenciosas de las Fases 5c (pin-lock) y 5d (pin sin conectar atado a GND), el
paso de `PROGRAM` contra hardware real queda para una fase separada, con la placa confirmada y bajo
supervisión directa — mismo criterio que se usó en esas fases.
