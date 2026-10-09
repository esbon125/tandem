"""Client for the mpeg2fpga decoder, protocol v1 (api/PROTOCOL-v1.md)."""

import io
import json
import os
from urllib.parse import urlencode

from . import _http
from .errors import DecodeIncomplete, from_response
from .protocol import (FRAME_HEADER, PICTURE_TYPES, PROTOCOL_MAJOR, RECORD_END,
                       RECORD_FRAME, ProtocolError, read_record)

DEFAULT_PORT = 8080
DEFAULT_TLS_PORT = 8443
UPLOAD_CHUNK = 256 * 1024


class _Obj(dict):
    """dict with attribute access, for JSON answers (`info.limits.max_width`)."""

    def __getattr__(self, name):
        try:
            value = self[name]
        except KeyError:
            raise AttributeError(name)
        return _Obj(value) if isinstance(value, dict) else value


class Frame:
    """One decoded picture, I420: y is width*height bytes, u and v a quarter each."""

    __slots__ = ("display_index", "decode_index", "width", "height",
                 "picture_type", "structure", "y", "u", "v")

    def __init__(self, extra, payload):
        if len(extra) < FRAME_HEADER.size:
            raise ProtocolError("FRAME record header too short")
        (self.display_index, self.decode_index, self.width, self.height,
         ptype, self.structure, _r0, _r1) = FRAME_HEADER.unpack_from(extra)
        self.picture_type = PICTURE_TYPES.get(ptype, "?")
        ysize = self.width * self.height
        csize = (self.width // 2) * (self.height // 2)
        if len(payload) < ysize + 2 * csize:
            raise ProtocolError("FRAME payload %d bytes, expected %d"
                                % (len(payload), ysize + 2 * csize))
        mv = memoryview(payload)
        self.y = mv[:ysize]
        self.u = mv[ysize:ysize + csize]
        self.v = mv[ysize + csize:ysize + 2 * csize]

    def to_numpy(self):
        """(Y, U, V) as numpy arrays; numpy is optional and imported here."""
        import numpy as np

        w, h = self.width, self.height
        return (np.frombuffer(self.y, np.uint8).reshape(h, w),
                np.frombuffer(self.u, np.uint8).reshape(h // 2, w // 2),
                np.frombuffer(self.v, np.uint8).reshape(h // 2, w // 2))

    def __repr__(self):
        return "<Frame %d %s %dx%d>" % (self.display_index, self.picture_type,
                                        self.width, self.height)


class DecodeResult:
    """Iterate to get Frames in display order; then `summary` holds END's report.

    The upload runs while you iterate, so iterate promptly: pausing between
    frames pauses the upload too (and the device then pauses the decoder) --
    nothing is lost, it just goes slower.
    """

    def __init__(self, chunks, decode_id):
        self.decode_id = decode_id
        self.summary = None
        self._chunks = chunks
        self._buf = bytearray()
        self._iter = self._frames()

    def __iter__(self):
        return self._iter

    def __next__(self):
        return next(self._iter)

    def _read_exact(self, n):
        while len(self._buf) < n:
            try:
                self._buf += next(self._chunks)
            except StopIteration:
                break
        if not self._buf and n:
            return b""
        out = bytes(self._buf[:n])
        del self._buf[:n]
        return out

    def _frames(self):
        while True:
            record = read_record(self._read_exact)
            if record is None:
                raise DecodeIncomplete("frame stream ended without an END record")
            rtype, extra, payload = record
            if rtype == RECORD_FRAME:
                yield Frame(extra, payload)
            elif rtype == RECORD_END:
                self.summary = _Obj(json.loads(payload.decode("utf-8")))
                return
            # unknown record types are skipped: that is how v1 grows

    def wait(self):
        """Consume (and discard) the remaining frames; return the summary."""
        for _ in self:
            pass
        return self.summary


def _source_chunks(source, chunk_size):
    if isinstance(source, (bytes, bytearray, memoryview)):
        source = io.BytesIO(bytes(source))
        close = False
    elif isinstance(source, (str, os.PathLike)):
        source = open(source, "rb")
        close = True
    else:
        close = False
    try:
        while True:
            piece = source.read(chunk_size)
            if not piece:
                return
            yield piece
    finally:
        if close:
            source.close()


class Device:
    """One mpeg2fpga decoder on the network.

    token: the device's access token (protocol section 6.1; on the device
        in /etc/mpeg2fpgad/token).
    tls: use HTTPS. tls_fingerprint="sha256:<hex>" pins the device's
        self-signed certificate (section 6.2); without it the certificate
        must chain to a trusted CA.
    timeout: seconds without any progress before giving up.
    """

    def __init__(self, host, token=None, port=None, tls=False, tls_fingerprint=None,
                 timeout=30.0):
        self.host = host
        self.token = token
        self.tls = tls or bool(tls_fingerprint)
        self.port = port or (DEFAULT_TLS_PORT if self.tls else DEFAULT_PORT)
        self.fingerprint = tls_fingerprint
        self.timeout = timeout

    # -- plumbing ------------------------------------------------------------

    def _open(self, method, path, body_chunks=None, body=None, extra_headers=None):
        headers = {"Accept": "*/*"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if extra_headers:
            headers.update(extra_headers)
        sock = _http.connect(self.host, self.port, self.timeout, self.tls, self.fingerprint)
        stream = _http.exchange(sock, method, path, "%s:%d" % (self.host, self.port),
                                headers, body_chunks=body_chunks, body=body,
                                timeout=self.timeout)

        def chunks():
            try:
                for piece in stream:
                    yield piece
            finally:
                sock.close()

        it = chunks()
        resp = next(it)
        if resp.status != 200:
            body_bytes = b"".join(it)
            raise from_response(resp.status, body_bytes, resp.headers)
        return resp, it

    def _json(self, method, path):
        _, it = self._open(method, path)
        return _Obj(json.loads(b"".join(it).decode("utf-8")))

    # -- protocol v1 ---------------------------------------------------------

    def health(self):
        return self._json("GET", "/v1/health")

    def info(self):
        """GET /v1/device: versions, capabilities, limits. Checks the protocol
        major version, so a v2-only device fails here and not mid-decode."""
        info = self._json("GET", "/v1/device")
        major = int(str(info.get("protocol", "0")).split(".")[0])
        if major != PROTOCOL_MAJOR:
            raise ProtocolError("device speaks protocol %s, this client %d.x"
                                % (info.get("protocol"), PROTOCOL_MAJOR))
        return info

    def status(self):
        return self._json("GET", "/v1/status")

    def reset(self):
        return self._json("POST", "/v1/reset")

    def decode(self, source, frames="all", max_frames=None, chunk_size=UPLOAD_CHUNK):
        """Decode a clip: bytes, a path, or a binary file object.

        Returns a DecodeResult; iterate it for Frames in display order. The
        clip is streamed, so its length is not limited by memory here or on
        the device.
        """
        query = {}
        if frames != "all":
            query["frames"] = frames
        if max_frames is not None:
            query["max_frames"] = int(max_frames)
        path = "/v1/decode" + ("?" + urlencode(query) if query else "")
        resp, it = self._open("POST", path,
                              body_chunks=_source_chunks(source, chunk_size),
                              extra_headers={"Content-Type": "application/octet-stream"})
        return DecodeResult(it, resp.headers.get("x-decode-id"))
