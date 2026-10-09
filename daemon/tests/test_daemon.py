"""mpeg2fpgad end to end: the real server and session over FakeBoard, driven by
the real client library (api/python), on localhost."""

import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, os.pardir))
sys.path.insert(0, os.path.join(HERE, os.pardir, os.pardir, "api", "python", "src"))
sys.path.insert(0, HERE)

import mpeg2fpga  # noqa: E402
from mpeg2fpgad import security, session  # noqa: E402
from mpeg2fpgad.fakeboard import FakeBoard, frame_values  # noqa: E402
from mpeg2fpgad.server import Daemon, Server  # noqa: E402
from streams import IPBB, display_types, stream  # noqa: E402

TOKEN = "t" * 43


class Running:
    def __init__(self, board=None, tls_context=None, debug=False, max_connections=8):
        self.board = board or FakeBoard()
        self.daemon = Daemon(self.board, TOKEN, tls=bool(tls_context), debug=debug,
                             log=lambda m: None)
        self.server = Server(("127.0.0.1", 0), self.daemon, tls_context, max_connections)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, args=(0.05,), daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()

    def device(self, **kw):
        kw.setdefault("token", TOKEN)
        return mpeg2fpga.Device("127.0.0.1", port=self.port, timeout=20, **kw)


class DecodeTest(unittest.TestCase):
    def test_frames_in_display_order_with_content(self):
        gops = [IPBB, IPBB, IPBB]
        with Running() as r:
            result = r.device().decode(stream(gops))
            frames = list(result)
        self.assertEqual([f.display_index for f in frames], list(range(12)))
        self.assertEqual([f.picture_type for f in frames], display_types(gops))
        self.assertEqual(frames[1].decode_index, 2)      # first B: third in the stream
        for k, f in enumerate(frames):
            y, cb, cr = frame_values(k)
            self.assertEqual((f.width, f.height), (64, 32))
            self.assertEqual((f.y[0], f.y[-1], f.u[0], f.v[-1]), (y, y, cb, cr))
            self.assertEqual(len(f.y) + len(f.u) + len(f.v), 64 * 32 * 3 // 2)
        s = result.summary
        self.assertTrue(s.complete)
        self.assertEqual((s.frames_sent, s.pictures_in_stream), (12, 12))
        self.assertFalse(s.aborted)

    def test_long_clip_goes_through_many_aligned_chunks(self):
        old = session.FIRST_CHUNK, session.CHUNK
        session.FIRST_CHUNK, session.CHUNK = 1000, 4093          # odd sizes on purpose
        try:
            gops = [IPBB] * 10
            data = stream(gops, filler=3000)
            with Running() as r:
                result = r.device().decode(data, chunk_size=777)
                self.assertEqual(len(list(result)), 40)
                log = r.board.dma_log
        finally:
            session.FIRST_CHUNK, session.CHUNK = old
        self.assertTrue(result.summary.complete)
        self.assertGreater(len(log), 20)
        self.assertTrue(all(off % 8 == 0 for off, _, _ in log))
        self.assertEqual([last for _, _, last in log], [False] * (len(log) - 1) + [True])
        self.assertEqual(sum(n for _, n, _ in log), len(data))
        self.assertEqual(result.summary.bytes_in, len(data))

    def test_slow_client_freezes_the_decoder_and_loses_nothing(self):
        # real-size frames (~0.5 MB): small ones would all fit in the TCP
        # buffers and the daemon's queue would never grow
        gops = [IPBB] * 12                    # 48 frames, ~24 MB: more than TCP buffers hold
        with Running() as r:
            result = r.device().decode(stream(gops, width=704, height=480))
            got = []
            for f in result:
                got.append(f.display_index)
                time.sleep(0.03)              # a client slower than the decoder
            freezes = list(r.board.freeze_log)
        self.assertEqual(got, list(range(48)))
        self.assertTrue(result.summary.complete)
        self.assertIn(True, freezes)
        self.assertEqual(freezes[-1], False)

    def test_frames_last_and_max_frames(self):
        gops = [IPBB, IPBB]
        with Running() as r:
            last = list(r.device().decode(stream(gops), frames="last"))
            first3 = r.device().decode(stream(gops), max_frames=3)
            got3 = list(first3)
        self.assertEqual([f.display_index for f in last], [7])
        self.assertEqual([f.display_index for f in got3], [0, 1, 2])
        self.assertEqual(first3.summary.pictures_in_stream, 8)

    def test_next_decode_can_start_as_soon_as_end_arrives(self):
        # END used to go out before the decoder was released: a client chaining
        # decodes got 409 (seen on the board)
        with Running() as r:
            dev = r.device()
            for _ in range(10):
                self.assertEqual(len(list(dev.decode(stream([IPBB])))), 4)

    def test_chained_decodes_without_reset(self):
        with Running() as r:
            dev = r.device()
            for n in (1, 3, 2):
                self.assertEqual(len(list(dev.decode(stream([IPBB] * n)))), 4 * n)
            self.assertEqual(r.board.resets, 0)


class ErrorsTest(unittest.TestCase):
    def test_not_mpeg2_is_rejected_before_the_decoder(self):
        with Running() as r:
            with self.assertRaises(mpeg2fpga.BadRequest):
                r.device().decode(b"\xff" * 5000)
            self.assertEqual(r.board.dma_log, [])

    def test_auth_and_brake(self):
        with Running() as r:
            self.assertTrue(r.device(token=None).health().ok)
            bad = r.device(token="wrong")
            for _ in range(10):
                with self.assertRaises(mpeg2fpga.Unauthorized):
                    bad.status()
            with self.assertRaises(mpeg2fpga.TooManyAttempts):
                bad.status()
            with self.assertRaises(mpeg2fpga.TooManyAttempts):    # blocked even with the right one
                r.device().status()

    def test_busy(self):
        board = FakeBoard(frame_s=0.05)
        with Running(board) as r:
            first = r.device().decode(stream([IPBB] * 4))
            next(iter(first))
            with self.assertRaises(mpeg2fpga.DeviceBusy):
                r.device().decode(stream([IPBB]))
            self.assertEqual(r.device().status().state, "decoding")
            self.assertEqual(len(list(first)), 15)
        self.assertTrue(first.summary.complete)

    def test_reset_aborts_a_running_decode(self):
        board = FakeBoard(frame_s=0.05)
        with Running(board) as r:
            result = r.device().decode(stream([IPBB] * 10))
            next(iter(result))
            st = r.device().reset()
            rest = list(result)
            self.assertEqual(st.state, "idle")
            self.assertEqual(r.board.resets, 1)
        self.assertTrue(result.summary.aborted)
        self.assertFalse(result.summary.complete)
        self.assertLess(len(rest), 39)

    def test_client_disconnect_frees_the_decoder(self):
        board = FakeBoard(frame_s=0.02)
        with Running(board) as r:
            result = r.device().decode(stream([IPBB] * 10))
            next(iter(result))
            result._chunks.close()               # drop the connection mid-decode
            deadline = time.time() + 10
            while r.daemon.session is not None and time.time() < deadline:
                time.sleep(0.05)
            self.assertIsNone(r.daemon.session)
            self.assertEqual(len(list(r.device().decode(stream([IPBB])))), 4)

    def test_device_info_and_debug_off(self):
        with Running() as r:
            info = r.device().info()
            self.assertEqual(info.versions.bitstream, "0.1.0+fakefab")
            self.assertIsNone(info.limits.max_stream_bytes)
            self.assertFalse(info.security.tls)
            with self.assertRaises(mpeg2fpga.NotFound):
                r.device()._json("GET", "/v1/debug/perf")


@unittest.skipUnless(shutil.which("openssl"), "openssl CLI needed for the certificate")
class TlsTest(unittest.TestCase):
    def test_decode_over_tls_with_pinned_certificate(self):
        d = tempfile.mkdtemp()
        try:
            cert, key = os.path.join(d, "c.pem"), os.path.join(d, "k.pem")
            security.ensure_certificate(cert, key)
            with Running(tls_context=security.server_context(cert, key)) as r:
                dev = r.device(tls_fingerprint=security.fingerprint(cert))
                self.assertTrue(dev.info().security.tls)
                self.assertEqual(len(list(dev.decode(stream([IPBB, IPBB])))), 8)
                with self.assertRaises(mpeg2fpga.FingerprintMismatch):
                    r.device(tls_fingerprint="sha256:" + "0" * 64).info()
        finally:
            shutil.rmtree(d)


_ = subprocess
if __name__ == "__main__":
    unittest.main()
