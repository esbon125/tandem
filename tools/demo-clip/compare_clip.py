#!/usr/bin/env python3
"""Compara los cuadros del FPGA contra mpeg2decode, cuadro por cuadro.

    mpeg2decode -b tos_cif.m2v -o0 REFDIR/f%d -f
    compare_clip.py --width 352 --height 288 REFDIR fpga.yuv \
        --ref-out ref.yuv --json framecmp.json

mpeg2decode (el de trunk/mpeg2fpga/tools/mpeg2dec, con -o0) deja cada plano
como PGM ASCII: REFDIR/f<N>.y.ppm, .u.ppm, .v.ppm (además de los buffers
internos frame_*, que no se usan). Los planos u/v son Cb/Cr, igual que I420.
--ref-out arma con ellos un I420 concatenado para make_media.sh.

Métricas sobre Y+Cb+Cr: MAD y error pico por cuadro, PSNR de luma.
Necesita numpy.
"""
import argparse
import json
import math
import sys

import numpy as np


def read_pgm(path):
    tok = open(path).read().split()
    if tok[0] != "P2":
        raise ValueError(f"{path}: se esperaba PGM ASCII (P2)")
    w, h = int(tok[1]), int(tok[2])
    return np.array(tok[4:4 + w * h], np.uint8).reshape(h, w)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--ref-out")
    ap.add_argument("--json")
    ap.add_argument("ref_dir")
    ap.add_argument("fpga")
    args = ap.parse_args()

    luma = args.width * args.height
    size = luma * 3 // 2
    fpga = np.fromfile(args.fpga, np.uint8)
    if fpga.size % size:
        sys.exit(f"{args.fpga}: no es un múltiplo de {size} bytes")
    fpga = fpga.reshape(-1, size)
    ref_out = open(args.ref_out, "wb") if args.ref_out else None

    rows = []
    for i, got in enumerate(fpga):
        ref = np.concatenate([read_pgm(f"{args.ref_dir}/f{i}.{c}.ppm").ravel()
                              for c in "yuv"])
        if ref_out:
            ref_out.write(ref.tobytes())
        d = np.abs(got.astype(int) - ref)
        mse_y = float((d[:luma] ** 2).mean())
        rows.append({"frame": i, "mad": float(d.mean()), "peak": int(d.max()),
                     "psnr_y": None if mse_y == 0 else 10 * math.log10(255 ** 2 / mse_y)})

    mads = [r["mad"] for r in rows]
    psnrs = sorted(r["psnr_y"] for r in rows if r["psnr_y"] is not None)
    summary = {
        "frames": len(rows),
        "mad_mean": sum(mads) / len(mads),
        "mad_max": max(mads),
        "peak_max": max(r["peak"] for r in rows),
        "bit_exact_frames": sum(m == 0 for m in mads),
        "psnr_y_min": psnrs[0] if psnrs else None,
        "psnr_y_median": psnrs[len(psnrs) // 2] if psnrs else None,
    }
    print(json.dumps(summary))
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"summary": summary, "frames": rows}, f, indent=1)


if __name__ == "__main__":
    main()
