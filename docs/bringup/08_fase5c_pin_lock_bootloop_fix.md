# Fase 5c (continuación) — El bitstream real: bug de pines sin fijar, boot loop resuelto

**Fecha:** 2026-08-15
**Rama:** `hardware_development`
**Contexto:** con síntesis/P&R limpios y timing cerrado (`docs/bringup/07_...md`), esta fase cubre el
primer intento de programar el diseño (MSS + mpeg2fpga integrado) en la placa real, un boot loop
persistente que tomó una sesión completa de debugging resolver, y el hallazgo del bug real.

## Síntoma en hardware real

Al programar el primer bitstream con timing limpio, la placa nunca llegaba a Linux. Capturando las 4
interfaces UART simultáneamente (mismo método de la Fase 1), se encontró el log de HSS repitiéndose en
loop cada ~0.5s:

```
HSS: decompressing from eNVM to L2 Scratch ... Passed
[0.38ms] wdog_service monitoring [u54_1] [u54_2] [u54_3] [u54_4]
[0.46ms] beu_service :: [init] -> [monitoring]
[0.52ms] Initializing Mi-V IHC V2
<reset y vuelve a arrancar>
```

Nunca llegaba a DDR training, OpenSBI, ni U-Boot. Como control, el `.job` oficial de Microchip
(`polarfire-soc-discovery-kit-reference-design`) programado en la misma placa, mismos cables, booteaba
Linux limpio hasta el prompt de login — descartando placa, alimentación, JTAG y cableado como causa.

## Lo que se descartó, en orden, con evidencia de hardware real

1. **`mpeg2fpga_apb_peripheral` en sí**: se sacó por completo del slot 4 de `FIC_3_PERIPHERALS`
   (instancia borrada, IRQ atada a `1'b0`) vía un script de parche puntual sobre el proyecto ya
   sintetizado (`debug_remove_mpeg2fpga.tcl` — no es parte del flujo normal de build, solo se usó para
   este aislamiento). Reprogramado: **el loop siguió idéntico**.
2. **Mismatch de eNVM/HSS**: nuestro proyecto nunca había tocado el eNVM (solo exportaba componentes
   `FABRIC SNVM`), a diferencia del `.job` oficial que sí incluye una actualización de HSS
   (`bitstream + HSS v2026.04.1` según el release de Microchip). Se agregó el mecanismo `HSS_UPDATE`
   del reference design (descarga `hss-envm-wrapper.mpfs-disco-kit.hex`, `create_eNVM_config`,
   `configure_envm`) para igualar el eNVM al oficial. Reprogramado: **el loop siguió idéntico**.
3. **RTL genuinamente distinto**: se generó una copia local del proyecto Libero del reference design
   (`libero SCRIPT:MPFS_DISCOVERY_KIT_REFERENCE_DESIGN.tcl`, sin argumentos, solo genera — no
   sintetiza) y se comparó byte a byte contra el Verilog generado por nuestro proyecto:
   `MSS_WRAPPER.v` y `FIC_3_ADDRESS_GENERATION.v` resultaron **idénticos** (solo difiere el timestamp
   del comentario de cabecera); `FIC_3_PERIPHERALS.v` y `MPFS_DISCOVERY_KIT.v` (top level) solo
   difieren exactamente en lo esperado por el reemplazo del SPI del 7-segmentos por mpeg2fpga. Esto
   descarta cualquier diferencia estructural en la MSS o el decodificador de direcciones como causa.
4. **Nuestro propio toolchain/proceso de build**: se sintetizó, ruteó y exportó el proyecto del
   reference design **con nuestro propio pipeline** (nunca antes probado — hasta ahora solo se había
   programado el `.job` prearmado de Microchip). Ese bitstream, construido enteramente con nuestras
   herramientas, **booteó Linux limpio hasta el login por SSH**. Esto descarta cualquier problema de
   entorno, versión de herramienta, o proceso de build en general.

Con RTL, timing, eNVM y toolchain descartados uno por uno con evidencia de hardware real, el problema
tenía que estar en algo del *proyecto* `MPEG2FPGA_SOC` que no fuera visible en el Verilog generado.

## La causa real: pines de I/O nunca fijados

Cada build de nuestro proyecto mostraba, sin excepción, el warning:

```
Warning: You are about to 'Generate FPGA Array Data' without all IOs assigned and locked.
```

Se venía tratando como benigno. No lo era. Comparando `MPFS_DISCOVERY_KIT_pinrpt_name.rpt` de nuestro
proyecto contra el del reference design recién construido:

| Señal | Reference design | Nuestro proyecto (antes del fix) |
|---|---|---|
| `REF_CLK_50MHz` | **R18**, fijo, LVCMOS18 | **E12**, sin fijar, LVCMOS18 |
| `MBUS_I2C_SCL` | **D11**, fijo, LVCMOS**33** | **F18**, sin fijar, LVCMOS**18** |

No solo un pin físico distinto — un **estándar eléctrico distinto** (1.8V vs 3.3V) en algunas señales.
**Los 55 pines de la placa** estaban en este estado, autoasignados por Libero a ubicaciones y voltajes
arbitrarios en cada build, incluyendo el reloj de referencia principal del chip.

### Los tres bugs combinados en `organize_tool_files`

`build_mpeg2fpga_soc.tcl` importa los PDC de I/O (`MPFS_DISCOVERY_KIT_BANK_SETTINGS.pdc`,
`..._BOARD_MISC.pdc`, etc.) y los registra para la herramienta `PLACEROUTE` vía
`organize_tool_files`. Tres errores independientes, cada uno enmascarando al anterior, dejaban esa
registración sin efecto:

1. **Orden incorrecto**: `organize_tool_files` para los PDC debe correr **antes** de
   `build_design_hierarchy` — exactamente como lo hace el script del reference design. Un intento de
   mover esa llamada a después de `build_design_hierarchy`/`derive_constraints_sdc` (para que
   reaplicara sobre un proyecto ya existente) produjo, incluso en un proyecto recién creado,
   `"No User PDC file(s) was specified"` y `0/55` pines fijados — sin ningún error visible.
2. **`organize_tool_files` reemplaza, no suma**: había **dos** llamadas separadas para
   `-tool {PLACEROUTE}` — una con los PDC de I/O, otra (agregada en sesiones anteriores) solo con el
   `.sdc` de excepciones CDC del bridge de mpeg2fpga. La segunda llamada **pisaba por completo** la
   lista de archivos de la primera, dejando a PLACEROUTE sin ningún PDC registrado. Se combinaron en
   una sola llamada con todos los archivos juntos.
3. **`MPFS_DISCOVERY_I2C_LOOPBACK.pdc` registrado por error**: el reference design importa este
   archivo incondicionalmente pero **solo lo registra para PLACEROUTE dentro de su variante
   `I2C_LOOPBACK`** (dos de sus cuatro líneas `set_io`, `I2C1_SCL`/`I2C1_SDA`, referencian puertos que
   solo existen cuando esa variante reconfigura la MSS con `I2C_1` en modo `FABRIC`). Copiado
   literalmente a nuestro script sin notar esa condición, causaba errores reales de PDC
   (`PDCPF-01: Port name doesn't exist in the netlist`) apenas se corrigieron los dos bugs anteriores.
   Se sacó por completo — no lo necesitamos.

### Verificación

Con los tres bugs corregidos, reconstruyendo el proyecto desde cero:

```
Info:  I/O Bank and Globals Assigner identified 61 fixed I/O macros, 0 unfixed I/O macros
...
| Locked |  55   | 100.00%    |
```

`REF_CLK_50MHz` en R18/LVCMOS18, `MBUS_I2C_SCL`/`SDA` en D11/D12/LVCMOS33 — coincide exactamente con
el reference design. El warning de "IOs sin asignar/bloquear" desapareció por completo. `VERIFY_TIMING`
confirmó timing limpio (`No Path`). Bitstream generado y programado en la placa: **arrancó completo**,
DDR training → OpenSBI → U-Boot → kernel Linux → systemd → sshd → Ethernet con link up → prompt de
login, con acceso por SSH confirmado.

## Lección general

`organize_tool_files` tiene dos comportamientos no obvios y no documentados explícitamente en la
ayuda de Libero, encontrados ambos por el método de "confirmar contra el archivo consolidado real que
la herramienta consume" (mismo método usado en la Fase 5c anterior para el bug del `.sdc` del bridge):

- El **orden** de la llamada relativo a `build_design_hierarchy` importa — llamarla después no es
  equivalente a llamarla antes, aunque el contenido sea idéntico y no arroje ningún error.
- Múltiples llamadas para la **misma herramienta** no son acumulativas: la última gana, reemplazando
  por completo el conjunto de archivos de las anteriores. Cualquier archivo nuevo que deba
  registrarse para una herramienta ya usada en otra parte del script debe agregarse a esa misma
  llamada, no como una llamada adicional.

Antes de asumir que una constraint "está aplicada" porque `organize_tool_files` no tiró error,
conviene verificar el resultado real (`I/O Bank and Globals Assigner identified N fixed, M unfixed` en
el log de PLACEROUTE, o el pin report generado) — el mismo principio que ya había costado una sesión
completa con el `.sdc` del bridge.

## Conclusión

Fase 5c queda cerrada de verdad: el diseño completo (MSS + mpeg2fpga integrado como esclavo APB3, IRQ
ruteada al PLIC) sintetiza, rutea, cierra timing, y **arranca Linux en hardware real** con acceso por
SSH confirmado. El bitstream nunca había sido válido hasta ahora — el timing limpio de intentos
anteriores era necesario pero no suficiente, ya que los pines físicos nunca estuvieron correctamente
fijados. Próximo paso: Fase 5d, overlay de device tree real con la dirección/IRQ de mpeg2fpga, y
repetición de la prueba de `insmod`/`probe()` de la Fase 4d contra este hardware ya funcional.
