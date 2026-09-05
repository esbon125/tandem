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
    python3 capture_framestore.py STREAM [-o OUTPUT.bin]

Writes OUTPUT.bin (12 MiB) and OUTPUT.txt next to it. Copy both to the host and

    python3 framecmp.py ref STREAM -o ref/
    python3 framecmp.py compare OUTPUT.bin ref/
"""
import argparse
import hashlib
import os
import sys
import time

sys.path.insert(0, "/root/webserver")

from decoder_push import PAGE_OFFSET
from dma_push import (DmaPusher, REG_DMA_ADDR, REG_DMA_LEN, REG_DMA_CTRL,
                      STAGE_OFFSET, sync_for_device)
from ddr_region import DDRRegion, STAGING_DEVICE, FRAMESTORE_DEVICE
from framestore import (WIDTH_Y, WIDTH_C, OSD_WORD, FRAMESTORE_BYTES,
                        macroblocks)

REG = lambda a: PAGE_OFFSET + a * 4
REG_STATUS, REG_SIZE, REG_DISP_SIZE, REG_FRAME_RATE = 0x01, 0x02, 0x03, 0x04

STATUS_ERROR, STATUS_FRAME_END, STATUS_WATCHDOG = 1 << 0, 1 << 2, 1 << 7


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
    args = ap.parse_args()

    data = open(args.stream, "rb").read()
    print("stream %s: %d bytes" % (args.stream, len(data)))

    with DmaPusher() as p, DDRRegion(FRAMESTORE_DEVICE) as fs:
        # start from a known state: core off, framestore poisoned so that
        # "never written" is distinguishable from "reconstructed to mid-grey".
        p.set_core_enable(False)
        time.sleep(0.3)
        poison = b"\xEE" * (1 << 20)
        for off in range(0, FRAMESTORE_BYTES, len(poison)):
            fs.write(off, poison)
        p.set_core_enable(True)
        time.sleep(0.5)
        p._read_reg(REG(REG_STATUS))            # clear sticky status

        with DDRRegion(STAGING_DEVICE) as st:
            st.write(STAGE_OFFSET, data)
        sync_for_device(len(data))
        p._write_reg(REG_DMA_ADDR, STAGE_OFFSET)
        p._write_reg(REG_DMA_LEN, len(data))
        t0 = time.time()
        p._write_reg(REG_DMA_CTRL, 1)
        status = p.dma_status()
        while not status["done"] and time.time() - t0 < 10.0:
            status = p.dma_status()
        print("DMA: %s in %.3f s" % (status, time.time() - t0))

        # Let the decoder run, accumulating sticky status, until the framestore
        # stops changing. This is the hardware counterpart of mem_ctl.v's
        # settle wait: dumping while reconstruction is still in flight yields a
        # torn frame, which then reads as a decoder bug.
        sticky = 0
        previous, stable_since, t0 = None, None, time.time()
        while time.time() - t0 < args.settle_timeout:
            time.sleep(0.25)
            sticky |= p._read_reg(REG(REG_STATUS))
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
        print("framestore %s after %.1f s"
              % ("settled" if settled else "STILL CHANGING", time.time() - t0))

        size = p._read_reg(REG(REG_SIZE))
        disp = p._read_reg(REG(REG_DISP_SIZE))
        rate = p._read_reg(REG(REG_FRAME_RATE))
        width, height = (size >> 16) & 0x3FFF, size & 0x3FFF
        print("SIZE      = %d x %d" % (width, height))
        print("DISP_SIZE = %d x %d" % ((disp >> 16) & 0x3FFF, disp & 0x3FFF))
        print("STATUS sticky = 0x%04x  error=%d frame_end=%d watchdog=%d"
              % (sticky, bool(sticky & STATUS_ERROR), bool(sticky & STATUS_FRAME_END),
                 bool(sticky & STATUS_WATCHDOG)))

        if width == 0 or height == 0:
            raise SystemExit("SIZE reads 0 -- the decoder never parsed a sequence header")

        with open(args.out, "wb") as fp:
            for off in range(0, FRAMESTORE_BYTES, 1 << 20):
                fp.write(fs.read(off, 1 << 20))

    meta = os.path.splitext(args.out)[0] + ".txt"
    with open(meta, "w") as fp:
        fp.write("# mpeg2fpga raw framestore dump\n")
        fp.write("source hardware\n")
        fp.write("stream %s\n" % os.path.basename(args.stream))
        fp.write("horizontal_size %d\n" % width)
        fp.write("vertical_size %d\n" % height)
        fp.write("display_horizontal_size %d\n" % ((disp >> 16) & 0x3FFF))
        fp.write("display_vertical_size %d\n" % (disp & 0x3FFF))
        mb_width, mb_height = macroblocks(width, height)
        fp.write("mb_width %d\n" % mb_width)
        fp.write("mb_height %d\n" % mb_height)
        fp.write("frame_rate 0x%04x\n" % rate)
        fp.write("status_sticky 0x%04x\n" % sticky)
        fp.write("settled %d\n" % int(settled))
        fp.write("base_word_address 0\n")
        fp.write("word_count %d\n" % OSD_WORD)
        fp.write("word_bytes 8\n")
        fp.write("byteorder little\n")

    print("wrote %s (%d bytes) and %s"
          % (args.out, os.path.getsize(args.out), meta))


if __name__ == "__main__":
    main()
