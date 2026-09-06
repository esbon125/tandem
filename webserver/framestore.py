"""Where the decoded pictures live in DRAM, and how to get a plane out.

Mirrors rtl/mpeg2/mem_codes.v (MP_AT_HL mapping) and the address arithmetic in
rtl/mpeg2/mem_addr.v. Single source of truth for both the webserver and
capture_framestore.py.

Two facts about the layout that are easy to get wrong, and that made the first
attempt at comparing decoded frames produce meaningless numbers (see
trunk/mpeg2fpga/tools/framecmp on the hardware_development branch):

  * Pixels are stored SIGNED, offset by -128: motcomp_recon.v says "-128
    corresponding to 0 and 127 corresponding to 255". The unsigned value is
    `byte ^ 0x80`.
  * The leftmost pixel of a 64-bit word is bits [63:56], so in DRAM's
    little-endian byte order the eight pixels of a word run right to left.

Neither is undone here. A plane is handed out as the raw bytes DRAM holds,
because the two fixups are per-byte work that Python on the MSS is bad at and
the browser is good at; `static/index.html` does them while converting to RGB.

What this module does guarantee is that a plane is one *contiguous* range. From
mem_addr.v,

    address = pixel_y * mb_width * (2 if luma else 1) + (pixel_x >> 3)

so row y of the luma plane starts at byte 16*mb_width*y and rows sit back to
back: the whole plane is a single slice, and reading it is a memcpy.
"""

WIDTH_Y = 18        # luminance region: 2**18 words of 8 bytes = 2 MiB
WIDTH_C = 16        # chrominance region: 2**16 words = 512 KiB

_FRAME_WORDS = (1 << WIDTH_Y) + 2 * (1 << WIDTH_C)

NUM_FRAMES = 4
OSD_WORD = NUM_FRAMES * _FRAME_WORDS
FRAMESTORE_BYTES = OSD_WORD * 8         # 12 MiB, what a capture covers

# Component names as the RTL spells them. Note that mpeg2fpga's COMP_CR carries
# MPEG-2 block 4 and COMP_CB block 5, which are Cb and Cr respectively -- the
# internal names are swapped relative to the standard. Consumers want Cb/Cr, so
# that is what the accessors below are named after; the mapping is applied here
# once instead of being rediscovered by every caller.
_PLANE_CB = "CR"    # framestore's "CR" region holds Cb
_PLANE_CR = "CB"    # framestore's "CB" region holds Cr


def plane_base_word(frame, component):
    """Word address of a plane. `component` is one of 'Y', 'CR', 'CB' as in
    mem_codes.v -- use luma_range()/chroma_ranges() rather than this directly
    unless you mean the RTL's naming."""
    base = frame * _FRAME_WORDS
    if component == "Y":
        return base
    if component == "CR":
        return base + (1 << WIDTH_Y)
    if component == "CB":
        return base + (1 << WIDTH_Y) + (1 << WIDTH_C)
    raise ValueError("unknown component %r" % (component,))


def macroblocks(width, height):
    return (width + 15) // 16, (height + 15) // 16


class PlaneGeometry:
    """Byte offsets and sizes of one frame buffer's three planes."""

    def __init__(self, frame, width, height):
        mb_width, mb_height = macroblocks(width, height)
        self.frame = frame
        self.width = width
        self.height = height
        self.mb_width = mb_width
        self.mb_height = mb_height

        # A row is 16*mb_width pixels of luma; that is >= width when width is
        # not a multiple of 16, so the consumer crops.
        self.luma_stride = 16 * mb_width
        self.luma_rows = 16 * mb_height
        self.chroma_stride = 8 * mb_width
        self.chroma_rows = 8 * mb_height

        self.luma_offset = plane_base_word(frame, "Y") * 8
        self.luma_bytes = self.luma_stride * self.luma_rows
        self.cb_offset = plane_base_word(frame, _PLANE_CB) * 8
        self.cr_offset = plane_base_word(frame, _PLANE_CR) * 8
        self.chroma_bytes = self.chroma_stride * self.chroma_rows

    def read(self, region):
        """Y, Cb, Cr as raw DRAM bytes, in that order. Three memcpys."""
        return (region.read(self.luma_offset, self.luma_bytes),
                region.read(self.cb_offset, self.chroma_bytes),
                region.read(self.cr_offset, self.chroma_bytes))

    def looks_written(self, region, samples=512):
        """True if the luma plane is not one uniform value.

        Capture poisons the framestore before a push, so a buffer the decoder
        never wrote to reads back uniform. Sampling rather than scanning keeps
        this cheap on a 2 MiB plane.
        """
        step = max(1, self.luma_bytes // samples)
        probe = region.read(self.luma_offset, self.luma_bytes)[::step]
        return len(set(probe)) > 1
