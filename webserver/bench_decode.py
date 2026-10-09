#!/usr/bin/env python3
"""Decode-rate benchmark: the same stream, decoded N times, timed.

What is timed is the decoder itself: from the start of the DMA to the last
write into the framestore. Before each run the framestore is poisoned and the
previous stream dropped with flush_vbuf (no core reset, the way a player
switches streams), and a cheap fingerprint of all four frame buffers is polled
in a tight loop; once nothing has changed for QUIET_S the run is over, and its
decode time is the timestamp of the last change.

Why not decode_stream.decode()'s capture_seconds, as profile_decode.py does:
that measures the capture, not the decoder. It counts a picture only when a
buffer *changes*, so decoding the same stream twice without poisoning in
between rewrites buffers with identical pictures, nothing is seen, and the run
ends on the 3 s give-up timer -- the first version of this script reported
0.6 fps for tek-5.2 that way. It also counts field pictures one by one while
the decoder writes both fields into the same buffer.

The fingerprint samples the bottom rows of every buffer densely (a picture is
written top to bottom, so its last write lands there) plus a spread over the
rest. A final picture identical to what its buffer already held (a still
scene) goes unseen and makes the run look shorter by up to that picture; the
`changes` count per run is there to sanity-check that.

Usage (on the board):
    python3 bench_decode.py STREAM [--reps N] [--json]

With --json, one 'RESULT {...}' line per run and a final 'SUMMARY {...}' line,
for tools/regress on the host.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, "/root/webserver")

import decoder_control
import elementary_stream
import framestore
import trick_mode
from ddr_region import DDRRegion, FRAMESTORE_DEVICE, STAGING_DEVICE
from dma_push import STAGE_OFFSET, sync_for_device

POISON = b"\xEE" * (1 << 20)
QUIET_S = 1.0             # >> one picture (~45 ms at 704x480), << any real stall
FIRST_WRITE_TIMEOUT_S = 10.0
RUN_TIMEOUT_S = 120.0
SPOT_BYTES = 64


def count_frames(data):
    """Coded frames: frame pictures plus pairs of field pictures.

    picture_structure is the low two bits of the third byte of the picture
    coding extension (extension id 8); 3 is a frame picture.
    """
    frames = fields = 0
    at = data.find(b"\x00\x00\x01\xb5")
    while 0 <= at < len(data) - 7:
        if data[at + 4] >> 4 == 8:
            if data[at + 6] & 3 == 3:
                frames += 1
            else:
                fields += 1
        at = data.find(b"\x00\x00\x01\xb5", at + 4)
    if frames + fields == 0:            # no extensions at all: MPEG-1
        return len(elementary_stream.parse(data).pictures), 0
    return frames + fields // 2, fields


def spots(geometry):
    """Byte offsets to fingerprint in one frame buffer's luma plane."""
    stride, rows = geometry.luma_stride, geometry.luma_rows
    base = geometry.luma_offset
    out = []
    for r in range(rows - 16, rows, 2):             # last macroblock row, densely
        for c in (0, stride // 2, stride - SPOT_BYTES):
            out.append(base + r * stride + c)
    for i in range(16):                             # and a spread over the rest
        out.append(base + (i * geometry.luma_bytes) // 16)
    return out


def fingerprint(fs, offsets):
    return b"".join(fs.read(o, SPOT_BYTES) for o in offsets)


def timed_decode(data, control, fs, buffers):
    control.set_freeze(False)
    control.set_source_select(trick_mode.SOURCE_LAST_DECODED)
    control.flush_vbuf()
    for off in range(0, framestore.FRAMESTORE_BYTES, len(POISON)):
        fs.write(off, POISON)
    control.clear_status()
    with DDRRegion(STAGING_DEVICE) as staging:
        staging.write(STAGE_OFFSET, data)
    sync_for_device(len(data))

    marks = [fingerprint(fs, b) for b in buffers]
    changes = 0
    dma_done_at = None
    t0 = time.time()
    control.dma_start(STAGE_OFFSET, len(data))
    last_change = None
    while True:
        now = time.time()
        for i, b in enumerate(buffers):
            mark = fingerprint(fs, b)
            if mark != marks[i]:
                marks[i] = mark
                last_change = time.time()
                changes += 1
        if dma_done_at is None and control.dma_status()["done"]:
            dma_done_at = now
        if last_change is None:
            if now - t0 > FIRST_WRITE_TIMEOUT_S:
                break
        elif now - last_change > QUIET_S or now - t0 > RUN_TIMEOUT_S:
            break
    status = control.status()
    return {
        "decode_seconds": round(last_change - t0, 4) if last_change else None,
        "dma_seconds": round(dma_done_at - t0, 4) if dma_done_at else None,
        "changes": changes,
        "error": bool(status.get("error")),
        "watchdog": bool(status.get("watchdog")),
        "sticky": "0x%04x" % status.get("sticky", 0),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    data = open(args.stream, "rb").read()
    name = os.path.basename(args.stream)
    frames, fields = count_frames(data)
    sequence = elementary_stream.parse(data)
    width, height = sequence.width, sequence.height
    buffers = [spots(framestore.PlaneGeometry(f, width, height))
               for f in range(framestore.NUM_FRAMES)]

    def emit(tag, fields_):
        fields_ = dict(fields_, stream=name)
        print(tag + " " + json.dumps(fields_, sort_keys=True) if args.json
              else "%s %s" % (tag, fields_))
        sys.stdout.flush()

    fps = []
    failed = 0
    control = decoder_control.open_control()
    try:
        with DDRRegion(FRAMESTORE_DEVICE) as fs:
            # a freshly programmed FPGA has core_enable 0 (see profile_decode.py);
            # enable it once, then never reset again
            if not control.is_enabled():
                control.set_enable(True)
                time.sleep(0.3)
            emit("RESULT", dict(timed_decode(data, control, fs, buffers), run="warmup"))
            for i in range(args.reps):
                r = timed_decode(data, control, fs, buffers)
                if r["decode_seconds"]:
                    r["fps"] = round(frames / r["decode_seconds"], 3)
                    fps.append(r["fps"])
                else:
                    failed += 1
                emit("RESULT", dict(r, run=i))
    finally:
        control.close()

    # no statistics module in the board's Python
    mean = sum(fps) / len(fps) if fps else 0.0
    stdev = (sum((f - mean) ** 2 for f in fps) / (len(fps) - 1)) ** 0.5 if len(fps) > 1 else 0.0
    emit("SUMMARY", {
        "width": width, "height": height,
        "frames": frames, "field_pictures": fields,
        "frame_rate": round(sequence.frame_rate, 3),
        "reps": args.reps, "failed": failed,
        "fps_mean": round(mean, 3), "fps_stdev": round(stdev, 3),
        "fps_min": min(fps) if fps else 0.0, "fps_max": max(fps) if fps else 0.0,
    })


if __name__ == "__main__":
    main()
