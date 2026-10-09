import hashlib
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), os.pardir, "src"))
sys.path.insert(0, os.path.dirname(__file__))

import mpeg2fpga  # noqa: E402
from fake_device import TOKEN, FakeDevice, tls_server_context  # noqa: E402


class ClientTest(unittest.TestCase):
    def test_health_needs_no_token(self):
        with FakeDevice() as fake:
            self.assertTrue(mpeg2fpga.Device("127.0.0.1", port=fake.port).health().ok)

    def test_info(self):
        with FakeDevice() as fake:
            info = mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port).info()
            self.assertEqual(info.product, "mpeg2fpga")
            self.assertIsNone(info.limits.max_stream_bytes)

    def test_wrong_protocol_major_is_refused(self):
        with FakeDevice() as fake:
            fake.protocol = "2.0"
            with self.assertRaises(mpeg2fpga.ProtocolError):
                mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port).info()

    def test_missing_token_is_unauthorized(self):
        with FakeDevice() as fake:
            with self.assertRaises(mpeg2fpga.Unauthorized) as cm:
                mpeg2fpga.Device("127.0.0.1", port=fake.port).status()
            self.assertEqual(cm.exception.status, 401)

    def test_unknown_path_is_not_found(self):
        with FakeDevice() as fake:
            dev = mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port)
            with self.assertRaises(mpeg2fpga.NotFound):
                dev._json("GET", "/v1/nope")

    def test_decode_streams_both_ways(self):
        """6 MiB of frames come back while 4 MiB go up, through 64 KiB socket
        buffers: only a client that reads while it uploads gets through."""
        clip = os.urandom(4 << 20)
        with FakeDevice() as fake:
            dev = mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port, timeout=10)
            result = dev.decode(clip, chunk_size=64 * 1024)
            frames = list(result)
        self.assertEqual(len(frames), 64)
        self.assertEqual([f.display_index for f in frames], list(range(64)))
        self.assertEqual(result.decode_id, "d-000001")
        self.assertEqual(result.summary.bytes_in, len(clip))
        self.assertTrue(result.summary.complete)
        f = frames[5]
        self.assertEqual((f.width, f.height, f.picture_type), (256, 256, "B"))   # 1 + 5 % 3
        self.assertEqual(len(f.y), 256 * 256)
        self.assertEqual(len(f.u), 128 * 128)
        self.assertEqual(bytes(f.y[:4]), b"\x05" * 4)
        self.assertEqual(bytes(f.v[:4]), b"\x0f" * 4)

    def test_decode_from_path_and_file(self):
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp.write(b"\x00" * 300000)
        try:
            with FakeDevice() as fake:
                dev = mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port)
                self.assertEqual(dev.decode(tmp.name, chunk_size=100000).wait().frames_sent, 3)
                with open(tmp.name, "rb") as fp:
                    self.assertEqual(dev.decode(fp, chunk_size=150000).wait().frames_sent, 2)
        finally:
            os.unlink(tmp.name)

    def test_future_fields_and_records_are_ignored(self):
        with FakeDevice() as fake:
            fake.extra_header_bytes = 8
            fake.unknown_record = True
            frames = list(mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port)
                          .decode(b"x" * 1000, chunk_size=500))
        self.assertEqual([f.display_index for f in frames], [0, 1])

    def test_busy_device(self):
        with FakeDevice() as fake:
            fake.busy = True
            with self.assertRaises(mpeg2fpga.DeviceBusy) as cm:
                mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port).decode(b"x" * 10)
        self.assertEqual(cm.exception.retry_after, 2.0)
        self.assertTrue(cm.exception.retryable)

    def test_stream_without_end_is_incomplete(self):
        with FakeDevice() as fake:
            fake.cut_after = 2
            result = mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port).decode(
                b"x" * 5000, chunk_size=1000)
            with self.assertRaises(mpeg2fpga.DecodeIncomplete):
                list(result)

    def test_to_numpy(self):
        try:
            import numpy  # noqa: F401
        except ImportError:
            self.skipTest("numpy not installed")
        with FakeDevice() as fake:
            fake.frame_size = (32, 16)
            frame = next(iter(mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port)
                              .decode(b"x" * 10)))
        y, u, v = frame.to_numpy()
        self.assertEqual((y.shape, u.shape, v.shape), ((16, 32), (8, 16), (8, 16)))


@unittest.skipUnless(shutil.which("openssl"), "openssl CLI needed to make a test certificate")
class TlsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        cls.cert = os.path.join(cls.dir, "cert.pem")
        cls.key = os.path.join(cls.dir, "key.pem")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                        "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1",
                        "-subj", "/CN=mpeg2fpga-test", "-keyout", cls.key, "-out", cls.cert],
                       check=True, capture_output=True)
        der = ssl.PEM_cert_to_DER_cert(open(cls.cert).read())
        cls.fingerprint = "sha256:" + hashlib.sha256(der).hexdigest()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir)

    def test_pinned_fingerprint(self):
        with FakeDevice(tls_server_context(self.cert, self.key)) as fake:
            dev = mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port,
                                   tls_fingerprint=self.fingerprint, timeout=10)
            self.assertEqual(dev.info().product, "mpeg2fpga")
            frames = list(dev.decode(os.urandom(1 << 20), chunk_size=64 * 1024))
        self.assertEqual(len(frames), 16)

    def test_wrong_fingerprint_is_refused(self):
        with FakeDevice(tls_server_context(self.cert, self.key)) as fake:
            dev = mpeg2fpga.Device("127.0.0.1", token=TOKEN, port=fake.port,
                                   tls_fingerprint="sha256:" + "00" * 32)
            with self.assertRaises(mpeg2fpga.FingerprintMismatch):
                dev.info()


if __name__ == "__main__":
    unittest.main()
