"""Just enough MPEG-2 parsing to feed the decoder one picture at a time.

The decoder has four frame buffers and chews through a stream far faster than
real time, so pushing a whole stream and reading afterwards only ever recovers
the last four pictures -- everything before that has been overwritten. To get
the whole sequence out, the stream has to be fed in picture-sized bites and each
picture read back before the next one lands on top of it.

This module finds where to cut, and works out what display order the pictures go
in. Two details make that possible without decoding anything:

  * A picture is only finished when the decoder sees the *next* start code.
    So a chunk that ends just before picture N+1's start code leaves picture N
    parsed but not flushed; after pushing chunk N, picture N-1 is the one that
    is complete. The caller pushes a sequence_end_code at the end to flush the
    last one.
  * temporal_reference in the picture header is the picture's position in
    display order within its GOP, which is exactly the reordering information
    a decoder would otherwise have to reconstruct from picture types.
"""
import struct

PICTURE_START = b"\x00\x00\x01\x00"
GROUP_START = b"\x00\x00\x01\xb8"
SEQUENCE_HEADER = b"\x00\x00\x01\xb3"
SEQUENCE_END = b"\x00\x00\x01\xb7"

PICTURE_TYPES = {1: "I", 2: "P", 3: "B", 4: "D"}

# ISO/IEC 13818-2 Table 6-4
FRAME_RATES = {1: 24000 / 1001, 2: 24.0, 3: 25.0, 4: 30000 / 1001, 5: 30.0,
               6: 50.0, 7: 60000 / 1001, 8: 60.0}


class Picture:
    __slots__ = ("index", "offset", "temporal_reference", "coding_type",
                 "gop", "display_index")

    def __init__(self, index, offset, temporal_reference, coding_type, gop):
        self.index = index                      # decode order
        self.offset = offset                    # of its picture_start_code
        self.temporal_reference = temporal_reference
        self.coding_type = coding_type
        self.gop = gop
        self.display_index = None               # filled in by parse()

    @property
    def type_name(self):
        return PICTURE_TYPES.get(self.coding_type, "?")

    def __repr__(self):
        return "<picture %d %s tr=%d display=%s>" % (
            self.index, self.type_name, self.temporal_reference,
            self.display_index)


class Sequence:
    """Geometry and picture list of an elementary stream."""

    def __init__(self, data):
        self.data = data
        self.width = 0
        self.height = 0
        self.frame_rate_code = 0
        self.pictures = []

    @property
    def frame_rate(self):
        return FRAME_RATES.get(self.frame_rate_code, 25.0)

    def chunks(self):
        """Byte ranges to push, one per picture.

        Chunk i runs from picture i's start code up to (not including) picture
        i+1's, so anything before the first picture -- sequence header, GOP
        header, quantiser matrices -- rides along in chunk 0, and a GOP header
        sitting between two pictures goes out at the tail of the earlier chunk.
        Everything reaches the decoder in stream order either way; the cuts only
        choose where to pause.
        """
        if not self.pictures:
            return []
        cuts = [0] + [p.offset for p in self.pictures[1:]] + [len(self.data)]
        return [(cuts[i], cuts[i + 1]) for i in range(len(self.pictures))]


def parse(data):
    """Find the sequence geometry and every picture header."""
    sequence = Sequence(data)
    gop = -1
    at = data.find(b"\x00\x00\x01")
    while at >= 0 and at + 3 < len(data):
        code = data[at + 3]
        if code == 0xB3 and not sequence.width and at + 8 <= len(data):
            b = data[at + 4:at + 8]
            sequence.width = (b[0] << 4) | (b[1] >> 4)
            sequence.height = ((b[1] & 0x0F) << 8) | b[2]
            sequence.frame_rate_code = b[3] & 0x0F
        elif code == 0xB8:
            gop += 1
        elif code == 0x00 and at + 6 <= len(data):
            # picture header: 10 bits temporal_reference, 3 bits coding type
            header = struct.unpack(">H", data[at + 4:at + 6])[0]
            sequence.pictures.append(Picture(
                index=len(sequence.pictures),
                offset=at,
                temporal_reference=header >> 6,
                coding_type=(header >> 3) & 0x07,
                gop=max(gop, 0)))
        at = data.find(b"\x00\x00\x01", at + 3)

    _assign_display_order(sequence.pictures)
    return sequence


def _assign_display_order(pictures):
    """Display order = temporal_reference, offset by where each GOP starts.

    A stream with no GOP headers at all keeps decode order, which is right for
    a sequence with no B pictures and the best guess otherwise.
    """
    base = 0
    seen = set()
    for picture in pictures:
        if picture.gop not in seen:
            if seen:
                base += max(p.temporal_reference for p in pictures
                            if p.gop == max(seen)) + 1
            seen.add(picture.gop)
        picture.display_index = base + picture.temporal_reference

    # Guard against a stream whose temporal_references collide (some
    # conformance streams do not reset them the way the spec implies): fall
    # back to decode order rather than silently dropping frames.
    if len({p.display_index for p in pictures}) != len(pictures):
        for picture in pictures:
            picture.display_index = picture.index
        return

    # Only the relative order matters, and a stream cut mid-GOP leaves gaps --
    # the last picture of a 60 picture clip came out as display index 60, one
    # past the end of the array the player had allocated. Rank them instead, so
    # the indices are always 0..n-1.
    for rank, picture in enumerate(sorted(pictures, key=lambda p: p.display_index)):
        picture.display_index = rank
