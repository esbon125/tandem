"""An in-memory stand-in for board.Board: the daemon's tests, and `--fake` for
developing clients without the hardware.

It enforces the hardware's and driver's rules rather than being lenient about
them -- 8-byte aligned DMA starts, zero-length only as the last chunk, one DMA
at a time -- because a test double that accepts what the hardware refuses
hides bugs (the unaligned-chunk one did, in bench/stream_dma, 2026-10-08).

The "decoder" emits frame k in display order once the stream scanner has seen
it and the picture after it, writes a recognisable constant picture into
frame buffer k % 4, and raises a picture event: Y = (7k) & 0xFF,
Cb = k & 0xFF, Cr = (255 - k) & 0xFF. It honours freeze, and only finishes a
DMA chunk at `bytes_per_s`, so flow control can be exercised.
"""

import errno
import queue
import threading
import time

from .board import (EVENT_LOST, NUM_FRAMES, STAGING_SLOT_SIZE, STAGING_SLOTS, Event)
from .esparse import StreamScanner


def frame_values(k):
    return (7 * k) & 0xFF, k & 0xFF, (255 - k) & 0xFF


class _FakeEvents:
    def __init__(self, board):
        self.board = board

    def read(self, timeout):
        out = []
        try:
            out.append(self.board._events.get(timeout=timeout))
            while True:
                out.append(self.board._events.get_nowait())
        except queue.Empty:
            pass
        return out

    def close(self):
        self.board._listening = False


class FakeBoard:
    def __init__(self, bytes_per_s=50e6, frame_s=0.005):
        self.bytes_per_s = bytes_per_s
        # decode time per frame: a decoder that writes all four buffers in
        # zero time would overwrite pictures before anyone could read them,
        # which the real one (~43 ms per frame) does not
        self.frame_s = frame_s
        self._generation = 0
        self._lock = threading.Lock()
        self._events = queue.Queue()
        self._listening = False
        self._staging = bytearray(32 << 20)
        self._frames = {}                         # buffer -> (w, h, (y, cb, cr) values)
        self.freeze_log = []
        self.dma_log = []                         # (offset, length, last)
        self.resets = 0
        self._flush()
        threading.Thread(target=self._decoder, daemon=True).start()

    # -- identity / status ---------------------------------------------------------

    def build(self):
        return "0.1.0+fakefab"

    def core_version(self):
        return "0x000c"

    def driver_version(self):
        return "fake"

    def enabled(self):
        return True

    def set_enable(self, on):
        pass

    def geometry(self):
        s = self._scanner
        return {"width": s.width or 0, "height": s.height or 0, "display_width": 0,
                "display_height": 0, "frame_rate_millihz": 25000 if s.width else 0}

    def status(self):
        return {"error": False, "watchdog": False, "video_change": False, "sticky": 0}

    def clear_status(self):
        pass

    def perf(self):
        return {"idle_cnt": 0}

    def set_freeze(self, on):
        self.freeze_log.append(bool(on))
        self._frozen = bool(on)

    def set_source_select(self, value):
        pass

    def _flush(self):
        with self._lock:
            self._generation += 1
            self._scanner = StreamScanner()
            self._pending = []                    # [(remaining_bytes, last)]
            self._dma_busy = False
            self._ended = False
            self._next = 0
            self._frozen = False

    def prepare_stream(self):
        self._flush()

    def reset(self):
        self.resets += 1
        self._flush()

    # -- stream in -----------------------------------------------------------------

    def staging_write(self, offset, data):
        self._staging[offset:offset + len(data)] = data

    def dma_start(self, offset, length, last):
        if offset & 7:
            raise OSError(errno.EINVAL, "dma_addr must be 8-byte aligned")
        if length == 0 and not last:
            raise OSError(errno.EINVAL, "zero-length chunk must be the last")
        if not any(s <= offset and offset + length <= s + STAGING_SLOT_SIZE
                   for s in STAGING_SLOTS):
            raise OSError(errno.EINVAL, "outside the staging slots")
        with self._lock:
            if self._dma_busy:
                raise OSError(errno.EBUSY, "DMA busy")
            self._dma_busy = True
            self.dma_log.append((offset, length, last))
            self._pending.append([bytes(self._staging[offset:offset + length]), last])

    def dma_done(self):
        with self._lock:
            return not self._dma_busy

    # -- the "decoder" -----------------------------------------------------------------

    def _decoder(self):
        piece = 16 << 10
        while True:
            time.sleep(0.001)
            if self._frozen:
                continue
            with self._lock:
                if self._pending:
                    data, last = self._pending[0]
                    take, rest = data[:piece], data[piece:]
                    self._scanner.feed(take)
                    if rest:
                        self._pending[0][0] = rest
                    else:
                        self._pending.pop(0)
                        self._dma_busy = False
                        if last:
                            self._scanner.finish()
                            self._ended = True
                    delay = len(take) / self.bytes_per_s
                else:
                    delay = 0
                self._emit_ready()
            if delay:
                time.sleep(delay)

    def _emit_ready(self):
        gen = self._generation
        while not self._frozen and gen == self._generation:
            s = self._scanner
            k = self._next
            info = s.frame(k)
            if info is None or not (self._ended or s.frames_total > k + 1 or
                                    s.pictures > info.decode_index + 1):
                return
            buf = k % NUM_FRAMES
            self._frames[buf] = (info.width, info.height, frame_values(k))
            self._events.put(Event(time.monotonic_ns(), k, k & 0xFFFF, buf, 0))
            self._next += 1
            if self.frame_s:
                self._lock.release()
                time.sleep(self.frame_s)
                self._lock.acquire()

    # -- frames out ----------------------------------------------------------------------

    def open_events(self):
        self._listening = True
        while not self._events.empty():
            self._events.get_nowait()
        return _FakeEvents(self)

    def read_frame(self, frame, width, height):
        w, h, (vy, vcb, vcr) = self._frames.get(frame, (width, height, (0, 0, 0)))
        mbw, mbh = (width + 15) // 16, (height + 15) // 16
        # constant planes: the per-word byte reversal does not change them,
        # only the sign offset does
        return (bytes([vy ^ 0x80]) * (256 * mbw * mbh),
                bytes([vcb ^ 0x80]) * (64 * mbw * mbh),
                bytes([vcr ^ 0x80]) * (64 * mbw * mbh))

    def read_frame_i420(self, frame, width, height):
        from . import i420
        return i420.to_i420(*self.read_frame(frame, width, height), width, height)

    def close(self):
        pass


_ = EVENT_LOST
