"""ctypes binding for native/m2fconv.c: frame store -> I420 without the GIL.

Optional: if libm2fconv.so is not found, Board falls back to i420.py (same
output, ~24 ms per 704x480 frame with the GIL held). Looked up in
$MPEG2FPGAD_NATIVE, next to this package (installed layout), and in the
source tree's native/riscv64 or native/host build directories.
"""

import ctypes
import os
import platform

_HERE = os.path.dirname(os.path.abspath(__file__))


def _candidates():
    env = os.environ.get("MPEG2FPGAD_NATIVE")
    if env:
        yield env
    yield os.path.join(_HERE, os.pardir, "libm2fconv.so")
    arch = "riscv64" if platform.machine() == "riscv64" else "host"
    yield os.path.join(_HERE, os.pardir, "native", arch, "libm2fconv.so")


def load():
    for path in _candidates():
        if os.path.exists(path):
            lib = ctypes.CDLL(os.path.abspath(path))
            fn = lib.m2f_to_i420
            fn.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                           ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p]
            fn.restype = ctypes.c_ulong
            return Converter(fn, os.path.abspath(path))
    return None


class Converter:
    def __init__(self, fn, path):
        self._fn = fn
        self.path = path

    def from_addresses(self, y, cb, cr, width, height):
        """Convert from raw addresses (e.g. inside an mmap); returns bytes."""
        out = bytearray(width * height * 3 // 2)
        dst = (ctypes.c_char * len(out)).from_buffer(out)
        n = self._fn(y, cb, cr, width, height, ctypes.addressof(dst))
        del dst                                  # release the export on `out`
        # no bytes() copy: half a megabyte per frame on these cores
        return out if n == len(out) else out[:n]

    def from_bytes(self, y, cb, cr, width, height):
        """Convert from three bytes-like planes (tests, fallbacks)."""
        bufs = [ctypes.create_string_buffer(bytes(p), len(p)) for p in (y, cb, cr)]
        return self.from_addresses(*(ctypes.addressof(b) for b in bufs), width, height)


def buffer_address(mm):
    """Base address of a writable mmap, kept alive by the returned holder."""
    holder = (ctypes.c_char * len(mm)).from_buffer(mm)
    return ctypes.addressof(holder), holder
