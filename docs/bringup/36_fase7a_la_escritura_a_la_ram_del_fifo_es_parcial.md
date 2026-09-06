# Fase 7a: la escritura a la RAM del FIFO se completa a medias

Continuación de
[35_fase7a_CAUSA_RAIZ_colision_rw_en_vbuf_read_fifo.md](35_fase7a_CAUSA_RAIZ_colision_rw_en_vbuf_read_fifo.md),
cuya explicación (colisión read/write) quedó **retractada** ahí mismo. Esto la
reemplaza con una caracterización medida.

## Retractación previa, en una línea

La colisión no puede ocurrir: `empty`, `wr_addr` y `rd_addr` se actualizan en el
mismo flanco, así que `~empty` implica direcciones distintas, y que coincidan
los bits bajos siendo distintas las completas es exactamente `full`, que
bloquea la escritura. El aviso FX107 de síntesis aparece 41 veces, incluyendo
IP de Microchip: es "no puedo probarlo", no un defecto. Lo leí como evidencia.

## La medición nueva

Sondas dentro del propio `xfifo_sc` (8 palabras APB, 0x31-0x38), 8 corridas:

```
FAIL  din=ok  000001b32d01e024   dout=MAL 100001fe59d1e024
      1a escritura: wr_addr=0 rd_addr=0 full=0
      1a lectura  : wr_addr=1 rd_addr=0 empty=0
      escrituras durante reset=0   wr_cnt=1578 rd_cnt=1578
PASS  din=ok  000001b32d01e024   dout=ok  000001b32d01e024
```

- **`din` correcto 8/8.** El dato que entra a la RAM está bien.
- **`dout` corrupto en los FAIL**, leyendo `ram[0]`.
- Punteros y flags exactamente como los diseñó el autor. Ninguna anomalía.
- `wr_cnt = rd_cnt = 1578`: no se pierde ni se duplica una palabra.
- Escrituras durante reset: 33 en la primera corrida tras el boot, **0 en todas
  las demás**, y hay FAILs con 0. **Descartada** esa pista.

## Qué es exactamente el valor corrupto

Los valores corruptos de **dos bitstreams distintos** se explican íntegramente,
sin un solo bit sin justificar, como mezcla bit a bit de dos valores:

| | |
|---|---|
| palabra nueva | `000001b32d01e024` (bytes 0-7 del archivo) |
| palabra vieja en esa dirección | `967f2cfe59fcb3f9` = **word 1536** del stream |
| corrupto build A | `900001f20971e024` — 9 bits vienen de la vieja |
| corrupto build B | `100001fe59d1e024` — 12 bits vienen de la vieja |

Word 1536 es precisamente la que ocupa la dirección 0 del FIFO en la vuelta
anterior del buffer circular: 1536 = 6 × 256, y el FIFO tiene 256 entradas.

> **La escritura a la RAM se completa a medias: unas pocas celdas de bit
> conservan su contenido anterior.**

Que el número y la posición de los bits fallados cambie entre builds (9 contra
12) descarta un bug de lógica -- daría el mismo valor siempre -- y apunta a algo
físico, ligado a placement y ruteo.

## Lo que ya está descartado, todo por medición

| candidato | por qué no |
|---|---|
| colisión read/write en la RAM | imposible por construcción (ver arriba) |
| pérdida o duplicación de palabras | `wr_cnt = rd_cnt = 1578` |
| ventana `getbits` desalineada | `cursor=0`, `getbits=0x000001` en los PASS |
| escrituras durante el reset | 0 en corridas que fallan |
| punteros mal inicializados | snapshots exactos en 1ª escritura y 1ª lectura |
| violación de hold sin analizar | cobertura Hold 61105/61107 restringidos, post-route sin caminos violados; los `-8.176 ns` del log eran estados intermedios del placer |
| corrupción aguas arriba | correcta en AXI, en `mem_response_fifo` y entrando al FIFO |
| lectura APB defectuosa | `SIZE` 2000/2000 consistente, independiente del predecesor |

## Dónde seguir

La pregunta ahora es por qué una escritura a LSRAM no commitea todos sus bits
sin que el análisis de timing lo reporte. Direcciones razonables, en orden de
costo:

1. **Mirar cómo quedó mapeada esa RAM**: cuántos bloques RAM1K20, con qué
   ancho, y si el write-enable de todos los bloques viene del mismo camino.
   Se puede leer del netlist y del reporte de recursos, sin rebuild.
2. **Ver si el probe agregó un segundo puerto de lectura** y forzó a la
   herramienta a duplicar o repartir la RAM de un modo que empeore las cosas.
   Comparar el mapeo contra el build anterior (que ya fallaba igual, así que
   probablemente no sea esto, pero conviene descartarlo mirando).
3. **Forzar otro estilo de RAM** (`syn_ramstyle = "distributed"` o
   `"registers"`) sólo para `vbuf_read_fifo`: si la corrupción desaparece,
   queda confirmado que es el mapeo a LSRAM y no la lógica. Cuesta un rebuild
   pero es una prueba binaria.

Nótese que 1 y 2 no cuestan rebuild.

## Cambios

`hardware_development` `8b7482f`: instrumentación interna de `xfifo_sc`
(primer `din`, primer `dout`, punteros y flags en ambos momentos, contadores, y
escrituras durante reset), conectada solo en `vbuf_read_fifo`; las otras nueve
instancias dejan `dbg` abierto. 8 registros APB en 0x31-0x38.
`bench/apb_bridge` 71/71.

Dos trampas encontradas al escribirlo, ambas comentadas en el código:

- Rellenar los campos con `{{(64-dta_width){1'b0}}, ...}` **desborda** en las
  instancias de `fifo_sc` más anchas que 64 bits (las de vectores de
  movimiento): la cuenta de replicación se vuelve un número enorme sin signo e
  iverilog muere con `std::bad_alloc`. Una asignación normal extiende o trunca
  sola.
- `bench/iverilog` tiene su **propia copia** de `wrappers.v`, que también
  necesitaba el puerto nuevo.

Y el watchdog del testbench de APB tuvo que subir de 100000 a 400000: los
checks acumulados a lo largo de la Fase 7a habían pasado el presupuesto viejo y
disparaba en corridas sanas.
