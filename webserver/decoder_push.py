"""
Fase 7b (APB wiring): push an elementary stream to mpeg2fpga's
STREAM_PUSH_ADDR APB register over the UIO diagnostic mapping, reusing
the exact register layout and page-offset fix proven in Fase 7a's
driver/mpeg2fpga/tools/push_stream.py -- see that file's docstring for
the full UIO page-offset gotcha writeup.

This module only talks to the register file; it does not touch the
device-tree overlay lifecycle. The mpeg2fpga_uio overlay (see
driver/mpeg2fpga/tools/mpeg2fpga-uio.dts) must already be applied on the
board -- ensure_overlay_applied() checks for it and raises a clear error
instead of silently mmap'ing the wrong page if it's missing.
"""
import glob
import mmap
import os
import struct

UIO_NAME = "mpeg2fpga_diag"

# See push_stream.py: UIO maps the whole page containing the device's
# "reg" range, not the range itself -- every offset must add this back.
PAGE_OFFSET = 0x400

REG_VERSION = PAGE_OFFSET + 0x00
REG_STATUS = PAGE_OFFSET + 0x04
REG_SIZE = PAGE_OFFSET + 0x08
REG_DISP_SIZE = PAGE_OFFSET + 0x0C
REG_STREAM_PUSH = PAGE_OFFSET + 0x40

MAP_LEN = 4096

# ISO/IEC 13818-2 sequence_end_code padding, per doc/mpeg2fpga.txt sec 1.3
SEQUENCE_END_PADDING = bytes([0x00, 0x00, 0x01, 0xB7] * 8)


class OverlayNotApplied(RuntimeError):
    pass


def find_uio_device(name=UIO_NAME):
    for name_path in glob.glob("/sys/class/uio/uio*/name"):
        with open(name_path) as f:
            if f.read().strip() == name:
                uio_num = name_path.split("/")[4]  # ".../uioN/name"
                return f"/dev/{uio_num}"
    raise OverlayNotApplied(
        f"no UIO device named {name!r} -- apply mpeg2fpga-uio.dts first "
        "(see driver/mpeg2fpga/tools/mpeg2fpga-uio.dts)"
    )


class DecoderPusher:
    """mmaps the mpeg2fpga UIO diagnostic register range for repeated use."""

    def __init__(self, device_path=None):
        self.device_path = device_path or find_uio_device()
        self._fd = os.open(self.device_path, os.O_RDWR | os.O_SYNC)
        self._mm = mmap.mmap(self._fd, MAP_LEN, mmap.MAP_SHARED,
                              mmap.PROT_READ | mmap.PROT_WRITE, offset=0)

    def _read_reg(self, off):
        return struct.unpack_from("<I", self._mm, off)[0]

    def _write_reg(self, off, val):
        struct.pack_into("<I", self._mm, off, val)

    def regs(self):
        return {
            "version": self._read_reg(REG_VERSION),
            "status": self._read_reg(REG_STATUS),
            "size": self._read_reg(REG_SIZE),
            "disp_size": self._read_reg(REG_DISP_SIZE),
        }

    def push(self, data):
        """Pushes `data` + sequence_end_code padding, one byte per APB
        write (the C_STREAM_WAIT backpressure state in
        apb3_mpeg2fpga_bridge.v makes each write block until the
        decoder's `busy` deasserts). Returns (before_regs, after_regs)."""
        payload = data + SEQUENCE_END_PADDING
        before = self.regs()
        for b in payload:
            self._write_reg(REG_STREAM_PUSH, b)
        after = self.regs()
        return before, after

    def close(self):
        self._mm.close()
        os.close(self._fd)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
