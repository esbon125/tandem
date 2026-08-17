#!/usr/bin/env python3
"""
Fase 7b: minimal web server for the decoder demo.

Two independent listeners, deliberately not multiplexed on one port (the
`websockets` library can serve plain HTTP via process_request, but mixing
that with multipart-free file upload handling was more moving parts than
this needed):

  - HTTP  (default :8080): GET /            -> static/index.html
                            POST /upload     -> saves the raw request body
                                                to disk, then pushes it to
                                                the decoder over APB via
                                                decoder_push.py (Fase 7a's
                                                STREAM_PUSH_ADDR register,
                                                same mechanism as
                                                driver/mpeg2fpga/tools/
                                                push_stream.py). Responds
                                                with the register file
                                                before/after the push.
  - WS    (default :8081): pushes frames read from a DDRRegion in a loop.
                            Message = 8-byte little-endian (width, height)
                            header + raw RGBA bytes, so the browser side
                            never needs to hardcode a resolution.

The WS loop still reads TEST_PATTERN_DEVICE (write_test_pattern.py's
target), not the real framestore -- SIZE/DISP_SIZE staying 0 after a push
is still an open question (docs/bringup Fase 7a), so there is no real
framestore data to serve yet. The /upload response's register dump is the
intended next observation point for that investigation: it comes from a
single request/response instead of a manual SSH+scp round trip, using the
same UIO register file push_stream.py used. Switching FRAME_SOURCE to
FRAMESTORE_DEVICE is the follow-up once decode is confirmed working.
"""
import asyncio
import http.server
import json
import os
import struct
import threading

import websockets

from ddr_region import DDRRegion, TEST_PATTERN_DEVICE
from decoder_push import DecoderPusher, OverlayNotApplied

HTTP_PORT = 8080
WS_PORT = 8081

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
UPLOAD_PATH = "/tmp/uploaded_stream.m2v"

FRAME_SOURCE = TEST_PATTERN_DEVICE
FRAME_WIDTH = 320
FRAME_HEIGHT = 240
FRAME_BYTES = FRAME_WIDTH * FRAME_HEIGHT * 4
FRAME_FPS = 15


class HTTPHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[http] {self.address_string()} {fmt % args}")

    def do_GET(self):
        if self.path == "/":
            self._serve_file(os.path.join(STATIC_DIR, "index.html"), "text/html")
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/upload":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            self.send_error(400, "empty body")
            return
        body = self.rfile.read(length)
        with open(UPLOAD_PATH, "wb") as f:
            f.write(body)
        print(f"[http] saved upload: {length} bytes -> {UPLOAD_PATH}")

        try:
            with DecoderPusher() as pusher:
                before, after = pusher.push(body)
            print(f"[http] pushed to decoder: before={before} after={after}")
            response = {"status": "ok", "bytes": length, "regs_before": before, "regs_after": after}
        except OverlayNotApplied as e:
            print(f"[http] decoder push skipped: {e}")
            response = {"status": "saved_only", "bytes": length, "error": str(e)}

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(response).encode())

    def _serve_file(self, path, content_type):
        try:
            with open(path, "rb") as f:
                data = f.read()
        except FileNotFoundError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def run_http_server():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), HTTPHandler)
    print(f"[http] listening on :{HTTP_PORT}")
    server.serve_forever()


async def ws_handler(websocket, region):
    print(f"[ws] client connected: {websocket.remote_address}")
    header = struct.pack("<II", FRAME_WIDTH, FRAME_HEIGHT)
    period = 1.0 / FRAME_FPS
    try:
        while True:
            frame = region.read(0, FRAME_BYTES)
            await websocket.send(header + frame)
            await asyncio.sleep(period)
    except websockets.exceptions.ConnectionClosed:
        print(f"[ws] client disconnected: {websocket.remote_address}")


async def run_ws_server():
    with DDRRegion(FRAME_SOURCE) as region:
        async def handler(ws):
            await ws_handler(ws, region)

        async with websockets.serve(handler, "0.0.0.0", WS_PORT):
            print(f"[ws] listening on :{WS_PORT}, source={FRAME_SOURCE}")
            await asyncio.Future()


def main():
    threading.Thread(target=run_http_server, daemon=True).start()
    asyncio.run(run_ws_server())


if __name__ == "__main__":
    main()
