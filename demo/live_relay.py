#!/usr/bin/env python3
"""Public live demo relay: the page on GitHub Pages talks to this, this talks
to the decoder.

    live_relay.py --device 192.168.18.5 --token-file token \
        --preset bridge=clips/tos_bridge.m2v="Tears of Steel: el puente" ...
    tailscale funnel --bg 8000          # https://<host>.<tailnet>.ts.net

Runs on a PC next to the board, never on the board: it transcodes with
ffmpeg, holds the device token (the page is public, it cannot), and keeps the
board itself off the internet. The tunnel terminates TLS, so the board does
not pay for it (protocol v1 sec. 6.2).

What it does with a clip:
  1. normalize: whatever ffmpeg reads -> at most 20 s of MPEG-2 MP@ML,
     352x288 letterboxed, <= 30 fps, GOP 12, no loaded quantiser matrices --
     the regime tools/demo-clip measured (> 2x real time, MAD < 0.2). Presets
     are already in that form and skip this step.
  2. reference: the same normalized stream decoded in software (libavcodec).
  3. decode it on the board (protocol v1) at full speed into memory, never
     at the network's pace, and for every frame compute MAD and peak error
     against the reference on the raw I420 the decoder produced; only then
     recompress it for the trip to the browser. The metrics are the
     decoder's; the recompression is transport only. ?transport=h264
     (default, fragmented MP4, ~0.5-0.9 Mbit/s), jpeg (~4 Mbit/s) or raw
     (I420, ~30 Mbit/s at real time).

To the browser: chunked HTTP, records of [4-byte magic][u32 length][payload]
  M2HD  JSON events: queued, normalizing, start (with a session id), done,
        error
  M2MT  frame metadata only (h264): the 24-byte header
  M2MP  a piece of fragmented MP4 (h264), in order
  M2JP  frame: 24-byte header + JPEG
  M2RW  frame: 24-byte header + I420
GET /api/progress?id=SESSION: decoder-side progress, on its own connection.
  header: u32 display_index, u32 decode_index, u8 picture type (ASCII),
          3 pad, u16 width, u16 height, f32 MAD, u8 peak, 3 pad

Public, so: one decode at a time with a visible queue, a cap on uploads,
per-address rate limit, CORS only for the page's origin, ffmpeg restricted
to local files (an uploaded playlist must not make it fetch URLs), nothing
kept after the response. No reset endpoint and no device status beyond
versions.
"""

import argparse
import collections
import io
import queue
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.append(os.path.join(HERE, os.pardir, "api", "python", "src"))
import mpeg2fpga  # noqa: E402
from demo_server import record, stream_info  # noqa: E402

WIDTH, HEIGHT = 352, 288
MAX_SECONDS = 20
MAX_UPLOAD = 64 << 20
FFMPEG_TIMEOUT_S = 90
RATE_WINDOW_S, RATE_MAX = 600, 12          # decodes per address per window
QUEUE_MAX = 4
JPEG_QUALITY = 90
# MPEG-2 frame rates the normalizer may pick, as ffmpeg rationals
RATES = [(24000 / 1001, "24000/1001"), (24.0, "24"), (25.0, "25"),
         (30000 / 1001, "30000/1001"), (30.0, "30")]
FRAME_HEADER = struct.Struct("<IIB3xHHfB3x")


class Rejected(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------------------
# ffmpeg
# ---------------------------------------------------------------------------

def run(cmd, **kw):
    return subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True,
                          timeout=FFMPEG_TIMEOUT_S, **kw)


def probe(path):
    p = run(["ffprobe", "-v", "error", "-protocol_whitelist", "file",
             "-select_streams", "v:0", "-show_entries",
             "stream=codec_name,width,height,avg_frame_rate,r_frame_rate:format=duration",
             "-of", "json", path])
    info = json.loads(p.stdout or b"{}")
    if not info.get("streams"):
        raise Rejected(415, "el archivo no tiene video que ffmpeg pueda leer")
    s = info["streams"][0]

    def rate(text):
        num, _, den = (text or "0/1").partition("/")
        return float(num) / float(den or 1) if float(den or 1) else 0.0
    fps = rate(s.get("avg_frame_rate")) or rate(s.get("r_frame_rate"))
    return {"codec": s.get("codec_name"), "width": s.get("width"),
            "height": s.get("height"), "frame_rate": round(fps, 3),
            "duration": float(info.get("format", {}).get("duration") or 0)}


def pick_rate(fps):
    while fps > 30.5:                       # 50/60 -> 25/30
        fps /= 2
    return min(RATES, key=lambda r: abs(r[0] - (fps or 25.0)))[1]


def normalize(src, dst, fps):
    # square pixels first, fit into 4:3 (384x288 square), then squeeze to
    # 352x288 with the 12:11 pixels CIF is defined with
    vf = ("scale=trunc(iw*sar/2)*2:ih,setsar=1,"
          "scale=384:288:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos,"
          "pad=384:288:(ow-iw)/2:(oh-ih)/2,scale=352:288:flags=lanczos,setsar=12/11,"
          "fps=%s,format=yuv420p" % pick_rate(fps))
    p = run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
             "-protocol_whitelist", "file", "-i", src, "-map", "0:v:0",
             "-an", "-sn", "-dn", "-t", str(MAX_SECONDS), "-vf", vf,
             "-c:v", "mpeg2video", "-g", "12", "-bf", "2", "-b:v", "1500k",
             "-maxrate", "2500k", "-bufsize", "1835008", "-aspect", "4:3",
             "-threads", "4", "-f", "mpeg2video", "-y", dst])
    if p.returncode != 0 or not os.path.getsize(dst):
        raise Rejected(415, "ffmpeg no pudo convertir el video: "
                       + p.stderr.decode(errors="replace").strip()[-200:])


def reference_frames(path):
    """The software decode, display order, one I420 frame per row."""
    p = run(["ffmpeg", "-nostdin", "-v", "error", "-protocol_whitelist", "file",
             "-i", path, "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"])
    size = WIDTH * HEIGHT * 3 // 2
    if p.returncode != 0 or len(p.stdout) % size:
        raise Rejected(500, "la decodificación de referencia falló")
    return np.frombuffer(p.stdout, np.uint8).reshape(-1, size)


def check_stream(data):
    """Normalized streams and presets must be exactly what the decoder was
    measured on."""
    info = stream_info(data)
    if (info["width"], info["height"]) != (WIDTH, HEIGHT):
        raise Rejected(500, "stream normalizado con tamaño inesperado")
    at = data.find(b"\x00\x00\x01\xb3")
    if data[at + 11] & 3:
        raise Rejected(500, "stream normalizado con matriz de cuantización cargada")
    return info


# ---------------------------------------------------------------------------
# frames
# ---------------------------------------------------------------------------

def to_rgb(i420):
    """BT.601 limited range, the same conversion the old demo page did in JS."""
    y = i420[:WIDTH * HEIGHT].reshape(HEIGHT, WIDTH).astype(np.float32) - 16
    c = WIDTH * HEIGHT // 4
    u = i420[WIDTH * HEIGHT:WIDTH * HEIGHT + c].reshape(HEIGHT // 2, WIDTH // 2)
    v = i420[WIDTH * HEIGHT + c:].reshape(HEIGHT // 2, WIDTH // 2)
    u = u.repeat(2, 0).repeat(2, 1).astype(np.float32) - 128
    v = v.repeat(2, 0).repeat(2, 1).astype(np.float32) - 128
    y *= 1.164
    rgb = np.stack([y + 1.596 * v, y - 0.813 * v - 0.391 * u, y + 2.018 * u], -1)
    return np.clip(rgb, 0, 255).astype(np.uint8)


TRANSPORTS = ("h264", "jpeg", "raw")


class H264Transport:
    """The decoder's frames recompressed for the trip to the browser: fragmented
    MP4 (H.264 Constrained Baseline 3.0, what every MediaSource plays), one
    fragment per GOP of half a second, queued as M2MP records as ffmpeg emits
    them. Roughly a third of the JPEG bytes at similar quality. Transport
    only: the metrics were already taken on the raw I420 (M2MT records)."""

    def __init__(self, frame_rate, frames):
        rate = next((r for v, r in RATES if abs(v - frame_rate) < 0.01), "25")
        gop = str(max(1, round(frame_rate / 2)))
        self.proc = subprocess.Popen(
            ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
             "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", "%dx%d" % (WIDTH, HEIGHT),
             "-r", rate, "-i", "-", "-vf", "setsar=12/11",
             "-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
             "-profile:v", "baseline", "-level", "3.0", "-pix_fmt", "yuv420p",
             "-crf", "21", "-maxrate", "1800k", "-bufsize", "1800k",
             "-g", gop, "-keyint_min", gop, "-sc_threshold", "0",
             "-movflags", "frag_keyframe+empty_moov+default_base_moof",
             "-f", "mp4", "-"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.reader = threading.Thread(target=self._read, args=(frames,), daemon=True)
        self.reader.start()

    def _read(self, frames):
        while True:
            chunk = self.proc.stdout.read1(1 << 16)
            if not chunk:
                break
            frames.put(record(b"M2MP", chunk))

    def write(self, i420):
        self.proc.stdin.write(i420.tobytes())

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        self.reader.join(30)
        self.proc.wait(10)


def jpeg(i420):
    out = io.BytesIO()
    Image.fromarray(to_rgb(i420), "RGB").save(out, "JPEG", quality=JPEG_QUALITY)
    return out.getvalue()


# ---------------------------------------------------------------------------
# admission: rate limit and a single decoder with a visible queue
# ---------------------------------------------------------------------------

class Admission:
    def __init__(self):
        self.lock = threading.Condition()
        self.next_ticket = 0
        self.serving = 0
        self.finished = set()       # tickets done out of turn (left the queue)
        self.recent = collections.defaultdict(collections.deque)

    def rate_check(self, addr):
        now = time.time()
        with self.lock:
            q = self.recent[addr]
            while q and now - q[0] > RATE_WINDOW_S:
                q.popleft()
            if len(q) >= RATE_MAX:
                raise Rejected(429, "demasiados pedidos desde esta dirección; "
                               "probá de nuevo en unos minutos")
            q.append(now)

    def ticket(self):
        with self.lock:
            if self.next_ticket - self.serving >= QUEUE_MAX:
                raise Rejected(503, "la demo está ocupada; probá en un rato")
            t = self.next_ticket
            self.next_ticket += 1
            return t

    def wait(self, ticket, on_position):
        with self.lock:
            while ticket != self.serving:
                on_position(ticket - self.serving)
                self.lock.wait(1.0)

    def done(self, ticket):
        with self.lock:
            if ticket < self.serving or ticket in self.finished:
                return                          # already released
            self.finished.add(ticket)
            while self.serving in self.finished:
                self.finished.remove(self.serving)
                self.serving += 1
            self.lock.notify_all()

    def queued(self):
        with self.lock:
            return self.next_ticket - self.serving


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "mpeg2fpga-live"
    sys_version = ""

    def log_message(self, fmt, *args):
        sys.stderr.write("[live] %s %s\n" % (self.client(), fmt % args))

    def client(self):
        # behind the tunnel every connection comes from loopback
        fwd = self.headers.get("X-Forwarded-For") if self.headers else None
        if fwd and self.client_address[0] in ("127.0.0.1", "::1"):
            return fwd.split(",")[0].strip()
        return self.client_address[0]

    def cors(self):
        origin = self.headers.get("Origin")
        if origin in self.server.origins:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.cors()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.send_header("Access-Control-Allow-Methods", "GET, POST")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "600")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/health":
            return self._json(200, self.server.health())
        if path == "/api/progress":
            sid = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("id", [""])[0]
            st = self.server.sessions.get(sid)
            if st is None:
                return self._json(404, {"error": "no existe esa sesión"})
            return self._json(200, {"decoded": st["count"], "total": st["total"],
                                    "summary": st.get("summary"),
                                    "error": "error" in st})
        self._json(404, {"error": "no existe"})

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        if url.path != "/api/decode":
            return self._json(404, {"error": "no existe"})
        query = urllib.parse.parse_qs(url.query)
        preset = query.get("preset", [None])[0]
        transport = query.get("transport", ["h264"])[0]
        if query.get("raw", ["0"])[0] == "1":
            transport = "raw"
        if transport not in TRANSPORTS:
            return self._json(400, {"error": "transport: h264, jpeg o raw"})
        work = None
        self.producer_owns_ticket = False   # one handler serves a keep-alive connection
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if preset is not None and preset not in self.server.presets:
                raise Rejected(404, "no existe ese clip")
            if preset is None and not 0 < length <= MAX_UPLOAD:
                raise Rejected(413, "el archivo tiene que pesar hasta %d MB" % (MAX_UPLOAD >> 20))
            self.server.admission.rate_check(self.client())
            ticket = self.server.admission.ticket()
        except Rejected as exc:
            self.close_connection = True
            return self._json(exc.code, {"error": str(exc)})

        try:
            # read the upload before answering: the browser sends the whole body
            # first anyway, and a streamed reply can't carry a 4xx any more
            if preset is None:
                work = tempfile.mkdtemp(prefix="m2live-")
                src = os.path.join(work, "input")
                with open(src, "wb") as fp:
                    left = length
                    while left:
                        chunk = self.rfile.read(min(left, 1 << 20))
                        if not chunk:
                            raise ConnectionError("upload cut short")
                        fp.write(chunk)
                        left -= len(chunk)
            self.stream(ticket, preset, work, transport)
        except (ConnectionError, BrokenPipeError):
            pass
        finally:
            # once the producer runs it owns the board and releases it as soon
            # as the decode ends -- not when this visitor's network catches up,
            # and not earlier if this visitor hangs up mid-decode
            if not self.producer_owns_ticket:
                self.server.admission.done(ticket)
            if work:
                shutil.rmtree(work, ignore_errors=True)

    # -- the streamed reply --------------------------------------------------

    def produce(self, data, ref, transport, info, ticket, frames, decoded):
        """Pull every frame off the board as fast as it comes, score it against
        the reference on the raw I420, pack it for the wire, queue it."""
        mads, peaks = [], []
        encoder = None
        try:
            if transport == "h264":
                encoder = H264Transport(info["frame_rate"], frames)
            t0 = time.monotonic()
            first = None
            result = self.server.device.decode(data)
            for f in result:
                if first is None:
                    first = time.monotonic() - t0
                i420 = np.frombuffer(bytes(f.y) + bytes(f.u) + bytes(f.v), np.uint8)
                if f.display_index < len(ref):
                    d = np.abs(i420.astype(np.int16) - ref[f.display_index])
                    mad, peak = float(d.mean()), int(d.max())
                else:
                    mad, peak = -1.0, 255
                mads.append(mad)
                peaks.append(peak)
                head = FRAME_HEADER.pack(f.display_index, f.decode_index,
                                         ord(f.picture_type[0]), f.width, f.height,
                                         mad, min(peak, 255))
                if transport == "raw":
                    frames.put(record(b"M2RW", head + i420.tobytes()))
                elif transport == "jpeg":
                    frames.put(record(b"M2JP", head + jpeg(i420)))
                else:
                    frames.put(record(b"M2MT", head))
                    encoder.write(i420)
                decoded["count"] = len(mads)
            seconds = time.monotonic() - t0
            n = len(mads)
            ok = [m for m in mads if m >= 0]
            summary = result.summary
            decoded["summary"] = dict(
                frames=n, seconds=round(seconds, 3),
                first_frame_s=round(first or 0, 3),
                fps=round(n / seconds, 2) if seconds else 0.0,
                frame_rate=info["frame_rate"], complete=summary.complete,
                decoder=dict(summary.decoder),
                mad_mean=sum(ok) / len(ok) if ok else None,
                mad_max=max(ok) if ok else None,
                peak_max=max(peaks) if peaks else None,
                bitstream=self.server.versions.get("bitstream"))
        except Exception as exc:                # noqa: BLE001 - handed to stream()
            decoded["error"] = exc
        finally:
            self.server.admission.done(ticket)
            if encoder:
                encoder.close()                 # flushes the last fragments first
            frames.put(None)

    def stream(self, ticket, preset, work, transport):
        self.send_response(200)
        self.cors()
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        def chunk(payload):
            self.wfile.write(b"%x\r\n" % len(payload) + payload + b"\r\n")
            self.wfile.flush()

        def event(**obj):
            chunk(record(b"M2HD", json.dumps(obj).encode()))

        try:
            self.server.admission.wait(ticket, lambda n: event(kind="queued", position=n))
            if preset is None:
                event(kind="normalizing")
                src = os.path.join(work, "input")
                source = probe(src)
                dst = os.path.join(work, "clip.m2v")
                normalize(src, dst, source["frame_rate"])
                data = open(dst, "rb").read()
                label = None
            else:
                label, data = self.server.presets[preset]
                source = None
            info = check_stream(data)
            ref = reference_frames(self.server.preset_paths[preset] if preset
                                   else os.path.join(work, "clip.m2v"))
            sid = self.server.new_session(info["pictures"])
            event(kind="start", source=source, preset=label, bytes=len(data),
                  reference_frames=len(ref), session=sid, **info)

            # The board is drained at full speed into memory, never at the
            # network's pace: protocol v1 has flow control, so a slow reader
            # here would freeze the decoder (sec. 4) and the page would be
            # measuring the visitor's connection and calling it the FPGA.
            frames = queue.Queue()
            decoded = self.server.sessions[sid]
            self.producer_owns_ticket = True    # it releases the board when done
            producer = threading.Thread(
                target=self.produce, daemon=True,
                args=(data, ref, transport, info, ticket, frames, decoded))
            producer.start()
            while True:
                item = frames.get()
                if item is None:
                    break
                chunk(item)
            if "error" in decoded:
                raise decoded["error"]
            event(kind="done", **decoded["summary"])
            sys.stderr.write("[live] %s decoded %s: %d frames %.1f fps mad %.3f\n" % (
                self.client(), preset or "upload", decoded["summary"]["frames"],
                decoded["summary"]["fps"], decoded["summary"]["mad_mean"] or -1))
        except Rejected as exc:
            event(kind="error", error=str(exc))
        except subprocess.TimeoutExpired:
            event(kind="error", error="ffmpeg tardó demasiado con ese archivo")
        except (BrokenPipeError, ConnectionError):
            raise
        except Exception as exc:                # noqa: BLE001 - tell the browser
            sys.stderr.write("[live] decode failed: %r\n" % (exc,))
            try:
                event(kind="error", error="el decodificador no está disponible")
            except OSError:
                pass
        finally:
            try:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except OSError:
                pass


class Relay(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, device, presets, origins):
        super().__init__(addr, Handler)
        self.device = device
        self.origins = set(origins)
        self.admission = Admission()
        self.preset_paths = {k: path for k, (path, _) in presets.items()}
        self.presets = {}
        for key, (path, label) in presets.items():
            data = open(path, "rb").read()
            check_stream(data)
            self.presets[key] = (label, data)
        self.versions = {}
        self._health = (0.0, None)
        # decoder-side progress by session id, polled on its own connection:
        # in the frame stream it would queue behind megabytes of socket and
        # tunnel buffers and arrive long after the board finished
        self.sessions = {}
        self.sessions_lock = threading.Lock()

    def new_session(self, total):
        sid = os.urandom(9).hex()
        now = time.time()
        with self.sessions_lock:
            for k in [k for k, v in self.sessions.items() if now - v["created"] > 900]:
                del self.sessions[k]
            self.sessions[sid] = {"created": now, "total": total, "count": 0}
        return sid

    def health(self):
        at, cached = self._health
        if time.time() - at < 10 and cached:
            return dict(cached, queued=self.admission.queued())
        try:
            info = self.device.info()
            self.versions = dict(info.versions)
            up = True
        except Exception:                       # noqa: BLE001
            up = False
        cached = {"ok": up, "versions": self.versions,
                  "presets": [{"id": k, "label": v[0]} for k, v in self.presets.items()],
                  "max_seconds": MAX_SECONDS, "max_upload_mb": MAX_UPLOAD >> 20}
        self._health = (time.time(), cached)
        return dict(cached, queued=self.admission.queued())


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--device", default=os.environ.get("MPEG2FPGA_HOST", "192.168.18.5"))
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--origin", action="append", default=[],
                    help="origin allowed by CORS (repeatable)")
    ap.add_argument("--preset", action="append", default=[],
                    help="ID=PATH.m2v=LABEL, an already normalized clip")
    args = ap.parse_args()

    presets = {}
    for spec in args.preset:
        key, path, label = spec.split("=", 2)
        presets[key] = (path, label)
    with open(args.token_file) as fp:
        token = fp.read().strip()
    device = mpeg2fpga.Device(args.device, token=token, timeout=60)
    origins = args.origin or ["https://esbon125.github.io"]
    server = Relay((args.listen, args.port), device, presets, origins)
    h = server.health()
    sys.stderr.write("[live] device %s %s, presets %s, origins %s, listening %s:%d\n"
                     % (args.device, "up " + str(h["versions"].get("bitstream"))
                        if h["ok"] else "DOWN", ",".join(presets) or "-",
                        ",".join(origins), args.listen, args.port))
    server.serve_forever()


if __name__ == "__main__":
    main()
