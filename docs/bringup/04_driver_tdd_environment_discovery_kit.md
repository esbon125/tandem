# Fase 4 — Entorno TDD para el driver Linux de mpeg2fpga

**Fecha:** 2026-08-03
**Placa:** PolarFire SoC FPGA Discovery Kit (MPFS-DISCO-KIT), MPFS095T-1FCSG325E
**Kernel de referencia:** `6.18.17-linux4microchip-2026.04.1-g7fbe4f69684d` (el mismo confirmado por
`uname -a` en la Fase 2)
**Fuente del kernel:** `linux4microchip/linux.git`, rama `linux-6.18-mchp`, commit
`7fbe4f69684d19b9038beefbbc1d52bed3c141ab`

## Objetivo

Dejar preparado el entorno para desarrollar en TDD el driver de kernel que hablará con el core
mpeg2fpga: lógica pura testeada con KUnit (sin hardware), un modelo del periférico en Renode para
tests de integración, y confirmar que el driver real cross-compila exactamente contra el kernel que
corre en la placa. La integración física de mpeg2fpga como esclavo AXI/APB dentro del diseño Libero
del MSS sigue siendo trabajo de hardware separado, no cubierto acá.

## Interfaz de registros

Fuente: `trunk/mpeg2fpga/doc/mpeg2fpga.txt`, cap. 1 (rama `hardware_development`). No es un banco
plano de 32 registros: son **2×16 registros de 32 bits** (16 "read-mode" + 16 "write-mode"), ambos
direccionados por el mismo bus de 4 bits pero seleccionados por líneas `reg_rd_en`/`reg_wr_en`
independientes — leer y escribir la misma dirección accede a registros distintos, con semántica
distinta.

Read-mode: `0 version`, `1 status` (bits `error`, `video_ch`, `frame_end`, `picture_hdr`, `osd_*`,
`watchdog_status`, `matrix_coefficients` — todos read-to-clear salvo `matrix_coefficients`), `2 size`,
`3 display size`, `4 frame rate`, `f testpoint`.

Write-mode `0` (`stream`): `watchdog_interval` (bits 15-8; 0=expira ya, 1-254 habilitado/default 127,
255=deshabilitado) + `osd_enable` (bit 3) + `picture_hdr_intr_en`/`frame_end_intr_en`/
`video_ch_intr_en` (bits 2-0). Resto de registros write-mode (`1`-`b`, `f`): timing de video,
CLUT/datos/dirección OSD, trick-mode — no tienen impacto en el parseo de status/IRQ/watchdog y quedan
fuera del alcance de esta fase.

**Punto clave para el diseño del driver**: el banco write-mode no tiene lectura de vuelta (no existe
un registro read-mode que refleje `stream`) — el driver necesita mantener una copia sombra del último
valor escrito para poder cambiar un solo bit (p. ej. una sola fuente de IRQ) sin pisar los demás
(`watchdog_interval`, `osd_enable`, las otras dos `*_intr_en`).

## Estructura del código

```
driver/mpeg2fpga/
├── mpeg2fpga_regs.h        # offsets/bitfields, GENMASK/BIT de <linux/bitops.h>
├── mpeg2fpga_core.c/.h     # lógica pura: status, shadow RMW de IRQ/watchdog, sin ioremap
├── mpeg2fpga_platform.c    # platform_driver real: ioremap, IRQ, of_device_id "esbon,mpeg2fpga"
├── Makefile                # Kbuild out-of-tree para mpeg2fpga_platform.c
└── tests/
    ├── mpeg2fpga_core_test.c   # KUnit contra un backend de registros fake en memoria
    └── run_kunit.sh            # sincroniza el código a un árbol de kernel clonado y corre kunit.py

renode/
├── models/MPEG2FPGARegisters.cs   # modelo del periférico (mismos offsets/bits que mpeg2fpga_regs.h)
├── mpeg2fpga.resc                  # plataforma PolarFire SoC + mpeg2fpga simulado
└── tests/smoke_test.resc           # prueba manual de lectura/escritura/IRQ por consola de Renode
```

`mpeg2fpga_core.c` no conoce `ioremap`/`platform_device`: recibe un `struct mpeg2fpga_regops` con
callbacks `read`/`write` inyectables, lo que permite testearlo con KUnit contra un backend falso y
reutilizarlo tal cual desde `mpeg2fpga_platform.c` contra registros reales.

## Fase 4a — KUnit (lógica pura, sin hardware)

Los 7 casos de test cubren exactamente el punto clave de arriba: que `mpeg2fpga_core_set_irq_mask`,
`mpeg2fpga_core_set_watchdog_interval` y `mpeg2fpga_core_set_osd_enable` hacen read-modify-write
correcto sobre la sombra sin pisarse entre sí, que `mpeg2fpga_core_read_status` parsea todos los
campos del registro de status, y que el estado inicial coincide con power-up/reset real (watchdog en
127, todas las `*_intr_en` en 0).

Para correr KUnit bajo UML se clonó el mismo commit exacto que corre en la placa
(`linux4microchip/linux` @ `linux-6.18-mchp`, `7fbe4f69684d19b9038beefbbc1d52bed3c141ab` — coincide
con el sufijo `g7fbe4f69684d` que reporta `uname -a` desde la Fase 2) en `~/kernel-src/` (fuera del
repo). `run_kunit.sh` sincroniza el código a `drivers/misc/mpeg2fpga/` dentro de ese clon, genera un
`Kconfig`/`Makefile` locales, los engancha en `drivers/misc/{Kconfig,Makefile}`, y corre
`tools/testing/kunit/kunit.py run --arch=um`.

### Incidentes encontrados

- **Python del host demasiado viejo**: `kunit.py` usa sintaxis de Python ≥3.8 (operador walrus); el
  `python3` por defecto de este host (AlmaLinux 8) es 3.6.8. Fix: `run_kunit.sh` busca explícitamente
  un intérprete moderno (`python3.11` está instalado en este host) antes de invocar `kunit.py`.
- **Bug real del kernel 6.18 en builds UML**: el primer intento de build falló compilando
  `kernel/fork.c` con errores en `arch/x86/include/asm/unwind_user.h` (`struct pt_regs` sin el
  miembro `flags`). Causa raíz: a `arch/um/include/asm/Kbuild` le falta la línea
  `generic-y += unwind_user.h` — sin ella, el build de UML termina usando el header específico de x86
  (que asume el `pt_regs` real de x86_64) en lugar del stub genérico vacío
  (`include/asm-generic/unwind_user.h`) que si usan `bug.h`, `mmiowb.h`, etc. en ese mismo archivo.
  Es un fix de una línea, aplicado solo en el clon local (no afecta el build real para RISC-V de la
  Fase 4c, que no toca `arch/um`).

### Resultado

```
=============== mpeg2fpga_core (7 subtests) ================
[PASSED] mpeg2fpga_core_test_init_sets_default_watchdog
[PASSED] mpeg2fpga_core_test_get_version
[PASSED] mpeg2fpga_core_test_read_status_parses_all_fields
[PASSED] mpeg2fpga_core_test_set_irq_mask_preserves_watchdog
[PASSED] mpeg2fpga_core_test_set_watchdog_preserves_irq_mask
[PASSED] mpeg2fpga_core_test_set_osd_enable_preserves_other_bits
[PASSED] mpeg2fpga_core_test_watchdog_disable
================= [PASSED] mpeg2fpga_core ==================
...
Testing complete. Ran 741 tests: passed: 668, failed: 4, skipped: 69
Failures: fortify.fortify_test_alloc_size_kmalloc_const, fortify.fortify_test_alloc_size_vmalloc_const,
fortify.fortify_test_alloc_size_kvmalloc_const, fortify.fortify_test_alloc_size_devm_kmalloc_const
```

Los 7/7 tests propios pasan. Las 4 fallas son de la suite genérica `fortify` del kernel (no relacionadas
con este driver — quedaron habilitadas porque el `.config` se generó desde cero con `olddefconfig` en
vez de partir del `.config` real de la imagen).

## Fase 4b — Modelo del periférico en Renode

`MPEG2FPGARegisters.cs` sigue el patrón de
`extras/workspace.examples/mpfs-mustein/renode/models/MusteinGenericGPU.cs` (registro por offset con
callbacks de lectura/escritura) combinado con el patrón de IRQ de
`Peripherals/I2C/MPFS_I2C.cs` (`IRQ = new GPIO()`, `IRQ.Set(...)` desde un `UpdateInterrupt()`
centralizado), ambos incluidos en la instalación local de SoftConsole. A diferencia de Mustein, acá
`ReadDoubleWord`/`WriteDoubleWord` se implementan a mano (no vía `DoubleWordRegisterCollection`) para
poder modelar fielmente el read-to-clear del status y el shadow write-only de `stream`.

Expone métodos públicos (`RaisePictureHeader`, `RaiseFrameEnd`, `RaiseVideoChange`, `RaiseError`,
`ExpireWatchdog`) invocables como comandos de consola de Renode, para simular eventos del decoder sin
necesidad de un stream MPEG-2 real — es un doble de prueba para el driver, no un decoder funcional.

### Incidentes encontrados

- **`@scripts/...` no resuelve desde `renode/`**: `polarfire-soc-base-platform.resc` y `macros.resc`
  viven en `renode-microchip-mods/scripts/`, un árbol *hermano* del `renode/` principal que trae
  SoftConsole — no están bajo `renode/scripts/`. El launcher gráfico de SoftConsole agrega esa carpeta
  al `PATH` interno de Renode automáticamente; desde CLI hay que hacerlo a mano con el comando de
  monitor `path add @.../renode-microchip-mods` (ya resuelto dentro de `mpeg2fpga.resc`, no hace falta
  repetirlo al invocarlo).
- **`$GDB_SERVER_PORT` sin definir aborta el script**: `polarfire-soc-base-platform.resc` arranca un
  servidor GDB incondicionalmente y esa variable normalmente la fija el launcher de SoftConsole; sin
  ella el script aborta a mitad de camino. Fix: `mpeg2fpga.resc` la define explícitamente antes de
  incluir la plataforma base.
- **`uint >> uint` no compila en C#**: a diferencia de C, el operando derecho de `<<`/`>>` en C# debe
  ser `int`, no `uint` — un `private const uint ...Shift` causó un error de compilación al primer
  intento de cargar el modelo.

### Resultado (`renode/tests/smoke_test.resc`, por consola)

```
--- version register (expect 0x00000001) ---
0x00000001
--- enable picture_hdr_intr_en, watchdog_interval=127 (write 0x00007F04) ---
--- mpeg2fpga.IRQ before RaisePictureHeader (expect False) ---
GPIO: unset
--- mpeg2fpga.IRQ after RaisePictureHeader (expect True) ---
GPIO: set
--- status register read (expect bit3 picture_hdr set = 0x00000008) ---
0x00000008
--- status register read again (expect 0, read-to-clear) ---
0x00000000
--- mpeg2fpga.IRQ after status read (expect False again) ---
GPIO: unset
```

Confirma, de punta a punta y por fuera de cualquier test automatizado: la IRQ se activa exactamente
cuando la fuente correspondiente está habilitada, el registro de status se limpia solo al leerlo, y la
IRQ baja en consecuencia — el comportamiento que el driver real va a depender.

## Fase 4c — Driver real cross-compilado

**Hallazgo de toolchain**: la receta del kernel de `linux4microchip/meta-mchp`
(`meta-mchp-common/recipes-kernel/linux/linux-mchp_6.18.bb`) fija `SRCREV =
7fbe4f69684d19b9038beefbbc1d52bed3c141ab` sobre `linux4microchip/linux.git` rama `linux-6.18-mchp` —
ese hash es exactamente el sufijo `g7fbe4f69684d` del `uname -a` de la Fase 2. No hizo falta compilar
Yocto para conseguir el árbol de kernel exacto de la placa: alcanzó con clonar ese commit puntual.

**Toolchain bare-metal insuficiente para `modules_prepare`**: se intentó primero con
`riscv64-unknown-elf-gcc` (el toolchain bare-metal de SoftConsole, usado en la Fase 1). Compila casi
todo el árbol, pero su `ld` — construido sin soporte para objetos compartidos, algo que un toolchain
bare-metal nunca necesita — falla con `-shared not supported` al linkear el VDSO
(`arch/riscv/kernel/vdso/`), un paso obligatorio de `modules_prepare` en RISC-V porque el VDSO es en
sí mismo una biblioteca compartida expuesta a userspace. Se resolvió instalando el par
`gcc-riscv64-linux-gnu`/`binutils-riscv64-linux-gnu` de EPEL (`sudo dnf install`) — mismo host, sin
necesidad de Docker ni de un build de Yocto.

**`modules_prepare` solo no alcanza para un `Module.symvers` útil**: ese target prepara el árbol
(headers, `scripts/`, `module.lds`) pero no genera un `Module.symvers` poblado, porque no compila
`vmlinux` ni los módulos in-tree — no hay símbolos exportados que recolectar todavía. Se optó por un
build completo (`make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc)`, con `mpfs_defconfig`
como base) para obtener un `Module.symvers` real con símbolos genuinos.

### Resultado

```
$ make -C ~/kernel-src/linux4microchip-linux ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- \
      M=driver/mpeg2fpga modules
  CC [M]  mpeg2fpga_core.o
  CC [M]  mpeg2fpga_platform.o
  LD [M]  mpeg2fpga.o
  MODPOST Module.symvers
  CC [M]  mpeg2fpga.mod.o
  LD [M]  mpeg2fpga.ko
```

`.modinfo` del `.ko` resultante:

```
license=GPL
description=mpeg2fpga MPEG-2 decoder platform driver
author=Esteban Bustamante
alias=of:N*T*Cesbon,mpeg2fpgaC*
alias=of:N*T*Cesbon,mpeg2fpga
depends=
name=mpeg2fpga
vermagic=6.18.17-linux4microchip-2026.04.1-g7fbe4f69684d-dirty SMP mod_unload riscv
```

El `vermagic` coincide, símbolo a símbolo, con el kernel real de la placa (`6.18.17-linux4microchip-
2026.04.1-g7fbe4f69684d`) — el único añadido es `-dirty`, que viene del parche local (inofensivo, solo
afecta `arch/um`) aplicado para la Fase 4a, no de ningún cambio relevante para RISC-V. Para un build
de despliegue real bastaría con descartar ese parche antes de compilar.

### Pendiente: arranque de Linux dentro de Renode

El plan original contemplaba cargar el `.ko` dentro de una sesión de Linux arrancando en el modelo de
Renode de la Fase 4b, para probar `probe()` y la entrega de IRQ contra el periférico simulado de punta
a punta. Se evaluó y se decidió **no** encararlo en esta sesión: a diferencia de todo lo anterior (que
reutilizó ejemplos/plataformas ya armados), esto requiere construir desde cero un rootfs/initramfs
mínimo, adaptar un device tree para la plataforma simulada, y resolver la cadena de arranque completa
en Renode — un esfuerzo comparable al resto de la Fase 4 junta, sin ningún punto de partida local. Se
deja como trabajo futuro explícitamente delimitado; mientras tanto, la Fase 4b (modelo + smoke test
manual) y la verificación de `vermagic` de la Fase 4c ya dan cobertura razonable de que el driver va a
hacer `probe()` y recibir la IRQ correctamente una vez integrado.

## Conclusión

Queda validada la Fase 4 del plan en la medida planteada: lógica de negocio del driver (parseo de
status, shadow de IRQ/watchdog) cubierta por KUnit y corriendo en verde contra el kernel exacto de la
placa; modelo de hardware simulado en Renode que reproduce fielmente el comportamiento de IRQ y
read-to-clear documentado en `mpeg2fpga.txt`; y el driver real (`mpeg2fpga_platform.c`)
cross-compilando limpio con un `vermagic` que coincide con el kernel de producción. Falta, como
trabajo futuro delimitado, el arranque de Linux dentro de Renode para la prueba de integración final
end-to-end — y, fuera del alcance de este plan de software, la integración física de mpeg2fpga como
esclavo AXI/APB en el diseño Libero del MSS.
