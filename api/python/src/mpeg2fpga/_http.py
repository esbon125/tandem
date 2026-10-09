"""Minimal HTTP/1.1 client for protocol v1, stdlib only.

Why not http.client: a decode uploads the clip and downloads frames *at the
same time* on one request (api/PROTOCOL-v1.md, section 3), and http.client
sends the whole request body before it reads a byte of the response. With
the device applying TCP flow control to the upload until the frames are read,
that deadlocks on any clip longer than the socket buffers.

Why one thread and non-blocking I/O instead of a sender thread: with TLS,
Python does not promise that one SSL socket can be read and written from two
threads at once. A single selector loop is correct with and without TLS, and
gives flow control for free -- the loop only runs while the caller is pulling
response data, so a caller that stops reading frames also stops uploading.
"""

import hashlib
import selectors
import socket
import ssl

from .errors import FingerprintMismatch

READ_SIZE = 64 * 1024
MAX_HEADER_BYTES = 64 * 1024


def connect(host, port, timeout, tls=False, fingerprint=None, server_hostname=None):
    """TCP (or TLS) socket to the device.

    fingerprint "sha256:<hex>" pins the device's certificate instead of
    trusting a CA -- the device generates a self-signed one on first boot
    (protocol section 6.2).
    """
    sock = socket.create_connection((host, port), timeout=timeout)
    if not tls:
        return sock
    if fingerprint:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE        # trust comes from the pin below
    else:
        ctx = ssl.create_default_context()
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    tsock = ctx.wrap_socket(sock, server_hostname=server_hostname or host)
    if fingerprint:
        der = tsock.getpeercert(binary_form=True)
        got = "sha256:" + hashlib.sha256(der).hexdigest()
        if got.lower() != fingerprint.lower():
            tsock.close()
            raise FingerprintMismatch("device certificate %s does not match pinned %s"
                                      % (got, fingerprint))
    return tsock


class Response:
    def __init__(self):
        self.status = None
        self.reason = ""
        self.headers = {}


class _Dechunker:
    """Incremental Transfer-Encoding: chunked decoder."""

    def __init__(self):
        self.buf = bytearray()
        self.remaining = None      # bytes left in the current chunk; None = expecting a size line
        self.done = False

    def feed(self, data):
        self.buf += data
        out = bytearray()
        while not self.done:
            if self.remaining is None:
                eol = self.buf.find(b"\r\n")
                if eol < 0:
                    break
                size = int(bytes(self.buf[:eol]).split(b";")[0], 16)
                del self.buf[:eol + 2]
                self.remaining = size
                if size == 0:
                    self.done = True       # trailers, if any, are ignored
                    break
            elif self.remaining > 0:
                take = min(self.remaining, len(self.buf))
                if not take:
                    break
                out += self.buf[:take]
                del self.buf[:take]
                self.remaining -= take
            else:
                if len(self.buf) < 2:
                    break
                del self.buf[:2]           # CRLF after the chunk data
                self.remaining = None
        return bytes(out)


def exchange(sock, method, path, host, headers, body_chunks=None, body=None, timeout=30.0):
    """Send one request and yield the response body as it arrives.

    The first value yielded is the Response (status and headers parsed); the
    rest are body pieces. body_chunks: iterable of bytes, sent with chunked
    transfer encoding while the response is being read. body: bytes, sent with
    Content-Length. One request per connection (Connection: close).
    """
    lines = ["%s %s HTTP/1.1" % (method, path), "Host: %s" % host, "Connection: close"]
    lines += ["%s: %s" % kv for kv in headers.items()]
    if body_chunks is not None:
        lines.append("Transfer-Encoding: chunked")
    elif body is not None or method == "POST":
        lines.append("Content-Length: %d" % len(body or b""))
    out = bytearray(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1"))
    if body is not None:
        out += body
    source = iter(body_chunks) if body_chunks is not None else None

    sock.setblocking(False)
    sel = selectors.DefaultSelector()
    sel.register(sock, selectors.EVENT_READ)
    inbuf = bytearray()
    resp = None
    body_reader = None
    content_left = None

    try:
        while True:
            # keep one encoded chunk queued while the upload lasts
            if not out and source is not None:
                try:
                    piece = next(source)
                except StopIteration:
                    out += b"0\r\n\r\n"
                    source = None
                else:
                    if piece:
                        out += b"%x\r\n" % len(piece) + bytes(piece) + b"\r\n"
            sel.modify(sock, selectors.EVENT_READ | (selectors.EVENT_WRITE if out else 0))
            # TLS may already hold decrypted bytes the socket will never
            # signal as readable again: don't block on select then
            ssl_pending = isinstance(sock, ssl.SSLSocket) and sock.pending() > 0
            if not sel.select(0 if ssl_pending else timeout) and not ssl_pending:
                raise socket.timeout("no progress in %.0f s" % timeout)

            if out:
                try:
                    sent = sock.send(out[:READ_SIZE])
                    del out[:sent]
                except (BlockingIOError, ssl.SSLWantWriteError, ssl.SSLWantReadError):
                    pass
                except (BrokenPipeError, ConnectionResetError):
                    # the device stopped reading, typically because it already
                    # answered with an error; that answer is what matters
                    out.clear()
                    source = None

            # One read per turn, and the caller consumes what it yields before
            # the next turn: draining the socket here instead would pull the
            # whole frame stream into memory whenever the caller is slow,
            # defeating the flow control the device relies on (protocol 3.2).
            eof = False
            try:
                data = sock.recv(READ_SIZE)
                if data:
                    inbuf += data
                else:
                    eof = True
            except (BlockingIOError, ssl.SSLWantReadError, ssl.SSLWantWriteError):
                pass
            except ConnectionResetError:
                eof = True

            if resp is None:
                end = inbuf.find(b"\r\n\r\n")
                if end < 0:
                    if len(inbuf) > MAX_HEADER_BYTES:
                        raise ConnectionError("response headers too large")
                    if eof:
                        raise ConnectionError("connection closed before a response")
                    continue
                head = bytes(inbuf[:end]).decode("latin-1").split("\r\n")
                del inbuf[:end + 4]
                resp = Response()
                _, status, *reason = head[0].split(" ", 2)
                resp.status = int(status)
                resp.reason = reason[0] if reason else ""
                for line in head[1:]:
                    k, _, v = line.partition(":")
                    resp.headers[k.strip().lower()] = v.strip()
                if resp.status != 200:
                    # an error ends the upload: nothing more will be read
                    out.clear()
                    source = None
                if "chunked" in resp.headers.get("transfer-encoding", "").lower():
                    body_reader = _Dechunker()
                elif "content-length" in resp.headers:
                    content_left = int(resp.headers["content-length"])
                yield resp

            if inbuf:
                data, inbuf = bytes(inbuf), bytearray()
                if body_reader is not None:
                    piece = body_reader.feed(data)
                    if piece:
                        yield piece
                    if body_reader.done:
                        return
                elif content_left is not None:
                    piece = data[:content_left]
                    content_left -= len(piece)
                    if piece:
                        yield piece
                    if content_left <= 0:
                        return
                else:
                    yield data
            elif content_left == 0:
                return
            if eof:
                if body_reader is not None and not body_reader.done:
                    raise ConnectionError("connection closed inside a chunked body")
                if content_left:
                    raise ConnectionError("connection closed %d bytes short" % content_left)
                return
    finally:
        sel.close()
