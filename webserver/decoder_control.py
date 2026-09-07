"""One way to drive the decoder, over either of two backends.

The register map used to be folklore copied between a dozen diagnostic scripts,
each of them mmapping /dev/uio2 and open-coding the offsets. The kernel driver
owns it now, so the preferred backend is its sysfs interface: the offsets, the
DMA start ordering, the write-only-register shadowing and the read-to-clear
status accumulation all live in tested C instead of being re-derived here.

The UIO backend is kept because the two device tree overlays are mutually
exclusive -- both describe the register window at 0x40000400, and whichever
driver probes second cannot claim it -- so a board can be running either. It is
also the fallback if the module is not loaded.

What does NOT go through here is DDR: the staging buffer and the frame store are
u-dma-buf character devices, not registers, and are mmapped directly either way.
"""
import glob
import os

SYSFS_GLOB = "/sys/bus/platform/devices/*.mpeg2fpga"


def find_sysfs_device():
    for path in sorted(glob.glob(SYSFS_GLOB)):
        if os.path.exists(os.path.join(path, "version")):
            return path
    return None


def open_control():
    """The sysfs backend if the driver is bound, otherwise raw UIO."""
    path = find_sysfs_device()
    if path:
        return SysfsControl(path)
    return UioControl()


def _parse_lines(text):
    """The multi-line attributes are 'key value' per line."""
    out = {}
    for line in text.strip().splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            key, value = parts
            try:
                out[key] = int(value, 0)
            except ValueError:
                out[key] = value
    return out


class SysfsControl:
    """Talks to the kernel driver's attributes under /sys/bus/platform."""

    backend = "sysfs"

    def __init__(self, path):
        self.path = path

    def _read(self, name):
        with open(os.path.join(self.path, name)) as fp:
            return fp.read()

    def _write(self, name, value):
        with open(os.path.join(self.path, name), "w") as fp:
            fp.write(str(value))

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def version(self):
        return int(self._read("version").strip(), 0)

    def is_enabled(self):
        return self._read("enable").strip() == "1"

    def set_enable(self, enable):
        self._write("enable", 1 if enable else 0)

    def geometry(self):
        # Most attributes are "key value" per line, but geometry's sizes are
        # "key AxB", so parse it here rather than through _parse_lines.
        fields = {}
        for line in self._read("geometry").strip().splitlines():
            key, _, value = line.partition(" ")
            if "x" in value and key in ("size", "display_size", "macroblocks"):
                a, _, b = value.partition("x")
                fields[key] = (int(a), int(b))
            else:
                fields[key] = int(value, 0)
        return {
            "width": fields["size"][0],
            "height": fields["size"][1],
            "display_width": fields["display_size"][0],
            "display_height": fields["display_size"][1],
            "mb_width": fields["macroblocks"][0],
            "mb_height": fields["macroblocks"][1],
            "frame_rate_code": fields["frame_rate_code"],
            "frame_rate_millihz": fields["frame_rate_millihz"],
        }

    def status(self):
        """Sticky status. The driver's IRQ handler accumulates it, so unlike
        a raw read this does not race the hardware's read-to-clear."""
        return _parse_lines(self._read("status"))

    def clear_status(self):
        self._write("status", "1")

    def perf_counters(self):
        """Free-running core_clk cycle counters -- see mpeg2fpga_core.h's
        struct mpeg2fpga_perf_counters for what each one means. Never reset
        by reading; take the delta of two calls bracketing one decode."""
        return _parse_lines(self._read("perf_counters"))

    def dma_start(self, addr, length):
        self._write("dma_addr", addr)
        self._write("dma_len", length)
        self._write("dma_start", 1)

    def dma_status(self):
        return _parse_lines(self._read("dma_status"))

    def flush_vbuf(self):
        self._write("flush_vbuf", 1)

    def set_freeze(self, freeze):
        self._write("freeze", 1 if freeze else 0)

    def set_source_select(self, source):
        self._write("source_select", source)

    def set_persistence(self, on):
        self._write("persistence", 1 if on else 0)

    def trick_state(self):
        return {
            "frozen": self._read("freeze").strip() == "1",
            "source_select": int(self._read("source_select").strip(), 0),
            "persistence": self._read("persistence").strip() == "1",
            "backend": self.backend,
        }


class UioControl:
    """The original path: mmap the UIO register window and poke it directly."""

    backend = "uio"

    def __init__(self):
        import trick_mode
        from dma_push import DmaPusher

        self._pusher = DmaPusher()
        self._trick = trick_mode.TrickMode()
        self._trick_mode = trick_mode
        # The kernel driver accumulates read-to-clear status bits in its IRQ
        # handler, so a caller can clear once, do work, and read once at the
        # end without missing anything in between. UIO has no interrupt
        # thread to do that, so status() accumulates here on every call
        # instead -- the two backends have to agree on this, or code written
        # against one silently loses events on the other (as this once did:
        # a status() call inside a polling loop, one raw read-and-clear per
        # call, kept only the last poll's bits instead of the whole run's).
        self._sticky = 0

    def close(self):
        self._pusher.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # Register word addresses, only needed by this backend.
    _R_VERSION, _R_STATUS, _R_SIZE, _R_DISP, _R_RATE = 0x00, 0x01, 0x02, 0x03, 0x04

    def _reg(self, word):
        from decoder_push import PAGE_OFFSET
        return PAGE_OFFSET + word * 4

    def version(self):
        return self._pusher._read_reg(self._reg(self._R_VERSION)) & 0xFFFF

    def is_enabled(self):
        return self._pusher.core_enable()

    def set_enable(self, enable):
        self._pusher.set_core_enable(enable)

    def geometry(self):
        size = self._pusher._read_reg(self._reg(self._R_SIZE))
        disp = self._pusher._read_reg(self._reg(self._R_DISP))
        rate = self._pusher._read_reg(self._reg(self._R_RATE))
        width, height = (size >> 16) & 0x3FFF, size & 0x3FFF
        code = rate & 0xF
        # ISO/IEC 13818-2 table 6-4, milli-Hz; mirrors the driver's table.
        rates = {1: 23976, 2: 24000, 3: 25000, 4: 29970,
                 5: 30000, 6: 50000, 7: 59940, 8: 60000}
        return {
            "width": width,
            "height": height,
            "display_width": (disp >> 16) & 0x3FFF,
            "display_height": disp & 0x3FFF,
            "mb_width": (width + 15) // 16,
            "mb_height": (height + 15) // 16,
            "frame_rate_code": code,
            "frame_rate_millihz": rates.get(code, 0),
        }

    def status(self):
        """Read-to-clear in hardware, accumulated here -- see __init__."""
        raw = self._pusher._read_reg(self._reg(self._R_STATUS))
        self._sticky |= raw & 0x8F           # bits 0-3 and 7; 8-15 are matrix_coefficients
        s = self._sticky
        return {
            "sticky": s,
            "error": bool(s & 0x1),
            "video_ch": bool(s & 0x2),
            "frame_end": bool(s & 0x4),
            "picture_hdr": bool(s & 0x8),
            "watchdog": bool(s & 0x80),
            "matrix_coefficients": (raw >> 8) & 0xFF,   # not sticky in hardware either
        }

    def clear_status(self):
        self._pusher._read_reg(self._reg(self._R_STATUS))
        self._sticky = 0

    def dma_start(self, addr, length):
        from dma_push import REG_DMA_ADDR, REG_DMA_CTRL, REG_DMA_LEN
        self._pusher._write_reg(REG_DMA_ADDR, addr)
        self._pusher._write_reg(REG_DMA_LEN, length)
        self._pusher._write_reg(REG_DMA_CTRL, 1)

    def dma_status(self):
        return self._pusher.dma_status()

    def flush_vbuf(self):
        self._trick.flush_vbuf(self._pusher)

    def set_freeze(self, freeze):
        self._trick.set_freeze(self._pusher, freeze)

    def set_source_select(self, source):
        self._trick.set_source_select(self._pusher, source)

    def set_persistence(self, on):
        self._trick.set_persistence(self._pusher, on)

    def trick_state(self):
        state = self._trick.describe()
        state["backend"] = self.backend
        return state
