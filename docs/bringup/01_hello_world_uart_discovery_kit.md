# Fase 1 — Hello World en PolarFire SoC Discovery Kit

**Fechas:** 2026-07-29 – 2026-07-30
**Placa:** PolarFire SoC FPGA Discovery Kit (MPFS-DISCO-KIT), MPFS095T-1FCSG325E
**Diseño programado:** `polarfire-soc-discovery-kit-reference-design`, release `v2026.04`
(job `MPFS_DISCOVERY.job`, programado vía FlashPro Express sobre el FlashPro5 embebido)
**Aplicación bare-metal:** `mpfs-blank-baremetal` (repo `polarfire-soc-bare-metal-examples`),
build configuration `LIM-Debug-DiscoveryKit`

## Objetivo

Validar de punta a punta la cadena de bring-up de software sobre hardware real, antes de avanzar a
Linux (Fase 2): programar el reference design oficial de Microchip en la FPGA, confirmar arranque del
MSS por UART, y luego compilar, cargar y depurar (vía JTAG desde SoftConsole) una aplicación bare-metal
propia que imprima un mensaje de "hello world".

## Repositorios utilizados

Se clonaron dos repositorios oficiales de Microchip como proyectos hermanos del repo de la tesis (en
`/home/esbon/Proyectos/`, fuera de `tandem/`), porque son código/diseños de terceros con licencia
propia y sin relación con el port de mpeg2fpga que gobierna este repositorio:

| Repositorio | Uso |
|---|---|
| [`polarfire-soc-discovery-kit-reference-design`](https://github.com/polarfire-soc/polarfire-soc-discovery-kit-reference-design) | Diseño Libero (fabric + MSS) que habilita DDR4, SD, Ethernet, etc. en la Discovery Kit. Se usó el asset del release `v2026.04` (`MPFS_DISCOVERY_2026_04.zip`), que trae `MPFS_DISCOVERY.job` — un job de FlashPro Express listo para programar sin pasar por Libero. |
| [`polarfire-soc-bare-metal-examples`](https://github.com/polarfire-soc/polarfire-soc-bare-metal-examples) | Colección de aplicaciones y ejemplos de drivers bare-metal de Microchip. Contiene `applications/mpfs-blank-baremetal`, que trae soporte nativo para la Discovery Kit (carpeta `src/boards/mpfs-discovery-kit`, con XML/`.cfg` que coinciden exactamente con die `MPFS095T` / package `FCSG325`) y ya imprime `"**** Hello World !! ****"` por UART desde el hart E51. |

## Programación de la FPGA

1. Se descargó y descomprimió el asset `MPFS_DISCOVERY_2026_04.zip` del release `v2026.04`, quedando
   `MPFS_DISCOVERY.job` en `polarfire-soc-discovery-kit-reference-design/programming_job/`.
2. Se abrió FlashPro Express, se importó ese `.job` como nuevo Job Project, y se ejecutó **RUN** sobre
   el programador embebido (identificado por USB como **"Embedded FlashPro5"**, no FlashPro6 —
   corrección sobre lo que indica la documentación general de SoftConsole, que asume FlashPro6 para
   este kit). El resultado fue `RUN PASSED`.
3. La placa no tiene un botón de reset de sistema dedicado (los pulsadores `SW1`/`SW2` del kit son
   entradas de propósito general para el diseño de usuario en la fabric, no un reset global). Volver a
   ejecutar **RUN** sobre el mismo job es la forma práctica de forzar un reinicio limpio del MSS y
   observar el arranque desde cero cuando hace falta.

## Identificación de las interfaces serie del chip FT4232HL

La placa tiene un único chip FT4232HL (referencia `U16` en el esquemático) que cumple **doble función
sobre el mismo cable USB-C**: es a la vez el programador JTAG embebido ("Embedded FlashPro5") y el
puente USB-a-UART hacia varias MMUART del MSS. Tiene 4 interfaces USB, identificadas por Linux como
`1-7:1.0` a `1-7:1.3`.

Al conectar la placa, Linux solo expuso automáticamente **una** interfaz como puerto serie:

```
/dev/ttyUSB0   (interfaz USB 2)
```

Esto no es un error de conexión: el driver de kernel `ftdi_sio` declara en su tabla de identificación
que por defecto solo debe enlazarse a la interfaz número 2 de este par VID:PID (`1514:2008`,
"Actel"/Microsemi):

```
$ modinfo ftdi_sio | grep 1514
alias: usb:v1514p2008d*dc*dsc*dp*ic*isc*ip*in02*
```

Suposición inicial (parcialmente incorrecta): que las interfaces 0 y 1 eran ambas JTAG y la 3 no se
usaba. La investigación posterior (ver más abajo) mostró que solo la **interfaz 0** es JTAG puro; las
interfaces 1, 2 y 3 son las tres UART del kit (`UART_B`, `UART_C`, `UART_D` en la nomenclatura de la
guía de usuario), y **cada una lleva la consola de un hart/servicio distinto**:

| Interfaz USB | Dispositivo Linux | Contenido observado |
|---|---|---|
| `1-7:1.0` | (ninguno — reclamada por `usbfs`, usada por OpenOCD/FlashPro vía `libusb`) | Canal JTAG |
| `1-7:1.1` | `/dev/ttyUSB1` | Consola del hart **E51** de la aplicación bare-metal (`mpfs-blank-baremetal`) → aquí salió el "Hello World" |
| `1-7:1.2` | `/dev/ttyUSB0` | Consola de **HSS** (Hart Software Services), el bootloader de primera etapa |
| `1-7:1.3` | `/dev/ttyUSB2` | Sin actividad observada en esta prueba (probablemente consola de otro hart U54, no ejercitada por este ejemplo) |

Es decir: aunque tanto HSS como el hart E51 de la aplicación usan nominalmente "MMUART1" en la
nomenclatura del software (`p_uartmap_e51 = &g_mss_uart1_lo` para `MPFS_DISCOVERY_KIT` en
`uart_mapping.c`), **físicamente terminan en interfaces USB distintas del mismo chip**. Para trabajar
con esta placa hay que tener presente que puede ser necesario escuchar más de una interfaz según qué
componente de software se esté observando.

### Cómo exponer las interfaces adicionales

Por defecto Linux solo crea el nodo de dispositivo para la interfaz 2. Para forzar al driver a
enlazarse también a las demás (necesita privilegios de root):

```bash
sudo bash -c 'echo 1514 2008 > /sys/bus/usb-serial/drivers/ftdi_sio/new_id'
```

Esto le indica a `ftdi_sio` que intente reclamar **todas** las interfaces sin driver de ese VID:PID.
La interfaz 0 no se ve afectada porque ya está reclamada exclusivamente por el proceso que tiene
abierto el canal JTAG (OpenOCD/FlashPro Express vía `libusb`); las interfaces 1 y 3 quedan libres y
pasan a aparecer como `/dev/ttyUSB1` y `/dev/ttyUSB2`.

## Comando de configuración del puerto serie (`stty`)

```bash
stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb -crtscts raw -echo
```

Explicación de cada parte del comando (el mismo formato se usó para `ttyUSB1` y `ttyUSB2`, cambiando
solo el nombre del dispositivo):

| Parte | Significado |
|---|---|
| `stty` | Utilidad de Unix para leer o configurar los parámetros de línea de un dispositivo terminal (TTY). |
| `-F /dev/ttyUSB0` | Indica el dispositivo a configurar (en vez del terminal por defecto de la sesión actual). Es el nodo de carácter creado por el driver `ftdi_sio` para esa interfaz del FT4232HL. |
| `115200` | **Baud rate**: 115200 símbolos por segundo. Es la velocidad configurada en firmware tanto por HSS como por el HAL de PolarFire SoC para sus consolas UART (`MSS_UART_init(..., MSS_UART_115200_BAUD, ...)`). Debe coincidir exactamente en ambos extremos del enlace serie o los caracteres se reciben corruptos. |
| `cs8` | *Character size* = 8 bits de datos por carácter transmitido (el "8" del formato "8N1"). |
| `-cstopb` | Desactiva el uso de 2 bits de parada; queda un solo bit de parada (el "1" de "8N1"). |
| `-parenb` | Desactiva el bit de paridad (el "N" = *no parity* de "8N1"). |
| `-crtscts` | Desactiva el control de flujo por hardware (RTS/CTS) — el enlace no usa handshaking de hardware. |
| `raw` | Pone la línea en modo *raw*: desactiva el procesamiento de línea del driver de terminal (sin *canonical mode*, sin interpretación de caracteres especiales de control como Ctrl-C, sin buffering por línea). Necesario para pasar los bytes del log tal cual, sin que el TTY los reinterprete. |
| `-echo` | Desactiva el eco local de los caracteres recibidos (el eco, si lo hay, ya lo hace el otro extremo del enlace). |

En conjunto, esto configura el puerto en el formato estándar **115200 8N1** (8 bits de datos, sin
paridad, 1 bit de parada, sin control de flujo).

## Captura del log

Una vez configurado el puerto, la captura se hizo redirigiendo la salida cruda del dispositivo a un
archivo:

```bash
cat /dev/ttyUSB0 > uart_capture.txt
```

`cat`, al leer de un dispositivo de carácter en vez de un archivo regular, simplemente copia byte a
byte todo lo que llega por la UART hacia la salida indicada, de forma continua, hasta que el proceso se
interrumpe. Al investigar tres interfaces a la vez se lanzó una instancia de este comando por cada
`/dev/ttyUSBn` en paralelo, redirigiendo cada una a su propio archivo.

Punto práctico observado durante las pruebas: como el mensaje de arranque (de HSS o de la aplicación)
se imprime **una sola vez** al arrancar, hay que tener la captura corriendo *antes* de resetear/reprogramar
la placa o relanzar la sesión de debug — si el proceso `cat` se inicia después de que el mensaje ya
salió, no se captura nada. Por eso conviene lanzar la captura en segundo plano sin límite de tiempo y
resetear/relanzar recién después.

## Log de arranque de HSS (interfaz 2 / `/dev/ttyUSB0`)

Salida cruda tal como llegó por el puerto (incluye secuencias de escape ANSI usadas por HSS para la
barra de progreso, por eso los códigos `\x1b[...`):

```
^[[2J^[[H^[[0mDDR training ...^M
    0% [..................................................]^M   20% [...]^M   40% [...]^M   60% [...]^M   80% [...]^M                                                                ^M^[[ADDR training ... Passed ( 3172 ms)^M
^[[32m[3.257784]^[[0m DDR-Lo size is   32 MiB^M
^[[0m^[[32m[3.262463]^[[0m DDR-Hi size is  888 MiB^M
```

Versión legible (códigos ANSI removidos, solo el contenido):

```
DDR training ...
    0% [..................................................]   20% [..........]   40% [....]   60% [....]   80% [....]
DDR training ... Passed ( 3172 ms)
[3.257784] DDR-Lo size is   32 MiB
[3.262463] DDR-Hi size is  888 MiB
```

### Interpretación

- El texto y los timestamps (`[3.257784]`, formato segundos.microsegundos desde el inicio de HSS) son
  característicos del **Hart Software Services (HSS)**, el bootloader de primera etapa que corre en el
  hart E51 de la MSS antes de arrancar cualquier aplicación bare-metal o sistema operativo en los harts
  U54.
- `DDR training ... Passed` confirma que el controlador DDR4 de la MSS entrenó correctamente el enlace
  con la memoria DDR4 de 1 GB de la placa (parte Micron `MT40A512M16TB-062E`), en 3172 ms.
- `DDR-Lo size is 32 MiB` / `DDR-Hi size is 888 MiB`: HSS reporta la memoria detectada en dos regiones
  (32 MiB + 888 MiB ≈ 920 MiB direccionables de los ~1024 MiB físicos, el resto reservado para uso
  interno de HSS/mapa de memoria).
- El log se corta ahí porque, en este punto, HSS pasa a buscar un payload de arranque (aplicación
  bare-metal en eNVM, o imagen de Linux en la microSD/eNVM según el modo de boot configurado) y todavía
  no hay ninguno programado — normal en esta etapa, antes de la Fase 2 (Linux).

## Aplicación "Hello World" en SoftConsole

Pasos realizados:

1. Se importó el proyecto `polarfire-soc-bare-metal-examples/applications/mpfs-blank-baremetal` en
   SoftConsole (`File > Import > General > Existing Projects into Workspace`).
2. Se seleccionó la build configuration **`LIM-Debug-DiscoveryKit`** (memoria local rápida, pensada
   para debug por JTAG sin depender de que la DDR ya esté entrenada). Se confirmó en el `.cproject`
   que esta configuración define el macro de preprocesador `MPFS_DISCOVERY_KIT`, necesario para que
   `uart_mapping.c` asigne la UART correcta a cada hart (para este kit: `p_uartmap_e51 = &g_mss_uart1_lo`,
   es decir, MMUART1 para el hart E51).
3. Se compiló el proyecto sin errores.
4. Se depuró vía el launch ya incluido en el proyecto, `mpfs-blank-baremetal hw all-harts debug`, que
   conecta por JTAG a través del FlashPro5 embebido (OpenOCD, `board/microsemi-riscv.cfg`, `DEVICE MPFS`),
   carga el ELF y detiene los harts en el vector de reset a la espera de **Resume**.

### Troubleshooting: por qué no se veía el mensaje al principio

Varios intentos iniciales de captura no mostraron nada en `/dev/ttyUSB0`, a pesar de que:

- El hart E51 ya había ejecutado más allá del `print` (se lo confirmó parado en el `while(1)` final de
  `e51()`, código que se ejecuta *después* de la llamada a `MSS_UART_polled_tx_string`).
- La build configuration activa era la correcta (`LIM-Debug-DiscoveryKit`, con `MPFS_DISCOVERY_KIT`
  definido).

Como el código sí se había ejecutado, la causa no era de software sino de **routing físico de la
UART**: el mensaje del hart E51 (nominalmente "MMUART1") no sale por la misma interfaz USB que la
consola de HSS, sino por la interfaz 1 (`/dev/ttyUSB1`), que Linux no expone por defecto (ver sección
de arriba). El diagnóstico se hizo escuchando las tres interfaces UART a la vez tras exponer las que
faltaban con `new_id`.

### Log capturado (interfaz 1 / `/dev/ttyUSB1`)

```
 **** Hello World !! ****
```

Con esto queda confirmado el flujo completo: build → programación vía JTAG → ejecución → salida por
UART, usando una aplicación bare-metal propia (no la demo de fábrica ni HSS).

## Conclusión

Queda validada la cadena hardware y de herramientas completa para la Fase 1: alimentación,
programación JTAG vía FlashPro5, bitstream del reference design, arranque de HSS con entrenamiento de
DDR4 exitoso, y compilación/carga/depuración de una aplicación bare-metal propia desde SoftConsole con
salida verificada por UART. Se documentó además una particularidad de esta placa que conviene tener
presente en trabajo futuro: **el chip USB-UART expone 3 consolas distintas en 3 interfaces USB
distintas, y Linux solo enlaza una de ellas (`/dev/ttyUSB0`) automáticamente** — las otras dos
requieren `new_id` para aparecer como dispositivo.

Con esto queda lista la base para la Fase 2 del plan: arranque de Linux vía microSD.
