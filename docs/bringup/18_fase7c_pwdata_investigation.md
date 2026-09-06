# Fase 7c (continuación) — investigación en vivo de PWDATA con SmartDebug

**Fecha:** 2026-08-17
**Rama:** `hardware_development`
**Contexto:** el doc anterior (`17_fase7c_dma_streamer.md`) cerró con `DMA_LEN`/`DMA_ADDR` confirmados
como no-funcionales por software (readback siempre en 0) y sin causa raíz identificada — parqueado
para retomar con SmartDebug/JTAG en vivo, algo que el entorno de esta sesión no puede manejar
directamente. Esta sesión es esa continuación: el usuario operó SmartDebug directamente en Libero
mientras yo diseñaba los experimentos, generaba los registros de debug, y corría síntesis/P&R/
programación. Sigue sin resolverse — este doc deja todo lo descartado y la hipótesis que queda en pie
para la próxima sesión.

## Hallazgo central: `apb_wdata_r` nunca lleva el dato real

Con el registro de debug de `DMA_ADDR`/`DMA_LEN` (readback agregado en la sesión anterior) más una
captura de SmartDebug directa sobre `u_bridge` (no `u_stream_dma`), se consiguió ver el estado real de
los registros PCLK-domain del bridge en el momento exacto de un write real a `DMA_LEN`:

- `apb_addr_r[4:0]` = `10010` = `0x12` = **exactamente `DMA_LEN_ADDR`** — dirección correcta.
- `apb_write_r` = `1` — correctamente identificado como escritura.
- `apb_wdata_r` (`reg_dta_in[31:0]`) = **`0x00000000`** — se escribió `12599` (`0x3137`), no llegó nada.

Esto es la pieza clave: el control de la transacción (dirección, flag de escritura, handshake
`PSEL`/`PENABLE`/`PREADY`) funciona perfecto. Es específicamente el **dato** el que nunca llega.

## Descartado en esta sesión (con evidencia, no por descarte especulativo)

1. **Ancho/valor de los datos**: se probó una matriz de valores (`0xAA` — el mismo ancho/valor que
   supuestamente ya maneja `STREAM_PUSH_ADDR` —, `0x01`, `0x8000`, y `12599` real) escritos a `DMA_LEN`
   uno por uno con capturas de SmartDebug entre cada uno. Los 5 casos dieron `dma_len_r = 0`. No es un
   problema de ancho de bus ni de qué bits están en 1.

2. **`STREAM_PUSH_ADDR` (Fase 7a) tiene el mismo bug**: se escribió `0xC3` directo a `STREAM_PUSH_ADDR`
   y se sondeó `apb_wdata_r` — también `0`. Esto es importante: el bug **no es nuevo de la Fase 7c**,
   viene de la Fase 7a (o de antes). El mecanismo de push manual "funcionaba" en el sentido de que las
   transacciones completaban y el backpressure por `busy` medía tiempos reales — pero eso nunca probó
   que el **dato en sí** llegara bien, solo que el control sí. Es enteramente posible que ningún byte
   real del stream haya llegado nunca a `mpeg2video` durante toda la Fase 7a — lo cual, de ser cierto,
   sería la explicación unificadora de la Fase 7a *y* de este bug: la misma causa raíz detrás de
   `SIZE=0` y de `DMA_LEN=0`.

3. **Mecanismo de escritura de software (`struct.pack_into` sobre `mmap`)**: se verificó de forma
   aislada (sin tocar hardware) que escribe los 4 bytes correctos en un buffer de memoria — descarta
   un bug de software puro.

4. **`/dev/mem` / `devmem2` como camino de escritura independiente**: bloqueado por
   `CONFIG_STRICT_DEVMEM` del kernel (`Operation not permitted`). Se evaluó forzarlo con
   `iomem=relaxed` en el bootloader, pero se descartó: `devmem2` internamente hace lo mismo que ya hace
   Python (un store de 32 bits alineado a un puntero volatile sobre memoria mapeada) — no iba a aportar
   una vía genuinamente distinta.

5. **`PSTRB` (byte write-strobes)**: se encontró que el MSS expone `FIC_3_APB_M_PSTRB[3:0]` como puerto
   nativo separado, y que en este diseño se conecta únicamente a `RECONFIGURATION_INTERFACE_0`, no a
   nuestro periférico ni al bus compartido. Se confirmó por `git log -S` que esa conexión viene del
   commit original de la Fase 5b (`aa982b9`), sin tocar desde entonces — no es algo que rompimos
   nosotros. Se descartó como causa: si fuera un problema de strobes no llegando a nadie, el UART
   (mismo bus compartido, misma ausencia de `PSTRB`) tampoco debería funcionar — y funciona (por ahí
   sale la consola SSH que se usó toda la sesión).

6. **Cableado del netlist (`PWDATA` mal conectado a nuestro periférico específicamente)**: se comparó
   directamente en el `.v` generado post-síntesis la conexión de `PWDATA` hacia
   `CoreUARTapb_C0_0` (funciona) contra `MPEG2FPGA_APB_PERIPHERAL_0` (no funciona). Ambos derivan del
   **mismo** `FIC_3_ADDRESS_GENERATION_1_FIC_3_0x4000_00xx_PWDATA` de 32 bits — UART toma un slice de 8
   bits (`PWDATA[7:0]`, coherente con su propio ancho de bus), nosotros tomamos el bus completo de 32
   bits, ambos por un `assign` directo sin lógica intermedia. Cableado correcto de punta a punta —
   descarta un bug de conectividad del netlist.

7. **`COREAXI4INTERCONNECT`/`COREFIFO`**: Libero avisó de versiones nuevas disponibles para estos dos
   cores. Se revisó si `COREAXI4INTERCONNECT` era una pieza faltante en el camino de FIC_3 — no lo es:
   solo se usa en `FIC0_INITIATOR.tcl`/`DMA_INITIATOR.tcl` (el propio `DMA_CONTROLLER` del diseño base
   en FIC_0), un camino completamente distinto al de FIC_3/APB. No se actualizaron los cores durante la
   investigación para no introducir una variable más mientras se acotaba el problema.

8. **Timing de captura — dos experimentos de RTL directos, ambos negativos**:
   - *Intento 1*: relatchear `apb_addr_r`/`apb_wdata_r`/`apb_write_r` en cada ciclo que `PSEL` está
     alto (no solo en el ciclo `PSEL&&PENABLE`), para el caso de que el master solo sostuviera
     `PWDATA` válido durante la fase de Setup. Sin cambios: sigue en 0.
   - *Intento 2* (más agresivo): agregar un estado `A_SETTLE` que mantiene la fase de Access abierta
     64 ciclos extra de `PCLK`, re-latcheando `PWDATA` en cada uno de ellos antes de comprometerse —
     protocolarmente válido, ya que el master de todas formas debe tolerar un `PREADY` demorado
     (el CDC de este mismo bridge ya lo demora bastante en cada acceso normal). Sin cambios: sigue en
     0, incluso con 64 ciclos completos de margen.

   Estos dos experimentos, sumados a la prueba anterior con 50&nbsp;ms de pausa entre escrituras
   separadas, descartan de forma bastante concluyente **cualquier** explicación de timing/asentamiento
   — tanto "lo muestreamos muy temprano" como "necesita más ciclos" quedan descartadas. `PWDATA` parece
   estar en 0 de forma persistente durante toda la ventana de la transacción, no por una cuestión de
   *cuándo* se lo mira.

## Investigado pero sin conclusión firme

- **Manual técnico del MSS** (`docs/polarfire/PolarFire_SoC_FPGA_MSS_Technical_Reference_Manual_VC.pdf`,
  sección 6.1): confirma que FIC_3 tiene su propia conversión **"AXI to APB"** integrada en el bloque
  duro del MSS (Figura 6-1) — un camino fijo, no inspeccionable, distinto del `COREAXI4INTERCONNECT` de
  FIC_0. La sección 3.7 ("AHB-to-APB") describe un modo de escritura *posted* (`SR_AHBAPB_CR.APBx_POSTED`)
  donde la CPU puede seguir de largo antes de que la escritura APB realmente se complete — coincide en
  espíritu con el síntoma, pero esa sección específica describe el puente AHB-a-APB **interno** que
  alimenta a `MMUART0`/`WDOG0`/`SYSREG-PRIV` (rango `0x2000_xxxx`), no necesariamente el mismo camino que
  usa FIC_3 (`0x4000_xxxx`+), y no se encontró un bit de control equivalente documentado para FIC_3.
  Además, cualquier teoría de "una escritura posterior le gana de mano a la nuestra" ya quedaba
  descartada por la prueba de 50&nbsp;ms de pausa (punto 8 arriba).

## Nota de proceso: cuidado al re-sintetizar con Libero GUI abierto

Dos veces durante esta sesión el usuario tenía Libero abierto en modo gráfico con el proyecto cargado
(sesión de SmartDebug en curso) mientras yo corría `rm -rf soc_build/MPEG2FPGA_SOC` para forzar una
resíntesis limpia (necesario porque `build_mpeg2fpga_soc.tcl` solo re-lee los TCL de SmartDesign en un
proyecto nuevo, ver `libero_build_script_gotchas` en memoria). El handle de la GUI a `MPEG2FPGA_SOC.prjx`
quedó apuntando a un archivo borrado (confirmado con `lsof`) — el usuario indicó que no había problema
en continuar, pero es un riesgo real a tener en cuenta: **antes de borrar `soc_build/MPEG2FPGA_SOC`,
chequear `ps aux | grep libero_bin` y `lsof -p <pid>` por una instancia gráfica con el proyecto abierto**.

## Estado al cierre de esta sesión

`DMA_ADDR`/`DMA_LEN` (y muy probablemente `STREAM_PUSH_ADDR` desde la Fase 7a) nunca reciben el dato
real escrito por software, confirmado con lectura directa de `apb_wdata_r` por JTAG — no es un artefacto
del mecanismo de lectura de software. Descartado: ancho/valor de los datos, mecanismo de escritura de
Python, conectividad del netlist (comparado contra UART, que sí funciona, mismo bus), `PSTRB`,
`COREAXI4INTERCONNECT`, y — con dos experimentos de RTL distintos en hardware real — cualquier teoría de
timing de captura.

**Lo que queda en pie para la próxima sesión**: una captura de `PWDATA` completamente libre, sin
ninguna condición de protocolo (`PSEL`/`PENABLE`) — un registro que muestree el bus en todo momento,
para ver si alguna vez, en cualquier instante, se ve algo distinto de 0. Si nunca aparece nada real,
el problema deja de ser de esta lógica de captura por completo y pasa a ser más físico/estructural
(algo específico de cómo ese bit del bus compartido llega a nuestro periférico, más allá de lo ya
confirmado como correcto a nivel de netlist estático). Discutido y acordado con el usuario, pendiente
de implementar.

## Commits de esta sesión

- `hardware_development` `ee7ad19`: agrega el estado `A_SETTLE` (experimento 2 de timing, negativo,
  documentado igual porque descarta una hipótesis real y deja el mecanismo funcionando sin regresión —
  `bench/apb_bridge/testbench.v` sigue en 25/25).
