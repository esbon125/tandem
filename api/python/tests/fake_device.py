"""A stand-in for the device side of protocol v1, for the client's tests.

Deliberately written separately from the client (blocking socket file I/O,
its own chunked decoding), so a bug shared by both sides cannot make the
tests pass. Its decode answers one FRAME per received upload chunk, sized to
overflow socket buffers, so a client that does not read while it uploads
deadlocks -- which is the property the real device depends on.
"""

import json
import socket
import socketserver
import ssl
import struct
import threading

TOKEN = "test-token-0123456789"
COMMON = struct.Struct("<4sBBHI")
FRAME = struct.Struct("<IIHHBBHI")


def record(rtype, extra, payload):
    return COMMON.pack(b"M2FR", rtype, 0, COMMON.size + len(extra), len(payload)) + extra + payload


class Handler(socketserver.StreamRequestHandler):
    def send(self, data):
        self.wfile.write(data)
        self.wfile.flush()

    def send_chunk(self, data):
        self.send(b"%x\r\n" % len(data) + data + b"\r\n")

    def respond(self, status, obj, reason="X", extra_headers=""):
        body = json.dumps(obj).encode()
        self.send(("HTTP/1.1 %d %s\r\nContent-Type: application/json\r\n"
                   "Content-Length: %d\r\n%sConnection: close\r\n\r\n"
                   % (status, reason, len(body), extra_headers)).encode() + body)

    def error(self, status, code, retryable=False, extra_headers=""):
        self.respond(status, {"error": {"code": code, "message": code, "retryable": retryable}},
                     extra_headers=extra_headers)

    def body_chunks(self, headers):
        if "chunked" in headers.get("transfer-encoding", ""):
            while True:
                size = int(self.rfile.readline().split(b";")[0], 16)
                if size == 0:
                    self.rfile.readline()
                    return
                data = self.rfile.read(size)
                self.rfile.readline()
                yield data
        else:
            n = int(headers.get("content-length", "0"))
            if n:
                yield self.rfile.read(n)

    def handle(self):
        server = self.server
        request = self.rfile.readline().decode().split()
        if not request:
            return
        method, path = request[0], request[1]
        headers = {}
        while True:
            line = self.rfile.readline().decode().strip()
            if not line:
                break
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
        server.seen_paths.append(path)

        if path == "/v1/health":
            return self.respond(200, {"ok": True})
        if headers.get("authorization") != "Bearer " + TOKEN:
            return self.error(401, "unauthorized", extra_headers="WWW-Authenticate: Bearer\r\n")
        if path == "/v1/device":
            return self.respond(200, {"product": "mpeg2fpga", "protocol": server.protocol,
                                      "limits": {"max_stream_bytes": None, "max_width": 1920}})
        if path == "/v1/status":
            return self.respond(200, {"state": "decoding" if server.busy else "idle"})
        if path == "/v1/reset" and method == "POST":
            return self.respond(200, {"state": "idle"})
        if path.startswith("/v1/decode") and method == "POST":
            return self.decode(path, headers)
        return self.error(404, "not_found")

    def decode(self, path, headers):
        server = self.server
        if server.busy:
            return self.error(409, "busy", retryable=True, extra_headers="Retry-After: 2\r\n")
        server.busy = True
        try:
            self.send(b"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.mpeg2fpga.frames; "
                      b"version=1\r\nTransfer-Encoding: chunked\r\nX-Decode-Id: d-000001\r\n"
                      b"Connection: close\r\n\r\n")
            w, h = server.frame_size
            total, n = 0, 0
            for chunk in self.body_chunks(headers):
                total += len(chunk)
                y = bytes([n & 0xFF]) * (w * h)
                c = bytes([(n * 3) & 0xFF]) * ((w // 2) * (h // 2))
                extra = FRAME.pack(n, n ^ 1, w, h, 1 + n % 3, 0, 0, 0)
                if server.extra_header_bytes:
                    extra += b"\xAA" * server.extra_header_bytes   # a future v1.x field
                self.send_chunk(record(1, extra, y + c + c))
                if server.unknown_record:
                    self.send_chunk(record(9, b"", b"from the future"))
                n += 1
                if server.cut_after is not None and n >= server.cut_after:
                    self.send(b"0\r\n\r\n")           # ends the body with no END record
                    return
            end = {"id": "d-000001", "frames_sent": n, "bytes_in": total, "complete": True,
                   "aborted": False, "decoder": {"error": False, "watchdog": False}}
            self.send_chunk(record(2, b"", json.dumps(end).encode()))
            self.send(b"0\r\n\r\n")
        finally:
            server.busy = False


class FakeDevice(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, tls_context=None):
        super().__init__(("127.0.0.1", 0), Handler)
        self.tls_context = tls_context
        self.protocol = "1.0"
        self.busy = False
        self.frame_size = (256, 256)
        self.cut_after = None
        self.extra_header_bytes = 0
        self.unknown_record = False
        self.seen_paths = []
        self.thread = threading.Thread(target=self.serve_forever, args=(0.05,), daemon=True)

    def server_bind(self):
        # Small buffers make a client that does not read while it uploads
        # deadlock after kilobytes instead of megabytes. They must be set on
        # the listening socket, before the handshake: shrinking them on an
        # accepted connection leaves TCP stalling on zero-window probes
        # (~0.4 s per frame here), which tests nothing.
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
        super().server_bind()

    def get_request(self):
        sock, addr = super().get_request()
        if self.tls_context:
            sock = self.tls_context.wrap_socket(sock, server_side=True)
        return sock, addr

    @property
    def port(self):
        return self.server_address[1]

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.shutdown()
        self.server_close()


def tls_server_context(certfile, keyfile):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile, keyfile)
    return ctx
