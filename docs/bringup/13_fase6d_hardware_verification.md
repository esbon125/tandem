# Fase 6d — Programación y verificación del bridge DDR en hardware real

**Fecha:** 2026-08-16
**Rama:** `hardware_development`
**Contexto:** con el bitstream de la Fase 6c exportado (timing cerrado, sin violaciones), toca la primera
vez que el diseño con `mem2axi_bridge` cableado hasta `FIC_1_AXI4_TARGET` toca silicio real — el mismo
tipo de checkpoint que separó las Fases 5c (implementación) y 5d (hardware) para el bridge APB.

## Programación

```sh
cd trunk/mpeg2fpga/soc_build
libero SCRIPT:build_mpeg2fpga_soc.tcl SCRIPT_ARGS:PROGRAM
```

Vía JTAG con el FlashPro5 integrado de la Discovery Kit (`E2009O0C3E`):

```
programmer 'E2009O0C3E' : device 'MPFS095T' : Executing action PROGRAM PASSED.
programmer 'E2009O0C3E' : Chain programming PASSED.
```

Los tres digests del bitstream leídos de vuelta del dispositivo coinciden exactamente con los que
`EXPORT_FPE` había calculado en la Fase 6c (`d741bf6a...`/`b0a9e2be...`/`f3a1e24c...`) — programación
confirmada, no solo "comando sin error".

## Verificación: Linux sigue arrancando y SSH funciona

A diferencia de la Fase 5d (que abrió una sesión `screen` sobre UART para diagnosticar un cuelgue), acá
no hizo falta consola serie: la placa ya está en la red local con Ethernet configurado de fases
anteriores, así que la verificación fue directamente `ssh root@192.168.18.5`. El reset que dispara la
reprogramación JTAG no impidió que la MSS volviera a arrancar Linux normalmente
(`mpfs-disco-kit`, kernel `6.18.17-linux4microchip-2026.04.1-g7fbe4f69684d`) — esperable, porque esta
fase no tocó la configuración de la MSS, el HSS ni el eNVM, solo agregó wiring de fabric.

## Prueba real: `insmod` del driver contra el hw programado ahora

Mismo procedimiento que cerró la Fase 5d (overlay de device tree + `insmod`), reutilizando el
`mpeg2fpga.ko` ya compilado (vermagic `6.18.17-linux4microchip-2026.04.1-g7fbe4f69684d`, coincide
exacto con el kernel corriendo) y el overlay `mpeg2fpga.dts` (`compatible = "esbon,mpeg2fpga"`,
`reg = 0x40000400`, IRQ PLIC 138, `target-path = "/fabric-bus@40000000"`) de la Fase 5d:

```sh
dtc -@ -I dts -O dtb -o mpeg2fpga.dtbo mpeg2fpga.dts
mkdir /sys/kernel/config/device-tree/overlays/mpeg2fpga
cp mpeg2fpga.dtbo /sys/kernel/config/device-tree/overlays/mpeg2fpga/dtbo   # status: applied
insmod mpeg2fpga.ko
```

```
mpeg2fpga 40000400.mpeg2fpga: mpeg2fpga hw version 0x000c, irq 100
```

Mismo `hw version 0x000c` que en la Fase 5d — coherente, el register file de la Fase 5b no cambió en
esta fase, solo se le agregó memoria real detrás. IRQ Linux 100, mapeada al PLIC 138, confirmada en
`/proc/interrupts` (`40000400.mpeg2fpga`) y el dispositivo visible en
`/sys/bus/platform/devices/40000400.mpeg2fpga`. `probe()` completó de punta a punta igual que en la
Fase 5d.

**Lo que esto confirma**: el cableado nuevo (mem2axi_bridge, `mem_clk_out` reemplazando a
`CLOCKS_AND_RESETS:FIC_1_CLK` como fuente de `FIC_1_ACLK`, el árbol de reset compartido) no rompió nada
del camino ya probado (regfile vía APB/FIC_3, IRQ). No prueba todavía que el propio `mem2axi_bridge`
mueva bytes correctamente hacia/desde la DDR real — para eso hace falta un stream real llegando a
`stream_data` y un mecanismo de lectura del framestore, que es trabajo de Fase 7 (firmware/aplicación).

## Limpieza

`rmmod mpeg2fpga`, `rmdir` del overlay de configfs (desaplica automáticamente), archivos temporales
borrados de la placa. `dmesg` sin señales de error tras el `rmmod`, `uptime` normal — mismo estado
limpio que se dejó al cerrar la Fase 5d.

## Conclusión

Queda cerrada la Fase 6d: el bitstream de la Fase 6c está programado en la Discovery Kit real, Linux
arranca normalmente, y el driver del regfile sigue funcionando de punta a punta (registro + IRQ) con el
bridge DDR ya presente en el diseño. No se probó movimiento de datos real por `mem2axi_bridge` todavía
— eso queda para cuando el lado firmware (Fase 7) tenga un mecanismo para alimentar `stream_data` y leer
el framestore.
