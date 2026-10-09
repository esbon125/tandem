"""One decode: clip in, frames out, both streaming (api/PROTOCOL-v1.md sec. 3).

Three threads, because the three halves run at three different paces:

  pump      request body -> stream scanner -> staging slot -> DMA chunk.
            Reads the socket only when a slot is free, so a decoder slower
            than the network pushes back on the client through TCP (3.1).
  capture   picture event -> read that frame buffer *now*. The decoder will
            reuse the buffer a picture or two later, so this never waits on
            anything downstream; the raw planes go into a queue.
  sender    (the caller's thread) queue -> I420 -> FRAME record -> socket.
            When the client reads slowly the queue grows; at HIGH_WATER the
            decoder is frozen (repeat_frame = 31: it stops without losing
            anything and without tripping the watchdog), at LOW_WATER it
            resumes (3.2). Memory stays bounded at roughly HIGH_WATER frames.
"""

import json
import threading
import time
from collections import deque

from .board import STAGING_SLOT_SIZE, STAGING_SLOTS, EVENT_LOST, EVENT_OVERRUN
from .esparse import StreamScanner

RECORD_FRAME, RECORD_END = 1, 2

FIRST_CHUNK = 256 << 10     # small first chunk: the decoder starts sooner
CHUNK = 1 << 20             # then 1 MiB per DMA transfer (~1 s of decoding at SD bitrates)
READ_PIECE = 64 << 10
HIGH_WATER, LOW_WATER = 8, 3
QUIET_S = 2.0               # no picture this long after the last byte went in: done
DMA_POLL_S = 0.002
DMA_STALL_S = 30.0          # a DMA chunk that does not drain this long: decoder wedged


def frame_record(display_index, decode_index, width, height, picture_type, structure, payload):
    import struct
    head = struct.pack("<4sBBHIIIHHBBHI", b"M2FR", RECORD_FRAME, 0, 32, len(payload),
                       display_index, decode_index, width, height, picture_type, structure, 0, 0)
    return head + payload


def end_record(summary):
    import struct
    payload = json.dumps(summary, sort_keys=True).encode()
    return struct.pack("<4sBBHI", b"M2FR", RECORD_END, 0, 12, len(payload)) + payload


class Aborted(Exception):
    pass


class DecodeSession:
    """Run with run(); abort() from any thread (reset, client gone)."""

    def __init__(self, board, body, send, decode_id, frames="all", max_frames=None,
                 log=lambda *a: None):
        self.board = board
        self.body = body                # iterator of request-body bytes
        self.send = send                # send(record_bytes); raises if the client is gone
        self.id = decode_id
        self.frames_mode = frames
        self.max_frames = max_frames
        self.log = log
        self.scanner = StreamScanner()
        self.started = time.time()
        self.bytes_in = 0
        self.frames_sent = 0
        self.captured = 0
        self.flow_paused = False
        self.aborted = False
        self._queue = deque()
        self._cond = threading.Condition()
        self._input_done_at = None
        self._last_event_at = None
        self._error = None
        self._frozen = False
        self._stop = threading.Event()
        self.lost_events = 0
        # events already waiting when capture got to them: 0 or 1 is normal;
        # more means capture fell behind and an early frame buffer may have
        # been reused before it was read
        self.capture_lag_max = 0
        # where the time goes, per stage, for tuning (reported in END)
        self.timing = {"read_s": 0.0, "send_s": 0.0,
                       "frozen_s": 0.0, "dma_wait_s": 0.0, "staging_write_s": 0.0}
        self._frozen_at = None

    # -- public ----------------------------------------------------------------

    def abort(self):
        self.aborted = True
        self._stop.set()
        with self._cond:
            self._cond.notify_all()

    def status(self):
        return {"id": self.id, "bytes_in": self.bytes_in, "frames_out": self.frames_sent,
                "flow_paused": self.flow_paused,
                "started": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(self.started))}

    def run(self):
        board = self.board
        board.prepare_stream()
        events = board.open_events()
        pump = threading.Thread(target=self._guard, args=(self._pump,), name="pump", daemon=True)
        capture = threading.Thread(target=self._guard, args=(self._capture, events),
                                   name="capture", daemon=True)
        capture.start()
        pump.start()
        last_frame = None
        try:
            while True:
                item = self._next_item()
                if item is None:
                    break
                ev_index, geom, raw = item
                if self.frames_mode == "last":
                    last_frame = (ev_index, geom, raw)
                    continue
                if self.max_frames is not None and self.frames_sent >= self.max_frames:
                    continue                    # keep draining the decode, send nothing
                self._send_frame(ev_index, geom, raw)
            if last_frame is not None:
                self._send_frame(*last_frame)
        except Exception:
            self.abort()
            raise
        finally:
            self._stop.set()
            pump.join(timeout=DMA_STALL_S + 5)
            capture.join(timeout=5)
            events.close()
            if self._frozen:
                board.set_freeze(False)
            if self.aborted:
                # whatever the decoder still holds belongs to nobody now
                try:
                    board.prepare_stream()
                except Exception as exc:        # noqa: BLE001
                    self.log("cleanup after abort failed: %r" % exc)
        # END is the caller's to send (end_record(summary)): the decoder must be
        # released first, or a client that starts its next decode the moment
        # END arrives finds it still taken (409, seen on the board)
        return self.summary()

    def summary(self):
        st = self.board.status()
        expected = self.scanner.frames_total
        return {
            "id": self.id,
            "bytes_in": self.bytes_in,
            "frames_sent": self.frames_sent,
            "pictures_in_stream": expected,
            "complete": (not self.aborted and self._error is None and self.lost_events == 0
                         and self.captured == expected),
            "aborted": self.aborted,
            "decoder": {"error": st["error"], "watchdog": st["watchdog"],
                        "video_change": st["video_change"]},
            "error": None if self._error is None else str(self._error),
            "capture_lag_max": self.capture_lag_max,
            "timing": {k: round(v, 3) for k, v in self.timing.items()},
            "seconds": round(time.time() - self.started, 3),
        }

    # -- threads ---------------------------------------------------------------

    def _guard(self, fn, *args):
        try:
            fn(*args)
        except Aborted:
            pass
        except Exception as exc:                # noqa: BLE001 - reported in END
            self._error = exc
            self.log("%s failed: %r" % (fn.__name__, exc))
            self.abort()

    def _pump(self):
        board = self.board
        slot = 0
        in_flight = False
        chunk = FIRST_CHUNK
        pending = bytearray()
        body = iter(self.body)
        eof = False
        while not eof:
            # fill one chunk from the socket
            while len(pending) < chunk:
                if self._stop.is_set():
                    raise Aborted()
                try:
                    piece = next(body)
                except StopIteration:
                    eof = True
                    break
                self.scanner.feed(piece)
                self.bytes_in += len(piece)
                pending += piece
            data, pending = bytes(pending[:chunk]), pending[chunk:]
            if eof and pending:
                # more than one chunk left over at the end: send it all, in order
                eof = False
            last = eof and not pending
            if last:
                self.scanner.finish()
            base = STAGING_SLOTS[slot]
            assert len(data) <= STAGING_SLOT_SIZE
            t = time.perf_counter()
            board.staging_write(base, data)
            t2 = time.perf_counter()
            self.timing["staging_write_s"] += t2 - t
            if in_flight:
                self._wait_dma()
            self.timing["dma_wait_s"] += time.perf_counter() - t2
            board.dma_start(base, len(data), last=last)
            in_flight = True
            slot ^= 1
            chunk = CHUNK
            if last:
                break
        self._wait_dma()
        with self._cond:
            self._input_done_at = time.time()
            self._cond.notify_all()

    def _wait_dma(self):
        t0 = time.time()
        while not self.board.dma_done():
            if self._stop.is_set() and time.time() - t0 > 5:
                raise Aborted()
            if not self._frozen and time.time() - t0 > DMA_STALL_S:
                raise RuntimeError("DMA did not drain in %.0f s: decoder stalled" % DMA_STALL_S)
            if self._frozen:
                t0 = time.time()                # a frozen decoder is allowed to sit
            time.sleep(DMA_POLL_S)

    def _capture(self, events):
        board = self.board
        while not self._stop.is_set():
            batch = events.read(0.1)
            if len(batch) - 1 > self.capture_lag_max:
                self.capture_lag_max = len(batch) - 1
                if self.capture_lag_max >= 2:
                    self.log("%s: capture %d pictures behind" % (self.id, self.capture_lag_max))
            for ev in batch:
                if ev.flags & (EVENT_OVERRUN | EVENT_LOST):
                    self.lost_events += 1
                info = self.scanner.frame(self.captured)
                if info is not None and info.width:
                    geom = (info.width, info.height)
                else:
                    g = board.geometry()        # scanner lost track: trust the decoder
                    geom = (g["width"], g["height"])
                # Read and convert now, before the decoder reuses the buffer:
                # in C off the frame store mapping when libm2fconv.so is
                # there (GIL released), else in Python. Frames that will not
                # be sent are not read at all.
                t = time.perf_counter()
                payload = (None if self._skip(self.captured)
                           else board.read_frame_i420(ev.frame, geom[0], geom[1]))
                self.timing["read_s"] += time.perf_counter() - t
                with self._cond:
                    self._queue.append((self.captured, geom, payload))
                    self.captured += 1
                    self._last_event_at = time.time()
                    if len(self._queue) >= HIGH_WATER and not self._frozen:
                        board.set_freeze(True)
                        self._frozen = self.flow_paused = True
                        self._frozen_at = time.perf_counter()
                    self._cond.notify_all()

    def _next_item(self):
        """Next captured frame for the sender, or None when the decode is over."""
        with self._cond:
            while True:
                if self._queue:
                    item = self._queue.popleft()
                    if self._frozen and len(self._queue) <= LOW_WATER:
                        self.board.set_freeze(False)
                        self._frozen = self.flow_paused = False
                        self.timing["frozen_s"] += time.perf_counter() - self._frozen_at
                    return item
                if self.aborted:
                    return None
                if self._input_done_at is not None:
                    expected = self.scanner.frames_total
                    quiet_since = max(self._input_done_at, self._last_event_at or 0)
                    if self.captured >= expected or time.time() - quiet_since > QUIET_S:
                        return None
                self._cond.wait(0.1)

    def _skip(self, index):
        """Frames that will not be sent need no conversion."""
        if self.frames_mode == "last":
            return False                        # which one is last is not known yet
        return self.max_frames is not None and index >= self.max_frames

    def _send_frame(self, index, geom, raw):
        width, height = geom
        info = self.scanner.frame(index)
        payload = raw
        t2 = time.perf_counter()
        self.send(frame_record(index,
                               info.decode_index if info else 0xFFFFFFFF,
                               width, height,
                               info.picture_type if info else 0,
                               info.structure if info else 0,
                               payload))
        self.timing["send_s"] += time.perf_counter() - t2
        self.frames_sent += 1
