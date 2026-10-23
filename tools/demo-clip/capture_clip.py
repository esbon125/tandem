#!/usr/bin/env python3
"""Decodifica un clip en el dispositivo por el daemon y guarda los cuadros.

    capture_clip.py --host 192.168.18.5 --token-file token tos_cif.m2v fpga.yuv \
        [--json run.json]

Escribe los cuadros en orden de presentación como I420 crudo concatenado y
mide del lado del cliente: tiempo hasta el primer cuadro y fps desde el primero
hasta el último (fps_steady), que es la tasa de punta a punta -- subida,
decodificación, conversión en la placa y bajada por red. La tasa del
decodificador solo se mide en la placa con webserver/bench_decode.py.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "api", "python", "src"))
import mpeg2fpga  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--json")
    ap.add_argument("clip")
    ap.add_argument("out")
    args = ap.parse_args()

    dev = mpeg2fpga.Device(args.host, token=open(args.token_file).read().strip(),
                           timeout=60)
    versions = dev.info().versions
    data = open(args.clip, "rb").read()
    stamps = []
    t0 = time.monotonic()
    with open(args.out, "wb") as f:
        result = dev.decode(data)
        for frame in result:
            stamps.append(time.monotonic() - t0)
            f.write(frame.y)
            f.write(frame.u)
            f.write(frame.v)
            width, height = frame.width, frame.height
    n = len(stamps)
    run = {
        "clip": os.path.basename(args.clip),
        "frames": n, "width": width, "height": height,
        "complete": result.summary.complete,
        "first_frame_s": round(stamps[0], 3),
        "total_s": round(stamps[-1], 3),
        "fps_steady": round((n - 1) / (stamps[-1] - stamps[0]), 2),
        "versions": versions,
    }
    print(json.dumps(run))
    if args.json:
        with open(args.json, "w") as f:
            json.dump(run, f, indent=1, default=str)
    return 0 if run["complete"] else 1


if __name__ == "__main__":
    sys.exit(main())
