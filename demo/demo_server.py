#!/usr/bin/env python3
"""Web demo for the mpeg2fpga decoder, built on the Python client library.

The browser uploads a clip here; this server hands it to the decoder through
protocol v1 (mpeg2fpga.Device) and relays every frame back as it arrives. It
is just another client of the device -- it touches no hardware, so it runs on
a PC next to the board as well as on the board itself:

    python3 demo_server.py --device 192.168.18.5 --token-file token
    # then open http://localhost:8000

Replaces webserver/server.py, which drove the registers itself and handed
the browser raw frame store bytes to unscramble in JavaScript. Frames now
arrive as standard I420 from the daemon, and the trick-mode buttons are gone:
they control a display path this board does not have, and protocol v1 keeps
them out of the public API.

To the browser: chunked HTTP, records of [4-byte magic][u32 length][payload].
  M2HD  JSON events: start (geometry, frame count), done (decode summary),
        error
  M2FR  one frame: u32 display_index, u32 decode_index, u8 picture type
        ("I"/"P"/"B" as ASCII), 3 pad, u16 width, u16 height, then I420
"""

import argparse
import http.server
import json
import os
import struct
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
# the client library, from the installed wheel or straight from the tree
sys.path.append(os.path.join(HERE, os.pardir, "api", "python", "src"))
import mpeg2fpga  # noqa: E402

FRAME_RATES = {1: 23.976, 2: 24.0, 3: 25.0, 4: 29.97, 5: 30.0, 6: 50.0, 7: 59.94, 8: 60.0}


def stream_info(data):
    """Size, frame rate and frame count, for the progress bar. Field pictures
    pair up into frames; a stream with no picture coding extension (MPEG-1)
    counts every picture."""
    info = {"width": 0, "height": 0, "frame_rate": 0.0, "pictures": 0}
    frames = fields = 0
    at = data.find(b"\x00\x00\x01")
    while 0 <= at < len(data) - 8:
        code = data[at + 3]
        if code == 0xB3 and not info["width"]:
            info["width"] = (data[at + 4] << 4) | (data[at + 5] >> 4)
            info["height"] = ((data[at + 5] & 0x0F) << 8) | data[at + 6]
            info["frame_rate"] = FRAME_RATES.get(data[at + 7] & 0x0F, 0.0)
        elif code == 0x00:
            info["pictures"] += 1
        elif code == 0xB5 and data[at + 4] >> 4 == 8:
            if data[at + 6] & 3 == 3:
                frames += 1
            else:
                fields += 1
        at = data.find(b"\x00\x00\x01", at + 3)
    if frames + fields:
        info["pictures"] = frames + fields // 2
    return info


def record(magic, payload):
    return magic + struct.pack("<I", len(payload)) + payload


def frame_record(f):
    head = struct.pack("<IIB3xHH", f.display_index, f.decode_index,
                       ord(f.picture_type[0]), f.width, f.height)
    return record(b"M2FR", head + bytes(f.y) + bytes(f.u) + bytes(f.v))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[demo] %s %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, "application/json", json.dumps(obj).encode())

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            with open(os.path.join(HERE, "static", "index.html"), "rb") as fp:
                return self._send(200, "text/html; charset=utf-8", fp.read())
        try:
            if path == "/api/device":
                return self._json(200, self.server.device.info())
            if path == "/api/status":
                return self._json(200, self.server.device.status())
        except (mpeg2fpga.DeviceError, OSError) as exc:
            return self._json(502, {"error": str(exc)})
        self.send_error(404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/reset":
            try:
                return self._json(200, self.server.device.reset())
            except (mpeg2fpga.DeviceError, OSError) as exc:
                return self._json(502, {"error": str(exc)})
        if path != "/api/decode":
            return self.send_error(404)
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            return self.send_error(400, "empty body")
        data = self.rfile.read(length)

        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

        def chunk(payload):
            self.wfile.write(b"%x\r\n" % len(payload) + payload + b"\r\n")

        def event(obj):
            chunk(record(b"M2HD", json.dumps(obj).encode()))

        info = stream_info(data)
        try:
            event(dict(info, kind="start"))
            t0 = time.time()
            result = self.server.device.decode(data)
            n = 0
            for frame in result:
                chunk(frame_record(frame))
                n += 1
            seconds = time.time() - t0
            done = dict(result.summary, kind="done", frames=n,
                        client_seconds=round(seconds, 3),
                        fps=round(n / seconds, 2) if seconds else 0.0,
                        frame_rate=info["frame_rate"], decode_id=result.decode_id)
            event(done)
        except Exception as exc:                # noqa: BLE001 - tell the browser
            sys.stderr.write("[demo] decode failed: %r\n" % (exc,))
            try:
                event({"kind": "error", "error": str(exc)})
            except OSError:
                pass
        finally:
            try:
                self.wfile.write(b"0\r\n\r\n")
            except OSError:
                pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--device", default=os.environ.get("MPEG2FPGA_HOST", "127.0.0.1"),
                    help="the decoder's address (default $MPEG2FPGA_HOST or 127.0.0.1)")
    ap.add_argument("--device-port", type=int)
    ap.add_argument("--token-file", default=os.environ.get("MPEG2FPGA_TOKEN_FILE",
                                                          "/etc/mpeg2fpgad/token"))
    ap.add_argument("--tls-fingerprint", help="sha256:... to use TLS and pin the device")
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    args = ap.parse_args()

    with open(args.token_file) as fp:
        token = fp.read().strip()
    server = http.server.ThreadingHTTPServer((args.listen, args.port), Handler)
    server.daemon_threads = True
    server.device = mpeg2fpga.Device(args.device, token=token, port=args.device_port,
                                     tls_fingerprint=args.tls_fingerprint, timeout=60)
    info = server.device.info()
    sys.stderr.write("[demo] device %s: bitstream %s, daemon %s; open http://%s:%d\n"
                     % (args.device, info.versions.bitstream, info.versions.daemon,
                        args.listen, args.port))
    server.serve_forever()


if __name__ == "__main__":
    main()
