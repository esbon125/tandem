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

## Dónde NO buscar

El camino de memoria está probado bueno y determinista: DRAM, `mem2axi_bridge`,
direccionamiento, el DMA y el contenido del VBUF son bit a bit idénticos entre
acierto y fallo. Cualquier próxima instrumentación debería ir dentro de
`getbits.v`/`vld.v` (o en el arranque del dominio de reset), no en la capa de
memoria.
