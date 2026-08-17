#!/usr/bin/env python3
"""
Fase 7b, step 1: write a visibly-animated RGBA test pattern into
/dev/udmabuf-ddr-nc-wcb0 in a loop, standing in for "the decoder just
finished a new frame" while the real decode path (Fase 7a's open SIZE=0
investigation) is still unresolved. server.py reads this same region
over mmap and streams it to the browser -- if that pipeline works with
this synthetic source, the WebSocket/canvas half of Fase 7b is proven
independently of whether real decode works.

No numpy on this board (no prebuilt riscv64 wheel, no on-device compiler
to build one, see docs/bringup Fase 7b) -- the animation is a horizontal
scroll implemented as row-slicing over a precomputed double-wide strip,
so the *entire* image is generated once at startup, and every frame after
that is just slicing, not per-pixel Python loops.
"""
import argparse
import sys
import time

from ddr_region import DDRRegion, TEST_PATTERN_DEVICE

WIDTH = 320
HEIGHT = 240
BYTES_PER_PIXEL = 4  # RGBA, matches Canvas ImageData directly
FRAME_BYTES = WIDTH * HEIGHT * BYTES_PER_PIXEL


def build_scroll_strip():
    """A (2*WIDTH) x HEIGHT RGBA image: a hue gradient across x with a
    coarse checkerboard overlay (makes misalignment/corruption obvious
    at a glance, a plain gradient can hide a one-pixel offset bug)."""
    strip_width = 2 * WIDTH
    row = bytearray(strip_width * BYTES_PER_PIXEL)
    for x in range(strip_width):
        hue6 = (x * 6 * 256 // strip_width) % (6 * 256)
        sector, frac = divmod(hue6, 256)
        if sector == 0: r, g, b = 255, frac, 0
        elif sector == 1: r, g, b = 255 - frac, 255, 0
        elif sector == 2: r, g, b = 0, 255, frac
        elif sector == 3: r, g, b = 0, 255 - frac, 255
        elif sector == 4: r, g, b = frac, 0, 255
        else: r, g, b = 255, 0, 255 - frac
        row[x * 4 + 0] = r
        row[x * 4 + 1] = g
        row[x * 4 + 2] = b
        row[x * 4 + 3] = 255

    checker = bytes(row)
    rows = []
    for y in range(HEIGHT):
        if (y // 20) % 2 == 0:
            rows.append(checker)
        else:
            # dim every other 20px band so the checkerboard is visible
            dim = bytearray(checker)
            for i in range(0, len(dim), 4):
                dim[i] = dim[i] // 2
                dim[i + 1] = dim[i + 1] // 2
                dim[i + 2] = dim[i + 2] // 2
            rows.append(bytes(dim))
    return rows, strip_width


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fps", type=float, default=15.0)
    ap.add_argument("--device", default=TEST_PATTERN_DEVICE)
    args = ap.parse_args()

    print(f"building {WIDTH}x{HEIGHT} test pattern ({FRAME_BYTES} bytes/frame)...")
    strip_rows, strip_width = build_scroll_strip()

    period = 1.0 / args.fps
    offset_px = 0
    frame_count = 0
    t_start = time.time()

    with DDRRegion(args.device) as region:
        print(f"writing to {args.device}, {args.fps} fps, Ctrl-C to stop")
        try:
            while True:
                t0 = time.time()
                frame = bytearray(FRAME_BYTES)
                row_bytes = WIDTH * BYTES_PER_PIXEL
                off_bytes = offset_px * BYTES_PER_PIXEL
                for y in range(HEIGHT):
                    src = strip_rows[y]
                    frame[y * row_bytes:(y + 1) * row_bytes] = src[off_bytes:off_bytes + row_bytes]
                region.write(0, frame)

                offset_px = (offset_px + 2) % WIDTH
                frame_count += 1
                if frame_count % (int(args.fps) * 5) == 0:
                    elapsed = time.time() - t_start
                    print(f"  {frame_count} frames written, avg {frame_count/elapsed:.1f} fps")

                dt = time.time() - t0
                if dt < period:
                    time.sleep(period - dt)
        except KeyboardInterrupt:
            print("\nstopped")


if __name__ == "__main__":
    main()
