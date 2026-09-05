"""Trick mode: what makes the decoder usable continuously.

doc/mpeg2fpga.txt sec 1.11. The trick mode register controls the *display*
path, not decoding: the decoder reconstructs pictures into the frame store at
its own rate, a separate reader scans them out to video, and trick mode sits
between the two deciding which picture is shown and how many times.

That indirection is why pause works the way it does. `repeat_frame = 31` tells
the display to keep showing the current picture; the decoder then stalls behind
it for want of anywhere to put the next one. Nothing is reset and no clock is
stopped. Measured on hardware: framestore writes go from 130/s to 0/s and back,
with the watchdog never tripping -- section 1.10 explicitly holds the watchdog
off while repeat_frame is 31 or source_select is non-zero, because a pause
looks exactly like the "busy but no data arriving" condition the watchdog
exists to catch.

`flush_vbuf` is the other half: it clears the input buffer, which the
documentation introduces with "useful when changing channels". Pushing a second
stream after a flush works with no core reset at all -- verified going from
704x480 to 720x576 with video_ch raised and error 0.

The write bank has no readback path (reading address 0x0b returns an unrelated
register), so the last written value has to be shadowed to change one field
without clobbering the others. Getting that wrong is not theoretical:
persistence is 1 at reset, and losing it turns "hold the last picture when
starved" into "go black".

This mirrors the kernel driver's mpeg2fpga_core trick-mode support, which is
where this belongs long term; the webserver still talks to the registers
directly through UIO.
"""
import threading

from decoder_push import PAGE_OFFSET

W_TRICK_MODE = 0x0b

FLUSH_VBUF = 1 << 0
SOURCE_SELECT_SHIFT, SOURCE_SELECT_MASK = 1, 0x7 << 1
PERSISTENCE = 1 << 4
REPEAT_FRAME_SHIFT, REPEAT_FRAME_MASK = 5, 0x1f << 5
DEINTERLACE = 1 << 10

REPEAT_FRAME_FREEZE = 31

SOURCE_LAST_DECODED = 0
SOURCE_BLANK = 1
SOURCE_FRAME_0 = 4          # 4..7 select framestore frames 0..3

# Reset value of the register, per the documentation: persistence set,
# everything else clear.
RESET_VALUE = PERSISTENCE


class TrickMode:
    """Shadowed access to the trick mode register.

    Holds the shadow, not a register handle. The shadow is long-lived state --
    it has to outlive any one request, because the register cannot be read back
    -- while a DmaPusher is a transient mmap that is closed when its `with`
    block ends. Binding the two together produced exactly that bug: the shadow
    survived, the mmap did not, and the next write failed with "argument must
    be read-write bytes-like object, not mmap.mmap".
    """

    def __init__(self, shadow=RESET_VALUE):
        self._shadow = shadow
        self._lock = threading.Lock()

    @property
    def shadow(self):
        return self._shadow

    @staticmethod
    def _write(pusher, value):
        pusher._write_reg(PAGE_OFFSET + W_TRICK_MODE * 4, value)

    def apply(self, pusher):
        """Push the shadow to hardware, e.g. after a core reset cleared it."""
        with self._lock:
            self._write(pusher, self._shadow)

    def _update(self, pusher, mask, value):
        with self._lock:
            self._shadow = (self._shadow & ~mask) | (value & mask)
            self._write(pusher, self._shadow)

    def flush_vbuf(self, pusher):
        """Drop whatever is left of the previous stream in the input buffer.

        A strobe, not a mode: raised for one write and dropped again, so the
        shadow does not carry a permanent flush into the next change of some
        unrelated field.
        """
        with self._lock:
            self._write(pusher, self._shadow | FLUSH_VBUF)
            self._write(pusher, self._shadow)

    def set_freeze(self, pusher, freeze):
        self._update(pusher, REPEAT_FRAME_MASK,
                     (REPEAT_FRAME_FREEZE if freeze else 0) << REPEAT_FRAME_SHIFT)

    @property
    def frozen(self):
        return ((self._shadow & REPEAT_FRAME_MASK) >> REPEAT_FRAME_SHIFT
                == REPEAT_FRAME_FREEZE)

    def set_repeat_frame(self, pusher, times):
        """Show each decoded picture `times`+1 times -- slow motion."""
        if not 0 <= times <= 31:
            raise ValueError("repeat_frame is 0..31")
        self._update(pusher, REPEAT_FRAME_MASK, times << REPEAT_FRAME_SHIFT)

    def set_source_select(self, pusher, source):
        if source in (2, 3) or not 0 <= source <= 7:
            raise ValueError("source_select is 0, 1, or 4..7")
        self._update(pusher, SOURCE_SELECT_MASK, source << SOURCE_SELECT_SHIFT)

    @property
    def source_select(self):
        return (self._shadow & SOURCE_SELECT_MASK) >> SOURCE_SELECT_SHIFT

    def set_persistence(self, pusher, on):
        self._update(pusher, PERSISTENCE, PERSISTENCE if on else 0)

    def describe(self):
        repeat = (self._shadow & REPEAT_FRAME_MASK) >> REPEAT_FRAME_SHIFT
        return {
            "raw": "0x%04x" % self._shadow,
            "frozen": self.frozen,
            "repeat_frame": repeat,
            "source_select": self.source_select,
            "persistence": bool(self._shadow & PERSISTENCE),
        }
