# mpeg2fpga — protocolo de red v1

**Estado: borrador revisado (2026-10-08).** Decisiones de diseño cerradas
(sección 9); falta implementarlo (daemon `mpeg2fpgad` y librería Python).

Este documento es el contrato entre el dispositivo y sus clientes. La librería
cliente (Python primero) es una forma cómoda de hablarlo, no la definición: un
cliente en cualquier lenguaje que implemente lo que está acá tiene que
funcionar. La demo web es un cliente más de este protocolo.

## 1. Qué hace el dispositivo (alcance de v1)

Recibe un **clip** MPEG-2 (elementary stream de video, ISO/IEC 13818-2) por
Ethernet, lo decodifica en la FPGA y devuelve los **frames decodificados** en
YUV 4:2:0 planar (I420), en orden de presentación, a medida que salen.

El clip **no tiene límite de largo**: entra por partes mientras se decodifica
y los frames salen mientras entra el resto (sección 3). Lo único que limita es
el tiempo: el decoder va más lento que tiempo real (tabla de abajo), así que
v1 sirve para clips grabados, no para una fuente en vivo que no se pueda
frenar.

No está en v1:

- **Fuentes en vivo a tiempo real.** Con el decoder a 0.5–0.77x tiempo real,
  una fuente que no acepta control de flujo desborda cualquier buffer.
  Requiere que el decoder llegue a ≥ 1x (optimización de `motcomp_recon`).
- **Salida de video.** La placa no tiene conector de video; la salida del
  producto son los frames por la red.
- **Trick modes** (pausa, blank, mostrar un buffer). Controlan el camino de
  display, que en esta placa no sale a ningún lado. El daemon usa la pausa
  internamente como control de flujo (sección 3.2).
- Program/transport streams (`.ts`, `.mpg` con audio): sólo elementary stream
  de video. Demultiplexar es trabajo del cliente.
- MPEG-1, escalabilidad, data partitioning, 4:2:2/4:4:4.

Lo que el dispositivo publica en `GET /v1/device` (sección 4.2), con los
valores de la plataforma actual:

| | valor | de dónde sale |
|---|---|---|
| largo de clip | sin límite | DMA por chunks (`stream_dma.v`, bit `no_pad`) |
| resolución máxima | 1920x1088 | mapa de memoria `MP_AT_HL` (`mem_codes.v`); verificado en hardware sólo hasta 720x576 |
| formato de croma | 4:2:0 | |
| decode rate medido | 20–23 fps a 704/720x480, 12–13.5 fps a 720x576 | `tools/regress`, docs/bringup/45 |

## 2. Transporte

- **HTTP/1.1 sobre TCP**, puerto **8080** por defecto (8443 con TLS).
- Mensajes de control y estado: **JSON** (UTF-8).
- Frames decodificados: un **stream binario** propio, enviado como respuesta
  HTTP chunked (sección 5).
- Seguridad: token obligatorio y TLS opcional (sección 6).

Por qué HTTP y no WebSocket/gRPC/un protocolo TCP propio: el lado placa se
puede hacer sólo con la biblioteca estándar de Python (en la imagen no hay
numpy), se prueba con `curl`, y cualquier lenguaje tiene un cliente HTTP.

### 2.1 Versionado

- Todas las rutas llevan el prefijo `/v1`.
- Dentro de v1 sólo se hacen cambios **aditivos**: campos JSON nuevos,
  endpoints nuevos y tipos de registro nuevos en el stream binario. Un cliente
  v1 tiene que ignorar los campos y los tipos de registro que no conoce.
- Un cambio incompatible es `/v2`; el dispositivo puede servir las dos
  versiones a la vez.
- El header de cada registro binario lleva su propio largo (`header_len`), así
  que se le pueden agregar campos sin romper a los clientes viejos.

### 2.2 Un decoder, un decode a la vez

El hardware tiene un solo decoder. Mientras un `POST /v1/decode` está en curso,
otro `POST /v1/decode` recibe **409 Conflict** con `Retry-After`. Los demás
endpoints responden siempre, también durante un decode.

### 2.3 Errores

Todo error HTTP (4xx/5xx) lleva un cuerpo JSON:

```json
{"error": {"code": "busy", "message": "a decode is already running", "retryable": true}}
```

| HTTP | `code` | cuándo |
|---|---|---|
| 400 | `bad_request` | parámetro inválido, o un cuerpo que no empieza a parecer MPEG-2 video (ver 4.4) |
| 401 | `unauthorized` | falta el token o es incorrecto (sección 6) |
| 404 | `not_found` | ruta desconocida |
| 409 | `busy` | ya hay un decode en curso |
| 429 | `too_many_attempts` | demasiados 401 seguidos desde la misma dirección (sección 6.3) |
| 503 | `decoder_unavailable` | el hardware no responde (driver no cargado, core trabado); probar `POST /v1/reset` |

Los errores que aparecen *durante* un decode, cuando el 200 ya salió, se
informan en el registro `END` del stream (sección 5.3), no con un código HTTP.

## 3. Modelo de un decode

Un decode es un único `POST /v1/decode`: el clip sube en el cuerpo del request
y los frames bajan en el cuerpo de la respuesta, **al mismo tiempo**. La
respuesta empieza en cuanto el decoder entrega el primer frame, sin esperar a
que termine de subir el clip.

1. El dispositivo responde `200` y empieza a pasar el clip al decoder **sin
   resetear el core**: cambia de clip con `flush_vbuf`, igual que un
   reproductor al cambiar de canal. Verificado en hardware que es determinista
   y que un clip dañado no afecta al siguiente (docs/bringup/45).
2. A medida que se completan, los frames salen como registros `FRAME`, en
   **orden de presentación** (I B B P se entrega I B B P en el orden en que se
   muestra, no en el del stream).
3. Al final sale un registro `END` con el resumen: cuántos frames, si quedó
   completo, y los bits de error/watchdog del decoder.

Un cambio de secuencia dentro del clip (otro tamaño) es válido: cada `FRAME`
trae su propio ancho y alto.

### 3.1 Entrada sin límite: control de flujo de TCP

El daemon lee del socket sólo cuando tiene lugar en su buffer de entrada (un
ring de dos mitades en la región de staging de 16 MiB: el DMA vacía una mitad
mientras el daemon llena la otra). Si el decoder va más lento que la red, el
daemon deja de leer, el buffer de TCP del cliente se llena y su `send()` se
bloquea. No se pierde nada y la memoria queda fija, para cualquier largo de
clip.

Del lado del cliente esto no requiere nada especial, salvo **mandar y recibir
en paralelo** (dos hilos, o I/O asíncrono): un cliente que primero sube todo y
después lee se traba solo, porque el dispositivo deja de leer en cuanto la
salida de frames se llena (3.2). La librería Python lo hace por dentro.

Cada chunk de entrada va al DMA con el bit `no_pad` (no es el último); el
último va sin él, y `stream_dma.v` agrega el `sequence_end_code` que hace
salir la última picture. Los chunks tienen que empezar en direcciones
alineadas a 8 bytes (el driver rechaza las otras): `stream_dma` lee palabras
AXI de 64 bits enteras, y un chunk desalineado reenvía los bytes anteriores.
Verificado en hardware: tek60 en 4 y en 37 chunks alineados da pictures
bit-idénticas al push único. Esto es interno del daemon; el cliente manda
chunks HTTP de cualquier tamaño.

### 3.2 Salida sin pérdidas: congelar el decoder

Los frames decodificados pesan mucho más que el stream (~0.5 MB cada uno a
704x480). Si el cliente los lee más lento de lo que salen, la cola de salida
del daemon (unos 8 frames, ~4 MB) se llena; entonces el daemon congela el
decoder (`repeat_frame = 31`, la pausa de trick mode, verificada en hardware:
el decoder se detiene sin perder nada y sin que salte el watchdog) hasta que
la cola baje. Un cliente lento recibe todo, más despacio.

### 3.3 Cómo sabe el daemon que hay un frame

Por una interrupción de hardware, una por picture terminada, en orden de
presentación, con el número de buffer del framestore que la contiene
(`/dev/mpeg2fpga`, ver `driver/mpeg2fpga/mpeg2fpga_uapi.h`). Trae un contador
de 16 bits, así que si se escapara alguna, el hueco se ve. No depende de
comparar contenido del framestore (el método de `decode_stream.py`, que no ve
una picture idéntica a la anterior).

## 4. Endpoints

Todos requieren el token (sección 6) salvo `GET /v1/health`.

### 4.1 `GET /v1/health`

Sin autenticación, para monitoreo y balanceadores. No revela nada del
dispositivo.

```json
{"ok": true}
```

### 4.2 `GET /v1/device`

Identidad, versiones y capacidades. No cambia mientras el dispositivo está
prendido.

```json
{
  "product": "mpeg2fpga",
  "protocol": "1.0",
  "versions": {
    "daemon": "1.0.0",
    "driver": "1.0.0",
    "bitstream": "0.1.0+a2446b6",
    "core": "0x000c"
  },
  "capabilities": {
    "input": ["mpeg2-video-es"],
    "output": ["i420"],
    "chroma_formats": ["4:2:0"]
  },
  "limits": {
    "max_stream_bytes": null,
    "max_width": 1920,
    "max_height": 1088
  },
  "security": {"tls": false}
}
```

- `bitstream` sale de los registros de build id del bridge APB (0x2b/0x2c):
  versión del release y hash del commit, con sufijo `-dirty` si se sintetizó
  con cambios sin commitear.
- `core` es el registro de versión del core mpeg2fpga de upstream y no cambia
  entre releases nuestros.
- `max_stream_bytes: null` = sin límite.

### 4.3 `GET /v1/status`

Estado actual. Se puede consultar en cualquier momento.

```json
{
  "state": "idle",
  "decode": null,
  "sequence": {"width": 704, "height": 480, "frame_rate": 29.97,
               "progressive": false, "display_width": 0, "display_height": 0},
  "decoder": {"enabled": true, "error": false, "watchdog": false, "video_change": false}
}
```

- `state`: `idle` | `decoding` | `error`.
- `decode`: mientras hay un decode en curso,
  `{"id": "...", "bytes_in": 1234567, "frames_out": 12, "flow_paused": false, "started": "...ISO 8601..."}`;
  si no, `null`. `flow_paused` = el decoder está congelado esperando al
  cliente (3.2).
- `sequence`: el último sequence header que parseó el decoder; `null` si
  todavía no parseó ninguno.
- `decoder`: los bits *sticky* que acumuló el driver desde el último decode.

### 4.4 `POST /v1/decode`

Decodifica un clip.

**Request**

- `Content-Type: application/octet-stream`; el cuerpo es el elementary stream.
- Largo: `Content-Length` o `Transfer-Encoding: chunked` (para un clip cuyo
  tamaño no se conoce de antemano).
- Parámetros de query, todos opcionales:

| parámetro | valores | por defecto | |
|---|---|---|---|
| `frames` | `all`, `last` | `all` | `last`: sólo el último frame (miniaturas, pruebas) |
| `max_frames` | entero > 0 | sin límite | corta el envío después de N frames; el decode sigue hasta el final |

El dispositivo valida el principio del cuerpo antes de comprometerse: si en
el primer MiB no aparece un `sequence_header_code`, responde `400` sin tocar
el decoder.

**Response**

- `200`, `Content-Type: application/vnd.mpeg2fpga.frames; version=1`,
  `Transfer-Encoding: chunked`, cuerpo en el formato de la sección 5.
- Header `X-Decode-Id`: el mismo id que figura en `/v1/status` y en `END`.

Si el cliente cierra la conexión a mitad de camino, el dispositivo descarta el
resto (`flush_vbuf`) y vuelve a `idle`.

### 4.5 `POST /v1/reset`

Recuperación: resetea el core (pulso de core enable), limpia el framestore y
los bits sticky. Un decode en curso termina con `END` y `"aborted": true`.
Respuesta `200` con el mismo cuerpo que `/v1/status`.

En operación normal no hace falta: los clips se encadenan sin reset. Es para
cuando `/v1/status` dice `error` o un decode termina con `watchdog: true`.

### 4.6 Debug (`/v1/debug/...`)

Sin garantía de compatibilidad dentro de v1: son para diagnóstico y para
`tools/regress`, no para aplicaciones. **Deshabilitados por defecto**
(`--enable-debug` en el daemon), porque exponen el estado interno.

- `GET /v1/debug/framestore/{n}?format=native|i420`: el frame buffer `n` (0–3)
  tal como está en DRAM ahora.
- `GET /v1/debug/perf`: los contadores de performance del driver.
- `GET /v1/debug/registers`: dump crudo de los registros del bridge APB.
- `POST /v1/debug/trick/{pause,resume,blank,show_buffer}`: trick modes.

## 5. Stream binario de frames

Todos los enteros son **little-endian**. Un stream es una sucesión de
registros; cada registro empieza con un header común de 12 bytes.

### 5.1 Header común

| offset | tipo | campo | |
|---|---|---|---|
| 0 | `char[4]` | `magic` | `"M2FR"` |
| 4 | `u8` | `type` | 1 = `FRAME`, 2 = `END`; otros: reservados, se ignoran salteando `payload_len` |
| 5 | `u8` | `flags` | reservado, 0 |
| 6 | `u16` | `header_len` | largo total del header, incluidos estos 12 bytes |
| 8 | `u32` | `payload_len` | bytes que siguen al header |

Para leer un registro: leer 12 bytes, leer `header_len - 12` bytes más (los
campos que el cliente no conozca se ignoran) y después `payload_len` bytes.

### 5.2 Registro `FRAME` (type 1)

Header extendido (v1: `header_len` = 32):

| offset | tipo | campo | |
|---|---|---|---|
| 12 | `u32` | `display_index` | posición en orden de presentación dentro del clip, desde 0 |
| 16 | `u32` | `decode_index` | posición en el orden del stream |
| 20 | `u16` | `width` | ancho en pixels (ya recortado: no es el stride de macrobloques) |
| 22 | `u16` | `height` | alto en pixels |
| 24 | `u8` | `picture_type` | 1 = I, 2 = P, 3 = B |
| 25 | `u8` | `structure` | 0 = frame picture, 1 = par de field pictures |
| 26 | `u16` | reservado | 0 |
| 28 | `u32` | reservado | 0 |

Payload: **I420 compacto**. Primero el plano Y (`width × height` bytes),
después Cb y Cr (`(width/2) × (height/2)` bytes cada uno), sin padding entre
filas. Los valores ya son pixels sin signo estándar: el dispositivo deshace la
inversión de bytes y el offset de signo del framestore (medido en la placa:
24 ms por frame de 704x480 en Python, contra ~43 ms por frame de decode).

`payload_len` = `width*height*3/2` en v1. Un cliente igual tiene que usar
`payload_len` y no calcularlo.

### 5.3 Registro `END` (type 2)

`header_len` = 12. El payload es un objeto JSON en UTF-8, y siempre es el
último registro del stream:

```json
{
  "id": "d-000042",
  "bytes_in": 9379864,
  "frames_sent": 150,
  "pictures_in_stream": 150,
  "complete": true,
  "aborted": false,
  "decoder": {"error": false, "watchdog": false, "video_change": false},
  "seconds": 6.53
}
```

- `complete`: se entregó un frame por cada frame codificado del clip (salvo lo
  que se excluyó a propósito con `frames=last` o `max_frames`).
- `decoder.error`: el VLD encontró algo que no pudo parsear. Los frames ya
  enviados pueden tener errores; el decoder sigue sano para el próximo clip
  (verificado con entradas truncadas, con bit flips y aleatorias).
- Si el stream se corta sin `END` (se cayó la conexión), el decode se
  considera fallido.

## 6. Seguridad

v1 se usa en una red de confianza (LAN). La capa de seguridad está pensada
para que el **mismo** protocolo pueda exponerse en una red pública más
adelante sin rediseñarlo, sólo cambiando la configuración, y para que su
costo en la red de confianza sea despreciable.

### 6.1 Token de acceso (siempre)

- Cada request (salvo `/v1/health`) lleva `Authorization: Bearer <token>`.
- El token es un secreto aleatorio de 256 bits (43 caracteres base64url),
  generado en el primer arranque y guardado en
  `/etc/mpeg2fpgad/token` (modo 0600, dueño `mpeg2fpgad`). Se lee por la
  consola serie o por ssh y se carga en el cliente. Se puede rotar con
  `mpeg2fpgad --rotate-token`.
- Comparación en tiempo constante (`hmac.compare_digest`), para no filtrar el
  token midiendo cuánto tarda la respuesta.
- Sin token o con uno incorrecto: `401` con `WWW-Authenticate: Bearer`.

Costo: una comparación de 32 bytes por request. Despreciable.

Qué protege: que otra máquina de la red use el decoder o lea su estado. Qué
**no** protege sin TLS: alguien que pueda espiar el tráfico de la red ve el
token pasar en texto plano y lo puede reutilizar. En una LAN de confianza se
acepta; en una red pública no, y para eso está 6.2.

### 6.2 TLS (opcional, obligatorio fuera de una LAN de confianza)

- `mpeg2fpgad --tls-cert cert.pem --tls-key key.pem`: el mismo protocolo sobre
  HTTPS (puerto 8443). Cifra todo el tráfico (token, clip y frames) y le
  prueba al cliente que habla con el dispositivo correcto.
- Certificado autofirmado generado en el primer arranque; el cliente lo fija
  por su huella digital (`fingerprint`) en vez de depender de una autoridad
  certificante. Para un despliegue público se reemplaza por uno real.
- Apagado por defecto, por costo. Medido en la placa de punta a punta
  (`webserver/tls_bench.py` + `tools/regress/tls_bench_client.py`, Python
  `ssl` sobre OpenSSL 3.2, un core U54 sin extensiones criptográficas,
  chunks del tamaño de un frame 704x480):

  | modo | MB/s | CPU por MiB | frames 704x480/s |
  |---|---|---|---|
  | HTTP plano | 29.0 | 34 ms | ~57 |
  | TLS 1.2 ChaCha20-Poly1305 | 7.6 | 132 ms | ~15 |
  | TLS 1.2 AES-128-GCM | 4.5 | 223 ms | ~9 |

  El core queda al 100% en los tres casos. Sin TLS sobra margen sobre los
  ~23 fps del decoder; con TLS la entrega pasa a estar limitada por la CPU
  (~15 fps con ChaCha20) y el control de flujo frena al decoder para
  acompañarla. Por eso el daemon fuerza ChaCha20 cuando TLS está activo
  (con AES rinde 40% menos), y por eso no está prendido en la LAN.
- Alternativa para un despliegue público: TLS terminado en otro equipo
  delante del dispositivo (un reverse proxy), con el dispositivo en una red
  privada detrás. El protocolo no cambia.

`GET /v1/device` informa `security.tls` para que el cliente sepa en qué modo
está.

### 6.3 Defensa básica (siempre, sin costo apreciable)

- **Usuario sin privilegios**: el daemon corre como `mpeg2fpgad`, no como
  root, con acceso sólo a `/dev/mpeg2fpga`, al u-dma-buf y a los atributos
  sysfs del driver (por grupo y reglas udev). Un bug en el daemon no da
  control de la placa.
- **Dirección de escucha configurable** (`--listen`): por defecto la interfaz
  de la LAN, no todas.
- **Debug apagado por defecto** (4.6).
- **Límites**: a lo sumo 8 conexiones simultáneas, headers de 16 KiB,
  timeout de 30 s sin recibir nada (evita que conexiones colgadas acaparen
  el dispositivo, el ataque *slowloris*).
- **Freno a la fuerza bruta**: después de 10 tokens incorrectos seguidos desde
  una misma dirección, `429` durante 60 s.
- **Entrada no confiable**: el clip sólo llega al decoder; nada de lo que
  manda el cliente se usa como ruta de archivo, comando o parámetro de
  sistema. Un clip malformado puede decodificar mal, pero no afecta al
  dispositivo (verificado con entradas dañadas, docs/bringup/45).

## 7. Ejemplo con curl

```sh
TOKEN=$(ssh root@192.168.18.5 cat /etc/mpeg2fpgad/token)
curl -s -H "Authorization: Bearer $TOKEN" http://192.168.18.5:8080/v1/device | jq
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/octet-stream' \
     -T clip.m2v -X POST http://192.168.18.5:8080/v1/decode -o frames.bin
```

(`-T` sube el archivo en streaming en vez de cargarlo entero en memoria.)

## 8. Librería Python (boceto, no normativo)

```python
from mpeg2fpga import Device

dev = Device("192.168.18.5", token=open("token").read().strip())
print(dev.info().versions.bitstream)

with open("clip.m2v", "rb") as f:
    result = dev.decode(f)                # sube en un hilo, devuelve un iterador
    for frame in result:                  # en orden de presentación
        frame.y, frame.u, frame.v         # bytes; o frame.to_numpy() si hay numpy
        frame.display_index, frame.picture_type
    print(result.summary.complete, result.summary.decoder.error)
```

Errores HTTP → excepciones tipadas (`DeviceBusy`, `Unauthorized`,
`DecoderUnavailable`, ...). Sin dependencias fuera de la biblioteca estándar.
Con TLS: `Device(..., tls_fingerprint="sha256:...")`.

## 9. Decisiones tomadas

| | decisión | por qué |
|---|---|---|
| 1 | Frames en **orden de presentación**, con `decode_index` incluido | es lo que casi cualquier cliente quiere; el hardware ya los entrega así (3.3) |
| 2 | **Trick modes fuera** de la API pública, en `/v1/debug` | controlan un display que esta placa no tiene; la pausa se usa adentro como control de flujo |
| 3 | **Entrada y salida en streaming con control de flujo** | clips sin límite de largo con memoria fija (3.1, 3.2) |
| 4 | **Token siempre + TLS opcional + defensa básica** | costo despreciable en LAN; el mismo protocolo sirve en una red pública prendiendo TLS (6) |
| 5 | **Registros de build id** en el bridge (0x2b versión, 0x2c hash) | para que `versions.bitstream` identifique el release y el commit |
| 6 | **Interrupción de picture lista** (bridge 0x2d, `/dev/mpeg2fpga`) | ninguna interrupción del core significa "hay una picture en el framestore": `picture_hdr` salta en el VLD antes de reconstruir y `frame_end` es el sincronismo vertical del display |

Los cambios de hardware de 3, 5 y 6 (bit `no_pad` en `DMA_CTRL`, build id,
interrupción de picture) entran en una misma síntesis.
