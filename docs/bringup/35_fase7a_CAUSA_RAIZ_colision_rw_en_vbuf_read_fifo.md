# Fase 7a CAUSA RAÍZ: colisión read/write en `vbuf_read_fifo`

Continuación de
[34_fase7a_la_primera_palabra_llega_corrupta.md](34_fase7a_la_primera_palabra_llega_corrupta.md),
que dejó la corrupción acotada al camino de retorno de lectura del VBUF pero
sin poder decir en cuál de sus cuatro etapas.

## La medición

Tres sondas nuevas parten el camino en segmentos. 10 corridas, sin ambigüedad:

| etapa | resultado |
|---|---|
| `dbg_first_rdata` — primera palabra del canal de lectura AXI | correcta 10/10 |
| `dbg_first_mem_res` — salida de `mem_response_fifo` (tras el cruce mem_clk→clk) | correcta 10/10 |
| `dbg_first_vbr_wr` — entrada a `vbuf_read_fifo` | **correcta 10/10** |
| `dbg_word0` en `getbits` — salida de ese mismo FIFO | correcta en cada PASS, **corrupta en cada FAIL** |

La palabra entra intacta al `vbuf_read_fifo` y sale mal. **La corrupción ocurre
adentro de ese FIFO**, el último eslabón de la cadena.

## La causa

`fifo_sc` con `FIFO_XILINX=0` usa `xfifo_sc.v`, un FIFO "blando" escrito a mano.
Su RAM:

```verilog
  always @(posedge clk)
    if (~rst) dout <= 0;
    else if (~empty) dout <= ram[rd_addr[addr_width-1:0]];
    else dout <= dout;

  always @(posedge clk)
    if (wr_en && ~full) ram[wr_addr[addr_width-1:0]] <= din;
```

No hay nada que proteja el caso en que la dirección de lectura y la de
escritura coinciden en el mismo ciclo. Y eso no es un caso raro acá: pasa
justamente cuando el FIFO está vacío y se lo está escribiendo -- que es su
condición normal de trabajo, porque el VLD consume tan rápido como el
subsistema de memoria entrega, así que `rd_addr` va pegado a `wr_addr`.

En Verilog conductual una lectura a la misma dirección tiene semántica definida
(devuelve el valor viejo). **En una LSRAM real de PolarFire no.**

## La síntesis lo venía avisando

```
@W: FX107 :"…/hdl/xfifo_sc.v":154 | RAM vbuf_read_fifo.genblk1\.xfifo_sc.ram[63:0]
(in view: work.mpeg2video(verilog)) does not have a read/write conflict check.
Possible simulation mismatch. To resolve a read/write conflict, either set
syn_ramstyle = rw_check, or enable the "Read Write Check on RAM" Implementation
Option.
```

Es **exactamente la RAM que la medición señaló**, nombrada por la herramienta,
en el log de todas las síntesis de este proyecto. Y "possible simulation
mismatch" explica de una por qué `bench/iverilog` nunca reprodujo nada de esto,
por más streams que se le tiraran.

Contraste en el mismo log: las matrices de cuantización (`wrappers.v:77`) **sí**
llevan propiedades `block_ram`/`no_rw_check`. A esta RAM se le pasó.

## Por qué encaja con todo lo observado

- **~50/50 y pegado a la sesión del core**: el resultado de una colisión no
  está definido; qué sale depende de las condiciones exactas del primer ciclo
  de escritura, que quedan fijadas al soltar el reset.
- **Determinista dentro de una sesión** (`900001f20971e024` siempre igual): una
  vez fijadas esas condiciones, la colisión resuelve siempre igual.
- **Dependiente de los datos, sin rotación ni shift**: es una mezcla eléctrica
  de dato viejo y nuevo, no un desplazamiento lógico.
- **Confinada al arranque**: la primera palabra es la que se escribe con el
  FIFO vacío y `rd_addr == wr_addr == 0`.
- **DRAM siempre byte-perfect**: la escritura nunca estuvo mal; el dato se
  ensucia recién al salir del FIFO.
- **La simulación siempre anduvo**: lo dice el propio warning.
- **`SIZE=0` como síntoma final**: la palabra corrupta contiene el
  `sequence_header_code` del byte 0, así que el VLD no lo encuentra, se saltea
  al `b5` siguiente y nunca carga `horizontal_size`.

## El fix, todavía no aplicado

Dos caminos, y conviene elegir a conciencia:

1. **Bypass en RTL** (neutral respecto del fabricante): detectar la colisión y
   reenviar `din` directamente a `dout` en vez del valor de la RAM. No depende
   de opciones de la herramienta, que es lo correcto para un port que ya sufrió
   varias trampas de tooling. Diff algo mayor sobre IP de terceros.
2. **`syn_ramstyle = "rw_check"`** sobre esa RAM (o la opción global "Read Write
   Check on RAM"): diff mínimo, la herramienta inserta la lógica de bypass. Deja
   la corrección dependiendo de una propiedad de síntesis.

Ojo con el alcance: `xfifo_sc.v` es el FIFO de **todas** las instancias
`fifo_sc` del diseño, no solo `vbuf_read_fifo`. El mismo peligro existe en
cualquier otra que trabaje cerca de vacío. Arreglarlo en `xfifo_sc.v` las cubre
a todas de una.

Cualquiera de los dos cuesta un rebuild completo (~45 min).

## Cambios

`hardware_development` `eea784a`: tres sondas (`mem2axi_bridge.v`,
`framestore.v`), cableado hasta el bridge con sincronizador de 2 flops para la
del dominio `mem_clk`, seis registros APB nuevos (0x2b-0x30), y 6 checks en
`bench/apb_bridge/testbench.v` (63/63).

Pipeline completo desde proyecto limpio: síntesis (811 apariciones de las
sondas en el netlist), PLACEROUTE 29.9 min "Router completed successfully",
VERIFY_TIMING "Timing constraints have been met", PROGRAM "Chain programming
PASSED".

## Nota operativa

`libero SCRIPT:… PLACEROUTE` tarda ~30 min y la herramienta Bash corta a 10.
Hay que lanzarlo en background sí o sí: correrlo en primer plano lo **mata a
mitad del ruteo** (pasó en esta sesión, se perdió una corrida entera). El log
además está buffereado, así que no avanza de a poco; conviene esperar por
"Router completed successfully" y no por el tamaño del archivo.
