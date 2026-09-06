# Fase 7a CAUSA RAÍZ: la RAM del FIFO usa los dos puertos para ancho

Continuación de
[36_fase7a_la_escritura_a_la_ram_del_fifo_es_parcial.md](36_fase7a_la_escritura_a_la_ram_del_fifo_es_parcial.md).
Los dos pasos que no costaban rebuild alcanzaron para cerrarlo.

## Cómo quedó mapeada la RAM

`vbuf_read_fifo` es el módulo `xfifo_sc_64_8_32` del netlist (identificado por
`VBUF_RD_THRESHOLD = 32`, y confirmado por los nombres de puerto `vbr_rd_dta`,
`vbr_wr_en`, `vbr_rd_en` que Synplify heredó del sitio de instanciación).

Su memoria de 64 bits × 256 quedó en **dos** bloques RAM1K20
(`RAMINDEX="ram[63:0]%256-256%64-64%SPEED%0%0%TWO-PORT%ECC_EN-0"`), repartida
así:

| bloque / puerto | bits | dirección | block enable |
|---|---|---|---|
| `ram_0_0` **A** | `[39:20]` | **`rd_addr`** | `VCC` (constante) |
| `ram_0_0` B | `[19:0]` | `wr_addr` | gateado por `~full` |
| `ram_0_1` **A** | `[63:60]` | **`rd_addr`** | `VCC` (constante) |
| `ram_0_1` B | `[59:40]` | `wr_addr` | gateado por `~full` |

Un RAM1K20 da 20 bits por puerto. Para 64 bits en modo simple-dual-port harían
falta **cuatro** bloques. La herramienta usó dos, y para llegar al ancho tomó
**los dos puertos de cada bloque**.

Pero este FIFO necesita leer y escribir **en direcciones distintas al mismo
tiempo**. El puerto A lleva `rd_addr` y el B lleva `wr_addr`. Entonces los bits
que viven en una porción del puerto A **no se pueden escribir mientras ese
puerto está leyendo**: un puerto no puede leer la dirección X y escribir la
dirección Y en el mismo ciclo.

## La correlación que lo cierra

Cruzando el reparto de arriba contra los bits corruptos medidos en **tres
bitstreams distintos**:

```
build A (900001f20971e024):  9 bits corruptos -> puerto A: 9   puerto B: 0
build B (100001fe59d1e024): 12 bits corruptos -> puerto A: 12  puerto B: 0
build C (000001000001e024):  9 bits corruptos -> puerto A: 9   puerto B: 0
```

**30 bits corruptos en total, los 30 en porciones del puerto A. Ninguno en el
puerto B.**

Y encaja con lo medido en el doc 36: el valor corrupto es una mezcla bit a bit
de la palabra nueva y de la que ya estaba en esa dirección. Los bits del puerto
B se escriben bien; los del puerto A pierden su escritura y **conservan el
contenido anterior**.

Por qué a veces acierta: cuando no cae una lectura en el mismo ciclo que la
escritura, el puerto A sí escribe. Que pase o no queda determinado por el
solapamiento de lecturas y escrituras al arranque, fijado al soltar el reset --
de ahí el ~50/50 pegado a la sesión.

## Por qué en Virtex-5 no pasaba

Con el RTL idéntico. Una BRAM de Virtex-5 son 36 Kbit y soporta modo
simple-dual-port de hasta ×72, así que 64 bits × 256 = 16 Kbit entran en **un
solo bloque** usado como SDP legítimo: un puerto de escritura, uno de lectura,
sin compartir. En PolarFire el bloque es más chico y más angosto, y la
herramienta prefirió ahorrar bloques compartiendo puertos. **El RTL upstream
está bien; lo que falla es el mapeo.**

(Esto es razonamiento sobre las capacidades de cada primitiva, no una medición
sobre hardware Xilinx, que no tenemos.)

## Qué NO era

Vale dejarlo anotado porque se afirmó y hubo que retractarlo:

- **No es una colisión de direcciones en el RTL.** Imposible por construcción:
  `empty`, `wr_addr` y `rd_addr` se actualizan en el mismo flanco.
- **El aviso FX107 no era la evidencia.** Aparece 41 veces, incluyendo IP de
  Microchip. Apunta en la dirección correcta por casualidad, pero el mecanismo
  real es el reparto de puertos, no una colisión de direcciones.
- No es timing (cobertura Hold 61105/61107, post-route limpio), ni pérdida de
  palabras, ni desalineación, ni escrituras durante reset.

## El fix

El objetivo es forzar que la memoria se mapee como **simple-dual-port de
verdad** -- un puerto de escritura y uno de lectura, cuatro bloques -- en vez de
repartir el ancho entre los dos puertos. Opciones, de menor a mayor intrusión:

1. `syn_ramstyle` sobre `ram` en `xfifo_sc.v` para forzar el estilo de mapeo.
   Es el intento más barato y hay que verificar en el netlist que efectivamente
   pasen a cuatro bloques con `A_ADDR`/`B_ADDR` cumpliendo roles separados.
2. Reescribir el cuerpo de la RAM en un estilo que infiera SDP sin ambigüedad
   (lectura con enable propio, sin el `if (~empty)` que la deja activa casi
   siempre).
3. Instanciar explícitamente un two-port RAM de Microchip.

La 1 y la 2 mantienen la ventaja de arreglar `xfifo_sc.v` una vez y cubrir las
diez instancias. **En cualquier caso, verificar el netlist es obligatorio**: el
criterio de éxito no es que compile sino que `A_ADDR` y `B_ADDR` dejen de
llevar direcciones distintas con datos repartidos.

## Alcance

Las otras instancias `xfifo_sc_64_8_*` también usan dos bloques, así que tienen
el mismo reparto. Son diez FIFOs en total (doc 35). Los otros nueve corromperían
píxeles, vectores de movimiento y coeficientes DCT -- artefactos de imagen, no
una falla limpia.

## Cómo se llegó

Dos pasos sin rebuild, sobre el netlist ya generado:

1. `RAMINDEX` y las conexiones de `A_ADDR`/`B_ADDR`/`A_BLK_EN`/`B_BLK_EN` de
   las dos instancias `RAM1K20` del módulo.
2. Cruzar el reparto de bits por puerto contra las posiciones de bit corruptas
   medidas en hardware.

Ninguno costó síntesis.
