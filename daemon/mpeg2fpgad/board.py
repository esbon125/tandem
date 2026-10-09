"""The decoder hardware, through the mpeg2fpga kernel driver.

Everything goes through the driver -- sysfs attributes, /dev/mpeg2fpga for
picture events -- plus the two u-dma-buf regions for data: the cached staging
buffer the DMA reads the stream from, and the uncached frame store the
decoder writes pictures to. No UIO, no raw register pokes: the driver owns
the register map (plan item 5).

The interface is what session.py needs; fakeboard.py implements the same one
in memory for tests.
"""

import glob
import mmap
from . import i420, native
import os
import select
import struct
import time

STAGING_DEVICE = "/dev/udmabuf-ddr-c0"
STAGING_SYSFS = "/sys/class/u-dma-buf/udmabuf-ddr-c0"
FRAMESTORE_DEVICE = "/dev/udmabuf-ddr-nc0"
EVENTS_DEVICE = "/dev/mpeg2fpga"
REGION_SIZE = 32 << 20

# The three u-dma-buf devices alias ONE 32 MiB buffer and the frame store
# occupies its first 12 MiB, so the stream is staged in the upper 16 MiB
# (webserver/dma_push.py, STAGE_OFFSET). Two slots there make the input ring:
# the DMA drains one while the next chunk is written into the other. Both
# starts are 8-byte aligned, which stream_dma needs.
STAGING_SLOTS = (16 << 20, 24 << 20)
STAGING_SLOT_SIZE = 8 << 20

# frame store layout, rtl/mpeg2/mem_codes.v MP_AT_HL (webserver/framestore.py)
_WIDTH_Y, _WIDTH_C = 18, 16
_FRAME_WORDS = (1 << _WIDTH_Y) + 2 * (1 << _WIDTH_C)
NUM_FRAMES = 4
FRAMESTORE_BYTES = NUM_FRAMES * _FRAME_WORDS * 8

EVENT = struct.Struct("<QIHBB")               # struct mpeg2fpga_event
EVENT_OVERRUN, EVENT_LOST = 1, 2


def _plane_offsets(frame):
    base = frame * _FRAME_WORDS
    y = base
    cr_region = base + (1 << _WIDTH_Y)                    # COMP_CR holds Cb
    cb_region = cr_region + (1 << _WIDTH_C)               # COMP_CB holds Cr
    return y * 8, cr_region * 8, cb_region * 8


class Event:
    __slots__ = ("timestamp_ns", "seq", "hw_count", "frame", "flags")

    def __init__(self, timestamp_ns, seq, hw_count, frame, flags):
        self.timestamp_ns, self.seq, self.hw_count = timestamp_ns, seq, hw_count
        self.frame, self.flags = frame, flags


class EventSource:
    """/dev/mpeg2fpga. Open = picture interrupt on, close = off."""

    def __init__(self, path=EVENTS_DEVICE):
        self.fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        self._poll = select.poll()
        self._poll.register(self.fd, select.POLLIN)

    def read(self, timeout):
        if not self._poll.poll(int(timeout * 1000)):
            return []
        try:
            raw = os.read(self.fd, EVENT.size * 16)
        except BlockingIOError:
            return []
        return [Event(*EVENT.unpack_from(raw, i)) for i in range(0, len(raw), EVENT.size)]

    def close(self):
        os.close(self.fd)


def find_sysfs():
    paths = glob.glob("/sys/bus/platform/drivers/mpeg2fpga/*.mpeg2fpga")
    if not paths:
        raise RuntimeError("mpeg2fpga driver not bound (is the overlay applied?)")
    return paths[0]


def _lines(text):
    out = {}
    for line in text.strip().splitlines():
        key, _, value = line.partition(" ")
        out[key] = value.strip()
    return out


class Board:
    def __init__(self, sysfs=None):
        self.sysfs = sysfs or find_sysfs()
        self._staging_fd = os.open(STAGING_DEVICE, os.O_RDWR | os.O_SYNC)
        self._staging = mmap.mmap(self._staging_fd, REGION_SIZE, mmap.MAP_SHARED,
                                  mmap.PROT_READ | mmap.PROT_WRITE)
        self._fs_fd = os.open(FRAMESTORE_DEVICE, os.O_RDWR | os.O_SYNC)
        self._fs = mmap.mmap(self._fs_fd, REGION_SIZE, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE)
        self.converter = native.load()
        if self.converter:
            self._fs_base, self._fs_holder = native.buffer_address(self._fs)

    # -- sysfs ---------------------------------------------------------------

    def _read(self, name):
        with open(os.path.join(self.sysfs, name)) as fp:
            return fp.read()

    def _write(self, name, value):
        with open(os.path.join(self.sysfs, name), "w") as fp:
            fp.write(str(value))

    def build(self):
        return self._read("build").strip()

    def core_version(self):
        return self._read("version").strip()

    def driver_version(self):
        try:
            with open("/sys/module/mpeg2fpga/version") as fp:
                return fp.read().strip()
        except OSError:
            return "unknown"

    def enabled(self):
        return self._read("enable").strip() == "1"

    def set_enable(self, on):
        self._write("enable", 1 if on else 0)

    def geometry(self):
        g = _lines(self._read("geometry"))
        w, h = (int(v) for v in g["size"].split("x"))
        dw, dh = (int(v) for v in g["display_size"].split("x"))
        return {"width": w, "height": h, "display_width": dw, "display_height": dh,
                "frame_rate_millihz": int(g.get("frame_rate_millihz", "0"), 0)}

    def status(self):
        s = _lines(self._read("status"))
        return {"error": s.get("error") == "1", "watchdog": s.get("watchdog") == "1",
                "video_change": s.get("video_ch") == "1", "sticky": int(s["sticky"], 0)}

    def clear_status(self):
        self._write("status", 1)

    def perf(self):
        return {k: int(v, 0) for k, v in _lines(self._read("perf_counters")).items()}

    def set_freeze(self, on):
        self._write("freeze", 1 if on else 0)

    def set_source_select(self, value):
        self._write("source_select", value)

    def prepare_stream(self):
        """Drop whatever the previous stream left in the input buffer, the way a
        player changes channel -- no core reset (trick_mode_continuous_operation)."""
        if not self.enabled():
            self.set_enable(True)
            time.sleep(0.3)
        self.set_freeze(False)
        self.set_source_select(0)
        self._write("flush_vbuf", 1)
        self.clear_status()

    def reset(self):
        """Core reset plus a poisoned frame store: the recovery path only."""
        self.set_enable(False)
        time.sleep(0.2)
        poison = b"\xEE" * (1 << 20)
        for off in range(0, FRAMESTORE_BYTES, len(poison)):
            self._fs[off:off + len(poison)] = poison
        self.set_enable(True)
        time.sleep(0.3)
        self.clear_status()

    # -- stream in -----------------------------------------------------------

    def staging_write(self, offset, data):
        self._staging[offset:offset + len(data)] = data
        # the staging region is cached on the CPU side: flush it to DRAM
        # before the fabric's AXI master reads it
        with open(STAGING_SYSFS + "/sync_offset", "w") as fp:
            fp.write(str(offset & ~0xFFF))
        with open(STAGING_SYSFS + "/sync_size", "w") as fp:
            fp.write(str(((offset & 0xFFF) + len(data) + 0xFFF) & ~0xFFF))
        with open(STAGING_SYSFS + "/sync_for_device", "w") as fp:
            fp.write("1")

    def dma_start(self, offset, length, last):
        self._write("dma_addr", offset)
        self._write("dma_len", length)
        self._write("dma_start", 1 if last else "chunk")

    def dma_done(self):
        return _lines(self._read("dma_status")).get("done") == "1"

    # -- frames out ----------------------------------------------------------

    def open_events(self):
        return EventSource()

    def read_frame(self, frame, width, height):
        """Native Y, Cb, Cr planes of frame buffer `frame` (0..3)."""
        mbw, mbh = (width + 15) // 16, (height + 15) // 16
        y_off, cb_off, cr_off = _plane_offsets(frame)
        ybytes, cbytes = 256 * mbw * mbh, 64 * mbw * mbh
        fs = self._fs
        return fs[y_off:y_off + ybytes], fs[cb_off:cb_off + cbytes], fs[cr_off:cr_off + cbytes]

    def read_frame_i420(self, frame, width, height):
        """Frame buffer `frame` as I420 bytes, read and converted in one pass.

        With libm2fconv.so this runs in C straight off the frame store
        mapping, without the GIL; otherwise read_frame() + i420.py."""
        if self.converter is None:
            y, cb, cr = self.read_frame(frame, width, height)
            return i420.to_i420(y, cb, cr, width, height)
        y_off, cb_off, cr_off = _plane_offsets(frame)
        base = self._fs_base
        return self.converter.from_addresses(base + y_off, base + cb_off, base + cr_off,
                                             width, height)

    def close(self):
        if self.converter:
            del self._fs_holder
        self._staging.close()
        self._fs.close()
        os.close(self._staging_fd)
        os.close(self._fs_fd)
