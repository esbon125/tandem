#!/usr/bin/env python3
"""Host side of webserver/tls_bench.py: download N MiB, report MB/s.

    tls_bench_client.py HOST PORT [--mb 64] [--plain]

Uses the mpeg2fpga client library's own HTTP/TLS layer (api/python on
firmware_development), so what is measured is what a client will get.
"""
import argparse
import os
import sys
import time

ap = argparse.ArgumentParser()
ap.add_argument("host")
ap.add_argument("port", type=int)
ap.add_argument("--mb", type=int, default=64)
ap.add_argument("--plain", action="store_true")
ap.add_argument("--client-src", default=os.path.expanduser("~/Proyectos/tandem-fw/api/python/src"))
args = ap.parse_args()
sys.path.insert(0, args.client_src)
from mpeg2fpga import _http  # noqa: E402

import ssl  # noqa: E402

sock = _http.connect(args.host, args.port, 30, tls=False)
if not args.plain:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    sock = ctx.wrap_socket(sock)
t0 = time.time()
n = 0
for piece in _http.exchange(sock, "GET", "/stream?mb=%d" % args.mb, args.host, {}):
    if isinstance(piece, (bytes, bytearray)):
        n += len(piece)
wall = time.time() - t0
cipher = sock.cipher()[0] if isinstance(sock, ssl.SSLSocket) else "plain"
print("client: %s %.1f MiB in %.2f s = %.2f MB/s" % (cipher, n / 2**20, wall, n / 2**20 / wall))
