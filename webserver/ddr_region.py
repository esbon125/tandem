"""
Fase 7b: thin wrapper around a u-dma-buf character device -- a reserved
DDR region the base Discovery Kit reference design already exposes to
Linux (dmesg: "u-dma-buf udmabufN: assigned reserved memory node ..."),
mmap-able directly with no device-tree overlay needed (unlike mpeg2fpga's
own registers, which go through UIO + a custom overlay -- see
driver/mpeg2fpga/tools/push_stream.py).

Two regions matter here, deliberately kept separate so the still-unproven
real decode path (Fase 7a's open SIZE=0 investigation) can't collide with
this test-pattern validation:

  /dev/udmabuf-ddr-nc0       0xc8000000  mem2axi_bridge's DDR_BASE
                                          (hardware_development,
                                          mpeg2fpga_apb_peripheral.v) --
                                          the real framestore/vbuf, once
                                          decode is confirmed working.
  /dev/udmabuf-ddr-nc-wcb0   0xd8000000  used here for the synthetic test
                                          pattern -- entirely software,
                                          untouched by mpeg2fpga hardware.

Both are non-cached from Linux's side, so a plain mmap() always sees
whatever was most recently written, no cache-invalidation dance needed.
"""
import mmap
import os

TEST_PATTERN_DEVICE = "/dev/udmabuf-ddr-nc-wcb0"
FRAMESTORE_DEVICE = "/dev/udmabuf-ddr-nc0"

REGION_SIZE = 32 * 1024 * 1024  # matches the reserved-memory node size


class DDRRegion:
    """mmap a u-dma-buf device for repeated read/write access."""

    def __init__(self, device_path, size=REGION_SIZE):
        self.device_path = device_path
        self.size = size
        self._fd = os.open(device_path, os.O_RDWR | os.O_SYNC)
        self._mm = mmap.mmap(self._fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=0)

    def read(self, offset, length):
        return self._mm[offset:offset + length]

    def write(self, offset, data):
        self._mm[offset:offset + len(data)] = data

    def close(self):
        self._mm.close()
        os.close(self._fd)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
