# Estimación de potencia con SmartPower (vectorless)

**Fecha:** 2026-10-08
**Placa:** PolarFire SoC FPGA Discovery Kit (MPFS-DISCO-KIT), MPFS095T, FCSG325
**Herramienta:** Libero SoC 2025.2 (2025.2.0.14), SmartPower, sin GUI
**Netlist analizado:** el place & route del 2026-09-08. Su copia de RTL (`MPEG2FPGA_SOC/hdl/`) es
idéntica byte a byte a `rtl/mpeg2/` en `60d512a` (Fase 9b). El rebuild posterior (stream_dma
no-pad, build-id, IRQ picture-ready) cambia el netlist, así que estos números no lo cubren.

## ¿Se puede medir la potencia en la placa?

No por software. El user guide (DS50003630D) y el esquemático del Discovery Kit muestran que:

- **No hay monitores de potencia.** No hay PAC19xx ni INA2xx, ni resistencias shunt en los rails. La
  Icicle Kit sí trae PAC1934 por I2C, con driver hwmon en Linux; el Discovery Kit no. En I2C solo
  están la EEPROM AT24CM01 y los buses de cámara, mikroBUS y RPi.
- **Los reguladores no reportan nada.** Son MIC22705 (VDD 1.0 V, 3P3V), MIC22405 (1P2V_DDR4, 1P8V),
  MIC69502 (2P5V) y MIC5166 (VTT), todos analógicos y sin PMBus.
- **Test points:** solo `TP_VDD` (1.0 V) y `TP_1P8V`. Sirven para medir voltaje, no corriente.

Las opciones reales son dos. Una es **medir el consumo total** con un medidor USB-C en línea en J4 o
una fuente de laboratorio en J7, y separar lo que consume el decoder por diferencia entre estados
(idle / decoder cargado / decodificando). La otra es **estimarlo por módulo** con SmartPower, que es
lo que documenta este informe.

## Método

SmartPower trabaja sobre el netlist post-layout y se puede correr headless con
`run_tool -name {VERIFYPOWER} -script <script>`. Archivos (rama `hardware_development`):

- `soc_build/run_verify_power.tcl`: abre el proyecto, registra los constraints de reloj (ver más
  abajo), corre VERIFYPOWER y guarda el proyecto.
- `soc_build/power_analysis.tcl`: los comandos `smartpower_*`.
  1. Inicializa las frecuencias desde los constraints (`smartpower_init_set_clocks_options
     -with_clock_constraints`, `smartpower_init_do -with {vectorless}`).
  2. Corre `smartpower_compute_vectorless`.
  3. Escribe los reportes typical y worst en texto y el desglose completo por instancia en CSV.
- `tools/power/summarize_power_by_module.py`: SmartPower lista celdas hoja y nets con su path
  jerárquico completo; este script los suma por prefijo de jerarquía, para tener un número por
  módulo RTL.

```sh
cd trunk/mpeg2fpga/soc_build
libero SCRIPT:run_verify_power.tcl LOGFILE:power_reports/run_verify_power.log   # ~15-20 min
python3 ../tools/power/summarize_power_by_module.py \
    power_reports/power_vectorless_typical_instances.csv \
    FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_mpeg2
```

Detalles de la herramienta que conviene saber:

- **`smartpower_report_power` con path relativo no escribe nada,** y tampoco da error. Hay que
  pasarle un path absoluto.
- **`-with_annotation_coverage` no existe en 2025.2,** aunque la ayuda lo documenta: Libero responde
  "Ignoring invalid argument".

## Hallazgo: Verify Timing corre sin relojes

En las primeras corridas SmartPower dejaba **todos los dominios de reloj del fabric en 0 MHz**. La
potencia dinámica del decoder daba cero y solo aparecía el bloque duro del MSS. Pedirle que tome las
frecuencias de los constraints de reloj no cambió nada.

**Causa:** SmartPower toma los relojes del set de constraints de **VERIFYTIMING** (de ahí sale
`designer/MPFS_DISCOVERY_KIT/power_analysis.sdc`). `build_mpeg2fpga_soc.tcl` registra para
VERIFYTIMING solo `apb3_mpeg2fpga_bridge_cdc.sdc`, y `organize_tool_files` **reemplaza** el set en
vez de agregar (el mismo comportamiento que causó el bug de pin-lock, doc 08). En consecuencia,
`timing_analysis.sdc` y `power_analysis.sdc` no tienen ningún `create_clock`.

**Consecuencia para timing, más allá de la potencia:**

- **Verify Timing analiza el diseño sin relojes.** En `MPFS_DISCOVERY_KIT_max_timing_multi_corner.xml`
  los paths aparecen con la columna *Slack* vacía.
- **El "0 violaciones" que se viene reportando no prueba que el timing cierre.** No había ningún
  período contra el cual medir.
- **Place & route sí tenía los relojes:** `place_route.sdc` tiene los 8 `create_clock` /
  `create_generated_clock` de `MPFS_DISCOVERY_KIT_derived_constraints.sdc`. La ubicación se hizo
  con timing en cuenta; lo que no está verificado es el signoff.

**Arreglo aplicado (solo para potencia):** `run_verify_power.tcl` vuelve a registrar
`MPFS_DISCOVERY_KIT_derived_constraints.sdc` junto con el SDC del bridge para VERIFYTIMING. Con eso
aparecen las frecuencias reales: `u_mpeg2` OUT0/OUT1/OUT2 a 162 / 108 / 27 MHz y los FIC a
162 / 51.2 MHz. **El script de build sigue sin corregir:** cada rebuild vuelve a dejar el set sin
relojes. Queda pendiente corregirlo y correr Verify Timing con los relojes.

## Resultados

Condiciones de operación por defecto del proyecto (rango EXT). Typical: Tj 25 °C, VDD 1.000 V.
Worst: Tj 100 °C, VDD 1.030 V.

### Total

|                | Typical (mW) | Worst (mW) |
|----------------|-------------:|-----------:|
| **Total**      | **1657.5**   | **1955.6** |
| Estática       | 239.6        | 441.6      |
| Dinámica       | 1417.9       | 1514.0     |

### Por rail (typical)

| Rail      | V     | mW      | mA      |
|-----------|------:|--------:|--------:|
| VDD       | 1.000 | 1293.7  | 1293.7  |
| VDDI 3.3  | 3.300 | 98.8    | 29.9    |
| VDDI 1.2  | 1.200 | 95.6    | 79.7    |
| VDDAUX    | 2.500 | 75.0    | 30.0    |
| VDD18     | 1.800 | 49.7    | 27.6    |
| VDD25     | 2.500 | 23.5    | 9.4     |
| VDDI 1.8  | 1.800 | 21.2    | 11.8    |

En worst, VDD sube a 1561 mW (1516 mA a 1.03 V). El regulador de VDD (MIC22705) da 7 A, así que
hay margen de sobra.

### Por tipo de recurso (typical)

| Tipo          | mW     | %     |
|---------------|-------:|------:|
| Gate          | 1121.4 | 67.7% |
| I/O           | 383.5  | 23.1% |
| Core Static   | 82.2   | 5.0%  |
| Net           | 47.6   | 2.9%  |
| Memory (LSRAM/uSRAM) | 13.3 | 0.8% |
| DSP (MACC)    | 9.0    | 0.5%  |

### Por bloque de primer nivel (typical, suma del CSV por instancia)

La suma por instancias da 1569.6 mW. La diferencia con el total (≈88 mW) es estática del core que
SmartPower no asigna a ninguna instancia.

| Bloque                 | mW     | % de 1569.6 |
|------------------------|-------:|------:|
| `MSS_WRAPPER_0`        | 1408.9 | 89.8% |
| `FIC_3_PERIPHERALS_0`  | 90.1   | 5.7%  |
| I/O y nets de top      | 38.7   | 2.5%  |
| `FIC_0_PERIPHERALS_0`  | 17.4   | 1.1%  |
| `CLOCKS_AND_RESETS_0`  | 14.5   | 0.9%  |

`MSS_WRAPPER_0` se divide así:

- el bloque duro MSS (`I_MSS`): 1053 mW
- los buffers de I/O del MSS: 352 mW, de los cuales 182 mW son de la interfaz DDR4

### Periférico mpeg2fpga (typical)

`FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0`: **68.0 mW** (4.3% del diseño).

| Submódulo       | mW    |
|-----------------|------:|
| `u_mpeg2` (decoder) | 63.6 |
| `u_mem_bridge`  | 1.6   |
| `u_stream_dma`  | 1.5   |
| `u_bridge` (APB)| 1.1   |

### Dentro del decoder, `u_mpeg2` (typical, 63.6 mW)

| Módulo                      | mW    | %     | Gate | Memory | Net |
|-----------------------------|------:|------:|-----:|-------:|----:|
| `idct`                      | 16.26 | 25.6% | 9.80 | 1.02 | 5.44 |
| `u_ccc` (PLL propio)        | 15.68 | 24.7% | 14.46 | — | 1.22 |
| `motcomp`                   | 7.51  | 11.8% | 5.89 | 1.05 | 0.57 |
| `framestore`                | 4.92  | 7.7%  | 1.19 | 2.38 | 1.35 |
| `vld`                       | 1.92  | 3.0%  | 1.12 | — | 0.80 |
| `regfile`                   | 1.83  | 2.9%  | 1.83 | — | — |
| `resample`                  | 1.74  | 2.7%  | 1.39 | 0.08 | 0.27 |
| celdas sueltas de `u_mpeg2` | 1.65  | 2.6%  | 0.21 | — | 1.45 |
| `fwd_reader`                | 1.50  | 2.4%  | 0.20 | 0.64 | 0.66 |
| `recon_writer`              | 1.45  | 2.3%  | 0.15 | 0.64 | 0.67 |
| `rld`                       | 1.29  | 2.0%  | 1.08 | 0.10 | 0.11 |
| `getbits_fifo`              | 1.24  | 1.9%  | 0.32 | — | 0.92 |
| `vbuf_write_fifo`           | 1.15  | 1.8%  | 0.13 | 0.48 | 0.54 |
| `vbuf_read_fifo`            | 1.09  | 1.7%  | 0.12 | 0.48 | 0.49 |
| `bwd_reader`                | 0.87  | 1.4%  | 0.16 | 0.42 | 0.28 |
| `idct_fifo`                 | 0.75  | 1.2%  | 0.23 | 0.31 | 0.22 |
| `osd_writer`                | 0.69  | 1.1%  | 0.06 | 0.38 | 0.24 |
| `disp_reader`               | 0.57  | 0.9%  | 0.18 | 0.30 | 0.10 |
| `rld_fifo`                  | 0.45  | 0.7%  | 0.10 | 0.13 | 0.22 |
| `probe`                     | 0.44  | 0.7%  | 0.41 | — | 0.03 |
| `pixel_queue`               | 0.23  | 0.4%  | 0.05 | 0.17 | 0.01 |
| resto (`watchdog`, `reset`, sincronizadores, matrices de cuantización, `syncgen_intf`, `mixer`) | < 0.4 | | | | |

En el CSV de instancias, los multiplicadores del IDCT (`MACC_PA`) aparecen como *Gate*, no como *DSP*.

## Cómo leer estos números

- **Es una estimación vectorless.** SmartPower usa tasas de toggle por defecto, propagadas desde los
  relojes: alrededor de 0.4–4% en salidas de registro, según el dominio. La estática y la de los
  relojes son confiables. La dinámica de la lógica es una suposición genérica: sirve para comparar
  órdenes de magnitud entre módulos, no como valor absoluto. Para refinarla hace falta importar
  actividad de simulación (`smartpower_import_vcd`).
- **El decoder no es lo que domina el consumo.** Con ~64 mW frente a ~1.4 W del MSS, un medidor en
  la entrada de 5 V va a ver un delta chico entre "decodificando" e "idle", del mismo orden que la
  resolución de un medidor USB barato y que la eficiencia de los buck.
- **El PLL del decoder (`u_ccc`) consume tanto como el IDCT.** Un PLL consume casi lo mismo con
  la lógica activa o quieta. Si en algún momento se buscara bajar el consumo, compartir el CCC de
  `CLOCKS_AND_RESETS` en vez de instanciar uno propio sería lo primero a mirar. Ojo: `CCC_FIC_x_CLK`
  ya genera 162 MHz.
- **La cadena de salida de video consume casi cero.** `syncgen_intf`, `mixer` y `pixel_queue` están
  prácticamente en cero porque `r/g/b/h_sync/v_sync` nunca se conectaron a pines y síntesis podó la
  lógica. Es consistente con el estado ya conocido de la salida de video.
- **No cuenta el resto de la placa.** DDR4, PHY Ethernet VSC8221, reguladores, LEDs y USB-UART
  consumen fuera del chip. El consumo total de la placa va a ser bastante mayor que 1.66 W.

## Próximos pasos

1. Corregir el registro de VERIFYTIMING en `build_mpeg2fpga_soc.tcl` (agregar
   `MPFS_DISCOVERY_KIT_derived_constraints.sdc`) y correr Verify Timing con los relojes.
2. Volver a correr `run_verify_power.tcl` sobre el netlist del rebuild nuevo.
3. Importar un VCD (de Icarus o de una simulación post-layout) para reemplazar la actividad
   vectorless en el decoder, y revisar qué porcentaje de las señales quedan anotadas.
4. Medir el consumo total real con un medidor USB-C en J4, en los tres estados (idle / decoder
   cargado / decodificando), para contrastar con la estimación.
