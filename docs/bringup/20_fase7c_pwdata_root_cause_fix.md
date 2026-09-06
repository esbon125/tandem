# Fase 7c — causa raíz de PWDATA encontrada y corregida (PSTRB)

**Fecha:** 2026-08-20
**Rama:** `hardware_development`
**Commit:** `4c12d5f`

Este documento cierra la investigación abierta en `18_fase7c_pwdata_investigation.md`
y `19_fase7c_pwdata_free_running_probe.md`: por qué `apb_wdata_r` en
`apb3_mpeg2fpga_bridge.v` nunca capturaba el valor real escrito por software en
`DMA_ADDR`/`DMA_LEN` (y, originalmente, en `STREAM_PUSH_ADDR`).

## Causa raíz

La conversión AXI-a-APB del hard IP de la MSS (FIC_3) presenta cada escritura
de 32 bits del software como **múltiples beats APB de 1 byte cada uno**, con
ese byte replicado en los 4 carriles de `PWDATA[31:0]`, usando `PSTRB[3:0]`
para marcar cuál de los 4 carriles es el real en cada beat. `apb3_mpeg2fpga_bridge.v`
nunca miró `PSTRB` — sobrescribía `dma_addr_r`/`dma_len_r` por completo en
*cada* beat, así que sólo sobrevivía el último beat (el byte más significativo
del valor original). Esto explica retroactivamente por qué **todos** los
valores probados en sesiones anteriores (`0xAA`, `0x8000`, `12599`, ...)
leían de vuelta exactamente `0x00000000`: todos tenían el byte más
significativo en `0x00` — coincidencia de qué valores se habían probado, no
evidencia de que PWDATA nunca llevara datos.

## Confirmación empírica (antes de tocar el RTL)

Escribiendo valores con el byte alto distinto de cero:

```
DMA_ADDR = 0x81234567 → leído 0x81818181
DMA_LEN  = 0xDEADBEEF → leído 0xdededede
```

El patrón es inconfundible: el byte más significativo del valor escrito
replicado en los 4 carriles. Se probó también con `ctypes.c_uint32` (una
escritura de 32 bits genuinamente atómica, no `struct.pack_into`) — **mismo
resultado exacto** — descartando que fuera un problema del mecanismo de
escritura de Python.

Como control adicional, se hizo un loopback físico UART en el conector
mikroBUS (jumper TXD-RXD, agregado por el usuario) contra `CoreUARTapb`, que
vive en el mismo bus APB FIC_3 y comparte el mismo `PWDATA`: el loopback
funcionó perfectamente. Esto no contradice el hallazgo — escribir 1 byte a
una UART es inherentemente una operación de 1 byte, así que nunca hubiera
mostrado el problema de reensamblado de 32 bits.

## Por qué PSTRB nunca llegó al bridge

`PSTRB[3:0]` sí existe como señal real, expuesta desde el hard IP de la MSS
(`MSS_WRAPPER`'s `FIC_3_APB_M_PSTRB`), pero se pierde en el camino: en
`FIC_3_PERIPHERALS.tcl` sólo estaba conectada a `RECONFIGURATION_INTERFACE_0`
(un IP de Microchip preexistente en el diseño de referencia). El decodificador
que alimenta a nuestro periférico (`FIC_3_ADDRESS_GENERATION` → `APB_ARBITER`
→ `CoreAPB3`) **no tiene ningún puerto PSTRB en absoluto** — es la IP
`Actel:DirectCore:CoreAPB3:4.2.100` de Microchip, sin soporte de byte-strobes.
Por lo tanto, enrutar PSTRB "correctamente" a través de esa cadena de
decodificación no era ni posible.

## La corrección

Como PSTRB es una señal de *broadcast* — el mismo valor le llega a todos los
slaves del bus, independientemente de cuál esté seleccionado, exactamente
igual que PWDATA — la solución no necesita tocar la cadena de decodificación
en absoluto. Se agrega en paralelo, al mismo nivel donde ya se conectaba a
`RECONFIGURATION_INTERFACE_0`:

- `FIC_3_PERIPHERALS.tcl`: una línea nueva de `sd_connect_pins` fanoutea
  `PSTRB` también hacia `MPEG2FPGA_APB_PERIPHERAL_0`.
- `mpeg2fpga_apb_peripheral.v`: nuevo puerto `PSTRB[3:0]`, pasado directo a
  `u_bridge`.
- `apb3_mpeg2fpga_bridge.v`: nuevo puerto `PSTRB[3:0]`, latcheado en
  `apb_pstrb_r` junto con `apb_addr_r`/`apb_wdata_r`/`apb_write_r` (mismo
  always block, misma ventana de estabilidad ya usada por esos otros
  registros). La escritura de `dma_addr_r`/`dma_len_r` pasa de una
  sobrescritura ciega de 32 bits a un merge por byte-lane:

```verilog
if (apb_write_r) begin
  if (apb_pstrb_r[0]) dma_len_r[7:0]   <= apb_wdata_r[7:0];
  if (apb_pstrb_r[1]) dma_len_r[15:8]  <= apb_wdata_r[15:8];
  if (apb_pstrb_r[2]) dma_len_r[23:16] <= apb_wdata_r[23:16];
  if (apb_pstrb_r[3]) dma_len_r[31:24] <= apb_wdata_r[31:24];
end
```

## Testbench

Se agregó una tarea `apb_transfer_pstrb` (variante de `apb_transfer` con
`PSTRB` explícito) y dos checks nuevos en `bench/apb_bridge/testbench.v`:

1. Reproduce el escenario real exacto: 4 beats angostos con `PSTRB` de un bit
   cada uno, reensamblando `DMA_LEN=12599` (`0x3137`) byte por byte —
   incluyendo el último beat con byte replicado `0x00000000`, el mismo que
   siempre se leyó en hardware real.
2. Confirma que un byte-lane con `PSTRB=0` no se toca (no es un "overwrite
   enmascarado" que por casualidad da bien cuando se escriben todos los
   bytes).

Resultado: **27/27 PASS** (25 preexistentes + 2 nuevos), sin regresiones.

## Confirmación en hardware real

Después de reconstruir el pipeline completo (`SYNTHESIZE` → `PLACEROUTE` →
`GENERATEDEBUGDATA` → `VERIFY_TIMING` → `GENERATE_PROGRAMMING_DATA` →
`EXPORT_FPE` → `PROGRAM`, timing limpio, 0 errores relevantes):

```
DMA_ADDR = 0x81234567 → leído 0x81234567   ✓
DMA_LEN  = 0xDEADBEEF → leído 0xdeadbeef   ✓
DMA_LEN  = 12599      → leído 12599        ✓
```

El valor que persiguió esta investigación durante múltiples sesiones ahora
se lee exacto.

## Qué queda abierto

Esta corrección cubre específicamente `DMA_ADDR`/`DMA_LEN` (registros que el
bridge posee directamente, con su valor actual siempre disponible para hacer
el merge). Los registros que pasan por `regfile.v` (direcciones 0-15, IP de
mpeg2fpga upstream, licenciada — ver `rtl/mpeg2/LICENSE-MPEG2`) probablemente
sufren la misma descomposición en beats angostos, pero `regfile.v` no puede
modificarse (no es código propio de este porting). Si algún registro del
register file necesita alguna vez una escritura de múltiples bytes
significativos, haría falta un shadow read-modify-write en el bridge antes
de emitir el pulso `reg_wr_en` — no implementado todavía, y de impacto
probablemente bajo ya que la mayoría de las escrituras a esos registros son
bits de control, no valores de 32 bits completos. `STREAM_PUSH_ADDR` nunca
estuvo afectado, ya que es una operación de 1 byte por diseño.

Una prueba end-to-end completa (push de un elementary stream real vía DMA,
decodificación de video) queda como validación separada de Fase 7c en
general — fuera del alcance de esta investigación puntual sobre PWDATA.

## Commits

- `hardware_development` `4c12d5f`: "Fix DMA_ADDR/DMA_LEN PWDATA corruption:
  honor PSTRB with byte-lane merge"
