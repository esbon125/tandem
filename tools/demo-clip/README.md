# Demo: clip en tiempo real

La página de la demo (https://esbon125.github.io/tandem/, rama `gh-pages`):
un fragmento de *Tears of Steel* en MPEG-2 352x288 a 24 fps, decodificado por
el FPGA, junto con la comparación contra el decodificador de referencia y lo
medido.

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
| `make_clip.sh` | fuente → `tos_cif.m2v`; falla si el sequence header carga matrices de cuantización (el núcleo las aplica mal) |
| `capture_clip.py` | decodifica por el daemon con el cliente (`api/python`), guarda I420 y mide fps de punta a punta |
| `compare_clip.py` | MAD, error pico y PSNR por cuadro contra la salida de `mpeg2decode -o0` |
| `make_media.sh` | videos H.264 para el navegador: `fpga.mp4` y `compare.mp4` (FPGA, referencia, diferencia x32) |
| `site/index.html` | la página |

## Medido (bitstream 0.1.0+8004bc9, 2026-10-13)

- decodificador: 53.6 fps (±0.9, 3 corridas); el stream es de 24 fps
- punta a punta por red: 49.8–51.5 fps en 5 corridas, todas idénticas byte a byte
- contra `mpeg2decode`: MAD medio 0.073, máximo 0.162, pico 3, PSNR-Y ≥ 55.8 dB

## Licencia del contenido

*Tears of Steel* © Blender Foundation | mango.blender.org, CC BY 3.0. El
`copyright.txt` del sitio de descarga menciona CC BY-ND, pero solo para la banda
sonora, que el clip no usa.
