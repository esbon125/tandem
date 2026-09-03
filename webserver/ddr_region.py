"""
Fase 7b: thin wrapper around a u-dma-buf character device -- a reserved
DDR region the base Discovery Kit reference design already exposes to
Linux (dmesg: "u-dma-buf udmabufN: assigned reserved memory node ..."),
mmap-able directly with no device-tree overlay needed (unlike mpeg2fpga's
own registers, which go through UIO + a custom overlay -- see
driver/mpeg2fpga/tools/push_stream.py).

!! THE THREE DEVICES BELOW ARE ONE BUFFER, NOT THREE !!

This docstring used to claim they were "deliberately kept separate". That was
wrong, and the mistake cost the whole Fase 7a SIZE=0 investigation. All three
u-dma-buf nodes name the SAME 32 MB of physical DRAM, reached through the
MSS's three cache-attribute windows onto it:

  /dev/udmabuf-ddr-c0        0x88000000  cached          stream_dma.v's
                                                         STAGING_BASE
  /dev/udmabuf-ddr-nc0       0xc8000000  non-cached      mem2axi_bridge's
                                                         DDR_BASE (framestore
                                                         + vbuf)
  /dev/udmabuf-ddr-nc-wcb0   0xd8000000  non-cached WCB  synthetic test
                                                         pattern

Proven on hardware: a write through one window is visible through another
(see docs/bringup, Fase 7a alias writeup). The device tree corroborates it --
reserved region@84000000 + buffer@88000000 in the cached window are exactly
the 96 MB that memory@c4000000 hands to Linux through the non-cached one, so
each window's usable RAM is reserved on the other.

WHY THE OBVIOUS TEST SAYS OTHERWISE: PolarFire SoC's L2 is a MEMORY-SIDE
cache, selected by address window rather than by page-table attribute. A write
to 0x88000000 sits dirty in L2 while a read of 0xc8000000 goes straight to
DRAM and sees the stale value, and vice versa -- so a naive write/readback
between the two windows reports "independent" in BOTH directions, even with
mmap'd O_SYNC. To see the truth, either compare the two non-cached windows
(neither goes through L2) or force real eviction by streaming >2 MB of other
cached addresses between the write and the read. u-dma-buf's
sync_for_cpu/sync_for_device are NOT enough on their own: they act on the
CPU's own caches, not on the memory-side L2.

CONSEQUENCES FOR CALLERS:
  - Offsets below 0xf7fff8 (~15.5 MB, mem_codes.v END_OF_MEM) belong to the decoder's
    framestore. dma_push.py stages streams at +16 MB to stay clear; see its
    docstring.
  - Writing to STAGING_DEVICE at a framestore offset corrupts a frame, and
    because it is the cached view the damage can land in DRAM seconds later,
    long after the writing code has finished.
  - TEST_PATTERN_DEVICE is NOT untouched by mpeg2fpga hardware. It is the
    framestore under a third name.
"""
import mmap
import os

TEST_PATTERN_DEVICE = "/dev/udmabuf-ddr-nc-wcb0"
FRAMESTORE_DEVICE = "/dev/udmabuf-ddr-nc0"
STAGING_DEVICE = "/dev/udmabuf-ddr-c0"
STAGING_SYSFS = "/sys/class/u-dma-buf/udmabuf-ddr-c0"

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
