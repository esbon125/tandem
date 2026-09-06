# Fase 5a — Puente APB3↔regfile de mpeg2fpga, test-first (Icarus Verilog)

**Fecha:** 2026-08-05
**Rama:** `hardware_development`
**Contexto:** primer paso de la Fase 5 (integrar mpeg2fpga como esclavo AXI/APB del MSS). Antes de
tocar Libero/SmartDesign, se diseñó y verificó en simulación el único bloque de RTL genuinamente nuevo
de toda la fase: el adaptador entre el bus APB3 que va a exponer el MSS y la interfaz de registros
propia de `mpeg2video` (`reg_addr`/`reg_wr_en`/`reg_rd_en`/`reg_dta_in`/`reg_dta_out`).

## Objetivo

Misma disciplina aplicada a la Fase 4 con el driver de Linux: verificar la lógica en la capa más barata
posible antes de subir una capa. Acá la "capa barata" es simulación con Icarus Verilog (segundos, sin
Libero, sin FPGA); la capa cara que se evita tocar prematuramente es sintetizar/rutear/programar la
placa con RTL todavía no probado.

## Por qué hace falta un adaptador

La interfaz de registros de `mpeg2video` (`trunk/mpeg2fpga/rtl/mpeg2/mpeg2video.v`, `regfile.v`) no es
un slave APB3 válido: no tiene `PSEL`/`PENABLE`/`PREADY`, y una lectura y una escritura a la misma
`reg_addr` acceden a dos bancos de 16 registros completamente independientes, seleccionados solo por
cuál strobe (`reg_rd_en` o `reg_wr_en`) se pulsa (ver `docs/bringup/04_...md` para el detalle completo
de la spec, tomada de `trunk/mpeg2fpga/doc/mpeg2fpga.txt`).

Además, `mpeg2video` corre en su propio dominio de reloj (`clk`, derivado internamente de `ref_clk` vía
`PF_CCC_C0`), no necesariamente el mismo que el reloj APB del bus fabric del MSS. En vez de tocar el
clocking interno del core (ya verificado, con RTL de terceros), el adaptador absorbe el cruce de
dominio él mismo.

## Diseño: handshake de dos fases (toggle) entre dominios

`trunk/mpeg2fpga/rtl/mpeg2/apb3_mpeg2fpga_bridge.v`. Lado APB3 (dominio `PCLK`): en cuanto entra la
fase de acceso (`PSEL && PENABLE`), latchea `PADDR`/`PWDATA`/`PWRITE` y invierte un bit `req_toggle`.
Lado core (dominio `core_clk`): sincroniza `req_toggle` con dos flip-flops, y al detectar el cambio
pulsa `reg_wr_en` o `reg_rd_en` según corresponda, usando `reg_addr`/`reg_dta_in` leídos directamente
(sin sincronizador propio) de los registros ya latcheados del lado APB — son seguros de leer así porque
se fijan un ciclo antes de que `req_toggle` cambie y se mantienen constantes hasta que este lado
confirma (el lado APB no puede iniciar una transferencia nueva hasta que `PREADY` se afirme); el único
bit que necesita cruzar dominios de forma sincronizada es el toggle en sí. Al terminar, invierte
`ack_toggle`, que el lado APB sincroniza de la misma forma para afirmar `PREADY`. Mismo razonamiento
aplicado en reversa para el dato de lectura (`rdata_hold`).

Es el patrón estándar de handshake de dos fases para cruzar un control de baja frecuencia entre
dominios de reloj no relacionados — apropiado acá porque el acceso a registros es de control/estado,
no una ruta de datos de alto throughput.

## Lo que encontró el proceso test-first

Dos bugs de timing reales, ninguno relacionado con lógica de negocio (el mapeo de registros en sí es
trivial) sino con el detalle fino de cómo se cruzan los dominios de reloj — exactamente el tipo de error
que es carísimo de diagnosticar una vez sintetizado en silicio, y trivial de atrapar en simulación:

1. **`PRDATA` un ciclo atrasado respecto a `PREADY`** (encontrado por inspección, antes de correr el
   testbench): el diseño original actualizaba `PRDATA` de forma registrada, un ciclo después de que
   `PREADY` ya se hubiera afirmado — viola APB3, que exige que ambos sean válidos en el mismo ciclo.
   Fix: `PRDATA` pasa a leerse de forma combinacional desde `rdata_hold` (`assign PRDATA = rdata_hold;`),
   que ya está estable en el dominio core desde antes de que el toggle de ack cruce de vuelta.

2. **Dato de lectura capturado un ciclo antes de tiempo** (encontrado por el testbench, primer run en
   rojo): `regfile.v` samplea `reg_rd_en` como entrada y recién en el *siguiente* flanco de `clk`
   registra `reg_dta_out` — o sea, hacen falta **dos** ciclos de `core_clk` después del pulso de
   `reg_rd_en` antes de que el dato esté listo, no uno. La primera versión del adaptador capturaba un
   ciclo demasiado pronto, y devolvía sistemáticamente el resultado de la *lectura anterior* — un bug
   que solo se manifiesta con una secuencia de transacciones consecutivas, exactamente lo que el test de
   "back-to-back" del testbench ejercita. Fix: se agregó un estado extra a la FSM del lado core
   (`C_READ_WAIT1` → `C_READ_WAIT2` → captura), documentado en el comentario del RTL con la traza
   ciclo-a-ciclo exacta.

Ninguno de los dos hubiera sido visible con un test que solo probara una transacción aislada — el
primero requería mirar la relación *entre* `PRDATA` y `PREADY` en el mismo ciclo, el segundo requería
una secuencia de al menos dos transacciones consecutivas sin tiempo muerto entre ellas.

## Testbench

`trunk/mpeg2fpga/bench/apb_bridge/` (mismo estilo que `bench/iverilog/`: Icarus Verilog, `Makefile` con
lista de fuentes). Instancia **solo el adaptador**, contra `fake_regfile.v` — un doble de prueba que
imita el timing exacto de `regfile.v` (banco de escritura y de lectura independientes, lectura
registrada con un ciclo de latencia) pero con contenido controlado por el test, en vez de instanciar
`mpeg2video` completo. Es la misma idea de inyección de dependencias que los tests KUnit del driver
(`driver/mpeg2fpga/tests/mpeg2fpga_core_test.c`, Fase 4a): reemplazar el hardware/core real por un doble
mínimo y verificar la lógica de interfaz de forma aislada.

`PCLK` (50 MHz) y `core_clk` (108 MHz, el mismo valor que usa `bench/iverilog/testbench.v` para `clk`)
corren a una relación de período deliberadamente no entera, para forzar al cruce de dominio a
manifestar cualquier bug de sincronización — un bug de CDC que solo aparece con una relación de reloj
"conveniente" habría sido un falso negativo.

Un BFM (`apb_transfer`, tarea reutilizable) maneja el protocolo APB3 completo (fases Setup/Access,
polling de `PREADY`) para escrituras y lecturas. Casos cubiertos: escrituras a distintas direcciones
llegan al banco de escritura correcto sin afectar direcciones vecinas; lecturas devuelven el contenido
correcto del banco de lectura (independiente del de escritura); una secuencia de transacciones
consecutivas sin ciclos ociosos entre ellas no pierde ni duplica ninguna.

### Resultado

```
$ cd trunk/mpeg2fpga/bench/apb_bridge && make
PASS write_mem[0]: 0x00007f04
PASS write_mem[5]: 0xdeadbeef
PASS write_mem[11]: 0x12345678
PASS write_mem[1] untouched: 0x00000000
PASS read reg 0 (version): 0x00000001
PASS read reg 1 (status): 0x00000008
PASS read reg 15 (testpoint): 0xcafebabe
PASS to-back: read after write, reg 2: 0x11111111
PASS  write_mem[2] unaffected by read: 0xaaaaaaaa
PASS back-to-back: read reg 3: 0x22222222
ALL TESTS PASSED (10 checks)
```

## Conclusión

Queda validado el único bloque de RTL nuevo de la Fase 5 en simulación, sin haber abierto Libero
todavía. Los dos bugs de timing encontrados y corregidos acá — ambos de cruce de dominio de reloj — son
exactamente la clase de error que, de no atraparse en esta capa, aparecería recién al sintetizar y
programar la placa, con un ciclo de depuración muchísimo más lento (bitstream + JTAG + logs de UART en
vez de una corrida de `make` de segundos). Sigue la Fase 5b: generar la MSS real y los periféricos
fabric vía TCL headless en Libero, conectar este adaptador ya verificado entre el bus APB resultante y
`mpeg2video`, y rutear la IRQ única al PLIC.
