#!/bin/sh
# Arma la página de la demo de punta a punta: clip, decodificación en el
# dispositivo, referencia, comparación y videos.
#
#   build_site.sh tears_of_steel_720p.mov HOST TOKEN_FILE MPEG2DECODE OUTDIR
#
# MPEG2DECODE es trunk/mpeg2fpga/tools/mpeg2dec/mpeg2decode (rama
# hardware_development). OUTDIR termina con index.html + media/, listo para
# copiar a la rama gh-pages. Las cifras de index.html están escritas a mano:
# si cambian las mediciones (stdout de este script y bench_decode.py en la
# placa, ver README.md), actualizarlas ahí.
set -eu
src=$1; host=$2; token=$3; mpeg2decode=$4; out=$5
here=$(cd "$(dirname "$0")" && pwd)
work=$out/.work
mkdir -p "$out/media" "$work/ref"
out=$(cd "$out" && pwd); work=$out/.work

"$here/make_clip.sh" "$src" "$out/media/tos_cif.m2v"
python3 "$here/capture_clip.py" --host "$host" --token-file "$token" \
    --json "$out/media/e2e_run.json" "$out/media/tos_cif.m2v" "$work/fpga.yuv"
# corre dentro de $work: además de f%d deja buffers internos frame_* en el cwd
(cd "$work" && "$mpeg2decode" -b "$out/media/tos_cif.m2v" -o0 ref/f%d -f > /dev/null 2>&1)
python3 "$here/compare_clip.py" --width 352 --height 288 \
    --ref-out "$work/ref.yuv" --json "$out/media/framecmp.json" \
    "$work/ref" "$work/fpga.yuv"
"$here/make_media.sh" "$work/fpga.yuv" "$work/ref.yuv" "$out/media"
(cd "$out/media" && sha256sum tos_cif.m2v) > "$out/media/SHA256SUMS"
(cd "$work" && sha256sum fpga.yuv ref.yuv) >> "$out/media/SHA256SUMS"
cp "$here/site/index.html" "$out/"
rm -rf "$work"
echo "listo: $out"
