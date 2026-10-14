# Demo pública: un clip real en tiempo real, y la demo en vivo por internet

Continúa [46]. Con el producto armado (protocolo v1, daemon, cliente), el
objetivo pasó a ser una demo para el informe y la defensa: un clip *real*,
aunque sea de baja resolución, decodificado en tiempo real por la placa, y
publicado en la GitHub Page del repo (https://esbon125.github.io/tandem/,
rama `gh-pages`). Terminó en dos cosas: una grabación verificada y una demo en
vivo a la que cualquiera puede subirle un video. Lo más útil para el informe
no es la página en sí sino lo que salió al llevarla a internet: el control de
flujo del protocolo hacía que la página midiera la red del visitante y lo
presentara como si fuera el decoder.

Código: `tools/demo-clip/` y `demo/live_relay.py` (firmware_development,
53bbc99 → 40e083b). Capturas para el informe: `docs/informe/figuras/demo_web/`.

## El clip y el régimen de medición

*Tears of Steel* (Blender Foundation, CC BY 3.0; el `copyright.txt` del sitio
de descarga dice CC BY-ND, pero sólo para la banda sonora, que no se usa).
Dos fragmentos de 20 s: 0:18–0:38 (la ciudad y el puente, filmado en
Ámsterdam: textura real, poco movimiento) y 7:38–7:58 (la batalla con los
robots, mucho movimiento). `make_clip.sh` los lleva a:

- MPEG-2 MP@ML 352x288 (CIF), letterbox con píxeles 12:11 (la película es 2.39:1);
- 24 fps nativos, sin convertir frame rate;
- GOP 12, IBBP, 1.5 Mb/s;
- **sin matrices de cuantización cargadas** (el script falla si el sequence
  header carga una): el núcleo aplica mal las matrices cargadas (plan, ítem 1b),
  y un clip que las cargara saldría mal desde el primer cuadro I. El GOP corto
  además acota la deriva conocida de los cuadros P/B (ítem 1).

Un detalle práctico: el servidor de descarga de Blender está detrás de
Cloudflare y responde 429 a varios pedidos seguidos (por ejemplo, los seeks de
ffmpeg sobre la URL). Hay que bajar la fuente una sola vez.

## Resultado verificado (bitstream 0.1.0+8004bc9)

| | |
|---|---|
| decodificación en la placa (`bench_decode.py`, 3 corridas) | **53.6 fps ±0.9**, 2.2x los 24 fps del stream |
| de punta a punta por LAN (cliente Python → daemon → cliente, 5 corridas) | 49.8–51.5 fps, las 5 idénticas byte a byte |
| contra `mpeg2decode`, 480 cuadros, Y+Cb+Cr | MAD medio 0.073, máximo 0.162, pico 3/255, PSNR-Y ≥ 55.8 dB |
| `mpeg2decode` contra libavcodec (control) | MAD ≤ 0.01 |

La estimación previa para CIF era ~40 fps (3.3x menos macrobloques que
704x480, más ~11 ms fijos por picture); dio mejor. `build_site.sh` rehace
todo de punta a punta y los hashes del clip, de la salida del FPGA y de la
referencia salen iguales en cada corrida (`media/SHA256SUMS` en la página).

## La demo en vivo: arquitectura

```
navegador (github.io, HTTPS) ──► Tailscale Funnel ──► live_relay.py (PC) ──LAN, token──► mpeg2fpgad (placa)
```

GitHub Pages sólo sirve archivos estáticos: la página puede estar ahí, el
decode no. El backend es un relay en una PC al lado de la placa, publicado con
Tailscale Funnel (gratis, URL estable con TLS, sin abrir puertos ni tener IP
pública). El relay va en la PC y no en la placa porque:

- transcodifica con ffmpeg, inviable en el U54;
- guarda el token del daemon (la página es pública, no puede llevarlo);
- la placa no paga TLS (en [46] se midió que con TLS cae a ~15 fps a 704x480):
  lo termina el túnel;
- la placa no queda expuesta a internet.

Cualquier video que lea ffmpeg pasa por la misma normalización del clip de
arriba (recorte a 20 s, 352x288 con letterbox o pillarbox, hasta 30 fps:
60 → 30, sin matrices). Así el decoder siempre trabaja en el régimen medido.
Probado con un .mov H.264 de 30 s con audio (→ 20 s, 24 fps, 49.3 fps en la
placa, MAD 0.083), un video vertical de 60 fps (→ pillarbox a 30 fps, MAD
0.017) y un archivo basura (error claro).

Es un servicio público, así que lleva: un decode a la vez con cola visible;
uploads de hasta 64 MB; 12 decodes cada 10 minutos por dirección (detrás del
Funnel se toma `X-Forwarded-For`, verificado que trae la IP real del
visitante); CORS sólo para el origen de la página; ffmpeg restringido a
archivos locales (`-protocol_whitelist file`, para que un playlist subido no
lo haga ir a buscar URLs); nada se guarda; sin endpoint de reset. A minutos de
publicada, la URL ya recibía pedidos de escáneres: las URLs del Funnel
aparecen en los logs públicos de certificados.

## Lo que salió mal al llevarla a internet

La primera versión mandaba cada cuadro como JPEG a medida que salía de la
placa, y el navegador reproducía apenas tenía 12. Desde la LAN, 2.1x tiempo
real. Desde un escritorio remoto, el usuario vio **1.58x en un clip, 0.9x en
el otro y 0.2x en modo sin pérdida**. Tres causas, de menor a mayor gravedad:

1. **El reproductor arrancaba demasiado pronto.** Con la red por debajo del
   tiempo real, empezar a los 12 cuadros garantiza trabarse.
2. **El JPEG pesaba más que el video original.** El MPEG-2 de entrada es
   1.5 Mbit/s; los cuadros decodificados en JPEG calidad 90 son ~3.7 Mbit/s (el
   puente) y ~4.0 Mbit/s (la batalla) a 24 fps, y en crudo (I420) 29 Mbit/s. Se
   estaba mandando por internet entre 2.5 y 20 veces más que el video
   comprimido. Por eso el clip con más movimiento rendía peor.
3. **La página medía la red y lo presentaba como el FPGA.** El protocolo v1
   tiene control de flujo: si el cliente no consume, el daemon congela el
   decoder (es una propiedad buscada, para no perder cuadros). El relay
   consumía al ritmo al que podía escribirle al navegador, así que con un
   visitante lento la placa decodificaba a la velocidad de la red de ese
   visitante. El "0.9x del FPGA" que mostraba la página era la red; la placa
   podía ir a 2x.

El camino de red, medido: la entrada pública del Funnel más cercana está en
**Nueva York** (NetActuate, ~176 ms de RTT desde acá). Un visitante en
Argentina va a NY, de NY a la PC en Argentina y vuelta. Por ese camino se
midieron 5.6–7 Mbit/s con JPEG y ~19 Mbit/s en crudo, contra ~60 que pedía el
crudo sin pacing.

Una trampa para medirlo: desde la misma PC, `*.ts.net` resuelve a la tailnet
(100.x), no al camino público. Las mediciones "por el Funnel" de la primera
versión en realidad iban por la tailnet y no lo detectaron. Además, Chrome
bloquea que una página pública le hable a esa dirección (Local Network Access).
Para probar como un visitante hay que forzar la IP pública del Funnel
(`dig @8.8.8.8`, `--host-resolver-rules` en Chrome).

## Las correcciones

**1. La placa no espera a la red.** El relay vacía la placa a máxima velocidad
en memoria con un hilo productor (MAD contra la referencia, compresión y
encolado) y manda desde la cola al ritmo de la red. La placa queda libre para
el siguiente visitante apenas termina de decodificar, no cuando termina la red
del anterior. El progreso del decoder va por un canal aparte
(`GET /api/progress`): dentro del mismo flujo llegaba unos 14 s tarde, encolado
detrás de megabytes en los buffers del socket, del túnel y del navegador. La
página muestra dos números separados, la tasa de la placa y la de llegada, y si
el límite fue la red lo dice. Con un cliente limitado a 2.4 Mbit/s, la placa
decodifica en 9.7 s (49.6 fps) aunque la red tarde 33 s.

**2. Buffer calculado.** Con N cuadros, tasa de llegada r y frame rate f, para
reproducir desde el cuadro p sin cortes hace falta tener cargados
(N − p)(1 − r/f) cuadros (con 15% de margen y un mínimo de 12). Es lo que hace
cualquier reproductor de video, y la página lo muestra ("tu conexión trae
0.60x tiempo real: cargando 7 s de buffer…").

**3. Un códec de transporte.** El relay recomprime el I420 de la placa, después
de medirlo, con x264 (Constrained Baseline 3.0, CRF 21, GOP de medio segundo)
en MP4 fragmentado, y el navegador lo reproduce con Media Source
(ManagedMediaSource en iOS 17+). JPEG queda como alternativa, y como respaldo
para navegadores sin MSE.

| clip | JPEG q90 | H.264 | H.264 contra la salida del FPGA |
|---|---|---|---|
| puente | ~3.7 Mbit/s | **0.50 Mbit/s** | PSNR-Y 43.3 dB (mín. 40.2) |
| batalla | ~4.0 Mbit/s | **0.85 Mbit/s** | PSNR-Y 39.3 dB (mín. 35.1) |

(Una primera medición con el filtro `psnr` de ffmpeg dio 20.8 dB en la batalla
por un desfase de timestamps; comparando cuadro por cuadro, por índice, son
los 39.3 dB de la tabla.)

Las métricas que muestra la página (MAD y error pico contra libavcodec) se
calculan siempre sobre el I420 crudo que salió del decoder, antes de cualquier
recompresión. Lo que se ve está recomprimido; lo que se mide, no.

## Resultados después de las correcciones

Chrome headless con la red emulada (CDP `emulateNetworkConditions`):

| caso | placa | llegada | arranque | cortes |
|---|---|---|---|---|
| JPEG, batalla, 2.4 Mbit/s | 2.11x | 0.60x | 15 s de buffer | 0 |
| H.264, batalla, 2.4 Mbit/s | 2.09x | 2.00x | 1.5 s | 0 |
| H.264, batalla, 1 Mbit/s | 2.06x | 1.12x | 1.5 s | 0 |
| H.264, página publicada, por la IP pública del Funnel (NY), 2.4 Mbit/s | 2.02–2.05x | 1.98–2.01x | 2.3 s | 0 |

Con H.264 el techo vuelve a ser el decoder, no la red. El modo sin pérdida
(~30 Mbit/s a tiempo real) por internet no llega; con el buffer se reproduce
fluido después de esperar.

## Lectura

- **Lo que demuestra la demo sobre el decoder:** en CIF, la placa decodifica a
  2x tiempo real con salida prácticamente idéntica a la referencia (MAD < 0.2,
  pico 3), sostenido sobre material real y sobre video arbitrario normalizado.
- **La lección de diseño:** el control de flujo de punta a punta del protocolo
  es correcto para el producto (nunca se pierde un cuadro), pero acopla la
  tasa del decoder a la del consumidor más lento de la cadena. Si se quiere
  medir o mostrar el decoder, el que consume de la placa tiene que hacerlo a
  máxima velocidad, y el ritmo de entrega se resuelve después, con buffer.
- **Los cuadros decodificados no son lo que conviene mandar por internet:**
  pesan entre 2.5 y 20 veces el video comprimido. Para una demo remota, la
  salida del decoder se mide en crudo y se transporta recomprimida.
- **Medir desde el lugar equivocado engaña:** desde la propia PC, el "camino
  público" del túnel era la tailnet.

## Operación

- Relay: servicio systemd de usuario `live-relay` (`demo/live-relay.service`),
  con linger habilitado para que arranque sin sesión abierta. Usa un venv de
  Python 3.11 con Pillow y numpy (el `python3` del host es 3.6). El token y los
  clips precargados están en `~/.local/share/mpeg2fpga-relay/`. Logs:
  `journalctl _SYSTEMD_USER_UNIT=live-relay.service`.
- Funnel: `tailscale funnel --bg 8000` persiste solo.
- La demo necesita la PC y la placa prendidas. Si no lo están, la página dice
  "apagada" y queda la grabación verificada.
- Capturas para el informe: `tools/demo-clip/capture_screenshots.js`; hay que
  regenerarlas con cada bitstream nuevo.
