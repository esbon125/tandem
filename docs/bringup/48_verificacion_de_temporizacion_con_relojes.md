# Verificación de temporización con los relojes reales

**Fecha:** 2026-10-16
**Placa:** PolarFire SoC FPGA Discovery Kit (MPFS-DISCO-KIT), MPFS095T, FCSG325, grado -1
**Herramienta:** Libero SoC 2025.2 (2025.2.0.14), SmartTime, sin GUI
**Commits:** hardware_development `8a6d847` (arreglo); bitstream analizado antes: `0.1.0+8004bc9`,
después: `0.1.0+8a6d847`

## El problema

Encontrado el 2026-10-08 con SmartPower (bitácora 46): `build_mpeg2fpga_soc.tcl` registraba para
SYNTHESIZE y VERIFYTIMING solo `apb3_mpeg2fpga_bridge_cdc.sdc`, y `organize_tool_files`
**reemplaza** el conjunto de archivos de la herramienta en vez de agregar. Resultado:

- **Síntesis sin relojes.** El `.srr` de 8004bc9 muestra todos los relojes como `inferred` a
  100 MHz.
- **Verify Timing sin relojes.** `timing_analysis.sdc` no tenía ningún `create_clock`, así que el
  "cero violaciones" de la Fase 5c no validaba nada.
- **Place & route sí los tenía.** `derive_constraints_sdc` agrega el archivo derivado a su
  conjunto: `place_route.sdc` tenía los 8 relojes.

Arreglo: los dos `organize_tool_files` registran `MPFS_DISCOVERY_KIT_derived_constraints.sdc` +
el sdc del puente, igual que el diseño de referencia de Microchip. `soc_build/run_verify_timing.tcl`
corre Verify Timing sobre un proyecto existente sin tocar la síntesis ni el place & route.

## Lo que mostró 8004bc9 con los relojes

Dentro de cada dominio del decodificador cumple todo. Las violaciones aparecen en los cruces entre
PCLK (FIC_3, 51,2 MHz, PLL de CLOCKS_AND_RESETS) y los relojes del decodificador (PLL `u_ccc`):

| Camino | Margen | Qué era |
|---|---|---|
| `CORERESET_0/dff_15_rep` (FIC_3) → `u_bridge/rdata_hold[*]:ALn` (clk) | −10,157 ns recovery | PRESETN reseteaba flops de `core_clk` sin sincronizar |
| `u_bridge/ack_toggle` (clk) → `u_bridge/ack_toggle_meta` (PCLK) | −3,533 ns hold | la entrada del sincronizador 2-FF, temporizada como camino síncrono |
| `DMA_CONTROLLER_0/.../numOfBytesInRdReg` → `extDscrptrAddr_extFetchReg` (FIC_0) | −0,006 ns setup | IP de Microchip del diseño de referencia, en la esquina slow_lv_ht |

- **El reset es un defecto real.** `rst_n` del periférico es `PRESETN`, que se libera con PCLK,
  pero reseteaba directo el lado `core_clk` de `u_bridge` y, vía `gated_rst_n`, a `u_stream_dma`.
  Al liberarse, distintos flops podían salir del reset en ciclos distintos. Es benigno en la
  práctica, porque se libera una vez al arrancar, sin `req_toggle` en vuelo y con el núcleo
  todavía apagado por `core_enable`, pero es un defecto. Ahora `mpeg2fpga_apb_peripheral.v` pasa
  `rst_n` por un sincronizador de 2 flops sobre `clk_internal`: aserción asíncrona, liberación
  síncrona. El PLL de `u_ccc` tiene `PLL_POWERDOWN_N_0` en 1, así que el reloj corre durante el
  reset y no hay deadlock. `mpeg2video` ya se sincronizaba en `reset.v`.
- **Los sincronizadores no son violaciones.** Los dos PLL parten del mismo `REF_CLK_50MHz`, así que
  SmartTime deduce una relación de fase y analiza cada cruce como un camino de un ciclo. Todos los
  cruces PCLK↔decodificador son toggles sincronizados con 2-FF, datos que el handshake mantiene
  estables (los false paths que ya existían) o el reset. Se agregó `set_clock_groups -asynchronous`
  (FIC_3 OUT3 contra u_ccc OUT0/1/2) a `apb3_mpeg2fpga_bridge_cdc.sdc`. Probado primero con
  `run_verify_timing.tcl` sobre 8004bc9: parsea sin errores y solo queda la violación de −6 ps de
  la IP de Microchip.

**Ojo con el orden:** el `set_clock_groups` también corta el camino del reset. Sin el
sincronizador, solo habría escondido el defecto real.

## 8a6d847: build completo con los relojes

Síntesis 6 min, place & route 30 min, Verify Timing 5 min. Cero violaciones de setup y de hold, en
las tres esquinas (slow_lv_lt, fast_hv_lt, slow_lv_ht). La de −6 ps de FIC_0 desapareció: con
relojes reales en la síntesis, ese camino quedó con +1,66 ns.

| Reloj | Frecuencia | Setup (ns) | Hold (ns) |
|---|---|---|---|
| u_ccc OUT0 (`mem_clk`) | 162 MHz | 0,950 | 0,071 |
| u_ccc OUT1 (`clk`) | 108 MHz | 0,810 | 0,023 |
| u_ccc OUT2 (`dot_clk`) | 27 MHz | 4,475 | 0,001 |
| CCC_FIC_x OUT0 (FIC_0) | 162 MHz | 1,659 | 0,048 |
| CCC_FIC_x OUT3 (FIC_3, PCLK) | 51,2 MHz | 3,022 | 0,067 |

Ocupación: 35 468 LUT4 (37,9 %), 31 347 DFF (33,5 %), 325 uSRAM, 30 LSRAM, 20 Math, 55 E/S.
Comparado con 8004bc9: +116 LUT y +31 DFF.

`.job` en `~/mpeg2fpga-bitstreams/8a6d847/`
(sha256 `2d6a63bbb1bc5c4c756e56bf3121f6b6ea92f2b6891267f481a731cd3465f2ee`).

**Pendiente:** calificarlo en la placa (`release/qualify.sh`) antes de fijarlo en
`release/manifest.json`. Cambió el RTL.

## Lección

Un "cero violaciones" solo vale si se comprueba que el análisis tuvo algo contra qué medir. En
8004bc9 el síntoma estaba a la vista: columnas de slack vacías en el reporte multi-corner.
