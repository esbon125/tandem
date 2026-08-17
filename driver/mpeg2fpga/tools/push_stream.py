#!/usr/bin/env python3
"""
Fase 7a smoke test: push an elementary stream to mpeg2fpga's new
STREAM_PUSH_ADDR APB register (index 0x10, byte offset 0x40) via a UIO
mapping, one 32-bit register write per byte. Prints VERSION/STATUS/SIZE/
DISP_SIZE before and after so a real decode can be recognized.

Setup on the board (root), using mpeg2fpga-uio.dts from this same
directory -- deliberately UIO, not the mpeg2fpga.ko driver, so this tool
can poke registers the driver doesn't expose a write path for yet:

    dtc -@ -I dts -O dtb -o mpeg2fpga-uio.dtbo mpeg2fpga-uio.dts
    mkdir /sys/kernel/config/device-tree/overlays/mpeg2fpga_uio
    cp mpeg2fpga-uio.dtbo /sys/kernel/config/device-tree/overlays/mpeg2fpga_uio/dtbo
    cat /sys/kernel/config/device-tree/overlays/mpeg2fpga_uio/status  # -> applied
    ls -l /sys/class/uio/  # find which uioN -> .../40000400.mpeg2fpga/uio/uioN

    python3 push_stream.py /dev/uioN <path-to-elementary-stream>

Cleanup: rmdir /sys/kernel/config/device-tree/overlays/mpeg2fpga_uio
(unbinds the overlay; safe to reapply the driver overlay afterward).

Gotcha that cost real debugging time (see docs/bringup Fase 7a): UIO maps
the whole page containing the device's "reg" range, not the range
itself -- register offsets here are relative to the *page-aligned*
mmap base, not to the device's own base address. The actual page-internal
offset is in /sys/class/uio/uioN/maps/map0/offset (0x400 for this
device); PAGE_OFFSET below encodes that. Get this wrong and every
register silently aliases to whatever else lives at the start of that
page -- no crash, no error, just wrong data that looks plausible.
"""
import mmap
import os
import struct
import sys
import time

UIO_PATH = sys.argv[1] if len(sys.argv) > 1 else "/dev/uio0"
STREAM_PATH = sys.argv[2]

## UIO maps the whole containing page (page-aligned base), not the "reg"
## start -- the registers live at a page-internal offset (see
## /sys/class/uio/uioN/maps/map0/offset, 0x400 here) that must be added
## back to every access. Confirmed the hard way: reads at buffer offset
## 0x00/0x04 without this were silently hitting physical 0x40000000/4,
## not our peripheral's 0x40000400/4 -- unrelated register, not our RTL.
PAGE_OFFSET = 0x400

REG_VERSION = PAGE_OFFSET + 0x00
REG_STATUS = PAGE_OFFSET + 0x04
REG_SIZE = PAGE_OFFSET + 0x08
REG_DISP_SIZE = PAGE_OFFSET + 0x0C
REG_STREAM_PUSH = PAGE_OFFSET + 0x40

MAP_LEN = 4096


def read_reg(mm, off):
    return struct.unpack_from("<I", mm, off)[0]


def write_reg(mm, off, val):
    struct.pack_into("<I", mm, off, val)


def dump_regs(mm, label):
    print(f"--- {label} ---")
    print(f"  VERSION   = 0x{read_reg(mm, REG_VERSION):08x}")
    print(f"  STATUS    = 0x{read_reg(mm, REG_STATUS):08x}")
    print(f"  SIZE      = 0x{read_reg(mm, REG_SIZE):08x}")
    print(f"  DISP_SIZE = 0x{read_reg(mm, REG_DISP_SIZE):08x}")


def main():
    with open(STREAM_PATH, "rb") as f:
        data = f.read()
    # ISO/IEC 13818-2 sequence_end_code padding, per doc/mpeg2fpga.txt sec 1.3
    data += bytes([0x00, 0x00, 0x01, 0xB7] * 8)
    print(f"stream: {STREAM_PATH} ({len(data)} bytes incl. padding)")

    fd = os.open(UIO_PATH, os.O_RDWR | os.O_SYNC)
    mm = mmap.mmap(fd, MAP_LEN, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0)

    dump_regs(mm, "before")

    t0 = time.time()
    for i, b in enumerate(data):
        write_reg(mm, REG_STREAM_PUSH, b)
    elapsed = time.time() - t0
    print(f"pushed {len(data)} bytes in {elapsed:.3f}s ({len(data)/elapsed:.0f} B/s)")

    dump_regs(mm, "after")

    mm.close()
    os.close(fd)


if __name__ == "__main__":
    main()
