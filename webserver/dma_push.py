"""
Fase 7c: push an elementary stream to the decoder via stream_dma.v's
hardware DMA path instead of decoder_push.py's byte-at-a-time APB write
(~177 KB/s, Fase 7a) -- software does one bulk mmap write into a DDR
staging buffer plus a handful of register writes, then hardware streams
the bytes into mpeg2video autonomously at core_clk rate.

Sequence (mirrors the control sequence in the Fase 7c design doc):
  1. mmap-write the stream into STAGING_DEVICE (/dev/udmabuf-ddr-c0,
     0x88000000 -- stream_dma.v's STAGING_BASE) at STAGE_OFFSET, NOT at 0.
     See "the staging offset" below -- offset 0 silently overwrites the
     decoder's own frame buffer.
  2. sync_for_device: STAGING_DEVICE is the *cached* u-dma-buf region (see
     ddr_region.py), so the CPU's writes need an explicit cache flush
     before the fabric-side AXI4 master can see them -- u-dma-buf exposes
     this as a pair of sysfs files (sync_size/sync_offset set the range,
     sync_for_device triggers the flush) rather than an ioctl.
  3. Write DMA_ADDR (byte offset inside the staging buffer = STAGE_OFFSET)
     and DMA_LEN (the real stream length -- stream_dma.v appends the
     sequence_end_code padding itself, same as decoder_push.py already
     does in software).
  4. Write DMA_CTRL's start bit.
  5. Poll DMA_STATUS until its done bit is set, then read the register
     file (VERSION/STATUS/SIZE/DISP_SIZE) same as decoder_push.py's push().

The staging offset (root cause of the whole Fase 7a "SIZE=0" saga)
---------------------------------------------------------------------
/dev/udmabuf-ddr-c0 (0x88000000), -nc0 (0xc8000000) and -nc-wcb0
(0xd8000000) are NOT three separate buffers. They are ONE 32 MB region of
physical DRAM seen through the MSS's cached / non-cached / write-combining
address windows -- proven on hardware by writing through one window and
reading another after forcing an L2 eviction (docs/bringup, Fase 7a alias
writeup). So stream_dma.v's STAGING_BASE (0x88000000) and
mpeg2fpga_apb_peripheral.v's DDR_BASE (0xc8000000) address the SAME bytes.

Staging at offset 0 therefore wrote the elementary stream directly on top
of FRAME_0_Y, and framestore_request.v's STATE_CLEAR sweep wrote its 0x80
fill back over the staged stream. The two raced on every push: the stream
the DMA read was partially shredded, the VBUF got a corrupted copy, and
vld.v never parsed a valid sequence header -- SIZE stayed 0.

mem_codes.v with MP_AT_HL has END_OF_MEM = 22'h1effff words * 8 bytes
= 0xf7fff8 = ~15.5 MB, so the decoder only uses the low half of the 32 MB. Staging at
+16 MB is clear of it, and DMA_ADDR is already defined as a byte offset
inside STAGING_BASE, so this needs no RTL change. With it, SIZE reads the
stream's real resolution (720x480 for tcela-17, 352x224 for sony-ct1) and
holds stable with error=0 and the watchdog quiet.

Corollary, and a live footgun: never write to /dev/udmabuf-ddr-c0 below
STAGE_OFFSET while the core is enabled. It is the decoder's framestore, and
because c0 is the *cached* view, a write can sit dirty in L2 and land in
DRAM seconds later, corrupting a frame long after the code that wrote it
has moved on.

Reuses decoder_push.py's UIO device discovery and page-offset handling
(same mpeg2fpga_diag overlay, same PAGE_OFFSET gotcha -- see that file's
docstring for the full writeup) rather than duplicating it.
"""
import time

from decoder_push import (
    DecoderPusher,
    REG_VERSION,
    REG_STATUS,
    REG_SIZE,
    REG_DISP_SIZE,
    PAGE_OFFSET,
)
from ddr_region import DDRRegion, REGION_SIZE, STAGING_DEVICE, STAGING_SYSFS

REG_DMA_ADDR = PAGE_OFFSET + 0x44
REG_DMA_LEN = PAGE_OFFSET + 0x48
REG_DMA_CTRL = PAGE_OFFSET + 0x4C
REG_DMA_STATUS = PAGE_OFFSET + 0x50

POLL_INTERVAL_S = 0.001
POLL_TIMEOUT_S = 5.0

# Byte offset inside the staging buffer at which a stream is placed. Must stay
# above the decoder's framestore, which shares this DRAM (see the module
# docstring): mem_codes.v END_OF_MEM = 22'h1effff words * 8 = 0xf7fff8 bytes.
STAGE_OFFSET = 0x1000000  # 16 MB
FRAMESTORE_END = 0xF7FFF8

assert STAGE_OFFSET > FRAMESTORE_END, \
    "staging would land inside the decoder's framestore -- they share DRAM"


def sync_for_device(length, offset=STAGE_OFFSET):
    """Flush the CPU's writes out to DRAM so the fabric AXI master sees them.

    sync_offset/sync_size must be page-granular for the range to cover the
    whole written region.
    """
    with open(f"{STAGING_SYSFS}/sync_offset", "w") as f:
        f.write(str(offset))
    with open(f"{STAGING_SYSFS}/sync_size", "w") as f:
        f.write(str((length + 0xFFF) & ~0xFFF))
    with open(f"{STAGING_SYSFS}/sync_for_device", "w") as f:
        f.write("1")


class DmaPusher(DecoderPusher):
    """Extends DecoderPusher (regfile/basic register access) with the
    Fase 7c DMA-control registers and the staging-buffer write path."""

    def dma_debug_readback(self):
        """Fase 7c debug: DMA_ADDR/DMA_LEN were write-only until a real
        hardware bug showed up (a push's len was silently treated as 0 --
        see docs/bringup). Reading them back tells us whether the bridge
        actually latched the written value (the same wire stream_dma.v's
        len/addr ports read), bisecting a write-path bug from a
        stream_dma-side one."""
        return {
            "dma_addr": self._read_reg(REG_DMA_ADDR),
            "dma_len": self._read_reg(REG_DMA_LEN),
        }

    def dma_status(self):
        raw = self._read_reg(REG_DMA_STATUS)
        return {
            "busy": bool(raw & 0x1),
            "done": bool(raw & 0x2),
            "bytes_done": (raw >> 8) & 0xFFFFFF,
        }

    def push_dma(self, data):
        """Writes `data` into the staging buffer and triggers a hardware
        DMA transfer. Returns (before_regs, after_regs), matching
        DecoderPusher.push()'s return shape."""
        if STAGE_OFFSET + len(data) > REGION_SIZE:
            raise ValueError(f"stream of {len(data)} bytes overflows the staging "
                             f"buffer past offset 0x{STAGE_OFFSET:x}")

        with DDRRegion(STAGING_DEVICE) as staging:
            staging.write(STAGE_OFFSET, data)
        sync_for_device(len(data))

        before = self.regs()

        self._write_reg(REG_DMA_ADDR, STAGE_OFFSET)
        self._write_reg(REG_DMA_LEN, len(data))
        self._write_reg(REG_DMA_CTRL, 1)

        deadline = time.time() + POLL_TIMEOUT_S
        status = self.dma_status()
        while not status["done"]:
            if time.time() > deadline:
                raise TimeoutError(f"DMA transfer did not complete within {POLL_TIMEOUT_S}s (status={status})")
            time.sleep(POLL_INTERVAL_S)
            status = self.dma_status()

        after = self.regs()
        after["dma_bytes_done"] = status["bytes_done"]
        return before, after


def main():
    import sys

    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-elementary-stream>")
        sys.exit(1)

    with open(sys.argv[1], "rb") as f:
        data = f.read()
    print(f"stream: {sys.argv[1]} ({len(data)} bytes)")

    with DmaPusher() as pusher:
        t0 = time.time()
        before, after = pusher.push_dma(data)
        elapsed = time.time() - t0

    print(f"before: {before}")
    print(f"after:  {after}")
    print(f"transferred {len(data)} bytes in {elapsed:.4f}s ({len(data) / elapsed / 1024:.1f} KB/s)")


if __name__ == "__main__":
    main()
