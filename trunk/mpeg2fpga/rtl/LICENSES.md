# Licencias del RTL

Este árbol mezcla dos autores y tres licencias. Cada archivo indica la suya.

| Archivos | Autor | Licencia |
|---|---|---|
| `mpeg2/*.v` con aviso de Koen De Vleeschauwer (el núcleo mpeg2fpga, incluidos los modificados para el port a PolarFire) | Koen De Vleeschauwer | BSD, según su publicación en [OpenCores](https://opencores.org/projects/mpeg2fpga). Los avisos originales se conservan. |
| `mpeg2/apb3_mpeg2fpga_bridge.v`, `mpeg2/build_id.v`, `mpeg2/mem2axi_bridge.v`, `mpeg2/mpeg2fpga_apb_peripheral.v`, `mpeg2/stream_dma.v`, `mpeg2/xfifo_dc.v` (integración con PolarFire SoC) | Esteban Bustamante | CERN-OHL-S-2.0 (`SPDX-License-Identifier` en cada archivo; texto en `LICENSE-CERN-OHL-S-2.0`) |
| `../soc_build/build_mpeg2fpga_soc.tcl` (derivado del diseño de referencia de la Discovery Kit) | Microchip / Esteban Bustamante | MIT (`../soc_build/REFERENCE_DESIGN_LICENSE.md`) |

La CERN-OHL-S es recíproca: quien distribuya un producto hecho con los
archivos propios debe publicar su fuente completa bajo la misma licencia. El
núcleo BSD y la IP que genera Libero (CCC, MSS, COREFIFO) quedan como
*Available Components* bajo sus propias licencias (CERN-OHL-S-2.0, §1.7 y §4.1).

Patentes: ver `LICENSE-MPEG2`. Las del pool MPEG-2 vencieron en casi todos los
países (la última de EE. UU., en febrero de 2018).
