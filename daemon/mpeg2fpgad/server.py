"""HTTP side of protocol v1 (api/PROTOCOL-v1.md, sections 2, 4 and 6).

http.server from the stdlib, one thread per connection, Connection: close on
every response. The request body of a decode is read as it arrives and the
frames go out as they are produced, both on the same request (section 3).
"""

import itertools
import json
import socket
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from . import __version__, i420
from .security import FailureBrake, token_ok
from .session import READ_PIECE, DecodeSession, end_record

PROTOCOL = "1.0"
PREFIX_CHECK = 1 << 20          # a decode must show a sequence header in its first MiB
MAX_HEADER_LINE = 16 << 10


class Daemon:
    """State shared by every connection: the board, the token, the one decode."""

    def __init__(self, board, token, tls=False, debug=False, log=print):
        self.board = board
        self.token = token
        self.tls = tls
        self.debug = debug
        self.log = log
        self.brake = FailureBrake()
        self.decode_lock = threading.Lock()
        self.session = None
        self.counter = itertools.count(1)
        self.limits = {"max_stream_bytes": None, "max_width": 1920, "max_height": 1088}

    def device(self):
        return {
            "product": "mpeg2fpga",
            "protocol": PROTOCOL,
            "versions": {"daemon": __version__, "driver": self.board.driver_version(),
                         "bitstream": self.board.build(), "core": self.board.core_version()},
            "capabilities": {"input": ["mpeg2-video-es"], "output": ["i420"],
                             "chroma_formats": ["4:2:0"]},
            "limits": self.limits,
            "security": {"tls": self.tls},
        }

    def status(self):
        session = self.session
        g = self.board.geometry()
        st = self.board.status()
        seq = None
        if g["width"]:
            seq = {"width": g["width"], "height": g["height"],
                   "frame_rate": round(g["frame_rate_millihz"] / 1000.0, 3),
                   "display_width": g["display_width"], "display_height": g["display_height"]}
        return {
            "state": "decoding" if session else ("error" if st["watchdog"] else "idle"),
            "decode": session.status() if session else None,
            "sequence": seq,
            "decoder": {"enabled": self.board.enabled(), "error": st["error"],
                        "watchdog": st["watchdog"], "video_change": st["video_change"]},
        }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mpeg2fpgad/" + __version__
    sys_version = ""
    timeout = 30                    # seconds without progress (slowloris)

    @property
    def daemon(self):
        return self.server.daemon_state

    def setup(self):
        self.request.settimeout(self.timeout)
        if isinstance(self.request, ssl.SSLSocket):
            self.request.do_handshake()           # in this thread, not the accept loop
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        super().setup()

    def log_message(self, fmt, *args):
        self.daemon.log("%s %s" % (self.client_address[0], fmt % args))

    # -- responses -------------------------------------------------------------

    def _json(self, status, obj, headers=()):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _error(self, status, code, message, retryable=False, headers=()):
        self._json(status, {"error": {"code": code, "message": message,
                                      "retryable": retryable}}, headers)

    # -- request plumbing --------------------------------------------------------

    def _body(self):
        """Request body as pieces, chunked or Content-Length, read on demand."""
        te = self.headers.get("Transfer-Encoding", "").lower()
        rfile = self.rfile
        if "chunked" in te:
            while True:
                line = rfile.readline(MAX_HEADER_LINE)
                size = int(line.split(b";")[0], 16)
                if size == 0:
                    while rfile.readline(MAX_HEADER_LINE) not in (b"\r\n", b"\n", b""):
                        pass                              # trailers
                    return
                left = size
                while left:
                    piece = rfile.read(min(left, READ_PIECE))
                    if not piece:
                        raise ConnectionError("client closed inside a chunk")
                    left -= len(piece)
                    yield piece
                rfile.readline(MAX_HEADER_LINE)           # CRLF after the chunk
        else:
            left = int(self.headers.get("Content-Length", "0"))
            while left:
                piece = rfile.read(min(left, READ_PIECE))
                if not piece:
                    raise ConnectionError("client closed %d bytes short" % left)
                left -= len(piece)
                yield piece

    def _authorized(self):
        ip = self.client_address[0]
        wait = self.daemon.brake.blocked(ip)
        if wait:
            self._error(429, "too_many_attempts", "too many wrong tokens; retry later",
                        True, [("Retry-After", str(int(wait) + 1))])
            return False
        if not token_ok(self.daemon.token, self.headers.get("Authorization")):
            self.daemon.brake.failed(ip)
            self._error(401, "unauthorized", "missing or wrong access token",
                        headers=[("WWW-Authenticate", 'Bearer realm="mpeg2fpga"')])
            return False
        self.daemon.brake.succeeded(ip)
        return True

    # -- routing -----------------------------------------------------------------

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def _route(self, method):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)
        if path == "/v1/health" and method == "GET":
            return self._json(200, {"ok": True})
        if not self._authorized():
            return
        d = self.daemon
        try:
            if path == "/v1/device" and method == "GET":
                return self._json(200, d.device())
            if path == "/v1/status" and method == "GET":
                return self._json(200, d.status())
            if path == "/v1/decode" and method == "POST":
                return self._decode(query)
            if path == "/v1/reset" and method == "POST":
                return self._reset()
            if path.startswith("/v1/debug/") and d.debug:
                return self._debug(method, path[len("/v1/debug/"):], query)
        except OSError as exc:
            if "decoder" in str(exc) or "mpeg2fpga" in str(exc):
                return self._error(503, "decoder_unavailable", str(exc), True)
            raise
        return self._error(404, "not_found", "no such endpoint: %s %s" % (method, path))

    # -- endpoints ---------------------------------------------------------------

    def _decode(self, query):
        d = self.daemon
        frames = query.get("frames", ["all"])[0]
        if frames not in ("all", "last"):
            return self._error(400, "bad_request", "frames must be 'all' or 'last'")
        max_frames = None
        if "max_frames" in query:
            try:
                max_frames = int(query["max_frames"][0])
                assert max_frames > 0
            except (ValueError, AssertionError):
                return self._error(400, "bad_request", "max_frames must be a positive integer")
        te = self.headers.get("Transfer-Encoding", "").lower()
        if "chunked" not in te and "Content-Length" not in self.headers:
            return self._error(400, "bad_request", "send Content-Length or chunked encoding")
        if not d.decode_lock.acquire(blocking=False):
            return self._error(409, "busy", "a decode is already running", True,
                               [("Retry-After", "1")])
        released = False
        try:
            body = self._body()
            # Look before touching the decoder: in the first MiB a real
            # MPEG-2 video stream has shown its sequence header.
            prefix, seen = [], 0
            for piece in body:
                prefix.append(piece)
                seen += len(piece)
                if seen >= PREFIX_CHECK:
                    break
            if b"\x00\x00\x01\xb3" not in b"".join(prefix):
                return self._error(400, "bad_request",
                                   "no MPEG-2 sequence header in the first MiB")
            decode_id = "d-%06d" % next(d.counter)
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.mpeg2fpga.frames; version=1")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("X-Decode-Id", decode_id)
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            wfile = self.wfile

            def send(record):
                wfile.write(b"%x\r\n" % len(record) + record + b"\r\n")

            session = DecodeSession(d.board, itertools.chain(prefix, body), send, decode_id,
                                    frames=frames, max_frames=max_frames, log=d.log)
            d.session = session
            t0 = time.time()
            try:
                summary = session.run()
            except (OSError, ConnectionError) as exc:
                d.log("%s: client went away (%r)" % (decode_id, exc))
                return
            finally:
                # free the decoder before END goes out (see session.run)
                d.session = None
                d.decode_lock.release()
                released = True
            send(end_record(summary))
            wfile.write(b"0\r\n\r\n")
            d.log("%s: %d frames, %d bytes in %.2f s, complete=%s"
                  % (decode_id, summary["frames_sent"], summary["bytes_in"],
                     time.time() - t0, summary["complete"]))
        finally:
            if not released:
                d.session = None
                d.decode_lock.release()

    def _reset(self):
        d = self.daemon
        session = d.session
        if session is not None:
            session.abort()
        if not d.decode_lock.acquire(timeout=30):
            return self._error(503, "decoder_unavailable", "decode did not stop", True)
        try:
            d.board.reset()
        finally:
            d.decode_lock.release()
        return self._json(200, d.status())

    def _debug(self, method, what, query):
        d = self.daemon
        if what == "perf" and method == "GET":
            return self._json(200, d.board.perf())
        if what.startswith("framestore/") and method == "GET":
            n = int(what.split("/")[1])
            g = d.board.geometry()
            y, cb, cr = d.board.read_frame(n, g["width"], g["height"])
            fmt = query.get("format", ["i420"])[0]
            data = (i420.to_i420(y, cb, cr, g["width"], g["height"]) if fmt == "i420"
                    else y + cb + cr)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("X-Geometry", "%dx%d" % (g["width"], g["height"]))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            return None
        if what.startswith("trick/") and method == "POST":
            action = what.split("/")[1]
            if action == "pause":
                d.board.set_freeze(True)
            elif action == "resume":
                d.board.set_freeze(False)
            elif action == "blank":
                d.board.set_source_select(1)
            elif action == "show_buffer":
                d.board.set_source_select(4 + int(query.get("n", ["0"])[0]) % 4)
            else:
                return self._error(404, "not_found", "unknown trick action")
            return self._json(200, {"ok": True})
        return self._error(404, "not_found", "unknown debug endpoint")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 16

    def __init__(self, address, daemon_state, tls_context=None, max_connections=8):
        self.daemon_state = daemon_state
        self.tls_context = tls_context
        self._slots = threading.BoundedSemaphore(max_connections)
        super().__init__(address, Handler)

    def get_request(self):
        sock, addr = super().get_request()
        if self.tls_context:
            sock = self.tls_context.wrap_socket(sock, server_side=True,
                                                do_handshake_on_connect=False)
        return sock, addr

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            try:
                request.settimeout(2)
                body = b'{"error": {"code": "busy", "message": "too many connections", "retryable": true}}'
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"
                                b"Content-Length: %d\r\nConnection: close\r\nRetry-After: 1\r\n\r\n"
                                % len(body) + body)
            except OSError:
                pass
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()
