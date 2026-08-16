# Fase 5d — Overlay de device tree real: hang de hardware en el primer acceso real a mpeg2fpga (cerrada)

**Fecha:** 2026-08-15/16
**Rama:** `hardware_development` (RTL/build), `firmware_development` (driver, sin cambios en esta fase)
**Estado: cerrada.** Causa raíz encontrada y corregida (`PLL_POWERDOWN_N_0` sin conectar en la
instancia de `PF_CCC_C0` de `mpeg2video.v`), verificada en silicio real por dos caminos de acceso
independientes (lectura cruda por UIO y `insmod` del driver de kernel con entrega de IRQ real
confirmada por `/proc/interrupts`). Instrumentación de diagnóstico removida del código fuente al
cierre. Este es, con diferencia, el documento de bring-up más largo del proyecto hasta ahora — cubre
dos crashes reales de placa, una investigación de RTL de varias rondas, y la resolución completa.

**Contexto:** con Fase 5c cerrada (`docs/bringup/08_...md`) la placa arranca Linux limpio hasta login por
SSH, con `mpeg2fpga_apb_peripheral` integrado como esclavo APB3 en `FIC_3` y su IRQ ruteada al PLIC.
Fase 5d era, en teoría, el cierre del ciclo TDD completo: aplicar un overlay de device tree real con la
dirección/IRQ verdaderas y repetir la prueba de `insmod`/`probe()` de la Fase 4d contra silicio real.
En cambio, el primer acceso real de hardware al periférico — por cualquier camino — colgó la placa
entera, dos veces. Este documento cubre la investigación completa, en orden cronológico: los dos
crashes, la revisión de RTL, tres rondas de instrumentación de diagnóstico (una de ellas un falso
negativo que hubo que reconciliar), la causa raíz real, y la verificación final en hardware.

## Verificación de dirección e IRQ contra la documentación oficial

Antes de sospechar de RTL, se confirmó que los parámetros del overlay eran correctos, no solo por
inspección empírica sino contra la fuente oficial:

- **Dirección**: `mpeg2fpga_apb_peripheral` ocupa el slot que antes tenía el SPI del 7-segmentos
  (`FIC_3_0x4000_04xx`, ver Fase 5b), es decir `0x40000400`. `/fabric-bus@40000000` tiene mapeo `ranges`
  1:1 (sin traducción de dirección) para toda esa región, confirmado leyendo el device tree en vivo —
  así que la dirección física real y la usada en el overlay coinciden sin sorpresas.
- **IRQ**: la IRQ de mpeg2fpga está en `MSS_INT_F2M[20]` (Fase 5b). La Tabla 5-1 del
  *PolarFire SoC FPGA MSS Technical Reference Manual*
  (`docs/polarfire/PolarFire_SoC_FPGA_MSS_Technical_Reference_Manual_VC.pdf`) documenta el ruteo fijo de
  silicio: `MSS_INT_F2M[31:0] → Global_int[136:105] → IRQ[149:118]`, es decir **PLIC = bit_F2M + 118**.
  Para el bit 20: PLIC IRQ **138**. Se descartó explícitamente una hipótesis alternativa (el mux
  `microchip,mpfs-gpio-irq-mux`, `drivers/irqchip/irq-mpfs-mux.c`) — ese mux es exclusivo de las 70
  líneas de interrupción de GPIO0/1/2 y no tiene nada que ver con el ruteo general fabric→PLIC.

Con esto confirmado contra la Tabla 5-1 oficial (no solo contra el patrón empírico de otros periféricos
del reference design), el overlay usado fue:

```dts
/dts-v1/;
/plugin/;

/ {
	fragment@0 {
		target-path = "/fabric-bus@40000000";
		__overlay__ {
			mpeg2fpga0: mpeg2fpga@40000400 {
				compatible = "esbon,mpeg2fpga";
				reg = <0x0 0x40000400 0x0 0x40>;
				interrupt-parent = <&plic>;
				interrupts = <138>;
				status = "okay";
			};
		};
	};
};
```

compilado con `dtc -@ -I dts -O dtb -o mpeg2fpga.dtbo mpeg2fpga.dts` (el flag `-@` genera
`__fixups__`/`__local_fixups__`, necesarios para resolver `&plic` contra la tabla `__symbols__` del
árbol en vivo) y aplicado dinámicamente vía configfs (`CONFIG_OF_OVERLAY=y`/`CONFIG_OF_CONFIGFS=y`,
ambos presentes en esta imagen):

```sh
mkdir /sys/kernel/config/device-tree/overlays/mpeg2fpga
cat mpeg2fpga.dtbo > /sys/kernel/config/device-tree/overlays/mpeg2fpga/dtbo
```

(los overlays de configfs no persisten entre reboots — hay que reaplicarlos cada vez.)

## Crash #1: `insmod` del driver de kernel

Con el overlay aplicado, `insmod mpeg2fpga.ko` (el platform driver de la Fase 4, sin cambios —
`driver/mpeg2fpga/mpeg2fpga_platform.c`, rama `firmware_development`) hace, en `probe()`:
`devm_platform_ioremap_resource` → `platform_get_irq` → `devm_request_irq` → escribe el registro
`STREAM`/máscara de IRQ → lee el registro `VERSION` (`mpeg2fpga_core_get_version()`, cuyo `dev_info` de
confirmación es la última línea de `probe()` — nunca apareció en ningún log, ni de este crash ni del
siguiente, señal de que el cuelgue ocurre en el primer acceso real, sea cual sea).

Resultado: la sesión SSH se cortó inmediatamente. La placa quedó sin responder a ping/ARP por más de 90
segundos. Solo se recuperó con un power-cycle físico.

## Intento de recuperación por UART, sin éxito

Antes del power-cycle físico se intentó un reboot vía Magic SysRq sobre el UART de consola. Esto
requiere una condición de **BREAK** real de la línea serie (no alcanza con escribir el carácter de
comando por `write()`/`printf` a `/dev/ttyUSBx` — hace falta el ioctl `TIOCSBRK`/`TIOCCBRK`). Se
implementó vía Python, pero no logró reiniciar la placa — el sistema estaba demasiado colgado, o SysRq
no estaba habilitado en esta imagen. Se confirma entonces que, una vez producido este cuelgue, **la
única recuperación conocida es el power-cycle físico**.

## Crash #2: acceso crudo desde userspace, sin driver ni IRQ

Para aislar si el driver de kernel (IRQ, `devm_request_irq`, etc.) tenía algo que ver, se repitió el
acceso de la forma más mínima posible: **sin ningún módulo de kernel cargado, sin pedir la IRQ**, un
simple `mmap` + lectura desde un script de Python en userspace.

`/dev/mem` crudo está bloqueado en esta imagen (`CONFIG_STRICT_DEVMEM=y` +
`CONFIG_IO_STRICT_DEVMEM=y`, `PermissionError: Operation not permitted` al intentar mapear una región
MMIO arbitraria). Se usó en cambio el framework genérico **UIO** (`compatible = "generic-uio"`, el mismo
patrón que usa el propio `.dtsi` de Microchip para `fpgalsram`), vía un segundo overlay:

```dts
/dts-v1/;
/plugin/;

/ {
	fragment@0 {
		target-path = "/fabric-bus@40000000";
		__overlay__ {
			mpeg2fpga_uio: mpeg2fpga@40000400 {
				compatible = "generic-uio";
				linux,uio-name = "mpeg2fpga_diag";
				reg = <0x0 0x40000400 0x0 0x40>;
				status = "okay";
			};
		};
	};
};
```

UIO mapea la página completa alineada a `PAGE_SIZE` que contiene el `reg`, expuesta en
`/sys/class/uio/uioN/maps/map0/{addr,size}` — el offset del registro dentro de esa página se calculó en
consecuencia (no es simplemente el offset dentro de `reg`, sino relativo a la base ya alineada). Una
lectura de 4 bytes del registro `VERSION` (offset 0) a través de `/dev/uio2`, sin driver, sin IRQ, sin
ningún código de kernel involucrado más allá del framework UIO genérico ya probado:

Mismo resultado exacto que el Crash #1 — corte inmediato de SSH, placa sorda a ARP/ICMP, confirmado
después (vía la sesión de UART, no de red) que `dmesg` mostraba la misma firma de crash. Volvió a
requerir power-cycle físico.

## Firma del crash, ambas veces

Idéntica en los dos casos, vista en el log de kernel de los harts que seguían respondiendo (no el que
se colgó):

```
rcu: INFO: rcu_sched detected stalls on CPUs/tasks
Tainted: G O
INFO: task ... blocked for more than N seconds
mmc0: Timeout waiting for hardware cmd/data interrupt
```

Con NMI backtraces y pérdida total de red mientras la consola UART seguía mostrando actividad de log de
*otros* harts. Esta es la firma clásica de **un hart genuinamente atascado en una espera de bus
bloqueante y no preemptible** (una transacción AHB/APB que nunca completa porque `PREADY` nunca se
activa) — no matable ni con `SIGKILL`/`timeout` a nivel de SO, porque el stall ocurre a nivel de
pipeline de CPU, no es una espera schedulable.

**Conclusión de estos dos crashes, reproducidos por caminos de acceso completamente independientes**
(driver de kernel con IRQ vs. lectura cruda de userspace sin IRQ ni driver): esto descarta cualquier
causa de software/driver/configuración de IRQ. El bug es genuinamente de hardware/RTL, en el camino de
acceso real a los registros de mpeg2fpga a través de `apb3_mpeg2fpga_bridge.v`.

## Revisión de RTL

Se releyó `trunk/mpeg2fpga/rtl/mpeg2/apb3_mpeg2fpga_bridge.v` completo: FSM de dos fases
(`A_IDLE`/`A_WAIT_ACK` en el dominio `PCLK`, `C_IDLE`/`C_READ_WAIT1`/`C_READ_WAIT2`/`C_DONE` en el
dominio `core_clk`), cada uno con sincronizadores de 2FF para el bit de toggle del otro dominio. No se
encontró ningún bug obvio de lógica. Se verificó también la polaridad del reset
(`mpeg2video.v` línea 93: `input rst; // active low reset`) — correcta, coincide con cómo se instancia.

## Hipótesis principal: el CCC de `mpeg2video` nunca lockea

En `mpeg2video.v` (líneas 556-561), la instancia de `PF_CCC_C0` **no tiene el puerto `LOCK` conectado
en absoluto** — solo se cablean `REF_CLK_0`, `OUT0_FABCLK_0` (`mem_clk`), `OUT1_FABCLK_0` (`clk`),
`OUT2_FABCLK_0` (`dot_clk`). La hipótesis principal: este PLL/CCC nunca llegó a lockear/alternar en
silicio real, porque **nunca antes se había ejercitado este dominio de reloj** — el arranque de Linux
no depende para nada del dominio de reloj de `mpeg2video`. Si `core_clk` está genuinamente muerto, la
FSM del lado `core_clk` del bridge queda esperando para siempre un toggle de ack que nunca puede llegar
— explicando un cuelgue en *cualquier* acceso, lectura o escritura, con o sin IRQ, exactamente lo
observado en los dos crashes.

## Camino descartado: Synopsys Identify

Antes de instrumentar, se evaluó usar el instrumentador/debugger de Synopsys Identify (empaquetado con
Synplify Pro en esta instalación de Libero) para poner un analizador lógico embebido sobre `core_clk`
sin necesitar un osciloscopio o LA externo — pedido explícito del usuario para evitar instrumentos
físicos. Se confirmó que tanto `identify_instrumentor_shell` como `identify_debugger_shell` soportan
modo headless (`-batch -nopopup -f script.tcl`), pero la integración oficial de Identify con Libero para
*configurar* la instrumentación sobre un diseño requiere interacción de GUI ("Configure Identify
Launch" desde dentro de Synplify, lanzado desde Libero) — no se encontró una forma documentada de
hacerlo puramente por TCL desde la orquestación propia de Libero. Ante ese gap real entre la preferencia
del usuario (sin instrumentos externos, sin GUI) y lo que la herramienta soporta de forma headless, se
descartó este camino a favor de una instrumentación propia más simple.

## Instrumentación: heartbeat de `core_clk`, expuesto por un camino de hardware distinto

En vez de una tercera prueba de riesgo por el mismo camino sospechoso (registro/bridge), se agregó un
diagnóstico aislado que **nunca toca `u_bridge` ni `regfile.v`**: un contador de 24 bits libre corriendo
en `core_clk`, sincronizado a `PCLK` con un simple sincronizador de 2FF (igual técnica que usa el propio
bridge para sus toggles, aplicada acá a un bit que ya cambia lento — sin riesgo de metaestabilidad),
expuesto como un nuevo puerto de salida `clk_alive` en `mpeg2fpga_apb_peripheral.v`:

```verilog
reg  [23:0] dbg_heartbeat_cnt = 24'h0;
reg         dbg_heartbeat_meta, dbg_heartbeat_sync;

always @(posedge clk_internal)
  dbg_heartbeat_cnt <= dbg_heartbeat_cnt + 24'h1;

always @(posedge PCLK or negedge PRESETn) begin
  if (!PRESETn) begin
    dbg_heartbeat_meta <= 1'b0;
    dbg_heartbeat_sync <= 1'b0;
  end else begin
    dbg_heartbeat_meta <= dbg_heartbeat_cnt[23];
    dbg_heartbeat_sync <= dbg_heartbeat_meta;
  end
end

assign clk_alive = dbg_heartbeat_sync;
```

24 bits a ~108MHz alternan el MSB cada ~78ms — suficientemente rápido para verse en dos lecturas
separadas por un par de segundos, suficientemente lento para que el sincronizador de un solo bit sea
seguro para cualquier relación de frecuencias entre los dos dominios.

Ese bit se ruteó, vía `FIC_3_PERIPHERALS.tcl` y `MPFS_DISCOVERY_KIT.tcl`, a
`MSS_WRAPPER_0:GPIO_2_F2M_24` — un bit del controlador GPIO2 nativo del MSS que hasta ahora estaba atado
a GND (sin usar) en el diseño. Este es un camino de hardware **completamente independiente** del bridge
sospechoso: GPIO2 (`gpio2`, `microchip,mpfs-gpio`, `20122000.gpio`) ya está `status = "okay"` en el
device tree base de esta placa (`mpfs-disco-kit.dts`) y ya lo usan los LEDs de la placa — un camino
Linux ya probado y seguro, sin overlay ni riesgo adicional. `GPIO_2_F2M_N` mapea 1:1 al índice de línea
del controlador (confirmado con el patrón ya existente en el diseño: `DIP5..DIP8` → `GPIO_2_F2M_25..28`,
leídos hoy sin overlay vía `gpioget`), así que `GPIO_2_F2M_24` es directamente la línea 24 de
`gpiochip1`.

### Cambios de RTL/SmartDesign (rama `hardware_development`, sin commitear al momento de escribir esto)

- `trunk/mpeg2fpga/rtl/mpeg2/mpeg2fpga_apb_peripheral.v`: puerto `clk_alive` + contador/sincronizador
  de arriba.
- `trunk/mpeg2fpga/soc_build/script_support/components/FIC_3_PERIPHERALS.tcl`: puerto
  `MPEG2FPGA_CLK_ALIVE` y su conexión a `MPEG2FPGA_APB_PERIPHERAL_0:clk_alive`.
- `trunk/mpeg2fpga/soc_build/script_support/components/MPFS_DISCOVERY_KIT.tcl`: se quitó la atadura a
  GND de `GPIO_2_F2M_24` y se conectó a `MPEG2FPGA_CLK_ALIVE`.

Es instrumentación **temporal**, a remover una vez encontrado y corregido el bug real del bridge/reloj.

### Rebuild y verificación de pines

Reconstruido desde cero (`SYNTHESIZE` → `PLACEROUTE` → `GENERATE_PROGRAMMING_DATA` → `EXPORT_FPE`), las
cuatro etapas terminaron limpias. `PLACEROUTE` reportó los mismos 4 errores de SDC de paths falsos
(`ARESETN` de `FIC_0_PERIPHERALS`/DMA e IHC, y paths de `shift_reg` internos de las FIFOs de memoria de
`mpeg2video`) ya vistos en builds previas — no relacionados con este cambio, el flujo continúa más allá
de esos errores sin abortar y termina con **55/55 pines fijados**. Se verificaron los pin locks
críticos contra los valores conocidos-correctos de la Fase 5c:

| Señal | Esperado (Fase 5c) | Este build |
|---|---|---|
| `REF_CLK_50MHz` | R18, LVCMOS18 | R18, LVCMOS18 |
| `MBUS_I2C_SCL` | D11, LVCMOS33 | D11, LVCMOS33 |

Coinciden. `.job` generado en `trunk/mpeg2fpga/soc_build/MPEG2FPGA_SOC.job`.

### Procedimiento de lectura (por SSH, sin overlay, sin tocar el bridge)

```sh
gpiodetect
# gpiochip1 [20122000.gpio] (32 lines)  <- GPIO2, el controlador correcto

gpioget -c gpiochip1 24
sleep 3
gpioget -c gpiochip1 24
```

Con el bitstream *anterior* (Fase 5c, `GPIO_2_F2M_24` atado a GND) esta lectura ya se probó y dio
`inactive` de forma consistente — confirma que el mecanismo de lectura en sí funciona antes de tener el
heartbeat real conectado.

Si el valor cambia entre las dos lecturas del bitstream nuevo → `core_clk` está vivo, y el bug hay que
seguir buscándolo en otra parte de la interacción bridge/`regfile.v`. Si queda fijo (en cualquiera de
los dos estados) → confirma la hipótesis de que el CCC nunca lockea, y el siguiente paso sería revisar
la configuración del `PF_CCC_C0` (routing del reloj de referencia, parámetros de configuración) en vez
de la lógica digital del bridge.

## Resultado de la ronda 1: confirmado, `core_clk` parece muerto

Con el `.job` instrumentado flasheado y la placa reiniciada, `gpioget -c gpiochip1 24` dio
`inactive` de forma consistente en múltiples lecturas separadas por varios segundos — el heartbeat de
24 bits sobre `core_clk` **nunca cambia**. Consistente con la hipótesis: `clk_internal` (la señal `clk`
interna de `mpeg2video`, derivada de `PF_CCC_C0`) parecía no tener ni un solo flanco desde el power-on.
(Este resultado terminó siendo, en parte, un falso negativo — ver más abajo la ronda 2 y la
reconciliación — pero en este punto de la investigación apuntaba con fuerza a un reloj muerto, y la
causa que se encontró a continuación era real independientemente de eso.)

## Causa raíz #1 (real, pero no toda la historia): `PLL_POWERDOWN_N_0` sin conectar

Revisando el Verilog generado por Libero para el macro `PF_CCC_C0`
(`component/work/PF_CCC_C0/PF_CCC_C0.v` y `..._PF_CCC.v`, dentro del proyecto ya sintetizado) se
encontró que el componente expone un puerto de entrada obligatorio,
**`PLL_POWERDOWN_N_0`** — cableado directo al pin físico **`POWERDOWN_N`** del primitivo `PLL` real de
silicio (activo bajo; confirmado en la config exportada del componente: `"PLL_EXPORT_PWRDWN:true"`).

La instanciación de `u_ccc` en `mpeg2video.v` (ver Fase 5b) **nunca conectó este puerto**:

```verilog
PF_CCC_C0 u_ccc (
  .REF_CLK_0(ref_clk),

  .OUT0_FABCLK_0(mem_clk),
  .OUT1_FABCLK_0(clk),
  .OUT2_FABCLK_0(dot_clk)
);
```

Una entrada de instancia sin conectar en Verilog queda flotante (`z`); en la síntesis de Libero/Synplify
para este tipo de IP dura, eso se resuelve atándola a GND — es decir, `POWERDOWN_N = 0` de forma
permanente. Esto sí mantenía al PLL en powerdown desde el power-on — un bug real, e independiente de lo
que se descubrió después. Fix aplicado (mínimo, aditivo):

```verilog
PF_CCC_C0 u_ccc (
  .REF_CLK_0(ref_clk),
  .PLL_POWERDOWN_N_0(1'b1),

  .OUT0_FABCLK_0(mem_clk),
  .OUT1_FABCLK_0(clk),
  .OUT2_FABCLK_0(dot_clk)
);
```

## Ronda 2: el heartbeat sigue sin moverse incluso con el powerdown corregido

Se reconstruyó (`SYNTHESIZE`→`PLACEROUTE`→`GENERATE_PROGRAMMING_DATA`→`EXPORT_FPE`, las cuatro etapas
limpias, 55/55 pines fijados igual que en Fase 5c) dejando la instrumentación de heartbeat de la ronda 1
en el mismo build, como verificación cruzada. Se flasheó y se repitió la lectura: **`gpioget -c
gpiochip1 24` seguía dando `inactive` de forma consistente**, a pesar del fix.

Antes de asumir una segunda causa, se verificó exhaustivamente que el fix realmente hubiera llegado al
silicio, leyendo directamente el netlist post-síntesis
(`MPEG2FPGA_SOC/synthesis/MPFS_DISCOVERY_KIT.vm`):

- La instancia de PLL que alimenta `clk_internal`/`mem_clk`/`dot_clk` de `mpeg2video` (identificada
  sin ambigüedad porque sus salidas `CLKINT` llevan esos nombres exactos) mostraba
  `.POWERDOWN_N(VCC)` — el fix **sí** se propagó correctamente hasta el primitivo real. (Había una
  *segunda* instancia de `PLL` en el mismo netlist, la del reloj de sistema de `CLOCKS_AND_RESETS`
  que ya arranca Linux — con `.POWERDOWN_N(AND4_FABRIC_PLL_POWERDOWN_Y)`, una señal derivada, no VCC —
  hay que tener cuidado de no confundir las dos instancias al leer este tipo de netlist.)
- `ref_clk` de esa misma instancia trazaba, a través de la jerarquía completa
  (`mpeg2fpga_apb_peripheral` → `FIC_3_PERIPHERALS` → top level `MPFS_DISCOVERY_KIT`), hasta
  `REF_CLK_50MHz_c`, la salida del mismo `INBUF` físico (`REF_CLK_50MHz_ibuf`, pad R18) que alimenta el
  PLL de sistema ya funcionando — mismo reloj de referencia físico, confirmado correcto.
- El propio contador `dbg_heartbeat_cnt` aparecía en el reporte de síntesis (`.srr`) clockeado
  exactamente por `pll_inst_0.OUT1` de **esa misma instancia** (vía `clkint_4`) — la cadena de reloj
  entre el PLL y el contador de diagnóstico estaba, en el papel, completamente correcta.

Con powerdown, referencia y clockeo del contador triple-verificados correctos, y el heartbeat
igualmente sin moverse, la contradicción quedó abierta: o el PLL seguía sin lockear por otra razón, o
el problema estaba en el propio diagnóstico.

## Ronda 3: en vez de inferir, medir `PLL_LOCK_0` directamente

Se agregó un segundo diagnóstico, más directo: exponer la señal real **`PLL_LOCK_0`** del macro
`PF_CCC_C0` (indicador de lock del propio circuito duro del PLL) en vez de depender de un contador
derivado. Cambios (puramente aditivos, mismo patrón que `clk_out`):

- `mpeg2video.v`: nuevo puerto de salida `pll_lock_out`, conectado a `.PLL_LOCK_0(pll_lock)` en la
  instancia `u_ccc`.
- `mpeg2fpga_apb_peripheral.v`: `clk_alive` pasó a reflejar `pll_lock` sincronizado a `PCLK` vía 2FF
  (en vez del contador de 24 bits) — mismo puerto/ruteo hacia `GPIO_2_F2M_24`, sin cambios de
  SmartDesign/Tcl necesarios.

Reconstruido y flasheado (mismo flujo de 4 etapas, mismos 55/55 pines). Resultado:

```
root@mpfs-disco-kit:~# gpioget -c gpiochip1 24
"24"=active
root@mpfs-disco-kit:~# gpioget -c gpiochip1 24
"24"=active
```

**`PLL_LOCK_0` está activo, de forma consistente.** El PLL genuinamente cree que está lockeado al
reloj de referencia.

## Reconciliando la contradicción

`LOCK` activo y el heartbeat de la ronda 1/2 inmóvil, con el mismo PLL, es contradictorio si ambos
diagnósticos fueran igualmente confiables — no lo son. Los dos comparten el mismo sincronizador de 2FF
hacia `PCLK` (así que un `PRESETn` trabado habría afectado a los dos por igual; como `LOCK` sí se lee
correctamente, `PRESETn` queda descartado como causa). La diferencia real está en la fuente:

- `LOCK` es una señal simple, de nivel, directamente desde el macro duro del PLL.
- El heartbeat dependía de un contador de 24 bits propio. El reporte de síntesis marcó explícitamente
  ese contador como un patrón reconocido (`@N: MO231 :... Found counter in view: ... instance
  dbg_heartbeat_cnt[23:0]`) — Synplify infiere primitivos/optimiza específicamente estructuras de
  contador reconocidas, y aunque la cadena de reloj se verificó correcta en el papel, la instrumentación
  añadida por este proyecto (no el diseño original) es la explicación más probable de un falso negativo,
  no evidencia de que el reloj siguiera muerto.

Dado que `LOCK` es la señal más directa y confiable disponible (viene del propio circuito de detección
de lock del hardware, no de lógica añadida por este diagnóstico), se decidió confiar en ese resultado y
pasar a la prueba que realmente importaba: el acceso real al registro.

## Verificación final: acceso real al registro, dos caminos, ambos exitosos

Sobre el mismo bitstream de la ronda 3 (el path del bridge/regfile no cambia entre rondas — solo cambia
qué se expone en el pin de diagnóstico), sin necesidad de reflashear nada:

**Lectura cruda por UIO** (mismo mecanismo del Crash #2, offset de registro `VERSION` = 0x0 dentro de la
página mapeada en `0x400`):

```
mmap ok, about to read VERSION register at offset 0x400
VERSION = 0x0000000c
```

Sin cuelgue. Placa healthy después (uptime normal, sin firma de crash en `dmesg`).

**`insmod` del driver de kernel real** (mismo overlay `compatible = "esbon,mpeg2fpga"`, IRQ 138, del
Crash #1 — con `target-path` corregido a `/fabric-bus@40000000` por prolijidad, aunque ya se había
determinado que `/soc` no era la causa del crash original):

```
mpeg2fpga 40000400.mpeg2fpga: mpeg2fpga hw version 0x000c, irq 100
```

Esta es exactamente la línea de `dev_info` final de `probe()` que **nunca había aparecido** en ningún
intento anterior — señal inequívoca de que `probe()` completó de punta a punta:
`devm_platform_ioremap_resource` → `platform_get_irq` → `devm_request_irq` → escritura de máscara de
IRQ → lectura de `VERSION` (0x000c, coincide con la lectura UIO). Confirmado además en
`/proc/interrupts`:

```
100:       2196          0          0          0 SiFive PLIC 138 Edge      40000400.mpeg2fpga
```

IRQ Linux 100, mapeada al PLIC ID 138 — exactamente el calculado contra la Tabla 5-1 del MSS TRM al
principio de este documento. Ya se habían disparado 2196 interrupciones al momento de revisar (sin
ningún stream real alimentando al decoder, así que probablemente una fuente de error/watchdog
disparando repetidamente sin datos válidos que procesar — no es un problema de estabilidad, pero queda
anotado como algo a tener en cuenta cuando se implemente manejo real de interrupciones en el driver).

Placa estable, sin ningún síntoma de crash, en ambos casos.

## Causa raíz real y completa

`PLL_POWERDOWN_N_0` sin conectar (causa raíz #1, arriba) era un bug genuino y su fix era necesario. Con
ese fix, el PLL lockea (confirmado directamente por `PLL_LOCK_0`) y el acceso real a los registros
funciona de punta a punta por dos caminos independientes. El heartbeat de las rondas 1-2 que seguía sin
moverse fue, con alta confianza, un artefacto de la instrumentación de diagnóstico agregada por este
proyecto (probablemente relacionado con cómo Synplify infiere/optimiza el patrón de contador de 24
bits), no evidencia de un segundo bug real. No se investigó más a fondo el porqué exacto de ese falso
negativo porque dejó de ser relevante una vez confirmado el resultado real contra silicio.

## Limpieza

Con el fix verificado en hardware, se removió toda la instrumentación de diagnóstico del código fuente
(`clk_alive`/`pll_lock_out` de `mpeg2video.v` y `mpeg2fpga_apb_peripheral.v`, el ruteo en
`FIC_3_PERIPHERALS.tcl`/`MPFS_DISCOVERY_KIT.tcl`, restaurando la atadura a GND original de
`GPIO_2_F2M_24`), dejando en el árbol únicamente el fix real (`.PLL_POWERDOWN_N_0(1'b1)` en
`mpeg2video.v`). Se reconstruyó una última vez para producir un `.job` limpio sin el pin de debug. En
la placa: `rmmod mpeg2fpga` y remoción del overlay de configfs, dejando el sistema en el mismo estado
que antes de empezar esta fase.

## Lecciones para la próxima vez que algo cuelgue la placa

- **Un crash reproducido por dos caminos de acceso completamente independientes** (con y sin driver de
  kernel, con y sin IRQ) es la forma más rápida de descartar software/configuración y confirmar que el
  bug es de hardware/RTL — no hace falta ninguna otra evidencia después de eso.
- **Un puerto de entrada de una IP dura sin conectar no siempre da error de síntesis** — puede
  atarse silenciosamente a un valor por defecto (acá GND) que cambia el comportamiento funcional del
  macro sin ningún warning visible en el flujo normal. Vale la pena revisar el Verilog generado de
  cualquier IP macro nueva (`component/work/<IP>/*.v`) puerto por puerto contra lo que la instanciación
  propia conecta, en vez de asumir que "compila sin error" implica "está bien conectado".
- **Un diagnóstico agregado por uno mismo puede mentir.** El heartbeat de 24 bits parecía la forma más
  simple y segura de verificar un reloj, y terminó siendo la pieza menos confiable de toda la
  investigación — mientras que la señal más simple posible (`LOCK`, un nivel estático directo del
  hardware, sin lógica propia interpuesta) fue la que finalmente destrabó el diagnóstico. Cuando un
  diagnóstico propio da un resultado que contradice todo lo demás que se pudo verificar (wiring,
  netlist, configuración), vale la pena sospechar del diagnóstico mismo antes de inventar una segunda
  causa raíz.
