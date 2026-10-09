"""Incremental MPEG-2 video elementary stream scanner.

The daemon feeds it the upload as it arrives, ahead of the decoder (bytes go
through here on their way to the DMA), and asks it what the k-th frame in
display order is: the hardware's picture interrupt says *that* a frame is
ready and in which buffer, not its picture type or position in the stream.

Display order within a GOP is temporal_reference order (ISO/IEC 13818-2
6.3.9), so frame k is found by walking GOPs: whole GOPs before it, then
temporal_reference k - offset inside its own. Field pictures come in pairs
with the same temporal_reference and make one frame. All of this is
metadata for the FRAME record; the pixels come from the frame store, so a
stream this scanner misreads still decodes, it is only labelled worse.
"""

PICTURE = 0x00
SEQUENCE = 0xB3
EXTENSION = 0xB5
GOP = 0xB8
SEQUENCE_END = 0xB7

EXT_SEQUENCE = 1
EXT_PICTURE_CODING = 8

# bytes after a start code that the parse below can need: picture coding
# extension up to picture_structure is 3, sequence header to frame_rate 4
NEED = 8


class FrameInfo:
    __slots__ = ("decode_index", "picture_type", "structure", "temporal_reference",
                 "width", "height")

    def __init__(self, decode_index, picture_type, temporal_reference, width, height):
        # the size of *this* frame's sequence: the scanner runs ahead of the
        # decoder, so "the current size" would already be the next sequence's
        self.width, self.height = width, height
        self.decode_index = decode_index
        self.picture_type = picture_type        # 1 I, 2 P, 3 B
        self.structure = 0                      # 0 frame picture, 1 field pair
        self.temporal_reference = temporal_reference


class _Gop:
    __slots__ = ("frames", "closed")

    def __init__(self):
        self.frames = {}                        # temporal_reference -> FrameInfo
        self.closed = False


class StreamScanner:
    def __init__(self):
        self._carry = b""
        self.bytes_seen = 0
        self.pictures = 0                       # coded pictures, fields counted singly
        self.sequence_headers = 0
        self.width = self.height = None
        self._gops = [_Gop()]
        self._last = None                       # (FrameInfo, is_field_pending)
        self._pending_field = None

    # -- feeding ------------------------------------------------------------

    def feed(self, data):
        self.bytes_seen += len(data)
        buf = self._carry + bytes(data)
        at = buf.find(b"\x00\x00\x01")
        done = 0
        while at >= 0:
            if at + 4 + NEED > len(buf):
                break                           # finish this one when more arrives
            self._start_code(buf[at + 3], buf, at + 4)
            done = at + 3
            at = buf.find(b"\x00\x00\x01", at + 3)
        if at >= 0:
            self._carry = buf[at:]
        else:
            self._carry = buf[max(done, len(buf) - 2):]   # a start code may straddle

    def finish(self):
        """End of stream: close the last GOP (its size is now final)."""
        self.feed(b"\x00" * (NEED + 4))        # flush a start code at the very end
        self._gops[-1].closed = True

    # -- parsing ------------------------------------------------------------

    def _start_code(self, code, buf, p):
        if code == SEQUENCE:
            self.sequence_headers += 1
            self.width = (buf[p] << 4) | (buf[p + 1] >> 4)
            self.height = ((buf[p + 1] & 0x0F) << 8) | buf[p + 2]
            self._new_gop()
        elif code == GOP:
            self._new_gop()
        elif code == PICTURE:
            tr = (buf[p] << 2) | (buf[p + 1] >> 6)
            ptype = (buf[p + 1] >> 3) & 0x07
            self._picture(tr, ptype)
        elif code == EXTENSION and buf[p] >> 4 == EXT_PICTURE_CODING:
            structure = buf[p + 2] & 0x03
            if self._last is not None and structure != 3:
                self._last.structure = 1
        elif code == SEQUENCE_END:
            self._gops[-1].closed = True

    def _new_gop(self):
        if self._gops[-1].frames:
            self._gops[-1].closed = True
            self._gops.append(_Gop())

    def _picture(self, tr, ptype):
        gop = self._gops[-1]
        index = self.pictures
        self.pictures += 1
        if tr in gop.frames:
            # second field of a pair (or a repeated reference): same frame
            self._last = gop.frames[tr]
            self._last.structure = 1
            return
        info = FrameInfo(index, ptype, tr, self.width, self.height)
        gop.frames[tr] = info
        self._last = info

    # -- queries ------------------------------------------------------------

    @property
    def frames_total(self):
        return sum(len(g.frames) for g in self._gops)

    def frame(self, k):
        """FrameInfo of the k-th frame in display order, or None if not seen yet."""
        offset = 0
        for gop in self._gops:
            n = len(gop.frames)
            if gop.closed:
                if k < offset + n:
                    # temporal_reference counts display order inside the GOP
                    return gop.frames.get(sorted(gop.frames)[k - offset])
                offset += n
            else:
                # still arriving: frames with a lower temporal_reference may
                # not have been seen yet (I0 P3 before B1 B2), so look the
                # temporal_reference up directly rather than by rank
                return gop.frames.get(k - offset)
        return None


def scan(data):
    """Whole-buffer convenience for tests."""
    s = StreamScanner()
    s.feed(data)
    s.finish()
    return s
