# Fase 7a: qué cambia exactamente cuando NO decodifica

Continuación de
[31_fase7a_udmabuf_alias_y_l2_memory_side.md](31_fase7a_udmabuf_alias_y_l2_memory_side.md).
Ese doc dejó el decoder andando "a veces sí, a veces no". Esto caracteriza la
diferencia, campo por campo, en vez de suponerla.

## Método

12 corridas idénticas de `tcela-17.bits`, cada una con reset limpio del core,
capturando el estado observable completo: arbiter, punteros del VBUF,
contadores libres, `STATUS` (leído una sola vez al final, porque sus bits son
sticky-hasta-leer y leerlo además pulsa `watchdog_status_rd`), y el stream
entero comparado contra DRAM.

Resultado: 8 PASS / 4 FAIL.

## Lo que NO cambia

Todo el lado de memoria y transporte es **idéntico** entre PASS y FAIL:

| campo | PASS | FAIL |
|---|---|---|
| VBUF vs archivo | 12592/12592 | **12592/12592** |
| `dma_bytes_done` | 12631 | 12631 |
| tiempo de DMA | 0.29–0.30 ms | 0.28–0.30 ms |
| arbiter antes / después | IDLE / IDLE | IDLE / IDLE |
| `vbuf_rd` | `0x1c0000`→`0x1c062a` | `0x1c0000`→`0x1c062a` |
| `vbuf_wr` | `0x1c0000`→`0x1c062a` | igual |
| `mem_res_valid` delta | 1578 | 1578 |
| `vbr_service` delta | 1578 | 1578 |
| `vbr_starved` delta | 0 | 0 |
| `FRAME_0_Y` | `8080…` | `8080…` |
| **bit `error`** | **0** | **0** |
| **`watchdog`** | **0** | **0** |

O sea: el VLD consume exactamente las mismas 1578 palabras, byte por byte
idénticas, sin reportar error ni disparar el watchdog. **No aparece ningún bit
de error y no cambia nada en memoria.** La diferencia está enteramente dentro
del parseo.

## Lo que SÍ cambia

Sólo dos registros, y ambos salen del mismo lugar del bitstream:

| | PASS | FAIL |
|---|---|---|
| `SIZE` | 720 x 480 | **0 x 0** |
| `FRAME_RATE` | `0x2004` (4:3, 29.97 fps — correcto) | `0x0` o `0x800` |
| `SIZE` visible a | ~0.4 ms (el primer poll) | nunca (1 s de polling) |
| `picture_hdr` | 0 o 1 | **1 en las 4** |

Dos cosas importantes ahí:

- **`picture_hdr=1` en todos los FAIL.** El VLD sí encuentra start codes de
  picture. No está colgado ni perdido: está corriendo y parseando. Lo único que
  no logra es dejar asentado el sequence header.
- Es binario y temprano: o `SIZE` está en el primer poll a 0.4 ms, o no aparece
  nunca.

### Con un stream más largo, el fallo es basura, no cero

`sony-ct1.bits` (690 KB, muchos sequence headers), 12 corridas — 8 correctas:

```
trial 0: SIZE=  352x224   FRAME_RATE=0x2005     <- correcto, coincide con su header
trial 2: SIZE= 7264x8416  FRAME_RATE=0x8025     <- basura
trial 7: SIZE=  352x8416  FRAME_RATE=0x2005     <- horizontal bien, vertical basura
trial 9: SIZE=  352x8416  FRAME_RATE=0x2005
trial10: SIZE= 7264x8416  FRAME_RATE=0x8025
```

Detalle que vale la pena mirar: `8416 = 0x20E0` y el valor correcto es
`224 = 0x00E0` — la diferencia es el **bit 13**. Y `SIZE` está armado como
`{2'b0, horizontal_size[13:0], 2'b0, vertical_size[13:0]}`, donde los bits
`[13:12]` de cada campo **no vienen del sequence header sino del
`sequence_extension`** (`horizontal_size_extension`/`vertical_size_extension`).
Lo mismo con `FRAME_RATE`: `0x8025` tiene `aspect_ratio=8` (inválido, los
válidos son 1–4) y los campos `frame_rate_extension_n/d` también salen del
`sequence_extension`.

Así que en el stream largo el parser no falla en cualquier lado: falla
concentradamente en los campos que vienen de la extensión que sigue
inmediatamente al sequence header.

(Nota aparte: `sony-ct1` levanta `error=1` **también en las corridas que
aciertan**, así que en ese stream el bit de error no discrimina nada.)

## Cuándo se decide

**Al soltar el reset del core, no en el push.** Cuatro pushes seguidos dentro de
una misma sesión del core dan casi siempre el mismo resultado:

```
run0: 720x480 -> 720x480 -> 720x480 -> 720x480
run1: 0x0     -> 0x0     -> 720x480 -> 720x480
run3: 0x0     -> 0x0     -> 0x0     -> 0x0
run4: 720x480 -> 720x480 -> 720x480 -> 720x480
```

Es una moneda al aire por `CORE_ENABLE`, ~50/50, pegada a la sesión.

## Hipótesis probadas y descartadas

Vale la pena dejarlas anotadas para no volver a recorrerlas:

1. **"Es una lectura prematura del registro"** — NO. Se polleó `SIZE` durante
   10 s: en un FAIL nunca aparece; en un PASS ya está a 0.4 ms y se queda.

2. **"Hay que darle más tiempo de settle tras soltar el reset"** — NO. Con
   n=16: 7/16 a 0.2 s, 9/16 a 1 s, 10/16 a 2 s, 7/16 a 4 s. Plano. (Una tanda
   previa con n=8 había dado 7/8 a 2 s y parecía una pista; era ruido de
   muestra chica.)

3. **"Se come el arranque del stream"** — NO. Era la hipótesis más prometedora
   (encajaba con `picture_hdr=1` + `SIZE=0`: perdés el sequence header, que
   está en el byte 0, y resincronizás en el próximo start code). Se probó
   anteponiendo stuffing de ceros, que MPEG-2 permite: 8, 16, 64, 256 y 1024
   bytes, más una variante con el header duplicado adelante. Todas dieron
   ~50%, igual que sin padding. Refutada.

4. **`getbits.v` ignora `clk_en` en su registro `state`** (línea 84-87: es el
   único registro del módulo cuyo `else` hace `state <= next` en vez de
   `state <= state`) — es raro, pero **inocuo**: `mpeg2video.v:819` instancia
   `getbits_fifo` con `.clk_en(1'b1)`, así que esa rama nunca corre.

5. **Reordenamiento AXI entre escritura y lectura** (AXI no garantiza orden
   entre canales, y el VLD lee el VBUF que el propio decoder acaba de
   escribir) — NO aplica: `mem2axi_bridge.v` es estrictamente
   single-outstanding y serializa todo (`S_IDLE → S_LATCH → S_WRITE → S_BRESP
   → S_IDLE`), no emite una lectura hasta haber recibido `BVALID` de la
   escritura anterior.

## Hipótesis viva (NO demostrada)

Una carrera de fase en la liberación del reset.

Los tres relojes salen del **mismo PLL** de `PF_CCC_C0` (`PLL_0`, ref 50 MHz):
`GL0_0`=162 MHz (`mem_clk`), `GL1_0`=108 MHz (`clk`), `GL2_0`=27 MHz
(`dot_clk`). Misma VCO, así que la relación de fase entre ellos es fija y
determinista.

Pero 162/108 = **3/2** no es entero, así que los flancos de `clk` no caen
siempre en el mismo lugar respecto de la grilla de `mem_clk`: alternan entre
dos posiciones, y el patrón se repite cada 18.52 ns (2 ciclos de `clk` = 3 de
`mem_clk`):

```
t (ns)      0      6.17   9.26   12.35  18.52
mem_clk     ^      ^             ^      ^        (T = 6.17 ns)
clk         ^             ^             ^        (T = 9.26 ns)
            |             |             |
         offset 0    offset +3.09    offset 0
          (slot A)     (slot B)      (slot A)
```

En general, si `f_mem/f_clk = p/q` irreducible, hay **q** posiciones posibles.
Acá q = 2.

`core_enable_r` es un registro del dominio `clk`, y la escritura APB que lo
setea aterriza en un flanco de `clk` cuyo slot depende del timing del CPU y
del bus -- asíncronos respecto del fabric. O sea: slot A o slot B, ~50/50, sin
control. Ese registro forma `gated_rst_n`, el `async_rst` de `reset.v`, cuyo
`mem_sreset_1` lo muestrea con `mem_clk`: según el slot, el dominio `mem_clk`
sale del reset un ciclo antes o un ciclo después respecto del dominio `clk`.

Dos slots equiprobables predicen el ~50/50 medido, y una carrera de reset
explica que quede pegada a la sesión y que no dependa ni del stream ni del
timing del push.

Detalle que refuerza la sospecha: `dot_clk` es 27 MHz, y 108/27 = 4 y
162/27 = 6, **enteros**. El único par con relación fraccionaria en todo el
diseño es `clk`<->`mem_clk`, que es exactamente el cruce que atraviesan los
FIFOs del vbuf.

### Dónde la hipótesis se pone floja

1. `reset.v` está diseñado precisamente para tolerar esto: sincroniza por
   dominio y `clk_rst`/`mem_rst` esperan a que ambos liberen. Para que se
   sostenga, algo tiene que ser sensible a un skew de un ciclo *a pesar* de
   eso. Candidatos: los CoreFIFO dual-clock, capa donde este diseño ya tuvo
   dos bugs reales ([24](24_fase7a_fwft_fix_and_axi4_interconnect_wedge.md),
   [25](25_fase7a_cdc_fix_and_corefifo_re_bug.md)).
2. La pegajosidad no es perfecta: una carrera de fase pura debería dar 4/4
   iguales siempre, y `run1` se dio vuelta al tercer push.
3. Nunca se observó el skew. Es una coincidencia cuantitativa, no una medición.

### Predicción falsable

Hacer `mem_clk` **múltiplo entero** de `clk` (por ejemplo 108/216, u 81/162).
Con ratio entero q = 1: una sola posición de fase, y la ambigüedad desaparece.
Si la hipótesis es cierta, el 50/50 debería colapsar a determinista.

Ojo con cómo se lee el resultado: lo informativo es que **desaparezca la moneda
al aire**, no que pase a andar. "Siempre falla" confirma la hipótesis igual que
"siempre anda". Cuesta un rebuild del CCC.

(Una versión anterior de este doc proponía pasar a 4:1 esperando ~25%/75%. Está
mal: 4:1 es entero, o sea q = 1 y un solo slot. El número de slots es el
denominador de `f_mem/f_clk` reducido, no el numerador.)

## Hipótesis 6, probada y descartada: los registros read-to-clear

Los registros de `STATUS` del regfile propio de mpeg2fpga son read-to-clear
(`regfile.v`: `picture_hdr`, `frame_end`, `video_ch`, `error`, `osd_*` e
`interrupt`, todos borrados con `reg_rd_en && reg_addr == REG_RD_STATUS`), y
nuestro polling los venía martillando. Valía preguntarse si la propia
instrumentación era parte del problema. **No lo es**, por dos vías
independientes.

**Por RTL**: `SIZE` no es read-to-clear. `regfile.v:184` es un mux puro:

```verilog
REG_RD_SIZE: reg_dta_out <= {2'b0, horizontal_size, 2'b0, vertical_size};
```

y esos valores vienen de instancias de `loadreg` en `vld.v`, que solo cargan
cuando el FSM está en su estado (`horizontal_size[11:0]` en
`STATE_SEQUENCE_HEADER`, `[13:12]` en `STATE_SEQUENCE_EXT` -- lo que explica
que la basura de `sony-ct1` esté justo en el bit 13) y **solo se borran con
`rst`**. Ninguna lectura las toca.

Vale la pena anotar además qué direcciones llegan siquiera al regfile:
`apb3_mpeg2fpga_bridge.v` hace `assign reg_addr = apb_addr_r[3:0]` pero solo
pulsa `reg_rd_en` en la rama de fallback, o sea para 0x00-0x0f. Todo lo de
0x10-0x20 (`DMA_STATUS`, `ARBITER_FLAGS`, `VBUF_*`, ...) lo decodifica el
bridge y nunca toca el regfile. Así que pollear `DMA_STATUS` es inocuo; leer
`STATUS`/`SIZE`/`FRAME_RATE` no.

**Por experimento**, comparando dos patrones de acceso extremos, n=60 cada uno:

```
QUIET (0 lecturas al regfile): 30/60 pass
NOISY (STATUS martillado)    : 30/60 pass   (~19.400 lecturas/corrida)
```

Idéntico. (Una primera tanda con n=20 dio 14/20 vs 10/20 y parecía un efecto
real; z≈1.3, p≈0.2 -- era ruido, igual que el 7/8 del settle. Tercera vez en
esta investigación que n=8..20 fabrica una pista falsa: **para cualquier cosa
medida contra este 50/50 hace falta n>=60**.)

Corolario útil: todas las mediciones anteriores de esta investigación siguen
siendo válidas, porque la instrumentación no perturba el resultado.

## Auditoría del reset de CoreFIFO: la hipótesis anterior NO sobrevive

Antes de gastar el rebuild del CCC se leyó el RTL de CoreFIFO para ver si ya
estaba protegido contra esto. **Lo está**, y el mecanismo que la hipótesis
proponía queda descartado.

### Cómo se resetea CoreFIFO

Los FIFOs se generan con `SYNC_RESET:1`, y en `COREFIFO.v` eso reduce a:

```verilog
assign aresetn_wclk = (SYNC_RESET == 1) ? 1'b1 : neg_wreset;  // async: sin usar
assign sresetn_wclk = (SYNC_RESET == 0) ? 1'b1 : neg_wreset;  // <- WRESET_N
assign aresetn_rclk = (SYNC_RESET == 1) ? 1'b1 : neg_rreset;
assign sresetn_rclk = (SYNC_RESET == 0) ? 1'b1 : neg_rreset;  // <- RRESET_N
```

O sea **dos resets síncronos independientes, uno por dominio**, muestreados
directamente por los flops de cada lado (punteros, sincronizadores Gray). La
protección existe, pero es condicional: exige que `WRESET_N` ya sea síncrono a
`WCLOCK` y `RRESET_N` a `RCLOCK` cuando llegan. Ese contrato es justo el que se
violaba antes del fix de 2026-08-26 (ver el comentario de cabecera de
`xfifo_dc.v`).

### El contrato se cumple

`reset.v` genera cada reset con `sync_reset`, que es async-assert /
sync-deassert de libro (shift de 5 flops registrado con el reloj destino):

```verilog
sync_reset clk_sreset_2 (.clk(clk),     .asyncrst(clkmem_rst), .syncrst(clk_rst));
sync_reset mem_sreset_2 (.clk(mem_clk), .asyncrst(clkmem_rst), .syncrst(mem_rst));
```

Así que `clk_rst` deasserta síncrono a `clk` y `mem_rst` síncrono a `mem_clk`,
por construcción. Y `clkmem_rst = clk_rst_1 && mem_rst_1` acota además el skew,
porque ninguno de los dos libera hasta que ambos dominios sincronizaron.

### Inventario completo de elementos dual-clock

| instancia | cruce | `wr_rst` / `rd_rst` | veredicto |
|---|---|---|---|
| `mem_request_fifo` (`framestore.v`) | clk→mem_clk | `rst` / `mem_rst` | correcto |
| `mem_response_fifo` (`framestore.v`) | mem_clk→clk | `mem_rst` / `rst` | correcto |
| `osd` `dpram_dc` (`osd.v`) | clk→dot_clk | `rst` / `dot_rst` | correcto |
| `pixel_fifo` (`pixel_queue.v`) | clk→dot_clk | `rst` / **`rst`** | **violación** |

Y los FIFOs del vbuf (`vbuf_write_fifo`/`vbuf_read_fifo` en `mpeg2video.v`) son
**`fifo_sc`**, mono-reloj en el dominio `clk`: no hay CDC ahí en absoluto.

### Conclusión

El camino de decode (clk↔mem_clk) está correctamente protegido, y el camino del
vbuf que alimenta a `getbits` ni siquiera cruza dominios. **La hipótesis de la
carrera de fase, tal como estaba formulada -- un CoreFIFO saliendo del reset
inconsistente en el borde clk↔mem_clk -- no tiene mecanismo. Queda descartada,
y NO justifica el rebuild del CCC.**

### Lo único que queda sin proteger

`pixel_fifo` es la última instancia de la clase de bug que se arregló en
agosto: pasa `rst` (dominio `clk`) a ambos lados, pero su `rd_clk` es
`dot_clk`. Está admitido en su propio comentario ("identical class of CDC gap
... out of scope for this fix"). Es notable que `osd.v` haga exactamente el
mismo cruce y lo haga bien, lo que sugiere olvido más que decisión.

Honestamente: **no hay evidencia que lo ligue al `SIZE=0`.** `disp_service_cnt`
tiene delta 0 tanto en PASS como en FAIL, o sea el arbiter nunca sirvió al
display durante el push, y no hay registro de debug que exponga el estado de
`pixel_fifo`. Es un bug real que conviene arreglar por mérito propio, y arreglarlo elimina
la última incógnita de CDC del diseño. **Hecho** (`hardware_development`,
commit `90e1a9a`): `pixel_queue.v` gana un puerto `rst_out`, cableado a
`dot_rst` en `mpeg2video.v`, con la misma forma que el `mem_rst` que
`framestore.v` ya recibió. Verificado en `bench/iverilog`: compila y el
decoder sigue reconstruyendo frames, incluido `tv_out_0000.ppm`, que sale
justamente por este fifo.

No es "la causa encontrada". Pero deja **una predicción falsable** que conviene
chequear con el próximo bitstream: hoy `disp_service_cnt` da delta 0 en TODAS
las corridas, o sea el arbiter nunca sirve al display -- que es exactamente
como se vería un `pixel_fifo` trabado (si su lado de lectura no resetea bien y
`full` queda pegado, `resample` no puede escribir, no genera direcciones, y
`do_disp` -- que exige `~disp_rd_addr_empty` -- nunca se asserta). Si el fix
hace algo real, ese contador debería dejar de ser 0.

## Dónde NO buscar

El camino de memoria está probado bueno y determinista: DRAM, `mem2axi_bridge`,
direccionamiento, el DMA y el contenido del VBUF son bit a bit idénticos entre
acierto y fallo. Cualquier próxima instrumentación debería ir dentro de
`getbits.v`/`vld.v` (o en el arranque del dominio de reset), no en la capa de
memoria.
