"""Frame store planes -> I420, stdlib only.

The frame store keeps pixels signed (offset -128) and, within each 64-bit
word, right to left in DRAM byte order (webserver/framestore.py and
tools/framecmp explain both). Both fix-ups run at C speed here:
array("Q").byteswap() reverses every 8-byte word, bytes.translate() flips the
sign bit. Measured on the board: 24 ms for a 704x480 frame, against ~43 ms per
decoded frame.
"""

import array
import sys

_SIGN = bytes(i ^ 0x80 for i in range(256))
_LITTLE = sys.byteorder == "little"


def plane(raw, stride, width, height):
    """One plane: raw frame store bytes (rows of `stride`) -> width x height."""
    # sign first, on the bytes object, then the word reversal: one copy
    # fewer than the other way round (16.7 -> 14.2 ms for a 704x480 luma
    # plane, measured on the board)
    words = array.array("Q", raw.translate(_SIGN))
    if _LITTLE:
        words.byteswap()
    flat = words.tobytes()
    if stride == width:
        return flat[:width * height]
    return b"".join(flat[r * stride:r * stride + width] for r in range(height))


def to_i420(y, cb, cr, width, height):
    """Native Y/Cb/Cr planes (as Board.read_frame returns them) -> I420 bytes.

    The daemon runs this in a process pool (session.py): it holds the GIL for
    its whole ~24 ms, and the board has four cores."""
    mbw = (width + 15) // 16
    return (plane(y, 16 * mbw, width, height)
            + plane(cb, 8 * mbw, width // 2, height // 2)
            + plane(cr, 8 * mbw, width // 2, height // 2))


def from_i420_constant(value):
    """Inverse for a uniform plane: the native byte that reads back as `value`
    (test helper; a constant plane is unaffected by the word reversal)."""
    return value ^ 0x80
