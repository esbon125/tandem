#!/usr/bin/env python3
"""
Fase 7b: minimal web server for the decoder demo.

Two independent listeners, deliberately not multiplexed on one port (the
`websockets` library can serve plain HTTP via process_request, but mixing
that with multipart-free file upload handling was more moving parts than
this needed):

  - HTTP  (default :8080): GET /            -> static/index.html
                            POST /upload     -> saves the raw request body
                                                to disk (decoder wiring is
                                                a follow-up step, not yet
                                                connected -- see
                                                docs/bringup Fase 7b)
  - WS    (default :8081): pushes frames read from a DDRRegion in a loop.
                            Message = 8-byte little-endian (width, height)
                            header + raw RGBA bytes, so the browser side
                            never needs to hardcode a resolution.

Right now the WS loop reads TEST_PATTERN_DEVICE (write_test_pattern.py's
target) so the browser <-> server <-> WebSocket half of the pipeline can be
proven independently of the still-unresolved real decode path (Fase 7a).
Switching FRAME_SOURCE to FRAMESTORE_DEVICE is the next step once that's
sorted out.
"""
import asyncio
import http.server
import os
import struct
import threading

import websockets

from ddr_region import DDRRegion, TEST_PATTERN_DEVICE

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
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status": "ok", "bytes": %d}' % length)

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
