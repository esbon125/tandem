"""Synthetic MPEG-2 video elementary streams: just the headers the daemon reads
(sequence, GOP, picture, picture coding extension) with filler in between,
which is enough for the scanner and for the fake decoder."""

import struct


def sequence_header(width, height):
    # horizontal_size(12) vertical_size(12) aspect(4) frame_rate_code(4) ...
    return (b"\x00\x00\x01\xb3" + bytes([width >> 4, ((width & 0xF) << 4) | (height >> 8),
                                         height & 0xFF, 0x13]) + b"\xff\xff\xe0\x18")


def gop_header():
    return b"\x00\x00\x01\xb8\x00\x08\x00\x00"


def picture(tr, ptype, structure=3, filler=200):
    hdr = b"\x00\x00\x01\x00" + bytes([tr >> 2, ((tr & 3) << 6) | (ptype << 3), 0xff, 0xf8])
    ext = b"\x00\x00\x01\xb5" + bytes([0x8f, 0xff, 0xf0 | structure, 0x80, 0x80])
    return hdr + ext + b"\xa5" * filler


TYPES = {"I": 1, "P": 2, "B": 3}


def stream(gops, width=64, height=32, filler=200, fields=False):
    """gops: list of GOPs, each a list of (temporal_reference, "I"/"P"/"B") in
    decode order. fields=True codes every frame as a top+bottom field pair."""
    out = bytearray(sequence_header(width, height))
    for gop in gops:
        out += gop_header()
        for tr, t in gop:
            if fields:
                out += picture(tr, TYPES[t], 1, filler) + picture(tr, TYPES[t], 2, filler)
            else:
                out += picture(tr, TYPES[t], 3, filler)
    out += b"\x00\x00\x01\xb7"
    return bytes(out)


IPBB = [(0, "I"), (3, "P"), (1, "B"), (2, "B")]


def display_types(gops):
    """Picture types in display order, the order frames must come out in."""
    out = []
    for gop in gops:
        out += [t for _, t in sorted(gop)]
    return out


_ = struct
