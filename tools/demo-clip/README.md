# Demo: clip en tiempo real

La página de la demo (https://esbon125.github.io/tandem/, rama `gh-pages`):
un fragmento de *Tears of Steel* en MPEG-2 352x288 a 24 fps, decodificado por
el FPGA, junto con la comparación contra el decodificador de referencia y lo
medido.

## Demo en vivo

La página tiene arriba una demo en vivo: clips precargados o un video propio,
decodificados por la placa en el momento. La página es estática (GitHub Pages);
el backend es `demo/live_relay.py`, en una PC al lado de la placa, publicado
con Tailscale Funnel en https://mpeg2fpga.tail5099f3.ts.net (la URL está en
`site/index.html`; `?backend=URL` en la página la cambia para probar).

```
navegador ──HTTPS──► Tailscale Funnel ──► live_relay.py (PC) ──LAN, token──► mpeg2fpgad (placa)
```

El relay normaliza cualquier video que lea ffmpeg al régimen medido acá
(MPEG-2 352x288, hasta 30 fps, primeros 20 s, sin matrices cargadas), lo
decodifica en la placa a máxima velocidad (nunca al ritmo de la red: el
control de flujo del protocolo congelaría el decoder y la página mediría la
conexión del visitante como si fuera la FPGA), compara cada cuadro crudo contra
libavcodec y recién después lo recomprime para el viaje: H.264 en MP4
fragmentado por Media Source (por defecto, 0.5-0.9 Mbit/s, PSNR-Y 39-43 dB
contra la salida de la FPGA), JPEG (~4 Mbit/s) o I420 sin pérdida (~30 Mbit/s).
La página muestra aparte la tasa de la placa (por `/api/progress`) y la de
llegada, y carga un buffer de (N - p)(1 - r/f) cuadros antes de reproducir
para no trabarse. Un decode a la vez con cola visible, uploads de hasta 64 MB,
12 decodes cada 10 min por dirección, CORS solo para esbon125.github.io.
Se instala como servicio de usuario con `demo/live-relay.service` (ver el
encabezado de ese archivo). Si está apagado, la página lo dice y queda la
grabación verificada.

Medido (2026-10-13, bitstream 0.1.0+8004bc9, Chrome headless con la red
emulada): la placa a 2.06-2.11x tiempo real en todos los casos; con H.264, a
1 Mbit/s llega a 1.12x y a 2.4 Mbit/s a 2.0x, sin cortes; con JPEG a 2.4 Mbit/s
llegaba a 0.60x (15 s de buffer, sin cortes). La entrada del Funnel está en
Nueva York (~176 ms de RTT desde Argentina).

## Rearmar la página

Hace falta: ffmpeg con libx264, numpy, el dispositivo con `mpeg2fpgad`
corriendo, su token, y `mpeg2decode` compilado
(`trunk/mpeg2fpga/tools/mpeg2dec`, rama `hardware_development`).

```sh
# la fuente, UNA sola descarga: el servidor de Blender corta con 429 (Cloudflare)
# si se le hacen varios pedidos seguidos, por ejemplo seeks de ffmpeg sobre la URL
curl -o tos_720p.mov https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov
ssh root@192.168.18.5 cat /etc/mpeg2fpgad/token > token

./build_site.sh tos_720p.mov 192.168.18.5 token \
    <checkout de hardware_development>/trunk/mpeg2fpga/tools/mpeg2dec/mpeg2decode out/
```

`out/` queda con `index.html` + `media/`, y se copia tal cual a la raíz de
`gh-pages`. El clip y la salida del FPGA son deterministas: los hashes de
`media/SHA256SUMS` tienen que salir iguales en cada corrida (con el mismo
bitstream).

La tasa del decodificador solo se mide en la placa, sin el daemon:

```sh
scp out/media/tos_cif.m2v root@192.168.18.5:/tmp/
ssh root@192.168.18.5 'systemctl stop mpeg2fpgad &&
    python3 /root/webserver/bench_decode.py /tmp/tos_cif.m2v --reps 3;
    systemctl start mpeg2fpgad'
```

Las cifras de `site/index.html` están escritas a mano: si cambia el bitstream,
actualizarlas con lo que den `bench_decode.py` y `build_site.sh`.

## Piezas

| | |
|---|---|
| `make_clip.sh` | fuente → `tos_cif.m2v`; falla si el sequence header carga matrices de cuantización (así es el clip publicado) |
| `capture_clip.py` | decodifica por el daemon con el cliente (`api/python`), guarda I420 y mide fps de punta a punta |
| `compare_clip.py` | MAD, error pico y PSNR por cuadro contra la salida de `mpeg2decode -o0` |
| `make_media.sh` | videos H.264 para el navegador: `fpga.mp4` y `compare.mp4` (FPGA, referencia, diferencia x32) |
| `site/index.html` | la página (demo en vivo + resultado grabado) |

## Medido (bitstream 0.1.0+918dde0, 2026-10-22)

- decodificador: 53.7 fps (±0.2, 3 corridas); el stream es de 24 fps
- punta a punta por red: 49.7–50.9 fps en 3 corridas, todas idénticas byte a byte
- contra `mpeg2decode`: MAD medio 0.0096, máximo 0.018, pico 3, PSNR-Y ≥ 64.8 dB

Con 0.1.0+8004bc9 (2026-10-13) el MAD medio era 0.073: el núcleo original
redondeaba mal el promedio de predicciones de las imágenes B (bitácora 50).

## Licencia del contenido

*Tears of Steel* © Blender Foundation | mango.blender.org, CC BY 3.0. El
`copyright.txt` del sitio de descarga menciona CC BY-ND, pero solo para la banda
sonora, que el clip no usa.
