# Fase 7a RESUELTO: `DDR_BASE` extendido con signo a `0x3f_c8000000`

**El bug que perseguimos durante toda la Fase 7a está encontrado y arreglado.**
Continuación de
[29_fase7a_clock_fix_mpu_status_and_fic_symmetry.md](29_fase7a_clock_fix_mpu_status_and_fic_symmetry.md).

## La causa raíz

`mpeg2fpga_apb_peripheral.v` declaraba:

```verilog
parameter [37:0] DDR_BASE = 38'hc8000000;
```

Al ser un `parameter` del **borde del módulo**, se convirtió en el único
parámetro que Libero introspectó al registrar este módulo como HDL+ core
(`create_hdl_core`, ver `MPEG2FPGA_APB_PERIPHERAL.tcl`). Libero lo guardó en
el XML del componente generado
(`component/User/Private/mpeg2fpga_apb_peripheral/1.0/*.xml`) como:

```xml
<spirit:hwParameter spirit:id="DDR_BASE" spirit:dataType="int"
                    spirit:resolve="user">-939524096</spirit:hwParameter>
```

`0xc8000000` reinterpretado como **int de 32 bits con signo** es exactamente
`-939524096`. La síntesis después extendió ese negativo con signo de vuelta a
38 bits, y el netlist se construyó literalmente con (confirmado en
`synthesis/MPFS_DISCOVERY_KIT.srr`):

```
DDR_BASE = 38'b11111111001000000000000000000000000000 = 0x3f_c8000000
```

en vez de `0x00_c8000000`.

**Consecuencia**: cada escritura de `mem2axi_bridge` apuntaba a
`0x3f_c8000000 + offset`. Esa dirección cae dentro de la **ventana propia de
64 GB de FIC1** (`0x30_00000000`–`0x3F_FFFFFFFF`, MSS TRM Tabla 6-2), no en
DDR.

## Por qué explica absolutamente todo

- **Los datos nunca aparecían en DRAM** pese a escaneos exhaustivos de
  96MB+32MB -- nunca se estaban escribiendo ahí.
- **`BVALID` nunca volvía** -- no hay nada en esa dirección que responda
  correctamente, y el bridge quedaba clavado en `S_BRESP`.
- **AW/W sí completaban** (`aw_done=1`/`w_done=1`) -- el MSS acepta la fase de
  dirección igual.
- **FIC0 andaba bien** -- otro periférico, otro camino de parámetros.
- **`addr_r` avanzaba millones de ciclos sin dejar datos** -- escrituras
  yéndose al vacío.
- **El RTL siempre se veía correcto, y lo estaba.** El bug nunca estuvo en el
  Verilog sino en cómo la herramienta introspectó el parámetro.
- **Todas las hipótesis previas fueron refutadas en hardware porque todas
  eran correctas**: relojes (125MHz→108/162/27MHz), resets (`reset.v`,
  `clkmem_rst`), MPU, `BREADY`/`RREADY`, CDC, simetría FIC0/FIC1, power
  cycle. Ninguna era el problema; la dirección era el problema.
- **Era invisible**: `dbg_last_write_awaddr_issued` solo expone los 32 bits
  bajos, que eran correctos (`0xc8e00000`). Los 6 bits altos corruptos nunca
  se vieron.

## Cómo se encontró

Encadenado desde dos cosas que se hicieron esta misma sesión, ninguna de las
cuales era "el fix":

1. **El gate de reset por software** (commit `5d9a9db`, ver abajo). Sin poder
   decidir *cuándo* arranca el core, era imposible desconfigurar el MPU antes
   de que el core escribiera -- su barrido `STATE_CLEAR` arrancaba solo, al
   liberarse el reset, mucho antes de que cualquier script pudiera correr.

2. **Denegar deliberadamente el MPU de FIC1** y capturar la violación
   resultante. `MPU2(FIC1).STATUS` (`0x20005180`) reportó la dirección de la
   escritura fallida como exactamente **`0x3fc8000000`** -- los bits altos
   corruptos, visibles por primera vez.

Detalle importante encontrado en el camino: el MPU **no** tiene semántica
RISC-V PMP de "primer match gana". Los primeros dos probes denegaron solo la
región 0 y no denegaron nada en absoluto (el push seguía llegando a su
`bytes_done` habitual, delatando que la denegación no había tenido efecto).
Hay que denegar **todas** las regiones (16 en FIC0/FIC1, 8 en FIC2) para que
el acceso se rechace de verdad: cualquier región que matchee y permita,
habilita.

## El fix

```verilog
localparam [37:0] DDR_BASE = 38'hc8000000;
```

Un `localparam` no es sobreescribible por definición, así que Libero no puede
introspectarlo ni re-tipearlo. `u_mem_bridge` conserva su propio `parameter`
(es submódulo interno, no el borde del core HDL que Libero mira).

**Verificado empíricamente** con un rebuild desde cero (commit `4b3b39c`):
- El XML del componente regenerado tiene el bloque `<spirit:hwParameters>`
  **vacío**, sin entrada `DDR_BASE`.
- El `.srr` ahora reporta
  `DDR_BASE=38'b00000011001000000000000000000000000000` = `0x00c8000000`.

## Resultado en hardware real

Push de `tcela-17.bits` (12599 bytes), comparado con todos los tests previos:

| | Antes (siempre) | Después |
|---|---|---|
| `dma_bytes_done` | 1385, timeout | **12631 -- stream completo, sin timeout** |
| `mem_res_valid_cnt` | 0 | **1578 -- respuestas de memoria volviendo** |
| `vbuf_rd_addr` | `0x1c0000` (parado) | **`0x1c062a` -- avanzó 1578 palabras** |
| `watchdog_status` | True (reset) | **False** |
| arbiter | clavado en `STATE_CLEAR` | avanzó |
| páginas 4K no-cero en DRAM | 0 / 8192 | **3968 / 8192** |

Y el dato decisivo -- contenido real en DRAM física:

```
FRAME_0_Y @ 0xc8000000: 000001b3 2d01e024 0c352382 ...
     VBUF @ 0xc8e00000: 24e0012d b3010000 ...
```

`00 00 01 B3` es el `sequence_header_code` de MPEG-2. El stream real,
escrito por el decoder, en memoria física real, por primera vez en el
proyecto.

## Lo que sigue: el decode en sí

**Sigue sin andar**: `SIZE=0`, `picture_hdr=False`. El decoder ingiere el
stream entero, lo escribe al VBUF, lo vuelve a leer (1578 palabras ~= 12.6KB,
prácticamente todo el stream) -- y el VLD nunca reporta haber encontrado un
picture header. Después de ese burst inicial la actividad se detiene.

Quedamos parados exactamente en el misterio original de "Fase 7a SIZE=0" que
arrancó toda esta investigación, pero por primera vez **alcanzable**: la capa
de memoria funciona, así que ahora se puede observar de verdad qué hace el
VLD en vez de estar tapado por el wedge de FIC1.

### Primera pista concreta a revisar: orden de bytes

Las dos zonas de DRAM tienen **los mismos 8 bytes con el empaquetado
invertido dentro de la palabra de 64 bits**:

```
FRAME_0_Y raw bytes: 00 00 01 b3 2d 01 e0 24
VBUF      raw bytes: 24 e0 01 2d b3 01 00 00   <- exactamente al revés
```

Si los bytes vuelven del VBUF con ese orden, `getbits.v` nunca vería un
`00 00 01 xx` -- vería `xx 01 00 00`, y por lo tanto nunca encontraría un
start code, que es exactamente el síntoma (`picture_hdr` nunca se setea).

**No confirmado todavía** -- puede ser que una de las dos zonas la haya
escrito un camino distinto (recordar el viejo apunte de "address aliasing" de
puntos anteriores de esta investigación, donde `FRAME_0_Y` recibía bytes del
stream mientras `VBUF` quedaba en cero). Pero es lo primero a mirar.

## El otro cambio de esta sesión: gate de reset por software

Commit `5d9a9db`. No era el fix del stall, pero fue lo que lo destapó, y es
un arreglo correcto por mérito propio.

`rst_n` estaba atado 1:1 a `FIC_3_PERIPHERALS_0:PRESETN` a nivel SmartDesign
-- se liberaba solo, apenas el MSS liberaba FIC_3, sin intervención de
software, mucho antes de que Linux (o el paso del HSS que configura las
PMPCFG del MPU) hubiera terminado. Eso causaba una violación de MPU en cada
boot: el barrido `STATE_CLEAR` de `framestore_request.v` escribía a
`FRAME_0_Y` antes de que el MPU estuviera configurado.

Nuevo registro APB `CORE_ENABLE_ADDR` (0x20), bit sticky, default 0, que
`mpeg2fpga_apb_peripheral.v` hace AND con el `rst_n` real para gatear
`u_mpeg2`/`u_stream_dma` (y transitivamente `u_mem_bridge`, vía la cadena de
`reset.v` interna de `mpeg2video.v`). El core queda reseteado por defecto y
solo se libera cuando el software lo pide.

Decisión de diseño importante: el `core_rst_n` del propio bridge APB queda
alimentado por el `rst_n` **sin gatear**, a propósito. La interfaz de
registros -- incluido este mismo bit -- nunca puede quedar rehén del gate que
controla. Verificado en hardware: con el core apagado los registros responden
normalmente (`version=0` en vez de colgarse), y al liberarlo pasa a
`version=12`.

`PADDR`/`apb_addr_r` ensanchados un bit (0x00-0x1f ya estaba completo).

Resultado en hardware: la violación de MPU de boot **desapareció por
completo** (antes aparecía en todos los boots, reproducida en dos reboots
limpios).

## Respuesta a la duda sobre el registro de STATUS del MPU

Sospecha del usuario: "limpiar el registro quizá no alcanza para que capture
violaciones nuevas". **Respondida: sí alcanza.** Confirmado con control
positivo en FIC2 (el camino demostrablemente funcional): limpiar
`SYSREG.MPU_VIOLATION_SR`, denegar las 8 regiones de MPU3, hacer un push, y
`MPU3(FIC2).STATUS` capturó `failed=True rw=read addr=0x88000000` --
exactamente `STAGING_BASE`, la dirección real de donde lee `stream_dma`.

## Arreglo colateral

`bench/apb_bridge/testbench.v` nunca conectó `dbg_mem_req_wr_push_cnt`/
`dbg_mem_req_rd_pop_cnt`, agregados al bridge en `0aea2f6` -- quedaban
flotantes y hacían fallar 3 checks por propagación de Z. Conectados e
inicializados. Ahora 46/46 (incluye 5 checks nuevos de `CORE_ENABLE`).

## Lección general

Un `parameter` en el borde de un módulo registrado como HDL core de Libero es
**tool-visible y tool-modificable**. Si su valor no entra en un int de 32 bits
con signo, la herramienta puede re-tipearlo silenciosamente y el netlist
sintetizado deja de coincidir con el Verilog que uno lee. Para constantes que
no necesitan ser configurables desde el SmartDesign, usar `localparam`.
Y para verificar qué se sintetizó realmente, mirar el `.srr` -- no alcanza
con leer el RTL ni con confiar en registros de debug que solo exponen parte
del valor.
