#!/usr/bin/env python3
"""Decode a stream and read every picture the moment its interrupt arrives.

Hardware check for the 2026-10-08 bitstream (protocol v1 groundwork): the
picture-ready interrupt (/dev/mpeg2fpga, see driver/mpeg2fpga/mpeg2fpga_uapi.h)
and chunked DMA (DMA_CTRL no_pad). It is also the shape the daemon's capture
loop will take: no fingerprint polling, the driver says which frame buffer
holds the next picture in display order.

    python3 picture_events.py STREAM [--chunks N] [-o OUT]

--chunks N splits the stream into N DMA transfers, all but the last started
with no_pad, so the decoder must see one continuous stream. OUT.bin gets the
raw planes (native framestore layout, as framestore.PlaneGeometry.read returns
them) of every picture in arrival order and OUT.json the events and geometry,
for tools/regress's host-side check against the reference decoder.
"""
import argparse
import json
import os
import select
import struct
import sys
import threading
import time

sys.path.insert(0, "/root/webserver")

import decoder_control
import elementary_stream
import framestore
import trick_mode
from ddr_region import DDRRegion, FRAMESTORE_DEVICE, STAGING_DEVICE
from dma_push import STAGE_OFFSET, sync_for_device

EVENT = struct.Struct("<QIHBB")           # struct mpeg2fpga_event
EVENT_OVERRUN, EVENT_LOST = 1, 2
QUIET_S = 2.0                             # no event this long after the last DMA: done


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("--chunks", type=int, default=1)
    ap.add_argument("--unaligned", action="store_true",
                    help="split at arbitrary byte offsets (reproduces the alignment bug)")
    ap.add_argument("-o", "--out", default="/tmp/picture_events")
    args = ap.parse_args()

    data = open(args.stream, "rb").read()
    seq = elementary_stream.parse(data)
    geoms = [framestore.PlaneGeometry(f, seq.width, seq.height)
             for f in range(framestore.NUM_FRAMES)]

    control = decoder_control.open_control()
    print("backend %s, build %s" % (control.backend, control.build()))
    captures = []
    out_bin = open(args.out + ".bin", "wb")

    with DDRRegion(FRAMESTORE_DEVICE) as fs:
        if not control.is_enabled():
            control.set_enable(True)
            time.sleep(0.3)
        control.set_freeze(False)
        control.set_source_select(trick_mode.SOURCE_LAST_DECODED)
        control.flush_vbuf()
        poison = b"\xEE" * (1 << 20)
        for off in range(0, framestore.FRAMESTORE_BYTES, len(poison)):
            fs.write(off, poison)
        control.clear_status()

        fd = os.open("/dev/mpeg2fpga", os.O_RDONLY | os.O_NONBLOCK)
        dma_finished = threading.Event()
        last_event = [time.time()]

        def reader():
            poller = select.poll()
            poller.register(fd, select.POLLIN)
            while True:
                if dma_finished.is_set() and time.time() - last_event[0] > QUIET_S:
                    return
                if not poller.poll(100):
                    continue
                try:
                    raw = os.read(fd, EVENT.size * 8)
                except BlockingIOError:
                    continue
                for i in range(0, len(raw), EVENT.size):
                    ts, seqno, hw_count, frame, flags = EVENT.unpack_from(raw, i)
                    t_read = time.time()
                    planes = geoms[frame].read(fs)
                    for p in planes:
                        out_bin.write(p)
                    captures.append({"seq": seqno, "hw_count": hw_count, "frame": frame,
                                     "flags": flags, "timestamp_ns": ts,
                                     "read_ms": round((time.time() - t_read) * 1e3, 2),
                                     "plane_bytes": [len(p) for p in planes]})
                    last_event[0] = time.time()

        thread = threading.Thread(target=reader)
        thread.start()

        with DDRRegion(STAGING_DEVICE) as staging:
            staging.write(STAGE_OFFSET, data)
        sync_for_device(len(data))
        # chunk starts must be 8-byte aligned: stream_dma reads whole 64-bit
        # AXI beats, so an unaligned start re-sends the bytes before it
        # (found on hardware 2026-10-08). --unaligned keeps the old split.
        bounds = [len(data) * i // args.chunks for i in range(args.chunks + 1)]
        if not args.unaligned:
            bounds = [b & ~7 for b in bounds[:-1]] + [len(data)]
        t0 = time.time()
        for i in range(args.chunks):
            start, end = bounds[i], bounds[i + 1]
            last = i == args.chunks - 1
            control.dma_start(STAGE_OFFSET + start, end - start, last=last)
            while not control.dma_status()["done"]:
                time.sleep(0.002)
        dma_seconds = time.time() - t0
        last_event[0] = max(last_event[0], time.time())
        dma_finished.set()
        thread.join()
        os.close(fd)
        status = control.status()

    out_bin.close()
    gaps = sum(1 for a, b in zip(captures, captures[1:])
               if (b["hw_count"] - a["hw_count"]) & 0xFFFF != 1)
    summary = {
        "stream": os.path.basename(args.stream), "chunks": args.chunks,
        "width": seq.width, "height": seq.height,
        "pictures_in_stream": len(seq.pictures), "events": len(captures),
        "hw_count_gaps": gaps,
        "overrun": sum(1 for c in captures if c["flags"] & EVENT_OVERRUN),
        "lost": sum(1 for c in captures if c["flags"] & EVENT_LOST),
        "frames_seen": sorted({c["frame"] for c in captures}),
        "dma_seconds": round(dma_seconds, 3),
        "error": bool(status.get("error")), "watchdog": bool(status.get("watchdog")),
        "build": control.build(),
    }
    json.dump({"summary": summary, "events": captures}, open(args.out + ".json", "w"))
    print("SUMMARY " + json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
