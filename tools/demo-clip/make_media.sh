#!/bin/sh
# Videos para la página a partir de los cuadros crudos (I420, 352x288, 24 fps).
#
#   make_media.sh fpga.yuv ref.yuv site/media
#
# fpga.mp4:    la salida del FPGA tal cual (cuadro completo, SAR 12:11).
# compare.mp4: FPGA | referencia | |diferencia| x32, recortado a las 160 líneas
#              con imagen y llevado a píxeles cuadrados.
# H.264 CRF 14 porque los navegadores no reproducen MPEG-2; los cuadros
# originales se verifican con SHA256SUMS, no con estos videos.
set -eu
fpga=$1; ref=$2; out=$3
mkdir -p "$out"
R="-f rawvideo -pix_fmt yuv420p -s 352x288 -r 24"
X="-c:v libx264 -preset slow -crf 14 -pix_fmt yuv420p -movflags +faststart"
ffmpeg -hide_banner -loglevel error $R -i "$fpga" -vf setsar=12/11 $X -y "$out/fpga.mp4"
ffmpeg -hide_banner -loglevel error $R -i "$fpga" $R -i "$ref" -filter_complex \
    "[0]split[a][a2];[1]split[b][b2];[a2][b2]blend=all_mode=difference,lutyuv=y='clip(val*32,0,255)':u=128:v=128[d];[a][b][d]hstack=3,crop=iw:160:0:64,scale=iw*12/11:-2:flags=lanczos,setsar=1" \
    $X -y "$out/compare.mp4"
ffmpeg -hide_banner -loglevel error -ss 6 -i "$out/fpga.mp4" -frames:v 1 \
    -vf scale=384:288 -y "$out/poster.jpg"
