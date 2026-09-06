# Fase 6a — Bridge mpeg2video ↔ AXI4 para la DDR real

**Fecha:** 2026-08-16
**Rama:** `hardware_development`
**Contexto:** con mpeg2fpga ya integrado como periférico APB3 de la MSS (Fase 5b) y funcionando en
hardware real (Fase 5c/5d, acceso a registros e IRQ confirmados), queda el bloqueador real para poder
decodificar algo: la interfaz de memoria de `mpeg2video` (`mem_req_rd_*`/`mem_res_wr_*`) sigue atada a
constantes en `hdl/top.v` y en `mpeg2fpga_apb_peripheral.v` — explícitamente fuera de alcance de la
Fase 5b. Sin memoria real detrás, el framestore, el vbuf y toda la reconstrucción de imagen no tienen
dónde vivir.

## Objetivo

Cerrar esa brecha con un bridge que traduzca la interfaz de memoria propia de `mpeg2video` a AXI4, para
poder colgarlo del puerto AXI4 fabric-initiator de `FIC_0` de la MSS (`FIC_0_AXI4_INITIATOR_USED true`
ya habilitado en el `.cfg` que reutilizamos desde Fase 5b, y sin usar por ninguna de las variantes que
excluye `build_mpeg2fpga_soc.tcl`) — el camino real hasta la DDR4. Primer corte, siguiendo la misma
metodología TDD que las fases anteriores: la Fase 6a se limita al bridge en sí, verificado en Icarus
contra un modelo de esclavo AXI4, sin tocar `top.v` ni Libero todavía (eso es Fase 6b).

## Por qué la interfaz de memoria no es AXI

`mem_req_rd_cmd[1:0]`/`mem_req_rd_addr[21:0]`/`mem_req_rd_dta[63:0]` (ver `mem_codes.v`) es una única
cola combinada de lecturas y escrituras, un pop de una palabra de 64 bits por vez, con las respuestas de
lectura devueltas por una segunda cola de solo datos, en el mismo orden en que se pidieron. La dirección
es de *palabra* de 64 bits (22 bits ⇒ ventana propia de 32 MB), sin ninguna noción de un espacio de
direcciones físico más amplio. `mem_ctl.v` (`bench/iverilog/mem_ctl.v`), el controlador de memoria
ficticio usado en la simulación grande del decoder, es "template para escribir tu propio controlador de
memoria" según su propio comentario — sirvió de referencia de contrato de protocolo: qué se espera que
haga cualquier cosa que juegue el rol de controlador de memoria detrás de ese puerto.

Dato relevante para el diseño del bridge: `framestore_request.v` tiene `REFRESH_EN` fijo en `1'b0`, así
que `CMD_REFRESH` nunca se emite en la práctica — el refresco de la DRAM queda enteramente del lado del
controlador DDR4 de la MSS, el bridge no necesita hacer nada especial con ese comando.

## Diseño: `mem2axi_bridge.v`

Un solo módulo (`trunk/mpeg2fpga/rtl/mpeg2/mem2axi_bridge.v`) que juega el rol de controlador de memoria
de `mpeg2video`, completamente serializado (una sola transacción AXI4 en vuelo, id fijo 0):

1. Popea una entrada de `mem_req_rd` (misma semántica registrada de `fifo_dc`/`xfifo_dc.v`: `rd_en` un
   ciclo, `dout`/`valid` presentados el ciclo siguiente).
2. Traduce la dirección de palabra a dirección de byte dentro de una ventana fija: `axi_addr = DDR_BASE
   + (addr << 3)`, con `DDR_BASE` parametrizable (alineado a 32 MiB, ya que `addr<<3` cubre 25 bits).
3. `CMD_WRITE` → una transacción de escritura AXI4 de un solo beat de 64 bits (`AWLEN=0`, `WSTRB=8'hff`).
   `CMD_READ` → una lectura de un solo beat, cuyo resultado se retiene y se empuja a `mem_res_wr_dta`
   solo cuando `mem_res_wr_almost_full` lo permite (sin descartar el dato ya leído mientras espera).
4. `CMD_NOOP`/`CMD_REFRESH` se descartan sin generar ninguna transacción AXI.

Reutiliza la lección de las Fases 5b/5d sobre relojes: el comentario de cabecera deja explícito que
`clk` debe ser el mismo reloj que maneja `FIC_0_ACLK` (a conectar externamente en Fase 6b), no un
PLL/CCC nuevo — exactamente la clase de bug que causó el problema de Fase 5b (bridge/regfile
desincronizados) y el cuelgue de Fase 5d (`PLL_POWERDOWN_N_0` sin conectar).

## Verificación: TDD contra un esclavo AXI4 de prueba

`bench/mem_axi_bridge/` — mismo patrón que `bench/apb_bridge/` de la Fase 5a: testbench aislado, sin
instanciar `mpeg2video` ni Libero. `fake_axi_ddr.v` es un esclavo AXI4 mínimo con latencia no nula y
distinta por canal (2/3/2/4/3 ciclos para AW/W/B/AR/R) para no dejar pasar un bridge que asuma
silenciosamente un esclavo siempre listo — el camino real `FIC_0`/DDR4 nunca lo va a ser.

**Bug encontrado por el propio test, en el esclavo de prueba, no en el bridge**: la primera versión de
`fake_axi_ddr.v` volvía a su estado `IDLE` en el mismo ciclo en que pulsaba `*READY`, mientras `*VALID`
seguía en alto un ciclo más (el master —el bridge— recién baja `*VALID` al *muestrear* `*READY` en alto,
un ciclo después). Eso hacía que el canal aceptara la misma transacción una segunda vez, fantasma, antes
de que el master llegara a bajar `*VALID`. Se corrigió agregando un estado `*S_DRAIN` en los tres
canales (AW, W, AR) que espera a que `*VALID` efectivamente caiga antes de rearmarse para una
transacción nueva — el mismo patrón que cualquier esclavo AXI4 real está obligado a respetar.

Con eso, las 9 verificaciones pasan:

```
PASS write then read back, addr 0x10: 0xdeadbeef00000001
PASS write then read back, addr 0x123: 0x1111222233334444
PASS addr 0x10 unaffected by write: 0xdeadbeef00000001
PASS back-to-back: read 0x200: 0xaaaaaaaaaaaaaaaa
PASS back-to-back: read 0x201: 0xbbbbbbbbbbbbbbbb
PASS backpressure: held off while mem_res_wr_almost_full
PASS backpressure: delivered later: 0xaaaaaaaaaaaaaaaa
PASS CMD_NOOP: no AXI transaction, no response
PASS read after CMD_NOOP works: 0xbbbbbbbbbbbbbbbb
ALL TESTS PASSED (9 checks)
```

Cubre: escritura+lectura en dos direcciones distintas (para atrapar un bug de latcheo de dirección que
"funciona" para un solo request), que una escritura no pise una dirección anterior, lecturas consecutivas
sin huecos entre pedidos (pipeline de request/response completamente serializado, sin duplicar ni
perder), backpressure de `mem_res_wr_almost_full` (el bridge retiene el dato ya leído de AXI y no lo
empuja hasta que hay lugar, sin corromperlo ni descartarlo), y que `CMD_NOOP` no dispare nada en AXI ni
rompa el siguiente request real.

## Decisión de diseño: serializado, no pipelineado

El bridge sostiene una sola transacción AXI4 en vuelo por vez — deliberado para este primer corte:
correctitud simple y fácil de verificar por sobre throughput. `fifo_size.v` (`MEMTAG_DEPTH`, comentario:
"debe ser más grande... por la latencia del controlador de memoria... que mem_req y mem_resp fifos
juntas") ya anticipa un controlador con múltiples requests en vuelo, así que si la latencia real de
ida y vuelta por `FIC_0`/DDR4 termina limitando el throughput del decoder, pipelinear (múltiples ids AXI
distintos en vuelo) es la palanca siguiente, sin cambiar la interfaz de este módulo hacia `mpeg2video`.

## Conclusión

Queda cerrada la Fase 6a: existe un bridge mpeg2video↔AXI4 verificado en simulación contra un modelo de
esclavo con latencia realista. No está todavía instanciado en `top.v` ni conectado a `FIC_0` en el
diseño Libero — eso es Fase 6b: agregar mpeg2fpga como master adicional del `COREAXI4INTERCONNECT` de
`FIC_0` (o uno propio), conectar `FIC_0_AXI4_INITIATOR_*` en el SmartDesign top, y reutilizar
`FIC_0_ACLK` como reloj del bridge en vez de generar uno nuevo.
