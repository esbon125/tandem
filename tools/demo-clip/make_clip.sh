#!/bin/sh
# Codifica el fragmento de Tears of Steel que usa la demo como MPEG-2 MP@ML.
#
#   make_clip.sh tears_of_steel_720p.mov tos_cif.m2v [INICIO_S]
#
# INICIO_S es el segundo de la película donde arranca el fragmento de 20 s
# (por defecto 18: la ciudad y el puente; la demo en vivo usa también 458,
# la batalla con los robots, con mucho más movimiento).
#
# La fuente es https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov
# (CC BY 3.0). Bajarla UNA vez con curl: el servidor está detrás de Cloudflare y
# responde 429 si se le hacen varios seeks por HTTP (ffmpeg -ss sobre la URL).
#
# 352x288 con letterbox (la película es 2.39:1; 160 líneas de imagen con
# píxeles 12:11), 24 fps nativos para no duplicar cuadros, GOP corto, y sin
# matrices de cuantización cargadas: ffmpeg no las escribe salvo que se le
# pidan. El chequeo quedó de cuando se creía que el núcleo las aplicaba mal
# (era la referencia, bitácora 49); se mantiene para que el clip siga siendo
# el publicado.
set -eu
src=$1; out=$2; start=${3:-18}
ffmpeg -hide_banner -loglevel error -ss "$start" -t 20 -i "$src" -an \
    -vf "scale=352:160:flags=lanczos,pad=352:288:0:64,setsar=12/11" \
    -pix_fmt yuv420p -c:v mpeg2video -g 12 -bf 2 \
    -b:v 1500k -maxrate 2500k -bufsize 1835008 -aspect 4:3 \
    -f mpeg2video -y "$out"
python3 - "$out" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
i = d.find(b"\x00\x00\x01\xb3")
flags = d[i + 11]
if flags & 2 or flags & 1:
    sys.exit("el sequence header carga una matriz de cuantización")
print(sys.argv[1], len(d), "bytes, sin matrices cargadas")
PY
