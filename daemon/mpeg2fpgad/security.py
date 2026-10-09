"""Access token, brute-force brake and TLS (api/PROTOCOL-v1.md, section 6)."""

import hashlib
import hmac
import os
import secrets
import ssl
import subprocess
import threading
import time

TOKEN_BYTES = 32                 # 256 bits
FAIL_LIMIT = 10                  # wrong tokens in a row from one address...
FAIL_BLOCK_S = 60.0              # ...block it this long


def load_or_create_token(path, rotate=False):
    """The device's access token; created (0600) on first start or on rotate."""
    if rotate or not os.path.exists(path):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        token = secrets.token_urlsafe(TOKEN_BYTES)
        fd = os.open(path + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fp:
            fp.write(token + "\n")
        os.replace(path + ".new", path)
        return token
    with open(path) as fp:
        return fp.read().strip()


def token_ok(expected, authorization_header):
    """Constant-time check of an "Authorization: Bearer <token>" header: a
    plain == returns sooner the earlier the first wrong character is, which
    leaks the token one character at a time to someone patient enough."""
    if not authorization_header or not authorization_header.startswith("Bearer "):
        presented = ""
    else:
        presented = authorization_header[len("Bearer "):].strip()
    return hmac.compare_digest(presented.encode(), expected.encode())


class FailureBrake:
    """After FAIL_LIMIT wrong tokens in a row from an address, refuse it for
    FAIL_BLOCK_S (429). A right token resets the count."""

    def __init__(self, limit=FAIL_LIMIT, block_s=FAIL_BLOCK_S, clock=time.monotonic):
        self.limit, self.block_s, self.clock = limit, block_s, clock
        self._lock = threading.Lock()
        self._fails = {}                 # address -> (count, blocked_until)

    def blocked(self, address):
        with self._lock:
            count, until = self._fails.get(address, (0, 0.0))
            if until and self.clock() < until:
                return until - self.clock()
            if until:
                self._fails.pop(address, None)
            return 0.0

    def failed(self, address):
        with self._lock:
            count, _ = self._fails.get(address, (0, 0.0))
            count += 1
            until = self.clock() + self.block_s if count >= self.limit else 0.0
            self._fails[address] = (count, until)

    def succeeded(self, address):
        with self._lock:
            self._fails.pop(address, None)


def ensure_certificate(cert, key):
    """Self-signed ECDSA P-256 certificate, made with the openssl CLI on first
    start (the image has it; Python's stdlib cannot make certificates)."""
    if os.path.exists(cert) and os.path.exists(key):
        return
    os.makedirs(os.path.dirname(cert) or ".", exist_ok=True)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                    "ec_paramgen_curve:prime256v1", "-nodes", "-days", "3650",
                    "-subj", "/CN=mpeg2fpga", "-keyout", key, "-out", cert],
                   check=True, capture_output=True)
    os.chmod(key, 0o600)


def fingerprint(cert):
    with open(cert) as fp:
        der = ssl.PEM_cert_to_DER_cert(fp.read())
    return "sha256:" + hashlib.sha256(der).hexdigest()


def server_context(cert, key):
    """TLS 1.2 with ChaCha20-Poly1305 only.

    ChaCha20 because it is what the U54 cores can afford: measured on the
    board, 7.6 MB/s against 4.5 MB/s for AES-128-GCM (no crypto extensions),
    and the frame stream needs ~12 MB/s at 704x480. Capped at TLS 1.2 because
    Python's ssl cannot choose TLS 1.3 suites, where clients pick AES-GCM.
    TLS 1.2 with ECDHE and an AEAD cipher is still a sound configuration.
    """
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    ctx.set_ciphers("ECDHE-ECDSA-CHACHA20-POLY1305")
    return ctx
