"""Push a stream and capture the decoder's framestore, for tools/framecmp.

The output is deliberately the same on-disk format bench/iverilog/mem_ctl.v
writes in simulation -- a raw little-endian dump of memory words
[FRAME_0_Y, OSD) plus a metadata sidecar -- so the same host-side extractor
(trunk/mpeg2fpga/tools/framecmp/framecmp.py) reads sim and hardware captures
with one code path. That matters: the extraction rules are the part that was
wrong before (pixels are signed and offset by -128, and the eight pixels of a
64-bit word appear reversed in a little-endian dump), and doing it once means
they get validated against the reference decoder in simulation and then reused
here unchanged.

Usage:
    python3 capture_framestore.py STREAM [-o OUTPUT.bin] [--no-reset] [--json]

Writes OUTPUT.bin (12 MiB) and OUTPUT.txt next to it. Copy both to the host and

    python3 framecmp.py ref STREAM -o ref/
    python3 framecmp.py compare OUTPUT.bin ref/

Registers go through decoder_control, which prefers the kernel driver's sysfs
interface and falls back to raw UIO -- either overlay can be applied on the
board (they are mutually exclusive; see driver/mpeg2fpga/tools/), and this
script does not need to know which.
"""
import argparse
import hashlib
import json
import os
import sys
import time

sys.path.insert(0, "/root/webserver")

import decoder_control
import trick_mode
from dma_push import STAGE_OFFSET, sync_for_device
from ddr_region import DDRRegion, STAGING_DEVICE, FRAMESTORE_DEVICE
from framestore import OSD_WORD, FRAMESTORE_BYTES


def digest(region):
    """Cheap fingerprint of the framestore: enough to tell if it is still moving."""
    h = hashlib.sha1()
    for word in range(0, OSD_WORD, 4096):       # sample every 32 kbyte
        h.update(region.read(word * 8, 256))
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stream")
    ap.add_argument("-o", "--out", default="hw_framestore.bin")
    ap.add_argument("--settle-timeout", type=float, default=30.0,
                    help="give up waiting for the framestore to stop changing")
    ap.add_argument("--no-reset", action="store_true",
                    help="keep the core running and drop the previous stream "
                         "with flush_vbuf, the way a player switches streams, "
                         "instead of pulsing core enable")
    ap.add_argument("--json", action="store_true",
                    help="end with one 'RESULT {...}' line for tools/regress")
    args = ap.parse_args()
    result = {"stream": os.path.basename(args.stream), "reset": not args.no_reset}

    def report(**fields):
        result.update(fields)
        if args.json:
            print("RESULT " + json.dumps(result, sort_keys=True))
            sys.stdout.flush()

    data = open(args.stream, "rb").read()
    print("stream %s: %d bytes" % (args.stream, len(data)))

    with decoder_control.open_control() as control, \
         DDRRegion(FRAMESTORE_DEVICE) as fs:
        print("backend: %s" % control.backend)

        # start from a known state: framestore poisoned so that "never
        # written" is distinguishable from "reconstructed to mid-grey". By
        # default the core is held off meanwhile; with --no-reset it keeps
        # running (idle, between streams), and the previous stream's tail is
        # dropped with flush_vbuf -- the path a corrupted stream must not
        # have broken, which is what tools/regress checks with it.
        poison = b"\xEE" * (1 << 20)
        if args.no_reset:
            control.set_freeze(False)
            control.set_source_select(trick_mode.SOURCE_LAST_DECODED)
            control.flush_vbuf()
            for off in range(0, FRAMESTORE_BYTES, len(poison)):
                fs.write(off, poison)
        else:
            control.set_enable(False)
            time.sleep(0.3)
            for off in range(0, FRAMESTORE_BYTES, len(poison)):
                fs.write(off, poison)
            control.set_enable(True)
            time.sleep(0.5)
        control.clear_status()

        with DDRRegion(STAGING_DEVICE) as st:
            st.write(STAGE_OFFSET, data)
        sync_for_device(len(data))
        t0 = time.time()
        control.dma_start(STAGE_OFFSET, len(data))
        status = control.dma_status()
        while not status["done"] and time.time() - t0 < 10.0:
            status = control.dma_status()
        dma_seconds = time.time() - t0
        print("DMA: %s in %.3f s" % (status, dma_seconds))

        # Let the decoder run, accumulating sticky status, until the framestore
        # stops changing. This is the hardware counterpart of mem_ctl.v's
        # settle wait: dumping while reconstruction is still in flight yields a
        # torn frame, which then reads as a decoder bug.
        sticky = {}
        previous, stable_since, t0 = None, None, time.time()
        while time.time() - t0 < args.settle_timeout:
            time.sleep(0.25)
            # Both backends accumulate internally (the driver's IRQ handler
            # for sysfs, an explicit sticky word here for UIO -- see
            # decoder_control.py), so each call already reflects everything
            # since clear_status() above, not just this one poll.
            sticky = control.status()
            now = digest(fs)
            if now == previous:
                if stable_since is None:
                    stable_since = time.time()
                elif time.time() - stable_since > 1.0:
                    break
            else:
                stable_since = None
            previous = now
        settled = stable_since is not None
        # time to the last change, not to the end of the settle wait
        settle_seconds = (stable_since if settled else time.time()) - t0
        print("framestore %s after %.1f s"
              % ("settled" if settled else "STILL CHANGING", time.time() - t0))

        geom = control.geometry()
        width, height = geom["width"], geom["height"]
        print("SIZE      = %d x %d" % (width, height))
        print("DISP_SIZE = %d x %d" % (geom["display_width"], geom["display_height"]))
        print("STATUS sticky = %s  error=%d frame_end=%d watchdog=%d"
              % (sticky, bool(sticky.get("error")), bool(sticky.get("frame_end")),
                 bool(sticky.get("watchdog"))))

        result.update(dma_done=bool(status["done"]), dma_seconds=round(dma_seconds, 3),
                      settled=settled, settle_seconds=round(settle_seconds, 3),
                      width=width, height=height,
                      sticky=sticky.get("sticky", 0), error=bool(sticky.get("error")),
                      watchdog=bool(sticky.get("watchdog")), dump=None)
        if width == 0 or height == 0:
            report()
            raise SystemExit("SIZE reads 0 -- the decoder never parsed a sequence header")

        h = hashlib.sha1()
        with open(args.out, "wb") as fp:
            for off in range(0, FRAMESTORE_BYTES, 1 << 20):
                chunk = fs.read(off, 1 << 20)
                h.update(chunk)
                fp.write(chunk)

    meta = os.path.splitext(args.out)[0] + ".txt"
    with open(meta, "w") as fp:
        fp.write("# mpeg2fpga raw framestore dump\n")
        fp.write("source hardware\n")
        fp.write("stream %s\n" % os.path.basename(args.stream))
        fp.write("horizontal_size %d\n" % width)
        fp.write("vertical_size %d\n" % height)
        fp.write("display_horizontal_size %d\n" % geom["display_width"])
        fp.write("display_vertical_size %d\n" % geom["display_height"])
        fp.write("mb_width %d\n" % geom["mb_width"])
        fp.write("mb_height %d\n" % geom["mb_height"])
        fp.write("frame_rate_code %d\n" % geom["frame_rate_code"])
        fp.write("status_sticky 0x%04x\n" % sticky.get("sticky", 0))
        fp.write("settled %d\n" % int(settled))
        fp.write("base_word_address 0\n")
        fp.write("word_count %d\n" % OSD_WORD)
        fp.write("word_bytes 8\n")
        fp.write("byteorder little\n")

    print("wrote %s (%d bytes) and %s"
          % (args.out, os.path.getsize(args.out), meta))
    report(dump=args.out, sha1=h.hexdigest())


if __name__ == "__main__":
    main()
