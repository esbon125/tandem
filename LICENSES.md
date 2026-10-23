# Licencias

El repositorio reúne componentes de distintos autores y licencias. `LICENSE`
(MIT) cubre todo lo que no tenga otra licencia indicada acá o en el propio
archivo.

| Componente | Dónde | Autor | Licencia |
|---|---|---|---|
| Servicio `mpeg2fpgad`, biblioteca Python, conversor nativo, demostración, herramientas, proceso de release, user guide | `daemon/`, `api/`, `demo/`, `tools/`, `webserver/`, `release/`, `user-guide/`, `doxygen/` | Esteban Bustamante | MIT (`LICENSE`) |
| Driver de kernel `mpeg2fpga.ko` | `driver/` | Esteban Bustamante | GPL-2.0 (`SPDX-License-Identifier` en cada fuente) |
| Módulos RTL propios (integración con PolarFire SoC) | `trunk/mpeg2fpga/rtl/` | Esteban Bustamante | CERN-OHL-S-2.0 (`trunk/mpeg2fpga/rtl/LICENSES.md`) |
| Núcleo decodificador mpeg2fpga | `trunk/mpeg2fpga/` | Koen De Vleeschauwer | BSD (avisos originales en cada archivo) |
| Script de construcción del SoC | `trunk/mpeg2fpga/soc_build/` | Microchip / Esteban Bustamante | MIT (`soc_build/REFERENCE_DESIGN_LICENSE.md`) |
| IP generada por Libero (MSS, CCC, COREFIFO, …) | proyecto Libero | Microchip | Términos de licencia de Microchip |
| Documentos académicos (anteproyecto, informe final) | `docs/` | Esteban Bustamante | Los que indique cada documento |

`trunk/` existe en `hardware_development` y `docs/` en la rama `docs`; en
`master` están todos juntos.

`THIRD_PARTY_NOTICES.md` lista lo que se distribuye en cada release y los
avisos que lo acompañan. Patentes: `trunk/mpeg2fpga/rtl/LICENSE-MPEG2`.
