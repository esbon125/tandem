#!/usr/bin/env python3
"""Web front end for the decoder: upload an elementary stream, see the pictures.

Replaces the Fase 7b version, which predated a working decode: it pushed one
byte at a time over APB and its WebSocket served a synthetic test pattern from
a scratch DRAM window, because at the time there were no real decoded frames to
serve.  Both of those are now obsolete -- the DMA path works, and the decoder
reconstructs pictures that match the reference decoder.

Flow:

  POST /decode   push a stream and stream every reconstructed picture back, in
                 display order, as it is captured. See decode_stream.py.
  GET  /frame/N  frame buffer N's three planes, read live out of DRAM. A
                 debugging view of what is in the framestore right now, which
                 is not the same thing as the captured sequence.

Registers go through decoder_control, which prefers the kernel driver's sysfs
interface and falls back to raw UIO when the module is not bound.

The planes are handed over untouched.  Undoing the framestore's storage format
-- pixels are signed and offset by -128, and the eight pixels of a 64-bit word
appear reversed in little-endian DRAM -- is per-byte work, which Python on the
MSS is bad at and a browser's JIT is good at, so static/index.html does it there
along with the YUV to RGB conversion.  See framestore.py.

  POST /control/{pause,resume,blank,flush,show_buffer}
                 trick mode. The core is reset once, at the first decode, and
                 never again: streams after that are separated with flush_vbuf,
                 which is what the decoder is designed for. See trick_mode.py.

There is no WebSocket any more.  The decoder consumes a whole stream in about a
second and only the last four pictures survive in the frame buffers, so there
is nothing to stream in real time yet; plain request/response is easier to
debug with curl and drops the websockets dependency.
"""
import http.server
import json
import os
import struct
import threading
import time
import urllib.parse

import decode_stream
import decoder_control
import framestore
import trick_mode
from ddr_region import DDRRegion, FRAMESTORE_DEVICE
from decoder_push import OverlayNotApplied

HTTP_PORT = 8080
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")

REG = lambda word: PAGE_OFFSET + word * 4
REG_STATUS, REG_SIZE, REG_DISP_SIZE, REG_FRAME_RATE = 0x01, 0x02, 0x03, 0x04

STATUS_BITS = (("error", 0), ("video_ch", 1), ("frame_end", 2),
               ("pic_hdr", 3), ("watchdog", 7))

POISON = 0xEE               # what an unwritten frame buffer reads back as
SETTLE_QUIET_S = 1.0        # how long the framestore must hold still
SETTLE_TIMEOUT_S = 30.0

FRAME_MAGIC = b"M2FS"

# Last successful decode, so GET /frame/N knows the geometry.
_state = {"width": 0, "height": 0, "written": []}

# The decoder is driven continuously: the core is reset once, at startup, and
# every stream after that is separated with flush_vbuf rather than another
# reset. See trick_mode.py for why that is the design's own intent.
_controls = {"control": None, "reset_done": False}
_controls_lock = threading.Lock()


def controls():
    """The one decoder handle for this process.

    Shared rather than opened per request because the UIO backend has to shadow
    the write-only trick mode register, and two independent shadows would fight
    over it. (The sysfs backend keeps that shadow in the driver, where it
    belongs, and is stateless here -- one more reason to prefer it.)
    """
    with _controls_lock:
        if _controls["control"] is None:
            _controls["control"] = decoder_control.open_control()
        return _controls["control"]


def _decode_status(sticky):
    return {name: bool(sticky & (1 << bit)) for name, bit in STATUS_BITS}


def _fingerprint(region):
    """Cheap sample of the framestore, to tell whether it is still changing."""
    return bytes(region.read(word * 8, 64)[0]
                 for word in range(0, framestore.OSD_WORD, 4096))


def frame_payload(frame):
    """Header + Y + Cb + Cr for one frame buffer."""
    width, height = _state["width"], _state["height"]
    if not width or not height:
        raise LookupError("no stream decoded yet")
    geometry = framestore.PlaneGeometry(frame, width, height)
    with DDRRegion(FRAMESTORE_DEVICE) as fs:
        luma, cb, cr = geometry.read(fs)
    header = FRAME_MAGIC + struct.pack(
        "<9I", 1, frame, width, height,
        geometry.luma_stride, geometry.luma_rows,
        geometry.chroma_stride, geometry.chroma_rows, 0)
    return b"".join((header, luma, cb, cr))


RECORD_HEADER = b"M2HD"     # json metadata
RECORD_FRAME = b"M2FR"      # one captured picture


def _frame_record(capture):
    geometry = capture.geometry
    luma, cb, cr = capture.planes
    body = struct.pack(
        "<8I", capture.display_index, capture.decode_index,
        capture.picture_type, geometry.width, geometry.height,
        geometry.luma_stride, geometry.luma_rows, geometry.chroma_stride)
    body += struct.pack("<I", geometry.chroma_rows)
    payload = b"".join((body, luma, cb, cr))
    return RECORD_FRAME + struct.pack("<I", len(payload)) + payload


def _json_record(payload):
    body = json.dumps(payload).encode()
    return RECORD_HEADER + struct.pack("<I", len(body)) + body


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("[http] %s %s" % (self.address_string(), fmt % args))

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            self._send_file(os.path.join(STATIC_DIR, "index.html"), "text/html")
        elif path == "/state":
            report = dict(_state)
            try:
                report["backend"] = controls().backend
            except Exception:                   # noqa: BLE001
                report["backend"] = "unavailable"
            self._send_json(200, report)
        elif path == "/control/state":
            self._do_control("state", None)
        elif path.startswith("/frame/"):
            try:
                frame = int(path[len("/frame/"):])
            except ValueError:
                self.send_error(400, "frame must be a number")
                return
            if not 0 <= frame < framestore.NUM_FRAMES:
                self.send_error(404, "no such frame buffer")
                return
            try:
                payload = frame_payload(frame)
            except LookupError as exc:
                self.send_error(409, str(exc))
                return
            self._send_bytes(200, "application/octet-stream", payload)
        else:
            self.send_error(404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/decode":
            self._do_decode()
            return
        if path.startswith("/control/"):
            query = urllib.parse.parse_qs(parsed.query)
            value = query.get("value", [None])[0]
            self._do_control(path[len("/control/"):],
                             int(value) if value is not None else None)
            return
        self.send_error(404)
    def _do_control(self, action, value):
        """Trick mode from the browser: pause, resume, blank, freeze a buffer.

        None of these touch the decoder's reset -- pause is repeat_frame=31,
        which holds the display on the current picture and lets the decoder
        stall behind it. See trick_mode.py.
        """
        try:
            control = controls()
            if action == "pause":
                control.set_freeze(True)
            elif action == "resume":
                control.set_freeze(False)
                control.set_source_select(trick_mode.SOURCE_LAST_DECODED)
            elif action == "blank":
                control.set_source_select(trick_mode.SOURCE_BLANK)
            elif action == "show_buffer":
                if value is None or not 0 <= value < framestore.NUM_FRAMES:
                    self.send_error(400, "buffer must be 0..3")
                    return
                control.set_source_select(trick_mode.SOURCE_FRAME_0 + value)
            elif action == "flush":
                control.flush_vbuf()
            elif action != "state":
                self.send_error(404, "unknown control")
                return
            state = control.trick_state()
        except OverlayNotApplied as exc:
            self._send_json(503, {"status": "no_overlay", "error": str(exc)})
            return
        except ValueError as exc:
            self.send_error(400, str(exc))
            return

        state["status"] = "ok"
        state["action"] = action
        self._send_json(200, state)

    def _do_decode(self):
        """Decode a whole stream, streaming every captured frame back as it lands.

        Chunked rather than one big response because a 150 picture clip is ~75
        MiB of planes and takes ten-odd seconds to capture: the browser gets to
        show progress and build its playback buffer as frames arrive, and the
        board only ever holds one frame at a time.
        """
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            self.send_error(400, "empty body")
            return
        data = self.rfile.read(length)
        print("[http] decode: %d bytes" % length)

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        def chunk(payload):
            self.wfile.write(b"%x\r\n" % len(payload) + payload + b"\r\n")

        try:
            sequence = decode_stream.elementary_stream.parse(data)
            chunk(_json_record({
                "kind": "start",
                "width": sequence.width,
                "height": sequence.height,
                "frame_rate": round(sequence.frame_rate, 3),
                "pictures": len(sequence.pictures),
            }))
            control = controls()
            first = not _controls["reset_done"]
            _controls["reset_done"] = True
            report = decode_stream.decode(
                data,
                lambda cap: chunk(_frame_record(cap)),
                on_capture_progress=lambda done, total: chunk(_json_record(
                    {"kind": "capturing", "captured": done, "total": total})),
                control=control, reset=first)
            report["kind"] = "done"
            _state.update(width=report.get("width", 0),
                          height=report.get("height", 0),
                          written=list(range(framestore.NUM_FRAMES)))
            chunk(_json_record(report))
            print("[http] decode done: %s" % report)
        except Exception as exc:                # noqa: BLE001 - tell the client
            print("[http] decode failed: %r" % (exc,))
            try:
                chunk(_json_record({"kind": "error", "error": repr(exc)}))
            except OSError:
                pass
        finally:
            try:
                self.wfile.write(b"0\r\n\r\n")
            except OSError:
                pass

    def _send_file(self, path, content_type):
        try:
            with open(path, "rb") as fp:
                data = fp.read()
        except FileNotFoundError:
            self.send_error(404)
            return
        self._send_bytes(200, content_type, data)

    def _send_json(self, code, payload):
        self._send_bytes(code, "application/json",
                         json.dumps(payload).encode())

    def _send_bytes(self, code, content_type, data):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def main():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    print("[http] listening on :%d" % HTTP_PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
