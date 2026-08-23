# Fase 7a — bug real de multiple-drivers en xfifo_dc.v, y el bloqueo que revela: AXI4 nunca completaba una escritura

**Fecha:** 2026-08-22/23
**Rama:** `hardware_development`

Continuación de `21_fase7c_e2e_push_and_vld_watchdog_stall.md`. Esta sesión encontró
y arregló dos bugs reales, uno confirmado en hardware y otro confirmado en
síntesis pero todavía sin probar en silicio real. Ambos tocan la ruta de memoria
(`framestore_request.v` → `fifo_dc`/CoreFIFO → `mem2axi_bridge.v` → AXI4 → MSS),
no la lógica de parseo de bitstream en sí.

## Bug 1: `xfifo_dc.v` tiene dos drivers en el mismo net (confirmado, arreglado)

Instrumentando `framestore_request.v` y `mem2axi_bridge.v` con registros de debug
(`vbuf_wr_addr`, `dbg_last_mem_req_wr_addr`, `dbg_last_write_addr_from_fifo`,
`dbg_last_write_awaddr_issued`, contadores de arbitraje — direcciones APB
`0x16`-`0x1f` en `apb3_mpeg2fpga_bridge.v`) se llegó a `rtl/mpeg2/xfifo_dc.v`, el
wrapper hand-written (no generado por Libero) que decide entre la FIFO "soft"
vieja (`generic_fifo_dc`, OpenCores) y la CoreFIFO real de Microchip.

El archivo tenía:

```verilog
assign valid     = fifo_valid;      // incondicional
assign underflow = fifo_underflow;  // incondicional
assign wr_ack     = fifo_wr_ack;     // incondicional
assign overflow  = fifo_overflow;   // incondicional
```

pero `fifo_valid`/`fifo_underflow`/`fifo_wr_ack`/`fifo_overflow` sólo se asignan
dentro de un bloque `if (USE_GENERIC==1'b1)` — la rama vieja, no usada en el
diseño real. Con `USE_GENERIC=0` (la rama CoreFIFO, confirmada activa: el
`wrappers.v` que instancia `xfifo_dc` nunca sobreescribe `.USE_GENERIC`), esos
regs quedan en `'bx` para siempre — y esos mismos `assign` compiten en el mismo
net con los pines reales de la CoreFIFO (`.DVLD`, `.UNDERFLOW`, `.WACK`,
`.OVERFLOW`), que **también** están conectados a `valid`/`underflow`/`wr_ack`/
`overflow` en la rama `else` del `generate`. Dos drivers en un mismo wire —
resolución indefinida.

Nunca se detectó en `bench/iverilog` porque esa testbench usa una copia vieja de
`wrappers.v` que ni siquiera pasa por `xfifo_dc.v`/CoreFIFO — usa
`generic_fifo_dc` directamente.

**Fix**: gatear los 8 `assign` con el mismo `generate if (USE_GENERIC==1'b1)`
que ya usan los `always` que los manejan, para que cada net tenga un solo
driver en cualquiera de las dos configuraciones.

### Verificación: reproducir el bug, aplicar el fix, confirmar — en la misma testbench

Se armó `bench/mem_response_corefifo/` (nueva), una testbench que instancia el
control lógico REAL de CoreFIFO (`corefifo_async.v`, `COREFIFO.v`, sync/fwft/
graytobinconv, copiados sin cifrar desde
`soc_build/MPEG2FPGA_SOC/component/work/.../rtl/vlog/core/`, con la celda de
memoria `RAM1K20` reemplazada por un stub de comportamiento equivalente — el
único bloque realmente cifrado/hard-macro), para `fifo_mem_req_dc_88x64` y
`fifo_mem_rsp_dc_64x128`.

- **Sin el fix**: 43/43 checks fallan. Todas las lecturas devuelven el
  centinela de timeout, incluido un test que arma exactamente 16 escrituras +
  16 lecturas — replicando el "se traba después de 16 palabras" observado en
  hardware real.
- **Con el fix**: ese mismo test de 16 lecturas pasa completo (16/16), y el
  segundo FIFO (`fifo_mem_req_dc_88x64`) dice explícitamente "bug does NOT
  reproduce here".

Reproducir → arreglar → reconfirmar, en la misma testbench, mismo seed — no es
una corrección especulativa.

**Aplicado a hardware real** (rebuild + reprogramado): el fix por sí solo NO
resolvió el stall completo — pero eso era esperable, porque revela un problema
más profundo que estaba enmascarado (ver Bug 2).

## Bug 2 (revelado por el fix del Bug 1): `mem2axi_bridge` nunca completaba una escritura AXI4

Con el Bug 1 arreglado, `framestore_request.v` queda trabado para siempre en
`STATE_CLEAR` (el barrido de inicialización de memoria al power-on), porque su
condición de salida (`(mem_clr_addr==VBUF_END) && ~mem_req_wr_almost_full`)
nunca se cumple — `mem_req_wr_almost_full` queda pegado en `1` para siempre.

Bajando un nivel más: `mem2axi_bridge.v` sí recibe un pedido de escritura
limpio desde el FIFO (`dbg_last_write_addr_from_fifo` muestra una dirección
real, no basura), pero **jamás** consigue `m_axi_awready` de vuelta —
0 transacciones AXI completadas en 3+ segundos reales, confirmado con un script
de polling en vivo (`dbg_last_write_awaddr_issued` clavado en `0x00000000`). El
FSM de escritura de `mem2axi_bridge.v` (`S_LATCH`→`S_WRITE`→`S_BRESP`) es
lógica AXI4 estándar, no tocada en esta sesión más allá de agregar los taps de
debug.

**Hipótesis de trabajo, ahora confirmada como la causa real (ver más abajo)**:
esta ruta de escritura AXI4 puede no haber completado NUNCA una transacción
real en toda la historia del proyecto. La evidencia previa de "las escrituras
funcionan" (`vbuf_wr_addr` incrementando hasta ~16 antes de trabarse) sólo
probaba que el contador propio de `framestore_request.v` avanzaba (se
incrementa con cada push al FIFO, `(previous==STATE_VBW) && vbw_rd_valid`), NO
que `mem2axi_bridge` convertía esos pushes en escrituras reales confirmadas por
`AWREADY` — la profundidad de buffer del FIFO por sí sola podía producir
exactamente el síntoma "llega a ~16 y se traba" incluso si `mem2axi_bridge`
estuvo trabado desde la primerísima escritura, siempre. El Bug 1 no causó esto;
lo reveló, al hacer que `mem_req_wr_almost_full` por fin reportara la realidad
(antes, la señal corrupta por el Bug 1 probablemente sintetizaba como una
constante que dejaba a `STATE_CLEAR` "completar" sin importar el backpressure
real).

## La causa real del Bug 2: wiring SmartDesign que evitaba el chequeo de compatibilidad de Libero

`mem2axi_bridge`'s AXI4 master (`m_axi_*`) se conecta hacia
`MSS_WRAPPER_0:FIC_1_AXI4_TARGET` a través de `soc_build/script_support/
components/FIC_3_PERIPHERALS.tcl` y `MPFS_DISCOVERY_KIT.tcl`. Un comentario de
"Fase 6b" (una sesión anterior) admitía: el intento original de declarar
`mem_axi_bif` con `hdl_core_add_bif` como bus interface AXI4 fue rechazado por
Libero como "not compatible" contra cualquier rol probado (`master`/
`mirroredMaster`/`mirroredSlave`), "por razones que no se resolvieron" — y se
sorteó conectando las 37 señales una por una (`sd_connect_pins` por pin), algo
que **sólo verifica anchos de pin, no compatibilidad de protocolo** — el
chequeo real de Libero nunca llegó a validar esta conexión.

### El experimento: reactivar la conexión bif-a-bif real

Se reactivó el `hdl_core_add_bif` de `mem_axi_bif` y se reemplazaron las 37
conexiones señal-por-señal por una conexión real bif-a-bif, en dos saltos:
`MPEG2FPGA_APB_PERIPHERAL_0:mem_axi_bif` → puerto de frontera propio de
`FIC_3_PERIPHERALS` → `MSS_WRAPPER_0:FIC_1_AXI4_TARGET`. Costó 5 iteraciones de
rebuild (headless `SYNTHESIZE`, ~10 min cada una) entender la sintaxis y la
convención de roles correcta:

1. `sd_create_bif_port` no crea los pines subyacentes automáticamente — hay que
   declararlos antes con `sd_create_scalar_port`/`sd_create_bus_port` (error:
   "Port 'MEM_AXI_RREADY' doesn't exist").
2. Rol `mirroredSlave` en el puerto de frontera + rol `master` en `mem_axi_bif`
   → falla la conexión INTERNA (`mem_axi_bif` ↔ frontera).
3. Rol `master` en ambos → la conexión interna pasa, pero falla la conexión
   EXTERNA (frontera ↔ `FIC_1_AXI4_TARGET`, rol `slave`).
4. **La corrección real**: el rol de `mem_axi_bif` mismo (la declaración
   `hdl_core_add_bif`) tiene que ser **`mirroredSlave`**, no `master` — a pesar
   de que `mem2axi_bridge` es un master AXI4 real con direcciones físicas de
   master. La convención de roles de SmartDesign sigue la posición en la
   jerarquía respecto del peer terminal real, no la dirección eléctrica local:
   como `mem_axi_bif` se burbujea hacia arriba por la frontera de
   `FIC_3_PERIPHERALS` antes de llegar al peer real (`FIC_1_AXI4_TARGET`, rol
   `slave`), cada salto necesita rol `mirroredSlave` — exactamente el patrón
   ya probado y funcionando de `FIC_0_PERIPHERALS.tcl`'s `AXI4mslave0` (que
   burbujea el master AXI4 real de `DMA_CONTROLLER` hasta
   `MSS_WRAPPER_0:FIC_0_AXI4_TARGET`).

Con `mirroredSlave` de punta a punta, la síntesis completó **limpia — sin
ningún error "not compatible", sin ningún warning nuevo** en la conexión
`MEM_AXI_*`/`FIC_1_AXI4_TARGET` (a diferencia de la de FIC_0, que sí tiene un
warning de mismatch de ancho de AWID).

## Estado al cierre de la sesión

- **Bug 1 (`xfifo_dc.v`)**: arreglado, confirmado en simulación (reproduce →
  arregla → reconfirma), aplicado a hardware real. Commit
  `2efc5eb` en `hardware_development`.
- **Bug 2 (wiring SmartDesign AXI4)**: arreglado, síntesis headless
  confirmada limpia. Commit `7e97458` en `hardware_development`. **Falta**:
  el ciclo manual PLACEROUTE → VERIFY_TIMING → GENERATE_PROGRAMMING_DATA →
  EXPORT_FPE → PROGRAM (vía GUI de Libero, porque PLACEROUTE headless choca
  con el bug pre-existente y no relacionado SDC0025 — ver
  `13_fase6d_hardware_verification.md` y notas de sesiones previas) y la
  prueba en hardware real para confirmar si `m_axi_awready` por fin llega y
  `STATE_CLEAR` completa.

Si después de este fix `m_axi_awready` sigue sin llegar, el ángulo
SmartDesign/bif está agotado y el próximo sospechoso es configuración/reloj de
`FIC_1` en la MSS (requisitos de frecuencia/fase para `FIC_1_ACLK`, o la
posible necesidad de habilitar/configurar FIC_1 desde HSS/u-boot/Linux) — no
investigado todavía.
