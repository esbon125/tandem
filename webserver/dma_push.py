"""
Fase 7c: push an elementary stream to the decoder via stream_dma.v's
hardware DMA path instead of decoder_push.py's byte-at-a-time APB write
(~177 KB/s, Fase 7a) -- software does one bulk mmap write into a DDR
staging buffer plus a handful of register writes, then hardware streams
the bytes into mpeg2video autonomously at core_clk rate.

Sequence (mirrors the control sequence in the Fase 7c design doc):
  1. mmap-write the stream into STAGING_DEVICE (/dev/udmabuf-ddr-c0,
     0x88000000 -- stream_dma.v's STAGING_BASE).
  2. sync_for_device: STAGING_DEVICE is the *cached* u-dma-buf region (see
     ddr_region.py), so the CPU's writes need an explicit cache flush
     before the fabric-side AXI4 master can see them -- u-dma-buf exposes
     this as a pair of sysfs files (sync_size/sync_offset set the range,
     sync_for_device triggers the flush) rather than an ioctl.
  3. Write DMA_ADDR (byte offset inside the staging buffer, always 0 here
     since each push starts at the buffer's base) and DMA_LEN (the real
     stream length -- stream_dma.v appends the sequence_end_code padding
     itself, same as decoder_push.py already does in software).
  4. Write DMA_CTRL's start bit.
  5. Poll DMA_STATUS until its done bit is set, then read the register
     file (VERSION/STATUS/SIZE/DISP_SIZE) same as decoder_push.py's push().

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
from ddr_region import DDRRegion, STAGING_DEVICE, STAGING_SYSFS

REG_DMA_ADDR = PAGE_OFFSET + 0x44
REG_DMA_LEN = PAGE_OFFSET + 0x48
REG_DMA_CTRL = PAGE_OFFSET + 0x4C
REG_DMA_STATUS = PAGE_OFFSET + 0x50

POLL_INTERVAL_S = 0.001
POLL_TIMEOUT_S = 5.0


def sync_for_device(length):
    with open(f"{STAGING_SYSFS}/sync_offset", "w") as f:
        f.write("0")
    with open(f"{STAGING_SYSFS}/sync_size", "w") as f:
        f.write(str(length))
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
        with DDRRegion(STAGING_DEVICE) as staging:
            staging.write(0, data)
        sync_for_device(len(data))

        before = self.regs()

        self._write_reg(REG_DMA_ADDR, 0)
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
