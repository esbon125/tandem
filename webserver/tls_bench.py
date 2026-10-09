#!/usr/bin/env python3
"""How much does TLS cost the board when it streams decoded frames?

Protocol v1 makes TLS optional because of this cost (api/PROTOCOL-v1.md,
section 6.2); this measures it end to end with the same stack the daemon will
use: Python's http.server-free socket loop + the ssl module (OpenSSL 3.2 on
the U54 cores, no crypto extensions).

On the board:
    python3 tls_bench.py serve [--port 9443] [--cipher chacha|aes] [--plain]

It serves GET /stream?mb=N: N MiB as chunked HTTP, in 506880-byte pieces (one
704x480 I420 frame), the way the daemon will send FRAME records. Each
connection reports server-side CPU seconds (process time) per MiB on stderr.
The host side is tools/regress/tls_bench_client.py.
"""
import argparse
import os
import socket
import ssl
import subprocess
import sys
import threading
import time

FRAME = 704 * 480 * 3 // 2


def make_cert(directory):
    cert, key = os.path.join(directory, "cert.pem"), os.path.join(directory, "key.pem")
    if not os.path.exists(cert):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                        "ec_paramgen_curve:prime256v1", "-nodes", "-days", "30",
                        "-subj", "/CN=mpeg2fpga", "-keyout", key, "-out", cert],
                       check=True, capture_output=True)
    return cert, key


def handle(conn, payload):
    f = conn.makefile("rb")
    line = f.readline().decode()
    while f.readline() not in (b"\r\n", b""):
        pass
    mb = int(line.split("mb=")[1].split()[0]) if "mb=" in line else 64
    cpu0, t0 = time.process_time(), time.time()
    conn.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
    left = mb << 20
    while left > 0:
        piece = payload[:min(len(payload), left)]
        conn.sendall(b"%x\r\n" % len(piece) + piece + b"\r\n")
        left -= len(piece)
    conn.sendall(b"0\r\n\r\n")
    wall, cpu = time.time() - t0, time.process_time() - cpu0
    cipher = conn.cipher()[0] if isinstance(conn, ssl.SSLSocket) else "plain"
    sys.stderr.write("RESULT cipher=%s mib=%d wall=%.2f MBps=%.2f cpu_s=%.2f cpu_per_mib_ms=%.1f\n"
                     % (cipher, mb, wall, mb / wall, cpu, cpu * 1000 / mb))
    conn.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["serve"])
    ap.add_argument("--port", type=int, default=9443)
    ap.add_argument("--plain", action="store_true")
    ap.add_argument("--cipher", choices=["chacha", "aes"], default="chacha")
    args = ap.parse_args()

    ctx = None
    if not args.plain:
        cert, key = make_cert("/tmp")
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, key)
        # pin TLS 1.2 so the cipher choice below is honoured (TLS 1.3 suites
        # are negotiated separately and the client would pick AES)
        ctx.maximum_version = ssl.TLSVersion.TLSv1_2
        ctx.set_ciphers("ECDHE-ECDSA-CHACHA20-POLY1305" if args.cipher == "chacha"
                        else "ECDHE-ECDSA-AES128-GCM-SHA256")
    payload = os.urandom(FRAME)
    srv = socket.create_server(("", args.port), reuse_port=True)
    sys.stderr.write("listening on %d (%s)\n" % (args.port, "plain" if args.plain else args.cipher))
    while True:
        conn, _ = srv.accept()
        if ctx:
            try:
                conn = ctx.wrap_socket(conn, server_side=True)
            except ssl.SSLError as exc:
                sys.stderr.write("handshake failed: %s\n" % exc)
                continue
        threading.Thread(target=handle, args=(conn, payload), daemon=True).start()


if __name__ == "__main__":
    main()
