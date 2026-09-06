# Fase 5b — Integración de mpeg2fpga en la MSS vía Libero headless

**Fecha:** 2026-08-05/06
**Rama:** `hardware_development`
**Contexto:** con el adaptador APB3↔regfile ya verificado en simulación (Fase 5a,
`docs/bringup/05_mss_apb_bridge_tdd.md`), esta fase integra mpeg2fpga de verdad en el diseño de fabric:
generar la MSS, colgar el periférico del bus APB de `FIC_3`, y rutear su interrupción al PLIC — todo
por script TCL headless (`libero SCRIPT:...`), sin abrir la GUI.

## Objetivo

Producir un diseño Libero completo (MSS + periféricos fabric + mpeg2fpga) que sintetice sin errores,
reutilizando en la mayor medida posible una configuración de MSS ya probada en hardware real.

## Hallazgo clave: cómo se genera la MSS en realidad

Investigando `polarfire-soc-discovery-kit-reference-design` (licencia MIT, clonado localmente — el
mismo diseño programado en la Fase 1) se encontró que la MSS **no** se configura con comandos TCL de
"System Builder" sueltos dentro de Libero: se genera con una herramienta externa,
`Designer/bin64/pfsoc_mss -GENERATE -CONFIGURATION_FILE:<archivo .cfg> -OUTPUT_DIR:<dir>` (invocada vía
`exec`, fuera de la sesión de Libero), a partir de un archivo de configuración de texto clave-valor de
~1200 líneas. El resultado (`.cxz`) se importa con `import_mss_component`.

**Decisión de reutilización**: en vez de armar esa configuración desde cero, se reusa tal cual el
`MPFS_DISCOVERY_KIT_MSS.cfg` del reference-design — es la misma config de MSS que ya está probada
arrancando Linux y Ethernet en las Fases 1-3 (`FIC_3_APB_INITIATOR_USED true` ya habilitado ahí). Esto
evita tener que redescubrir a mano qué combinación de parámetros de MSS/FIC funciona, y además mantiene
compatibilidad con el mismo device tree/kernel ya validado — el nuevo periférico es un agregado, no un
cambio de base.

## Hallazgo: el árbol de decodificadores de dirección no es fácilmente regenerable por TCL

El bus APB de `FIC_3` no cuelga de un `CoreAPB3` genérico suelto: usa un árbol de decodificadores de
dirección **auto-generados por Libero** (`FIC_3_0x4000_0xxx`, con 5 slots fijos `APBmslave0..4`
cubriendo `0x4000_00xx`–`0x4000_04xx`). En el reference-design esos 5 slots ya están completos: I2C,
GPIO, UART-apb, PWM, y el SPI del display de 7 segmentos de la placa. No se encontró la forma de
agregar un sexto slot por TCL puro — parece requerir el editor de memory-map de la GUI.

**Decisión tomada con el usuario** (ver conversación): en vez de pelear con la regeneración del
decodificador, mpeg2fpga **reemplaza** el slot que ocupaba el SPI del 7 segmentos
(`FIC_3_0x4000_04xx`) — no usado por este proyecto. Mismo mecanismo de conexión ya probado, cero
regeneración del árbol de direcciones.

## Cómo se registra RTL propio como periférico Libero

Los periféricos de catálogo (CoreGPIO, CoreI2C, etc.) se generan con `create_and_configure_core`, pero
RTL plano propio (no IP de catálogo) se registra como **HDL+ core**:

```tcl
create_hdl_core -file {hdl/mpeg2fpga_apb_peripheral.v} -module {mpeg2fpga_apb_peripheral} -library {work} -package {}
hdl_core_add_bif -hdl_core_name {mpeg2fpga_apb_peripheral} -bif_definition {APB:AMBA:AMBA2:slave} -bif_name {APB_bif} -signal_map {\
    "PADDR:PADDR" "PENABLE:PENABLE" "PWRITE:PWRITE" "PRDATA:PRDATA" \
    "PWDATA:PWDATA" "PREADY:PREADY" "PSELx:PSEL" }
```

Patrón confirmado en `script_support/components/APB_ARBITER.tcl` del reference-design (un adaptador
AXI/APB propio de Microchip, con exactamente esta técnica). Un detalle no documentado que costó un
intento fallido: el parámetro `-file` de `create_hdl_core` espera la ruta **relativa a la copia ya
importada dentro del proyecto** (`hdl/<archivo>`, tal como queda tras `import_files`), no la ruta
original del archivo fuente (`../../rtl/mpeg2/<archivo>`) — usar la ruta original produce un error
genérico ("Parameter 'file' is missing or has invalid value") que no deja adivinar la causa real.

## Nuevo wrapper: `mpeg2fpga_apb_peripheral.v`

`trunk/mpeg2fpga/rtl/mpeg2/mpeg2fpga_apb_peripheral.v` combina `apb3_mpeg2fpga_bridge` (Fase 5a) +
`mpeg2video` en un solo módulo con un port list limpio: `PCLK`/`PRESETn`/`PSEL`/`PENABLE`/`PWRITE`/
`PADDR`/`PWDATA`/`PRDATA`/`PREADY` (lado APB) + `ref_clk`/`rst_n` + `interrupt`. El resto de la
interfaz de `mpeg2video` (stream input, salida de video, FIFOs de memoria) queda atada a constantes,
igual que hacía `hdl/top.v` — fuera de alcance de esta fase (ver Fase 5, nota de alcance).

**Bug encontrado y corregido antes de compilar en Libero**: la primera versión del wrapper instanciaba
un **segundo** `PF_CCC_C0` para alimentar el `core_clk` del bridge — un PLL físicamente distinto del
que ya usa `mpeg2video` internamente para su propio `clk`, aunque nominalmente la misma frecuencia
(108 MHz). Dos PLLs independientes alimentados por el mismo `ref_clk` no están sincronizados entre sí
(fase arbitraria), lo que habría reintroducido exactamente el problema de cruce de dominio de reloj que
el bridge de la Fase 5a ya resuelve — pero ahora entre el bridge y `regfile.v`, sin ningún
sincronizador. Se corrigió con un cambio mínimo y aditivo en `mpeg2video.v`: un puerto de salida nuevo
`clk_out` que simplemente expone el wire interno `clk` que ya existía (sin tocar `PF_CCC_C0` ni ninguna
lógica existente), para que el wrapper reutilice el reloj real en vez de generar uno nuevo.

## Conexiones a nivel del SmartDesign top (`MPFS_DISCOVERY_KIT`)

- **`ref_clk`**: se reusa el mismo `REF_CLK_50MHz` que ya alimenta `CLOCKS_AND_RESETS` (un mismo neto
  de reloj puede alimentar varios PLL/CCC en paralelo; `PF_CCC_C0` dentro de `mpeg2video` ya estaba
  generado para esa frecuencia de referencia).
- **`interrupt`**: conectado a `MSS_INT_F2M[20:20]`. Encontrado en el camino: los bits 16-58 de
  `MSS_INT_F2M` estaban agrupados en **un solo slice combinado** atado a GND (`[58:16]`), no
  individualmente libres — conectar directo al bit 20 fallaba con "Parameter 'to' is missing or has
  invalid value" porque el slice ya existía con otro rango. Se resolvió partiendo ese slice en tres
  (`[19:16]` a GND, `[20:20]` a mpeg2fpga, `[58:21]` a GND), replicando el mismo patrón que ya usaban
  los bits 0/1/3/5 (cada uno con su propio slice individual).

## Build reproducible

Todo versionado en `trunk/mpeg2fpga/soc_build/` — adaptación recortada del script de build del
reference-design (`build_mpeg2fpga_soc.tcl`, solo el camino de proyecto default, sin las variantes
I2C_LOOPBACK/VECTORBLOX/SMARTHLS/MIV_RV32/FIR_DEMO/AXI4_STREAM_DEMO que trae el original) más la copia
modificada de `script_support/`. Se ejecuta con:

```sh
cd trunk/mpeg2fpga/soc_build
~/microchip/Libero_SoC_2025.2/Libero_SoC/Designer/bin64/libero SCRIPT:build_mpeg2fpga_soc.tcl
```

### Resultado

Build completo sin errores en el cuarto intento (los tres anteriores fallaron por, en orden: falta de
`source functions.tcl` para la función helper `safe_source`; ruta incorrecta en `create_hdl_core -file`;
slice de `MSS_INT_F2M` ya ocupado por el rango combinado — los tres corregidos arriba):

```
Reading file '.../MPEG2FPGA_SOC/hdl/mpeg2fpga_apb_peripheral.v'.
Reading file '.../MPEG2FPGA_SOC/hdl/mpeg2video.v'.
...
Info: 'FIC_3_PERIPHERALS' was successfully generated.
Info: 'MSS_WRAPPER' was successfully generated.
Info: /home/esbon/.../MPFS_DISCOVERY_KIT_derived_constraints.sdc was successfully generated.
TCL_END: build_mpeg2fpga_soc.tcl
The Execute Script command succeeded.
```

Los únicos `Warning` del log son preexistentes del reference-design (mismatch de ancho de datos en
periféricos de 8 bits como I2C/UART colgados de un bus de 32, pines flotantes de la MSS no usados) —
ninguno relacionado con mpeg2fpga.

### Verificación del Verilog generado

En `FIC_3_PERIPHERALS.v`:

```verilog
mpeg2fpga_apb_peripheral MPEG2FPGA_APB_PERIPHERAL_0(
        .PCLK      ( PCLK ),
        .PRESETn   ( PRESETN ),
        .PSEL      ( FIC_3_ADDRESS_GENERATION_1_FIC_3_0x4000_04xx_PSELx ),
        .PADDR     ( FIC_3_ADDRESS_GENERATION_1_FIC_3_0x4000_00xx_PADDR_4 ),
        .ref_clk   ( REF_CLK_MPEG2FPGA ),
        .rst_n     ( PRESETN ),
        .PRDATA    ( FIC_3_ADDRESS_GENERATION_1_FIC_3_0x4000_04xx_PRDATA ),
        .PREADY    ( FIC_3_ADDRESS_GENERATION_1_FIC_3_0x4000_04xx_PREADY ),
        .interrupt ( MPEG2FPGA_INTERRUPT_net_0 )
        );
```

`PSEL`/`PREADY`/`PRDATA` son correctamente específicos del slot `0x4000_04xx` (el único slave
seleccionado en esa dirección); `PADDR`/`PWDATA`/`PENABLE`/`PWRITE` son el bus compartido que Libero
etiqueta con el nombre de un slot cualquiera (en este caso `_00xx`) — comportamiento normal de un
decodificador APB, no un error (todos los slaves reciben el mismo bus, solo `PSEL` decide quién
responde).

En `MPFS_DISCOVERY_KIT.v`, la concatenación de `MSS_INT_F2M`:

```verilog
assign MSS_INT_F2M_net_0 = { ..., 38'h0 /* [58:21] */, FIC_3_PERIPHERALS_0_MPEG2FPGA_INTERRUPT /* [20] */, 4'h0 /* [19:16] */, ... };
```

confirma que la interrupción cae exactamente en el bit 20, flanqueada por los tramos a GND, tal como se
diseñó.

## Conclusión

Queda cerrada la Fase 5b: mpeg2fpga está integrado como esclavo APB3 real dentro del diseño de la MSS,
reutilizando la configuración de MSS ya probada en hardware (Fases 1-3), con la interfaz de registros
pasando por el adaptador ya verificado en simulación (Fase 5a) y la IRQ ruteada al PLIC. El build
completo (MSS + fabric + mpeg2fpga) genera sin errores. Quedan, como próximos pasos ya delimitados en
el plan: Fase 5c (síntesis, place & route, generación de bitstream, reprogramar la placa — la primera
vez que este diseño toca silicio real) y Fase 5d (overlay de device tree real con la dirección/IRQ que
resulten, y repetición de la prueba de `insmod`/`probe()` de la Fase 4d contra hardware real).
