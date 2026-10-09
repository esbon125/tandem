import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), os.pardir))
sys.path.insert(0, os.path.dirname(__file__))

from mpeg2fpgad import esparse, i420, security  # noqa: E402
from streams import IPBB, display_types, stream  # noqa: E402


class ScannerTest(unittest.TestCase):
    def test_display_order_across_gops(self):
        gops = [IPBB, IPBB, [(0, "I"), (2, "P"), (1, "B")]]
        s = esparse.scan(stream(gops))
        self.assertEqual(s.frames_total, 11)
        got = ["?IPB"[s.frame(k).picture_type] for k in range(11)]
        self.assertEqual(got, display_types(gops))
        # display 1 of the first GOP is the B decoded third
        self.assertEqual(s.frame(1).decode_index, 2)
        self.assertEqual(s.frame(3).decode_index, 1)
        self.assertIsNone(s.frame(11))
        self.assertEqual((s.width, s.height), (64, 32))
        self.assertEqual((s.frame(5).width, s.frame(5).height), (64, 32))

    def test_byte_by_byte_feed_matches(self):
        data = stream([IPBB, IPBB])
        s = esparse.StreamScanner()
        for i in range(len(data)):
            s.feed(data[i:i + 1])
        s.finish()
        whole = esparse.scan(data)
        self.assertEqual([s.frame(k).decode_index for k in range(8)],
                         [whole.frame(k).decode_index for k in range(8)])

    def test_open_gop_lookup_before_all_frames_arrived(self):
        data = stream([IPBB])
        s = esparse.StreamScanner()
        cut = data.index(b"\x00\x00\x01\x00", data.index(b"\x00\x00\x01\x00") + 4)  # after I
        cut = data.index(b"\x00\x00\x01\x00", cut + 4)                                # B1 starts here
        s.feed(data[:cut])                     # everything up to B1, exclusive
        self.assertEqual(s.frame(0).picture_type, 1)
        self.assertIsNone(s.frame(1))          # B1 not seen yet: not P3 by rank
        self.assertEqual(s.frame(3).picture_type, 2)

    def test_field_pairs_are_one_frame(self):
        s = esparse.scan(stream([IPBB], fields=True))
        self.assertEqual(s.pictures, 8)
        self.assertEqual(s.frames_total, 4)
        self.assertEqual(s.frame(0).structure, 1)

    def test_size_change_is_per_sequence(self):
        data = stream([IPBB], 64, 32)[:-4] + stream([IPBB], 128, 48)
        s = esparse.scan(data)
        self.assertEqual((s.frame(0).width, s.frame(7).width), (64, 128))


class I420Test(unittest.TestCase):
    def test_word_reversal_and_sign(self):
        # one row of 16 pixels 0..15, as the frame store holds it: each 8-pixel
        # word right to left in byte order, every value offset by -128
        pixels = list(range(16))
        native = b""
        for w in range(2):
            native += bytes(reversed([(p ^ 0x80) for p in pixels[8 * w:8 * w + 8]]))
        self.assertEqual(i420.plane(native, 16, 16, 1), bytes(pixels))

    def test_stride_crop(self):
        stride, width = 32, 20
        native = b""
        for row in range(2):
            vals = [(row * 50 + c) & 0xFF for c in range(stride)]
            for w in range(stride // 8):
                native += bytes(reversed([v ^ 0x80 for v in vals[8 * w:8 * w + 8]]))
        out = i420.plane(native, stride, width, 2)
        self.assertEqual(out[:width], bytes(range(width)))
        self.assertEqual(out[width:], bytes((50 + c) & 0xFF for c in range(width)))


class NativeTest(unittest.TestCase):
    """native/m2fconv.c must give byte-for-byte what i420.py gives."""

    @classmethod
    def setUpClass(cls):
        import shutil
        import subprocess
        native_dir = os.path.join(os.path.dirname(__file__), os.pardir, "native")
        if shutil.which("gcc"):
            subprocess.run(["make", "-s", "-C", native_dir, "host"], check=True)
        from mpeg2fpgad import native
        cls.conv = native.load()

    def test_matches_python_on_random_planes(self):
        if self.conv is None:
            self.skipTest("libm2fconv.so not built")
        import random
        rnd = random.Random(1180)
        for w, h in ((704, 480), (720, 576), (352, 240), (100, 50), (36, 18), (8, 2)):
            mbw, mbh = (w + 15) // 16, (h + 15) // 16
            y = bytes(rnd.randrange(256) for _ in range(256 * mbw * mbh))
            cb = bytes(rnd.randrange(256) for _ in range(64 * mbw * mbh))
            cr = bytes(rnd.randrange(256) for _ in range(64 * mbw * mbh))
            self.assertEqual(self.conv.from_bytes(y, cb, cr, w, h),
                             i420.to_i420(y, cb, cr, w, h), "%dx%d" % (w, h))


class SecurityTest(unittest.TestCase):
    def test_token_check(self):
        self.assertTrue(security.token_ok("abc", "Bearer abc"))
        self.assertFalse(security.token_ok("abc", "Bearer abd"))
        self.assertFalse(security.token_ok("abc", None))
        self.assertFalse(security.token_ok("abc", "Basic abc"))

    def test_brake(self):
        now = [100.0]
        b = security.FailureBrake(limit=3, block_s=60, clock=lambda: now[0])
        for _ in range(2):
            b.failed("1.2.3.4")
        self.assertEqual(b.blocked("1.2.3.4"), 0.0)
        b.failed("1.2.3.4")
        self.assertGreater(b.blocked("1.2.3.4"), 59)
        self.assertEqual(b.blocked("5.6.7.8"), 0.0)
        now[0] += 61
        self.assertEqual(b.blocked("1.2.3.4"), 0.0)

    def test_token_file_created_private(self):
        import tempfile
        d = tempfile.mkdtemp()
        path = os.path.join(d, "sub", "token")
        t1 = security.load_or_create_token(path)
        self.assertEqual(len(t1), 43)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(security.load_or_create_token(path), t1)
        self.assertNotEqual(security.load_or_create_token(path, rotate=True), t1)


if __name__ == "__main__":
    unittest.main()
