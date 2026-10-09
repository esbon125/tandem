"""Wire format of protocol v1 (api/PROTOCOL-v1.md, section 5).

Kept separate from the HTTP client so the frame-record parser can be tested,
and reused by the device side, without a network in the way.
"""

import struct

PROTOCOL_MAJOR = 1
CONTENT_TYPE_FRAMES = "application/vnd.mpeg2fpga.frames"

MAGIC = b"M2FR"
RECORD_FRAME = 1
RECORD_END = 2

# magic, type, flags, header_len, payload_len
COMMON_HEADER = struct.Struct("<4sBBHI")
# display_index, decode_index, width, height, picture_type, structure, 2 + 4 reserved
FRAME_HEADER = struct.Struct("<IIHHBBHI")
FRAME_HEADER_LEN = COMMON_HEADER.size + FRAME_HEADER.size     # 32 in v1

PICTURE_TYPES = {1: "I", 2: "P", 3: "B"}


class ProtocolError(Exception):
    """The device sent something that does not follow protocol v1."""


def pack_record(rtype, extra_header=b"", payload=b"", flags=0):
    header_len = COMMON_HEADER.size + len(extra_header)
    return (COMMON_HEADER.pack(MAGIC, rtype, flags, header_len, len(payload))
            + extra_header + payload)


def pack_frame(display_index, decode_index, width, height, picture_type,
               y, u, v, structure=0):
    extra = FRAME_HEADER.pack(display_index, decode_index, width, height,
                              picture_type, structure, 0, 0)
    return pack_record(RECORD_FRAME, extra, y + u + v)


def read_record(read_exact):
    """Read one record with `read_exact(n) -> bytes` (exactly n, or b"" at EOF).

    Returns (type, extra_header, payload), or None at a clean end of stream
    (EOF exactly on a record boundary). Unknown fields at the end of a header
    are kept in extra_header for the caller to ignore -- that is how v1 grows.
    """
    head = read_exact(COMMON_HEADER.size)
    if not head:
        return None
    if len(head) != COMMON_HEADER.size:
        raise ProtocolError("stream ended inside a record header")
    magic, rtype, _flags, header_len, payload_len = COMMON_HEADER.unpack(head)
    if magic != MAGIC:
        raise ProtocolError("bad record magic %r" % magic)
    if header_len < COMMON_HEADER.size:
        raise ProtocolError("header_len %d shorter than the common header" % header_len)
    extra = read_exact(header_len - COMMON_HEADER.size)
    payload = read_exact(payload_len)
    if len(extra) != header_len - COMMON_HEADER.size or len(payload) != payload_len:
        raise ProtocolError("stream ended inside a record")
    return rtype, extra, payload
