# Fase 6b — Cablear mem2axi_bridge en el diseño Libero

**Fecha:** 2026-08-16
**Rama:** `hardware_development`
**Contexto:** con `mem2axi_bridge.v` verificado en Icarus contra un esclavo AXI4 de prueba (Fase 6a),
corresponde instanciarlo de verdad e integrarlo al proyecto Libero, exactamente como Fase 5b hizo con el
bridge APB — headless, por script TCL, con verificación contra el Verilog generado al final.

## Objetivo

Que `mpeg2video` deje de tener su interfaz de memoria atada a constantes: conectar `mem_req_rd_*`/
`mem_res_wr_*` a un `mem2axi_bridge` real, y que ese bridge llegue de verdad hasta la DDR a través de
la MSS.

## Corrigiendo un error de la Fase 6a: el puerto correcto es `FIC_1`, no `FIC_0`

Al revisar `MSS_WRAPPER.tcl` con más cuidado para conectar el bridge a la MSS, apareció que
lo que la Fase 6a había asumido estaba invertido: `FIC_0_AXI4_INITIATOR` (con `ARVALID` como *output*
de `MSS_WRAPPER`) es el camino donde **la MSS es la master** hacia fabric (lo usa `MSS_LSRAM`, una
RAM en fabric que la MSS lee/escribe) — no el camino que necesitábamos. El que sirve es
`FIC_0_AXI4_TARGET`/`FIC_1_AXI4_TARGET` (con `ARVALID` como *input* de `MSS_WRAPPER`): ahí fabric es
master y la MSS es el target, que es como fabric llega a la DDR real.

De los dos, `FIC_0_AXI4_TARGET` ya está en uso (por `DMA_CONTROLLER`/`DMA_INITIATOR`, heredado del
reference-design base). `FIC_1_AXI4_TARGET` está **marcado `unused` explícitamente** en
`MPFS_DISCOVERY_KIT.tcl` — libre, mismo tipo de hallazgo que el slot APB libre de FIC_3 en la Fase 5b.
Además ya tiene un reloj propio generado (`CLOCKS_AND_RESETS:FIC_1_CLK`, sin usar por nadie) que
resultó no ser el que correspondía usar (ver la sección siguiente).

## Reloj: `mem_clk` de `mpeg2video`, no un CCC nuevo

`mem_req_rd_*`/`mem_res_wr_*` están documentados "clocked with mem_clk" contra el dominio de reloj
**interno** de `mpeg2video` (generado por su propio `PF_CCC_C0`, ya usado por `framestore.v`). Ese
`mem_clk` nunca se exponía fuera del módulo — solo `clk` lo hacía (`clk_out`, agregado en la Fase 5b
para el mismo problema, pero para el bridge APB). Se agregó el mismo tipo de puerto aditivo:
`mem_clk_out`/`mem_rst_out` en `mpeg2video.v`, sin tocar la configuración del `PF_CCC_C0` ni nada
existente.

Ese `mem_clk_out` reemplaza a `CLOCKS_AND_RESETS:FIC_1_CLK` como fuente de `MSS_WRAPPER:FIC_1_ACLK` —
el camino AXI4 completo (bridge + puerto de la MSS) corre en el mismo reloj real que
`mem_req_rd`/`mem_res_wr` ya usan, sin CDC nueva sin resolver. `CLOCKS_AND_RESETS:FIC_1_CLK` queda sin
consumidor (warning esperado de pin flotante, confirmado en el log de build).

## Bug latente encontrado de paso: comentario anidado en `mpeg2video.v`

Antes de tocar Libero, se armó una elaboración local en Icarus (con un stub de `PF_CCC_C0`, la única
IP dura que no se puede elaborar fuera de Libero) para atrapar errores de wiring/sintaxis baratos antes
de gastar una corrida completa de Libero. Encontró dos bugs reales:
- Dos comentarios propios (de esta fase) con la secuencia literal `_*/` cerrando el bloque de comentario
  antes de tiempo — corregidos.
- Uno preexistente de la Fase 5d: `component/work/PF_CCC_C0/PF_CCC_C0_0/*_PF_CCC.v` dentro de un
  comentario contiene un `/*` literal, que una versión más nueva de Icarus (14.0 devel) trata como
  "Possible nested comment" y aborta. Nunca se había disparado porque ese bloque vive bajo
  `` `ifndef __IVERILOG__ ``, fuera del alcance del testbench grande. Corregido reformulando el
  comentario (sin cambiar significado ni código).

## El error real de Libero: bus interface "not compatible"

Registrar `mem2axi_bridge`'s AXI4 master como bus interface del HDL+ core
(`hdl_core_add_bif -bif_definition {AXI4:AMBA:AMBA4:master} ...`, mismo patrón que ya funciona para
APB) y burbujearlo con `sd_create_bif_port`/`sd_connect_pins` hasta `MSS_WRAPPER:FIC_1_AXI4_TARGET`
falló repetidamente:

```
Error:  Cannot connect the two bus interface pins 'FIC_3_PERIPHERALS:mem_axi_bif' and
'MPEG2FPGA_APB_PERIPHERAL_0:mem_axi_bif' because they are not compatible.
```

Se probaron sistemáticamente: rol `mirroredSlave`, rol `mirroredMaster`, definición de bus con versión
explícita (`AXI4:AMBA:AMBA4:r0p0_0:master` — rechazada por el propio parser, "Incorrect number of
arguments", confirmando que el formato de 4 campos sin versión es el correcto), señal completa
(agregando `AWLOCK/AWCACHE/AWPROT/AWQOS/AWREGION/*USER`, el set completo de la definición de bus según
`busdefinition_catalog.xml` y `AMBA/AMBA4/AXI4/r0p0_0/AXI4.xml` del propio Libero instalado). Ninguna
combinación resolvió el "not compatible" — y no se encontró la causa raíz en la documentación Tcl de
Libero (`hdl_core_add_bif.htm`, `sd_create_bif_port.htm`, `sd_connect_pins.htm`) ni comparando contra
el único ejemplo funcionando en el proyecto (`AXI4mslave0`/`AXI4mmaster0` en `FIC_0_PERIPHERALS.tcl`),
que a diferencia de este caso viene de un IP de catálogo real (`COREAXI4INTERCONNECT` vía
`create_and_configure_core`), no de un `hdl_core_add_bif` sobre un módulo Verilog propio.

**Salida pragmática**: abandonar la abstracción de bus interface para esta conexión y conectar cada
señal individualmente con `sd_connect_pins` (que según su propia documentación solo valida que
ancho/rango coincidan, sin ningún chequeo de tipo/rol de bus) — mismo resultado eléctrico, sin
depender de un comportamiento de Libero no documentado. Costó ~40 líneas de TCL en vez de una sola
llamada, pero funcionó al primer intento una vez con los anchos correctos.

## Segundo hallazgo real: `AWLOCK`/`ARLOCK` es de 1 bit, no 2

Copiar el ancho de `AWLOCK`/`ARLOCK` desde el ejemplo `AXI4mslave0` (`[1:0]`, 2 bits — un resabio de
AXI3 en esa IP de catálogo concreta) produjo un error real y preciso:

```
Error:  Cannot connect 'FIC_3_PERIPHERALS_0:MEM_AXI_AWLOCK' to
'MSS_WRAPPER_0:FIC_1_AXI4_TARGET_FIC_1_AXI4_S_AWLOCK' because of a dimension incompatibility.
```

`MSS_WRAPPER.tcl` confirma que el puerto real de la MSS declara `AWLOCK`/`ARLOCK` como **escalar** (1
bit, el ancho correcto de AXI4 real) — corregido en `mem2axi_bridge.v`, `mpeg2fpga_apb_peripheral.v` y
el TCL.

## Señales sin implementar en la MSS

`MSS_WRAPPER`'s `FIC_1_AXI4_TARGET` (igual que `FIC_0_AXI4_TARGET`) no implementa `AWREGION`/
`ARREGION` ni ninguna señal `*USER` — ni siquiera existen como puertos ahí. `mem2axi_bridge` las deja
atadas a un valor fijo (no le importan) pero esas conexiones simplemente no se promueven más allá de
`mpeg2fpga_apb_peripheral.v`: los outputs quedan flotando sin problema (warning esperado, no error),
y los dos inputs no usados (`BUSER`/`RUSER`) se atan a GND con `sd_connect_pins_to_constant` — Libero sí
exige que un input quede conectado o marcado explícitamente.

## Verificación

Build headless completo (`build_design_hierarchy` → `derive_constraints_sdc`, sin síntesis/PnR — eso
es Fase 6c) terminó con exit code 0 y sin warnings nuevos más allá de los esperados (pines flotantes
por diseño: `CLOCKS_AND_RESETS:FIC_1_CLK`/`RESETN_FIC_1_CLK` ya sin consumidor, y las señales AXI4 sin
implementar en la MSS). Se confirmó además contra el Verilog generado, el mismo tipo de verificación
que cerró la Fase 5b:

```
# MPFS_DISCOVERY_KIT.v
.FIC_1_ACLK ( FIC_3_PERIPHERALS_0_MEM_CLK_MPEG2FPGA ),
.FIC_1_AXI4_TARGET_FIC_1_AXI4_S_ARVALID ( FIC_3_PERIPHERALS_0_MEM_AXI_ARVALID ),
.FIC_1_AXI4_TARGET_FIC_1_AXI4_S_AWVALID ( FIC_3_PERIPHERALS_0_MEM_AXI_AWVALID ),

# FIC_3_PERIPHERALS.v
.mem_clk_out   ( MEM_CLK_MPEG2FPGA_net_0 ),
.m_axi_awvalid ( MEM_AXI_AWVALID_net_0 ),
.m_axi_arvalid ( MEM_AXI_ARVALID_net_0 ),
```

confirmando la cadena completa `mem2axi_bridge → mpeg2fpga_apb_peripheral → FIC_3_PERIPHERALS →
MPFS_DISCOVERY_KIT → MSS_WRAPPER.FIC_1_AXI4_TARGET` de punta a punta.

## Lo que queda pendiente

- **`DDR_BASE`**: sigue en `38'h0`, un placeholder explícito hasta que el lado firmware (Fase 7) fije
  la dirección real del carve-out reservado en la DDR.
- **Fase 6c**: síntesis, place & route, generación de bitstream — la primera vez que este cableado
  toca silicio real. Dado el historial (Fase 5c: bug de pin-lock; Fase 5d: pin sin conectar atado a
  GND silenciosamente), se espera necesitar más de un intento.
- El *pipeline* de `mem2axi_bridge` sigue siendo serializado (una transacción AXI4 en vuelo por vez) —
  ver la nota de diseño en la Fase 6a sobre pipelinear si la latencia real de FIC_1/DDR4 termina
  limitando el throughput del decoder.

## Conclusión

Queda cerrada la Fase 6b: `mem2axi_bridge` está instanciado de verdad dentro de
`mpeg2fpga_apb_peripheral.v`, conectado a `mem_req_rd_*`/`mem_res_wr_*` de `mpeg2video`, y su AXI4
llega hasta `MSS_WRAPPER:FIC_1_AXI4_TARGET` — verificado por build headless limpio y por inspección del
Verilog generado. Sigue Fase 6c: síntesis, P&R, bitstream, y la primera prueba real contra hardware.
