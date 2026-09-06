# Fase 7a (cont.): reloj CCC corregido, MPU2(FIC1).STATUS, y simetría FIC0-3

Continuación de [28_fase7a_smartdebug_ground_truth_and_bvalid_wedge.md](28_fase7a_smartdebug_ground_truth_and_bvalid_wedge.md).
El bug de fondo (`mem2axi_bridge` se cuelga en `S_BRESP`, `bytes_done=1385` con
`tcela-17.bits`, `m_axi_bvalid` nunca llega desde el FIC1/MSS) **sigue sin
resolverse**. Esta sesión se dedicó a cerrar hipótesis candidatas con
evidencia dura, y a instrumentar dos vías nuevas (STATUS por-MPU, registros
de clock/reset/DLL por FIC) que no se habían mirado antes.

## 1. Bug real encontrado y corregido: `PF_CCC_C0` en 125/125/125MHz

`soc_build/script_support/components/PF_CCC_C0.tcl` tenía las tres salidas
(`clk`/`mem_clk`/`dot_clk`) en 125MHz desde que se creó (Fase 5b, 6-ago,
commit `aa982b9`) -- nunca coincidió con lo que `bench/iverilog/testbench.v`
documenta como las frecuencias reales del diseño: `clk=108MHz` (OUT1/GL1_0),
`mem_clk=162MHz` (OUT0/GL0_0), `dot_clk=27MHz` (OUT2/GL2_0). Nadie lo había
notado hasta que se releyó el testbench esta sesión.

Corregido vía la GUI de Libero (no a mano -- un intento manual de
`GL1_0_DIV:12` dio 124.8MHz en vez de 108MHz exacto) a: `GL0_0_DIV:6`
`OUT_FREQ:162`, `GL1_0_DIV:9` `OUT_FREQ:108`, `GL2_0_DIV:36` `OUT_FREQ:27`,
`PLL_REFDIV_0:1`, `PLL_IN_FREQ_0:50` (commit `8ccfd27`). VCO=972MHz
consistente (162x6=108x9=27x36=972), verificado exacto vía el SDC derivado.

**Gotcha de Libero encontrado en el camino**: el CCC tiene una 4ta salida
(`GL3_0`/OUT3) que nuestra instancia (`u_mpeg2/u_ccc`) no usa, pero una
instancia SEPARADA del mismo componente `PF_CCC_C0` en
`CLOCKS_AND_RESETS.tcl` (del reference design base, para `FIC_3_CLK`) sí la
necesita. Copiar el `GL3_0_IS_USED:false` que exportó la GUI (correcto para
NUESTRA instancia) rompió el build de la OTRA instancia. Se revirtió
`GL3_0_DIV`/`GL3_0_IS_USED` a sus valores originales manteniendo GL0/1/2
corregidos.

**Resultado en hardware: sin cambio.** Probado con el generador aislado
(`ISOLATED_MEM2AXI_TEST`, ver más abajo) a mem_clk=156MHz primero y luego con
el decoder real a 108/162/27MHz exactos -- mismo stall exacto,
`bytes_done=1385`, `push_cnt=60`, `pop_cnt=0`,
`dbg_last_write_awaddr_issued=0xc8e00000` en ambos casos. La hipótesis de
frecuencia de reloj queda **refutada** en todas las variantes probadas, pero
el fix en sí (125MHz→108/162/27MHz) se mantiene porque es correcto y
documentado -- no se revierte aunque no haya sido la causa del stall.

## 2. Test aislado de `mem2axi_bridge` (bypaseando el resto del decoder)

Se agregó (y luego se revirtió, commits `fb72880`/`85233ba`) un
`` `ifdef ISOLATED_MEM2AXI_TEST `` en `mpeg2fpga_apb_peripheral.v` que
reemplaza las salidas reales de `u_mpeg2` hacia `mem_req_rd_*` por un
generador free-running (`CMD_WRITE` incrementando dirección/dato), dejando
intacta la generación de `mem_clk_internal`/`mem_hard_rst_internal` (PF_CCC_C0
+ cadena de reset reales). Esto aísla FIC_1/`mem2axi_bridge` de la
arbitración de `framestore_request`, VLD, watchdog y lecturas concurrentes
por FIC_2.

Verificado primero con un testbench iverilog auto-generado (stubs por regex
de los módulos dependientes) antes de gastar un ciclo de build de Libero
(~50min) -- atrapó un bug real de declare-before-use (`mem_clk_internal`
referenciado antes de su propia declaración).

**Resultado en hardware**: reproduce el mismo wedge que el decoder real
-- `addr_r` avanza (confirmado vía SmartDebug, de `0x100000` a
`0x362170`, millones de ciclos de estado) pero ningún dato llega
realmente a DRAM (escaneo de 96MB+32MB, cero bytes). Confirma que el bug
no depende de la interacción con el resto del pipeline del decoder.

## 3. Verificación rigurosa de falso-negativo en la lectura de DRAM

A pedido explícito del usuario ("podes de verdad cerciorarte..."), se
verificó que el método de lectura de DRAM vía `/dev/mem` no esté dando
falsos negativos:
- write/readback de `0xDEADBEEF` en 4 direcciones repartidas en los 32MB
  de la región -- OK.
- write/readback de `0xCAFECAFECAFECAFE` en la dirección EXACTA esperada
  del FPGA (`0xc8800000 = DDR_BASE(0xc8000000) + addr_r(0x100000)*8`,
  calculada replicando exactamente la fórmula de `mem2axi_bridge.v` línea
  229) -- OK.

Descarta falso-negativo con certeza.

## 4. `MPU2(FIC1).STATUS` -- hallazgo nuevo, no explica el stall

Toda sesión anterior solo miraba el registro agregado de SYSREG
(`MPU_VIOLATION_SR`/`SW_FAIL_ADDR0/1_CR`, offset `0xF0`/`0xF8`/`0xFC` de
SYSREG). Nunca se había leído el STATUS **propio de cada MPU**
(`MPU_TypeDef.STATUS`, 64 bits, offset `0x80` dentro del bloque de cada MPU;
`MSS_MPU(master) = 0x20005000 + (master<<8)`; MPU2=FIC1 → STATUS en
`0x20005180`; campos `addr[37:0]` `write[38]` `id[42:39]` `failed[43]` per
MSS TRM Table 3-43).

Script: `/root/webserver/diag_mpu_violation.py` (limpia
`SYSREG.MPU_VIOLATION_SR`, hace push real de `tcela-17.bits`, vuelve a leer).
`/root/webserver/diag_mpu_check_only.py` es la variante read-only sin
dependencia de UIO/decoder.

Reproducido en **dos reboots limpios consecutivos** (un `reboot` de Linux NO
resetea la fábrica FPGA, así que este latch sobrevive reboots):

```
MPU2(FIC1).STATUS: failed=True  rw=write  id=0  addr=0x3fc8000000
```

- Los 32 bits bajos (`0xc8000000`) son exactamente `DDR_BASE`.
- Los 6 bits altos (`0x3f`, todo en 1) no deberían estar -- `DDR_BASE` es
  un parámetro de 38 bits con esos bits en 0.
- Esos mismos 6 bits altos coinciden con la ventana de 64GB que la Tabla
  6-2 del MSS TRM asigna a FIC1 (`0x30_00000000`-`0x3F_FFFFFFFF`) para el
  sentido MSS-maestro→fábrica (que nosotros no usamos).

Está pendiente de discutir con el usuario (leyendo el TRM en paralelo) si
esa tabla realmente aplica a nuestra dirección de tráfico o es una
coincidencia. **Importante**: se limpió el latch y se hizo un push real
completo -- el STATUS **no volvió a dispararse** durante el push que
efectivamente se cuelga. O sea, esta violación específica es un evento
único de arranque (sobrevive desde antes del primer reboot de esta sesión,
posiblemente desde el primer power-up/JTAG program del bitstream actual) y
**no coincide temporalmente con el stall que perseguimos** -- es un bug
real y nuevo, pero no parece ser la causa directa del wedge en `S_BRESP`.

## 5. Simetría de clock/reset/DLL entre los 4 FICs -- otra hipótesis cerrada

Script: `/root/webserver/diag_fic_clkrst.py`. Lee `SUBBLK_CLOCK_CR` (0x84),
`SOFT_RESET_CR` (0x88), `DLL_STATUS_SR` (0x15C) de SYSREG, decodifica por FIC.

```
FIC    clk_en  in_reset  dll_lock  dll_lock_now  dll_unlock(sticky)
FIC0   True    False     True      True          False
FIC1   True    False     True      True          False
FIC2   True    False     True      True          False
FIC3   True    False     True      True          False
```

Los cuatro FIC son bit-a-bit idénticos. Descarta una asimetría de
clock/reset/DLL a nivel MSS entre FIC0 (funciona) y FIC1 (se cuelga).

## 6. `FIC_1_AXI4_INITIATOR_USED=true` -- prendido mas allá del default, pero atado a "unused"

El usuario mostró la GUI del MSS Configurator con los valores **por
defecto**: FIC_1 tiene "Use Initiator Interface" DESTILDADO (solo "Use
Target Interface" tildado). Nuestro proyecto real
(`soc_build/script_support/MPFS_DISCOVERY_KIT_MSS.cfg`, confirmado también en
la copia de `components/MSS/`) tiene:

```
FIC_1_AXI4_INITIATOR_USED    true
FIC_1_AXI4_TARGET_USED       true
```

O sea, el Initiator SÍ está prendido en nuestro proyecto, a diferencia del
default -- no se sabe todavía por qué ni desde cuándo. Se verificó que ese
puerto (~40 señales AXI4 que `MSS_WRAPPER` expone cuando Initiator está
activo) no queda flotando: `MPFS_DISCOVERY_KIT.tcl` línea 183 tiene
`sd_mark_pins_unused -sd_name ${sd_name} -pin_names
{MSS_WRAPPER_0:FIC_1_AXI4_INITIATOR}`, así que Libero lo ata a un estado
seguro explícitamente. No hay evidencia de que esto cause el stall, pero
queda como cabo suelto -- no debería estar prendido si nunca se usa esa
dirección de tráfico, y valdría la pena simplemente apagarlo para
simplificar y sacarse la duda.

## Hipótesis descartadas esta sesión (con evidencia dura)

- Frecuencia de reloj del CCC (125MHz erróneo, luego 108/162/27MHz exacto;
  probado con generador aislado Y con decoder real) -- sin cambio en el
  hardware.
- `BREADY`/`RREADY` no unconditional (ya eran un fix de sesión previa,
  re-confirmado sin efecto en hardware).
- Falso negativo en el método de lectura de DRAM -- descartado
  rigurosamente.
- Asimetría de clock/reset/DLL FIC0 vs FIC1 a nivel SYSREG -- idénticos.
- Puerto Initiator de FIC1 flotando eléctricamente -- está atado
  explícitamente vía `sd_mark_pins_unused`.
- La violación de MPU2(FIC1) coincidiendo temporalmente con el stall real
  -- no se repite durante un push real después de limpiarla.

## Estado y próximos pasos

El misterio central sigue intacto: `mem2axi_bridge` completa AW/W
(`aw_done=1`/`w_done=1`) pero `m_axi_bvalid` nunca llega; el FSM da
evidencia de ciclar (vía `addr_r` avanzando) sin que el dato llegue
realmente a DRAM. Ningún registro software-visible (MPU, SYSREG
clock/reset/DLL, MPU-STATUS por-master) muestra nada anómalo DURANTE el
stall real -- todo lo anómalo encontrado (la violación de MPU2, el
Initiator prendido) resultó ser, hasta donde se pudo verificar, no
correlacionado temporalmente con el cuelgue.

Pendiente para la próxima sesión:
- Terminar de leer con el usuario TRM §3.4, capítulo 6, y §3.5
  (Segmentation Blocks) y comparar interpretaciones de la Tabla 6-2.
- Decidir si apagar `FIC_1_AXI4_INITIATOR_USED` (simplificación, no
  debería tener efecto pero saca un cabo suelto).
- Considerar una tap de RTL con `syn_keep`/`syn_preserve` real para
  `m_axi_bvalid` (la ronda anterior de debug bits sin esos atributos dio
  lecturas no confiables vía homemade taps -- ver
  [smartdebug_active_probes_vs_homemade_taps.md] en memoria) o habilitar
  `GENERATEDEBUGDATA` para verlo con Active Probes reales, ya que sigue
  siendo la única señal de la investigación completa que nunca se observó
  directamente.
