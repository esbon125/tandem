# Fase 2 — Arranque de Linux vía microSD en PolarFire SoC Discovery Kit

**Fecha:** 2026-08-01
**Placa:** PolarFire SoC FPGA Discovery Kit (MPFS-DISCO-KIT), MPFS095T-1FCSG325E
**Diseño programado:** `polarfire-soc-discovery-kit-reference-design`, release `v2026.04` (el mismo
bitstream de la Fase 1 — habilita DDR4, SD/SDIO y Ethernet en el MSS)
**Imagen Linux:** `mchp-base-image-mpfs-disco-kit`, release `linux4microchip-2026.04` del BSP
`linux4microchip/meta-mchp`

## Objetivo

Arrancar Linux desde una tarjeta microSD en la Discovery Kit, usando una imagen prebuilt del BSP
Yocto oficial de Microchip, y confirmar el arranque completo (HSS → OpenSBI → U-Boot → kernel →
userspace) capturando el log por UART.

## Imagen Linux utilizada

El release-design repo (`polarfire-soc-discovery-kit-reference-design`) solo publica en sus
"Releases" jobs de FlashPro Express (bitstream + HSS) — **no** incluye la imagen de Linux para SD,
a pesar de que versiones anteriores del plan asumían un asset `MPFS_DISCOVERY_LINUX_IMAGE.zip` ahí
(eso solo existió en el release inicial `v2024.04` del repo, ya desactualizado). El README del
propio reference-design remite, para "Linux images for eMMC and SD Cards", a la guía de usuario de
la placa:

```
https://github.com/polarfire-soc/polarfire-soc-documentation/blob/master/reference-designs-fpga-and-development-kits/mpfs-discovery-kit-embedded-software-user-guide.md
```

Esa guía a su vez remite a las releases del **BSP Yocto**:

```
https://github.com/linux4microchip/meta-mchp/releases
```

(`polarfire-soc/meta-polarfire-soc-yocto-bsp`, el repo mencionado en el plan original, está
archivado; `linux4microchip/meta-mchp` es el sucesor mantenido.)

Se usó el asset de la release `linux4microchip-2026.04` (30/04/2026), que coincide en versión con
el reference-design `v2026.04` ya programado en la Fase 1:

```
mchp-base-image-mpfs-disco-kit.rootfs-20260430114629.wic.gz   (~104 MiB)
mchp-base-image-mpfs-disco-kit.rootfs-20260430114629.wic.bmap
```

URLs de descarga:

- `https://github.com/linux4microchip/meta-mchp/releases/download/linux4microchip-2026.04/mchp-base-image-mpfs-disco-kit.rootfs-20260430114629.wic.gz`
- `https://github.com/linux4microchip/meta-mchp/releases/download/linux4microchip-2026.04/mchp-base-image-mpfs-disco-kit.rootfs-20260430114629.wic.bmap`

## Grabado de la SD

Por disponibilidad de lector de tarjetas, este paso se hizo de forma remota desde una PC con
Windows (no desde el host Linux usado para el resto del bring-up). Herramienta usada:
**balenaEtcher** (`https://etcher.balena.io/`), que acepta el `.wic.gz` directamente sin
necesidad de descomprimirlo a mano y sin depender del `.bmap` (a diferencia de `bmaptool` en
Linux, que sí lo usa para saltar bloques vacíos y escribir más rápido — con una imagen de solo
~104 MiB la diferencia de velocidad es despreciable).

Pasos: **Flash from file** → seleccionar el `.wic.gz` → **Select target** → elegir la SD por su
tamaño/letra (Etcher solo lista discos removibles) → **Flash!** (con verificación automática
posterior).

No se requirió cambiar jumpers de la placa: los valores de fábrica (`J45`/`J46` en 1&2, `J47`
cerrado, `J49` en 1&2 — los mismos usados en la Fase 1) ya son los correctos para bootear Linux
según la guía de usuario del kit; el arranque desde SD lo decide HSS en tiempo de ejecución, no un
jumper de hardware.

## Nueva identificación de interfaces UART (sesión de host reiniciada)

Entre la Fase 1 y esta sesión el host Linux usado para las capturas se reinició, así que el efecto
de `new_id` sobre `ftdi_sio` no persistía: al reconectar la placa, Linux volvió a exponer
automáticamente solo la interfaz 2 (`/dev/ttyUSB0`), igual que en el arranque en frío documentado
en la Fase 1.

### Incidente: `new_id` rompe la detección de FlashPro Express

Al repetir el comando de la Fase 1 para exponer las demás interfaces...

```bash
sudo bash -c 'echo 1514 2008 > /sys/bus/usb-serial/drivers/ftdi_sio/new_id'
```

...FlashPro Express dejó de detectar la placa (aunque seguía apareciendo en `lsusb`). Diagnóstico:

```
$ lsusb -t
    |__ Port 7: Dev 6, If 2, Class=Vendor Specific Class, Driver=ftdi_sio, 480M
    |__ Port 7: Dev 6, If 0, Class=Vendor Specific Class, Driver=ftdi_sio, 480M
    |__ Port 7: Dev 6, If 3, Class=Vendor Specific Class, Driver=ftdi_sio, 480M
    |__ Port 7: Dev 6, If 1, Class=Vendor Specific Class, Driver=ftdi_sio, 480M
```

Las 4 interfaces quedaron reclamadas por `ftdi_sio`, incluida la **interfaz 0** (`1-7:1.0`), que es
la que FlashPro Express necesita abrir en modo MPSSE crudo (vía `libusb`) para hacer JTAG. La
restricción "solo interfaz 2" de la Fase 1 viene de una entrada especial en la tabla de IDs
*incorporada* en el driver (`in02` en el alias de `modinfo ftdi_sio`); al agregar el mismo VID:PID
manualmente por `new_id`, esa restricción no se hereda y el kernel intenta reclamar las 4
interfaces como puertos serie.

**Fix** — liberar únicamente la interfaz 0, dejando las demás (UART) intactas:

```bash
echo -n "1-7:1.0" | sudo tee /sys/bus/usb/drivers/ftdi_sio/unbind
```

Tras esto, `ttyUSB1` (que correspondía a `1-7:1.0`) desaparece —es lo esperado— y FlashPro Express
vuelve a detectar la placa con normalidad. Quedaron expuestas:

| Interfaz USB | Dispositivo Linux | Contenido observado en esta prueba |
|---|---|---|
| `1-7:1.0` | (ninguno, libre para FlashPro/JTAG) | Canal JTAG |
| `1-7:1.1` | `/dev/ttyUSB2` | Consola interactiva de **HSS** (logo ASCII, máquina de estados de boot de los harts) |
| `1-7:1.2` | `/dev/ttyUSB0` | Log de **DDR training, OpenSBI, U-Boot y arranque completo de Linux** |
| `1-7:1.3` | `/dev/ttyUSB3` | Sin actividad observada |

Nótese que el mapeo de contenido por interfaz **no es el mismo** que en la Fase 1 (ahí `ttyUSB0`
llevaba el log de HSS y `ttyUSB1` el mensaje de la app bare-metal) — depende de qué software corre
en cada momento sobre cada MMUART física, no de un mapeo fijo interfaz→función. Conviene siempre
escuchar todas las interfaces disponibles y no asumir la asignación de una prueba anterior.

## Captura

Mismo procedimiento y flags de `stty` documentados en la Fase 1 (115200 8N1, modo raw), lanzando
una captura en background por interfaz antes de hacer el power-cycle de la placa:

```bash
stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb -crtscts raw -echo
cat /dev/ttyUSB0 > uboot_linux.log &

stty -F /dev/ttyUSB2 115200 cs8 -cstopb -parenb -crtscts raw -echo
cat /dev/ttyUSB2 > hss_console.log &
```

## Log de arranque — consola HSS (`/dev/ttyUSB2`)

Se omite el logo ASCII inicial de HSS (arte generado con bloques de color de terminal; al remover
los códigos ANSI queda como espacios en blanco, no aporta información en texto plano).

```
HSS: decompressing from eNVM to L2 Scratch ... Passed
[0.38426] wdog_service monitoring [u54_1] [u54_2] [u54_3] [u54_4]
[0.46065] beu_service :: [init] -> [monitoring]
[0.52271] Initializing Mi-V IHC V2
[0.56949] u54 State Change:  [Idle] [Idle] [Idle] [Idle]
[0.65065] loop 1 took 6532232 ticks (max 6532232 ticks)
[0.72035] Initializing IPI Queues (3304 bytes @ a023f00)...
[0.774126] loop 3 took 417001662 ticks (max 417001662 ticks)
[0.781573] Initializing PMPs
[0.785679] PolarFire(R) SoC Hart Software Services (HSS) - version 0.99.53-v2026.04.1
MPFS HAL version 2.3.110 / DDR Driver version 0.4.035 / Mi-V IHC version 2.0.64 / BOARD=mpfs-disco-kit
(c) Copyright 2017-2025 Microchip FPGA Embedded Systems Solutions.

incorporating OpenSBI - version 1.2
(c) Copyright 2019-2022 Western Digital Corporation.

[0.821006] Build ID: d941062b4a0c9c0adde95d734ac3a3d7a692ecf7
[0.828549] Built with the following tools:
 - riscv-none-elf-gcc (xPack GNU RISC-V Embedded GCC x86_64) 15.2.0
 - GNU ld (xPack GNU RISC-V Embedded GCC x86_64) 2.45

[0.846308] Serial Number:
37e3b2bbd676c748c9de276787a9ac9b00000000000000000000000000000000000000000000000000000000000000000000
[0.860249] Segment Configuration:
        Cached: SEG0_0: offset 0x0080000000, physical DDR 0x00000000
        Cached: SEG0_1: offset 0x1000000000, physical DDR 0x00000000
    Non-cached: SEG1_2: offset 0x00c0000000, physical DDR 0x00000000
    Non-cached: SEG1_3: offset 0x1400000000, physical DDR 0x00000000
Non-cached WCB: SEG1_4: offset 0x00d0000000, physical DDR 0x00000000
Non-cached WCB: SEG1_5: offset 0x1800000000, physical DDR 0x00000000
[0.905220] L2 Cache Configuration:
    L2-Scratchpad:  4 ways (512 KiB)
         L2-Cache:  8 ways (1024 KiB)
           L2-LIM:  4 ways (512 KiB)
[0.921165] DESIGNID: MPFS_DISCOVERY_KIT
[0.926607] DESIGNVER: 26.04
[0.930904] BACKLEVEL: 0000
[0.935105] startup_service :: [init] -> [boot]
[0.941216] ipi_poll_service :: [Init] -> [Monitoring]
[0.947995] startup_service :: [boot] -> [idle]
Press a key to enter CLI, ESC to skip
Timeout in 1 second
..
[4.385934] CLI boot interrupt timeout
[4.390899] loop 303510 took 606534426 ticks (max 606534426 ticks)
[4.398824] Initializing Boot Image ...
[4.403885] Trying to get boot image via MMC ...
[4.409804] Attempting to select SDCARD ... Passed
[4.429482] Preparing to copy from MMC ...
[4.435367] Validated GPT Header ...
[4.482803] Validated GPT Partition Entries ...
[4.489504] Boot Partition found at index 1
[4.495433] Attempting to read image header (1632 bytes) ...
[4.503679] Copying 791904 bytes to 0x103fc00000
[4.543832] MMC: Boot Image registered ...
[4.549249] Boot image set name: "PolarFire-SoC-HSS::U-Boot"
[4.556314] healthmon_service :: [init] -> [monitoring]
[4.563189] boot_service(u54_1) :: [Init] -> [SetupPMP]
[4.570063] boot_service(u54_2) :: [Init] -> [SetupPMP]
[4.576938] boot_service(u54_3) :: [Init] -> [SetupPMP]
[4.583812] boot_service(u54_4) :: [Init] -> [SetupPMP]
>> [4.590973] boot_service(u54_1)::Registering domain "u-boot.bin" (hart mask 0x1e)
[4.600044] boot_service(u54_1) :: [SetupPMP] -> [SetupPMPComplete]
[4.608064] boot_service(u54_2) :: [SetupPMP] -> [SetupPMPComplete]
[4.616085] boot_service(u54_3) :: [SetupPMP] -> [SetupPMPComplete]
[4.624105] boot_service(u54_4) :: [SetupPMP] -> [SetupPMPComplete]
[4.632125] u54 State Change:  [Booting] [Booting] [Booting] [Booting]
[4.641482] boot_service(u54_1) :: [SetupPMPComplete] -> [ZeroInit]
[4.649503] boot_service(u54_2) :: [SetupPMPComplete] -> [ZeroInit]
[4.657523] boot_service(u54_3) :: [SetupPMPComplete] -> [ZeroInit]
[4.665543] boot_service(u54_4) :: [SetupPMPComplete] -> [ZeroInit]
[4.673564] boot_service(u54_1) :: [ZeroInit] -> [Download]
[4.680820] boot_service(u54_2) :: [ZeroInit] -> [Download]
[4.688076] boot_service(u54_3) :: [ZeroInit] -> [Download]
[4.695333] boot_service(u54_4) :: [ZeroInit] -> [Download]
[4.702589] boot_service(u54_1)::Processing boot image: "u-boot.bin"
[4.710419] boot_service(u54_2) :: [Download] -> [Complete]
[4.717675] boot_service(u54_3) :: [Download] -> [Complete]
[4.724932] boot_service(u54_4) :: [Download] -> [Complete]
[4.784529] boot_service(u54_1) :: [Download] -> [OpenSBIInit]
[4.792072] boot_service(u54_1)::Registering domain "u-boot.bin" (hart mask 0x1e)
[4.801142] boot_service(u54_1) :: [OpenSBIInit] -> [Wait]
[4.809631] boot_service(u54_1) :: [Wait] -> [Complete]
[4.864775] u54 State Change:  [SBIHartInit] [Booting] [Booting] [Booting]
[4.909382] boot_service(u54_1) :: [Complete] -> [Idle]
[4.922358] boot_service(u54_2) :: [Complete] -> [Idle]
[4.941793] boot_service(u54_3) :: [Complete] -> [Idle]
[4.959248] boot_service(u54_4) :: [Complete] -> [Idle]
[5.55362] u54 State Change:  [Running] [SBIWaitForColdboot] [SBIWaitForColdboot] [SBIWaitForColdboot]
[22.254027] u54 State Change:  [Running] [Running] [Running] [Running]
```

### Interpretación

- HSS descomprime desde eNVM, arranca sus servicios (watchdog, IPI, health monitor) y detecta la
  tarjeta **SDCARD** correctamente (`Attempting to select SDCARD ... Passed`).
- Lee la tabla de particiones GPT de la SD, encuentra la partición de boot (índice 1) y copia de
  ahí un payload de 791904 bytes llamado `"PolarFire-SoC-HSS::U-Boot"` — es decir, HSS arranca
  **U-Boot** como siguiente etapa (Domain1 en la nomenclatura de OpenSBI, ver log de U-Boot abajo).
- Los 4 harts U54 pasan por la máquina de estados `Init → SetupPMP → ZeroInit → Download →
  OpenSBIInit → ...` hasta terminar en `Running` — U-Boot ya está corriendo en el hart 1 y los
  demás quedan disponibles (`SBIWaitForColdboot`) hasta que el sistema operativo los active.

## Log de arranque — U-Boot y Linux (`/dev/ttyUSB0`)

```
DDR training ...
    0% [..........]   20% [..........]   40% [..........]   60% [..........]   80% [..........]
DDR training ... Passed ( 3176 ms)
[3.261616] DDR-Lo size is   32 MiB
[3.266294] DDR-Hi size is  888 MiB

OpenSBI v1.2
   ____                    _____ ____ _____
  / __ \                  / ____|  _ \_   _|
 | |  | |_ __   ___ _ __ | (___ | |_) || |
 | |  | | '_ \ / _ \ '_ \ \___ \|  _ < | |
 | |__| | |_) |  __/ | | |____) | |_) || |_
  \____/| .__/ \___|_| |_|_____/|____/_____|
        | |
        |_|

Platform Name             : Microchip PolarFire(R) SoC
Platform Features         : medeleg
Platform HART Count       : 5
Platform IPI Device       : aclint-mswi
Platform Timer Device     : aclint-mtimer @ 1000000Hz
Platform Console Device   : mmuart
Platform HSM Device       : mpfs_hsm
Platform PMU Device       : ---
Platform Reboot Device    : mpfs_reset
Platform Shutdown Device  : mpfs_reset
Firmware Base             : 0xa000000
Firmware Size             : 119 KB
Runtime SBI Version       : 2.0

Domain0 Name              : root
Domain0 Boot HART         : 1
Domain0 HARTs             : 1,2,3,4
Domain0 Region00          : 0x0000000002008000-0x000000000200bfff (I)
Domain0 Region01          : 0x0000000002000000-0x0000000002007fff (I)
Domain0 Region02          : 0x000000000a000000-0x000000000a01ffff ()
Domain0 Region03          : 0x0000000000000000-0xffffffffffffffff (R,W,X)
Domain0 Next Address      : 0x0000000080200000
Domain0 Next Arg1         : 0x0000000000000000
Domain0 Next Mode         : S-mode
Domain0 SysReset          : yes

Domain1 Name              : u-boot.bin
Domain1 Boot HART         : 1
Domain1 HARTs             : 1*,2*,3*,4*
Domain1 Region00          : 0x000000000a000000-0x000000000a01ffff ()
Domain1 Region01          : 0x0000000000000000-0xffffffffffffffff (R,W,X)
Domain1 Next Address      : 0x0000000080200000
Domain1 Next Arg1         : 0x0000000000000000
Domain1 Next Mode         : S-mode
Domain1 SysReset          : yes

Boot HART ID              : 1
Boot HART Domain          : u-boot.bin
Boot HART Priv Version    : v1.10
Boot HART Base ISA        : rv64imafdc
Boot HART ISA Extensions  : none
Boot HART PMP Count       : 16
Boot HART PMP Granularity : 4
Boot HART PMP Address Bits: 36
Boot HART MHPM Count      : 2
Boot HART MIDELEG         : 0x0000000000000222
Boot HART MEDELEG         : 0x000000000000b109


U-Boot 2025.07-linux4microchip-2026.04 (Apr 29 2026 - 08:52:30 +0000)

CPU:   sifive,u54-mc
Model: Microchip PolarFire-SoC Discovery Kit
DRAM:  1 GiB (total 1.8 GiB)
Core:  58 devices, 14 uclasses, devicetree: separate
MMC:   mmc@20008000: 0
Loading Environment from FAT... OK
In:    serial@20106000
Out:   serial@20106000
Err:   serial@20106000
Net:   eth0: ethernet@20110000
Hit any key to stop autoboot:  2  1  0
rootpart not set, default to 3
switch to partitions #0, OK
mmc0 is current device
Scanning mmc 0:1...
Found U-Boot script /boot.scr
291 bytes read in 4 ms (70.3 KiB/s)
## Executing script at 8e000000
6179748 bytes read in 146 ms (40.4 MiB/s)
## Loading kernel (any) from FIT Image at 8e000000 ...
   Using 'conf-mpfs-disco-kit.dtb' configuration
   Trying 'kernel-1' kernel subimage
     Description:  Linux kernel
     Type:         Kernel Image
     Compression:  gzip compressed
     Architecture: RISC-V
     OS:           Linux
     Load Address: 0x80200000
     Entry Point:  0x80200000
     Hash algo:    sha256
   Verifying Hash Integrity ... sha256+ OK
## Loading fdt (any) from FIT Image at 8e000000 ...
   Using 'conf-mpfs-disco-kit.dtb' configuration
   Trying 'fdt-mpfs-disco-kit.dtb' fdt subimage
     Description:  Flattened Device Tree blob
     Type:         Flat Device Tree
     Architecture: RISC-V
     Load Address: 0x8a000000
     Hash algo:    sha256
   Verifying Hash Integrity ... sha256+ OK
   Loading fdt from 0x8e5deb34 to 0x8a000000
   Booting using the fdt blob at 0x8a000000
Working FDT set to 8a000000
   Uncompressing Kernel Image to 80200000
   Loading Device Tree to 000000008fff7000, end 000000008ffff8ee ... OK
Working FDT set to 8fff7000

Starting kernel ...

[    0.000000] Booting Linux on hartid 1
[    0.000000] Linux version 6.18.17-linux4microchip-2026.04.1-g7fbe4f69684d (oe-user@oe-host) (riscv64-mchp-linux-gcc (GCC) 13.4.0, GNU ld (GNU Binutils) 2.42.0.20240723) #1 SMP Wed Apr 29 16:43:56 UTC 2026
[    0.000000] Machine model: Microchip PolarFire-SoC Discovery Kit
[    0.000000] SBI specification v2.0 detected
[    0.000000] earlycon: ns16550a0 at MMIO32 0x0000000020106000 (options '115200n8')
[    0.000000] Kernel command line: earlycon root=/dev/mmcblk0p3 rootwait uio_pdrv_genirq.of_id=generic-uio
[    0.026062] Calibrating delay loop (skipped), value calculated using timer frequency.. 2.00 BogoMIPS (lpj=4000)
[    0.035908] smp: Bringing up secondary CPUs ...
[    0.042309] smp: Brought up 1 node, 4 CPUs
[    0.043021] Memory: 553168K/1048576K available (7167K kernel code, 4743K rwdata, 4096K rodata, 2266K init, 312K bss, 492276K reserved, 0K cma-reserved)
[    0.131773] riscv-plic: interrupt-controller@c000000: mapped 186 interrupts with 4 handlers for 9 contexts.
[    0.280334] Serial: 8250/16550 driver, 4 ports, IRQ sharing disabled
[    0.285980] 20100000.serial: ttyS0 at MMIO 0x20100000 (irq = 71, base_baud = 9375000) is a 16550A
[    0.288515] 20106000.serial: ttyS1 at MMIO 0x20106000 (irq = 72, base_baud = 9375000) is a 16550A
[    0.288640] printk: legacy console [ttyS1] enabled
[    1.433499] 40000300.serial: ttyCOREUART5 at MMIO 0x40000300 (irq = 73, base_baud = 3125000) is a mchp_coreuart
[    1.469797] microchip-spi 20108000.spi: Registered SPI controller 0
[    1.477738] microchip-spi 20109000.spi: Registered SPI controller 1
[    1.496248] macb 20110000.ethernet eth0: Cadence GEM rev 0x0107010c at 0x20110000 irq 76 (00:04:a3:b2:e3:37)
[    1.508903] mss-dma-uio 60010000.dma-controller: registered device as dma-controller@60010000
[    1.520025] mpfs_rtc 20124000.rtc: prescaler set to: 999999
[    1.540083] i2c_dev: i2c /dev entries driver
[    1.553287] microchip-corei2c 40000200.i2c: registered CoreI2C bus driver
[    1.562555] mpfs_wdt 20101000.watchdog: timeout 28 sec (nowayout=true)
[    1.569841] sdhci: Secure Digital Host Controller Interface driver
[    1.597322] mpfs-mailbox 37020800.mailbox: Registered MPFS mailbox controller driver
[    1.627477] mmc0: SDHCI controller on 20008000.mmc [20008000.mmc] using ADMA 64-bit
[    1.689135] mmc0: new UHS-I speed DDR50 SDHC card at address 1234
[    1.698086] mmcblk0: mmc0:1234 SA32G 29.3 GiB
[    1.704122] mpfs-rng mpfs-rng: Registered MPFS hwrng
[    1.710770] mpfs-sys-controller syscontroller: Registered MPFS system controller
[    1.718109]  mmcblk0: p1 p2 p3
[    1.724372] mpfs_dma_proxy mpfs-dma-proxy: proxy dma 4 channels initialized
[    1.729535] clk: Disabling unused clocks
[    1.855814] EXT4-fs (mmcblk0p3): INFO: recovery required on readonly filesystem
[    3.472847] EXT4-fs (mmcblk0p3): mounted filesystem 336e3d24-cb30-429f-80af-5195d1dacdb8 ro with ordered data mode. Quota mode: disabled.
[    3.485439] VFS: Mounted root (ext4 filesystem) readonly on device 179:3.
[    3.514592] Run /sbin/init as init process
[    3.955324] systemd[1]: System time before build time, advancing clock.

Welcome to Microchip Distro 1.0!

[  OK  ] Reached target Local File Systems.
[   23.806309] macb 20110000.ethernet end0: renamed from eth0
[   25.014227] u_dma_buf: loading out-of-tree module taints kernel.
[   25.231876] u-dma-buf udmabuf0: assigned reserved memory node buffer@88000000
[   25.411000] u-dma-buf udmabuf-ddr-c0: driver version = 5.4.2
[  OK  ] Started Network Time Synchronization.
[  OK  ] Reached target System Initialization.
[  OK  ] Reached target Login Prompts.
[  OK  ] Reached target Multi-User System.
[   31.134469] macb 20110000.ethernet end0: PHY [20110000.ethernet-ffffffff:0b] driver [Generic PHY] (irq=POLL)
[   31.145113] macb 20110000.ethernet end0: configuring for phy/sgmii link mode
[   31.153987] macb 20110000.ethernet: gem-ptp-timer ptp clock registered.
[  OK  ] Reached target Network.

Microchip Distro 1.0 mpfs-disco-kit ttyS1

mpfs-disco-kit login:
```

*(Se omitieron por brevedad varias líneas de `dmesg` puramente repetitivas —trimming de jerarquía
de IRQ, doble impresión del bloque `Booting Linux on hartid 1` que ocurre por el "replay" normal
del buffer de `printk` cuando el kernel pasa de `earlycon` a la consola definitiva `ttyS1`, y el
progreso porcentual de `fsck` durante el primer boot— sin quitar ningún paso relevante de la
cadena de arranque.)*

### Interpretación

- **U-Boot 2025.07-linux4microchip-2026.04** arranca, detecta la SD (`mmc@20008000: 0`), monta la
  partición FAT de boot, y ejecuta `/boot.scr`, que carga un **FIT image** (kernel + device tree
  empaquetados juntos, con verificación de integridad SHA-256) usando la configuración
  `conf-mpfs-disco-kit.dtb` — confirma que el DT base para esta placa ya viene resuelto en la
  imagen, sin overlays adicionales necesarios en este punto (ver la guía de device tree overlays
  para cuándo sí van a hacer falta).
- El **kernel Linux 6.18.17** arranca sobre 4 harts U54 SMP, monta la partición raíz
  (`/dev/mmcblk0p3`, ext4) desde la misma SD, y llega a `systemd` con `Welcome to Microchip Distro
  1.0!`.
- El controlador Ethernet **`macb`** (Cadence GEM, el IP que en PolarFire SoC implementa el MAC del
  MSS) se registra en `20110000.ethernet` con dirección MAC `00:04:a3:b2:e3:37`, y más adelante en
  el boot se configura automáticamente en **modo SGMII** (`configuring for phy/sgmii link mode`) —
  confirma que el reference-design ya deja el link físico hacia el PHY VSC8221 listo, sin trabajo
  adicional de device tree para esto (insumo directo para la Fase 3).
- El boot termina en el prompt de login (`mpfs-disco-kit login:`), confirmando arranque exitoso de
  punta a punta desde la SD.

## Cómo iniciar sesión y verificar el kernel

Las capturas anteriores usaron `cat /dev/ttyUSBn > archivo`, que solo lee de forma pasiva — no
sirve para escribir (login, comandos). Para una sesión interactiva real se usó **`screen`**, un
multiplexor de terminal: además de su uso habitual (sesiones persistentes que sobreviven a una
desconexión SSH), sabe hablar directamente con un dispositivo serie, poniendo la línea en modo
interactivo raw (se tipea y se ve la respuesta en tiempo real, carácter a carácter, tal cual llega
del otro extremo del enlace). Su "meta key" para comandos internos (salir, desconectar la sesión,
etc.) es `Ctrl-A`, separada de lo que efectivamente se le envía al dispositivo remoto.

```sh
stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb -crtscts raw -echo   # mismo formato 115200 8N1 de siempre
screen /dev/ttyUSB0 115200
```

(Para salir: `Ctrl-A` seguido de `k`, confirmando con `y`.)

Con el prompt `mpfs-disco-kit login:` visible:

1. Escribir `root` y Enter — usuario por defecto de la imagen `mchp-base-image`, sin contraseña
   configurada (si en algún momento la pidiera, la imagen usa `microchip` como default).
2. Ya en el prompt de shell, correr:
   ```sh
   uname -a
   ```
   Esto imprime, en una sola línea: nombre del kernel (`Linux`), hostname (`mpfs-disco-kit`),
   versión completa del kernel (la misma que ya vimos en el log de boot), fecha de build, y
   arquitectura (`riscv64`) — confirma, sin ambigüedad, que la sesión es la de Linux corriendo en
   los harts U54 (no la consola de HSS ni la de U-Boot) y que la versión de kernel es la que
   declaraba la imagen descargada.

### Log capturado

```
mpfs-disco-kit login: root
root@mpfs-disco-kit:~# uname -a
Linux mpfs-disco-kit 6.18.17-linux4microchip-2026.04.1-g7fbe4f69684d #1 SMP Wed Apr 29 16:43:56 UTC 2026 riscv64 GNU/Linux
```

Confirma login exitoso como `root` sin contraseña, y que la shell corre sobre el kernel
`6.18.17-linux4microchip-2026.04.1` en arquitectura `riscv64` — coincide exactamente con la versión
reportada durante el boot (`Linux version 6.18.17-linux4microchip-2026.04.1-...`), cerrando la
verificación de punta a punta de la Fase 2.

## Conclusión

Queda validada la Fase 2 del plan: arranque completo de Linux desde microSD sobre la Discovery Kit
usando la imagen prebuilt oficial de `linux4microchip/meta-mchp`, sin necesidad de compilar Yocto
desde cero. Se documentó además un hallazgo reutilizable: el mapeo interfaz-USB → contenido de
consola **no es estable entre sesiones/diseños** (depende de qué software esté corriendo en cada
MMUART en el momento de la captura, no de un número de interfaz fijo), y que exponer las interfaces
UART adicionales vía `new_id` puede interferir con la detección de FlashPro Express al reclamar
también la interfaz JTAG — con fix de una sola línea (`unbind` selectivo de esa interfaz).

El log de kernel confirma que el MAC Ethernet (`macb`) ya se inicializa y configura en modo SGMII
durante el boot estándar del reference-design, sin overlays de device tree adicionales — punto de
partida directo para la Fase 3 (verificación del link físico y conectividad por el RJ45).
