# Fase 5d — Overlay de device tree real: hang de hardware en el primer acceso real a mpeg2fpga (causa raíz encontrada)

**Fecha:** 2026-08-15/16
**Rama:** `hardware_development` (RTL/build), `firmware_development` (driver, sin cambios en esta fase)
**Contexto:** con Fase 5c cerrada (`docs/bringup/08_...md`) la placa arranca Linux limpio hasta login por
SSH, con `mpeg2fpga_apb_peripheral` integrado como esclavo APB3 en `FIC_3` y su IRQ ruteada al PLIC.
Fase 5d era, en teoría, el cierre del ciclo TDD completo: aplicar un overlay de device tree real con la
dirección/IRQ verdaderas y repetir la prueba de `insmod`/`probe()` de la Fase 4d contra silicio real.
En cambio, el primer acceso real de hardware al periférico — por cualquier camino — cuelga la placa
entera. Este documento cubre la investigación hasta el punto en que quedó, incluyendo una
instrumentación de diagnóstico que **todavía no fue probada en hardware** al momento de escribir esto.

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

## Resultado del heartbeat: confirmado, `core_clk` está muerto

Con el `.job` instrumentado flasheado y la placa reiniciada, `gpioget -c gpiochip1 24` dio
`inactive` de forma consistente en múltiples lecturas separadas por varios segundos — el heartbeat de
24 bits sobre `core_clk` **nunca cambia**. Confirma la hipótesis: `clk_internal` (la señal `clk` interna
de `mpeg2video`, derivada de `PF_CCC_C0`) nunca tuvo ni un solo flanco desde el power-on.

## Causa raíz: `PLL_POWERDOWN_N_0` sin conectar

Revisando el Verilog generado por Libero para el macro `PF_CCC_C0`
(`component/work/PF_CCC_C0/PF_CCC_C0.v` y `..._PF_CCC.v`, dentro del proyecto ya sintetizado) se
encontró que el componente expone un puerto de entrada obligatorio,
**`PLL_POWERDOWN_N_0`** — cableado directo al pin físico **`POWERDOWN_N`** del primitivo `PLL` real de
silicio (activo bajo; confirmado en la config exportada del componente: `"PLL_EXPORT_PWRDWN:true"`).

La instanciación de `u_ccc` en `mpeg2video.v` (líneas 556-562, ver Fase 5b) **nunca conectó este
puerto**:

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
permanente. El PLL queda en powerdown desde el power-on, para siempre: nunca produce salida de reloj
válida en ninguno de sus tres `OUT*_FABCLK_0`. Esto explica de punta a punta toda la investigación de
este documento:

- El heartbeat nunca cambia (no hay ningún flanco de `clk_internal` para incrementar el contador).
- Los dos crashes de hardware real: la FSM del lado `core_clk` del bridge (`apb3_mpeg2fpga_bridge.v`)
  literalmente no tiene reloj con el que avanzar — no es un bug de lógica de la FSM (ya revisada y
  correcta), es que su dominio de reloj entero nunca estuvo vivo. Cualquier acceso real, por cualquier
  camino (driver de kernel o UIO crudo), queda esperando para siempre un ack que ninguna lógica
  secuencial puede producir sin reloj — de ahí el hart bloqueado sin posibilidad de recuperación por
  software.
- Por qué nunca se había visto antes: el arranque de Linux (Fases 1-3) y la integración MSS (Fase 5b/c)
  no dependen para nada del dominio de reloj de `mpeg2video` — es la primera vez que algo intenta
  *usarlo* de verdad.

### Fix

Un cambio mínimo y aditivo en `mpeg2video.v`, atando el powerdown a deshabilitado permanentemente
(`1'b1`, activo bajo → nunca en powerdown):

```verilog
PF_CCC_C0 u_ccc (
  .REF_CLK_0(ref_clk),
  .PLL_POWERDOWN_N_0(1'b1),

  .OUT0_FABCLK_0(mem_clk),
  .OUT1_FABCLK_0(clk),
  .OUT2_FABCLK_0(dot_clk)
);
```

## Estado al cierre de este documento

Causa raíz encontrada y fix aplicado en `rtl/mpeg2/mpeg2video.v` (rama `hardware_development`, junto
con la instrumentación de heartbeat de este mismo documento, que se deja **en el mismo build** como
verificación cruzada: si el fix es correcto, el heartbeat en `gpiochip1`/línea 24 debería empezar a
alternar). Pendiente: rebuild completo (`SYNTHESIZE`→`PLACEROUTE`→`GENERATE_PROGRAMMING_DATA`→
`EXPORT_FPE`), reprogramar la placa, y verificar en dos pasos:

1. El heartbeat cambia entre lecturas (confirma que `core_clk` ahora está vivo).
2. Repetir la prueba de acceso real al registro (`insmod` del driver o lectura UIO) — con el reloj vivo,
   la FSM del bridge debería completar sus transacciones normalmente. Este es el único paso que vuelve a
   tocar el camino que causó los dos crashes anteriores; hacerlo con cautela (ver nota abajo) aunque la
   causa raíz identificada da confianza razonable de que ya no debería colgar la placa.

Una vez verificado en hardware, la instrumentación de heartbeat (`clk_alive`, el contador de
`mpeg2fpga_apb_peripheral.v`, y el ruteo por `FIC_3_PERIPHERALS.tcl`/`MPFS_DISCOVERY_KIT.tcl`) debe
removerse — era exclusivamente para este diagnóstico.

**Importante para cualquiera que retome esto antes de que el fix esté verificado en hardware**: el
camino de acceso a registros de mpeg2fpga a través de `apb3_mpeg2fpga_bridge.v` (vía driver de kernel o
vía `/dev/uioN`) colgó la placa entera de forma reproducible dos veces, con el bug de powerdown sin
corregir, y solo se recuperó con power-cycle físico. Con el fix del PLL aplicado no debería volver a
pasar, pero repetir esa prueba es, hasta confirmarlo, el paso de mayor riesgo que queda en esta fase.
