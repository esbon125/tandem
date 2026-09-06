# Fase 7a: la primera palabra que recibe el VLD llega corrupta

Continuación de
[33_fase7a_vld_se_saltea_el_primer_start_code.md](33_fase7a_vld_se_saltea_el_primer_start_code.md).

## La medición

Segunda tanda de instrumentación, esta vez dentro de `getbits.v` (seis palabras
APB, 0x25-0x2a): las dos primeras palabras de 64 bits que el módulo realmente
recibe, la ventana y el `cursor` en el primerísimo `STATE_READY`, y el conteo
total de palabras.

Se construyó para decidir entre dos historias: "se pierde una palabra al
arranque" contra "la ventana arranca desalineada". **Las dos son falsas.**

```
esperado word0 = 000001b32d01e024   (bytes 0-7 del archivo)

PASS  word0 = 000001b32d01e024   OK
FAIL  word0 = 900001f20971e024   idéntico en las 4 corridas que fallan
```

- `words = 1578` en **todas** las corridas: no se pierde ninguna palabra.
- `cursor = 0` y `getbits = 0x000001` en el primer `STATE_READY` de los PASS:
  la ventana arranca correctamente alineada. En los FAIL lee `0x900001`, que es
  simplemente la cabeza de la palabra corrupta.
- Correlación perfecta en el control: `word0` corrupta en exactamente las 4
  corridas que fallan y correcta en las 8 que pasan.

**Los datos que se le entregan al VLD llegan corruptos**, de forma
determinista, aunque esa misma DRAM leída después desde la CPU dé
byte-perfect.

## Qué clase de corrupción

- **No es direccionamiento**: el valor corrupto no aparece en ninguna parte del
  archivo (`find` sobre los 12599 bytes: -1).
- **No es un desplazamiento**: no hay rotación ni shift que relacione el valor
  correcto con el corrupto. Los bits que difieren están dispersos (word0: 20,
  21, 22, 26, 29, 32, 38, 60, 63), y entre word0 y word1 solo comparten 22, 26,
  32, 38 -- o sea no es un conjunto fijo de bits pegados.
- **Es dependiente de los datos** y determinista dado el estado de la sesión.
- **Está confinada al arranque**: las corridas que fallan después recorren
  correctamente los start codes #2 #3 #4 #5 del archivo (`b5`@140, `b2`@150,
  `b5`@225, `b8`@237), así que todo lo que llega desde ~byte 140 está intacto.

## Qué queda descartado, por medición

Con esto la ubicación del bug queda acotada de verdad:

| capa | veredicto |
|---|---|
| lógica de `vld.v` / `getbits.v` | descartada -- recibe datos malos y se comporta consistentemente con ellos |
| alineación de la ventana | descartada -- `cursor=0`, conteo de palabras exacto |
| arbiter, contadores, punteros | descartados (doc 32) |
| DMA y camino de escritura | descartados -- DRAM byte-perfect |
| DRAM y alias de memoria | descartados (doc 31) |
| camino de lectura APB | descartado (doc 32) |
| **camino de RETORNO de lectura del VBUF** | **es acá** |

Lo que queda es `mem2axi_bridge` → `mem_response_fifo` → `framestore_response`
→ `vbuf_read_fifo` → `getbits`, **durante su primera transferencia**.

## El detalle que probablemente importa

`framestore_request.v` **no tiene umbral de llenado**. `vbuf_holdoff` (línea
534) resulta ser solamente un interlock de "no hagas dos accesos vbuf
consecutivos":

```verilog
wire vbuf_holdoff = (state == STATE_VBW) || (state == STATE_VBR) ||
                    (previous == STATE_VBW) || (previous == STATE_VBR);
```

y `do_vbr = ~vbuf_empty && ~vbuf_holdoff && vbr_rd_almost_empty && ...`, con
`vbuf_empty = (vbuf_wr_addr == vbuf_rd_addr)`. O sea **el VLD puede leer apenas
existe UNA palabra**, y `vbuf_wr_addr` se incrementa cuando la escritura se
encola, no cuando aterriza. La primera lectura se emite en el turnaround
write→read más apretado posible.

El orden contra DRAM sí está garantizado (VBW y VBR van por el mismo
`mem_req_fifo` y `mem2axi_bridge` es single-outstanding, espera `BVALID` antes
de emitir la lectura). Así que si hay una ventana marginal, no es de orden sino
de integridad de datos en el retorno.

## Un test que salió mal (y por qué)

Se intentó confirmar el turnaround partiendo el push en dos (un trozo chico,
esperar, y después el resto). **El experimento está confundido y no se puede
interpretar**: `stream_dma.v` le agrega un `sequence_end_code` a *cada* push, así
que partirlo inserta un fin de secuencia en medio del stream -- ya no se está
midiendo `tcela-17`. Se nota en que la correlación se rompe (5/12 palabras
corruptas pero 11/12 aciertos). Descartado, no leer nada de esos números.

Para repetirlo bien haría falta o bien un modo de push sin padding, o bien
retrasar la primera lectura por otro medio.

## Qué medir después

La pregunta ahora es dónde se corrompe dentro de ese camino de retorno. Sondas
candidatas, todas del mismo estilo sticky y baratas:

1. En `framestore_response.v`, capturar la primera palabra que **entra** al
   `vbuf_read_fifo`, para comparar contra la que sale hacia `getbits`. Eso
   parte el camino en dos mitades de una sola vez.
2. En `mem2axi_bridge.v`, capturar la primera `RDATA` recibida del AXI. Si ya
   viene mal de ahí, el problema está en el MSS o en el propio bridge; si viene
   bien, está en el `mem_response_fifo` o aguas abajo.

Con esas dos, el tramo culpable queda aislado en un solo rebuild.

## Sobre la hipótesis de la fase de reloj

El doc 32 descartó la carrera de fase clk↔mem_clk **como mecanismo de reset**,
y ese descarte sigue en pie: los resets de CoreFIFO están correctamente
apareados por dominio. Pero esta medición reabre la misma relación de fase por
otra vía completamente distinta -- la **captura de datos** en el cruce
mem_clk→clk, no la liberación del reset. `mem_response_fifo` es justo el
CoreFIFO dual-clock de ese cruce, y `clk`/`mem_clk` están en 3/2, con dos
posiciones de fase posibles fijadas al soltar el reset. Eso encajaría con
determinista-por-sesión, ~50/50, y corrupción dependiente de los datos.

**No está demostrado** y no debería tratarse como causa hasta que las sondas de
arriba digan en qué tramo se corrompe. Se anota solo para no perder el hilo.

## Cambios

`hardware_development` `6430d33`: `getbits.v` instrumentado (seis palabras),
contador de `STATE_NEXT_START_CODE` en `vld.v`, cableado hasta el bridge, y 6
checks nuevos en `bench/apb_bridge/testbench.v` (57/57) que cubren cada palabra
del part-select indexado -- un off-by-one en esa aritmética es su modo de falla
obvio.

Pipeline completo desde proyecto limpio: síntesis (88 apariciones de los
registros nuevos en el netlist), PLACEROUTE 29.8 min "Router completed
successfully", VERIFY_TIMING "Timing constraints have been met",
GENERATE_PROGRAMMING_DATA, PROGRAM "Chain programming PASSED".
