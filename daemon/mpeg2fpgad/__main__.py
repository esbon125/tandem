"""mpeg2fpgad command line.

    python3 -m mpeg2fpgad [--listen ADDR] [--port N] [--tls] [--enable-debug]
    python3 -m mpeg2fpgad --rotate-token | --show-token | --show-fingerprint
    python3 -m mpeg2fpgad --fake          # no hardware: an in-memory decoder
"""

import argparse
import os
import sys
import time

from . import __version__, security
from .server import Daemon, Server

ETC = "/etc/mpeg2fpgad"


def main(argv=None):
    ap = argparse.ArgumentParser(prog="mpeg2fpgad", description=__doc__.split("\n\n")[0])
    ap.add_argument("--listen", default="0.0.0.0",
                    help="address to listen on (default all; set the LAN interface's)")
    ap.add_argument("--port", type=int, help="default 8080, or 8443 with --tls")
    ap.add_argument("--tls", action="store_true", help="HTTPS (ChaCha20, self-signed cert)")
    ap.add_argument("--etc", default=ETC, help="token and TLS files (default %s)" % ETC)
    ap.add_argument("--enable-debug", action="store_true", help="serve /v1/debug/*")
    ap.add_argument("--max-connections", type=int, default=8)
    ap.add_argument("--fake", action="store_true", help="in-memory decoder, for client development")
    ap.add_argument("--rotate-token", action="store_true", help="make a new token and exit")
    ap.add_argument("--show-token", action="store_true")
    ap.add_argument("--show-fingerprint", action="store_true")
    ap.add_argument("--version", action="version", version=__version__)
    args = ap.parse_args(argv)

    token_file = os.path.join(args.etc, "token")
    cert, key = os.path.join(args.etc, "tls", "cert.pem"), os.path.join(args.etc, "tls", "key.pem")

    if args.rotate_token:
        print(security.load_or_create_token(token_file, rotate=True))
        return 0
    if args.show_token:
        print(security.load_or_create_token(token_file))
        return 0
    if args.show_fingerprint:
        security.ensure_certificate(cert, key)
        print(security.fingerprint(cert))
        return 0

    def log(msg):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
        sys.stderr.flush()

    token = security.load_or_create_token(token_file)
    ctx = None
    if args.tls:
        security.ensure_certificate(cert, key)
        ctx = security.server_context(cert, key)
        log("TLS on, certificate %s" % security.fingerprint(cert))

    if args.fake:
        from .fakeboard import FakeBoard
        board = FakeBoard(bytes_per_s=1e6)
    else:
        from .board import Board
        board = Board()

    conv = getattr(board, "converter", None)
    log("frame conversion: %s" % (conv.path if conv else "Python (libm2fconv.so not found)"))

    port = args.port or (8443 if args.tls else 8080)
    daemon = Daemon(board, token, tls=bool(ctx), debug=args.enable_debug, log=log)
    server = Server((args.listen, port), daemon, ctx, args.max_connections)
    log("mpeg2fpgad %s on %s:%d (%s, bitstream %s)"
        % (__version__, args.listen, port, "fake board" if args.fake else "hardware",
           board.build()))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
