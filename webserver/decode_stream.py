"""Catch every picture on its way through the four frame buffers.

The decoder has four frame buffers and runs far faster than real time, so
pushing a stream and reading afterwards only ever recovers the last four
pictures -- everything before that has been overwritten. To get the whole
sequence out, something has to read each picture while it is still there.

Feeding the decoder one picture at a time would be the obvious way, and does not
work: stream_dma.v emits a 32-byte sequence_end_code after *every* DMA transfer
(its S_PAD state), which is right for a one-shot push -- it flushes the last
picture -- but ends the sequence after each chunk. The decoder then sits
starving with no sequence header to resync on, and only the first picture ever
gets decoded. Giving the DMA engine a "don't pad" control bit would be a small
change to stream_dma.v, but it is our own wrapper rather than the licensed core,
so it is a candidate for the next synthesis run rather than something to work
around in the bitstream we have.

So instead: start the whole stream going in one transfer and watch the frame
buffers go by. Measured on the board at 704x480 the decoder spends about 133 ms
per picture, while a fingerprint of all four buffers costs 1.0 ms and reading
one back 7 ms -- two orders of magnitude of headroom. A buffer is captured once
it has changed and then held still for STABLE_S. The last picture is flushed by
the very sequence_end padding that made the chunked approach impossible.

Two things had to be right before this worked, both of them counterintuitive:

  * The DMA is *started*, not pushed. dma_push's push_dma() blocks until the
    transfer reports done, and the transfer is throttled by the decoder's own
    backpressure, so it only returns once most of the stream has been decoded.
    Watching from there captures the tail of the clip and nothing else: on a
    60 picture stream it returned pictures 31 to 59, every one of them read
    correctly and every one of them labelled as though it were 0 to 28.
  * Frames are held in RAM until the capture finishes, and only sent after.
    The link is not the reason -- it moves 18.5 MB/s over plain HTTP -- but a
    write of half a megabyte still lands in the middle of a 133 ms budget, and
    the decoder does not wait.
"""

import threading
import time

import decoder_control
import elementary_stream
import framestore
import trick_mode
from ddr_region import DDRRegion, FRAMESTORE_DEVICE, STAGING_DEVICE
from dma_push import STAGE_OFFSET, sync_for_device

POISON = 0xEE

# A fingerprint is a cheap sample of a plane, taken to answer "did the decoder
# touch this buffer?" without reading half a megabyte of uncached DRAM. Reading
# the whole plane and subsampling in Python costs 19.5 ms for four buffers,
# which is slow enough to walk straight past pictures; 24 short reads spread
# over the plane cost 1.0 ms and miss nothing, because a new picture rewrites
# the plane end to end.
FINGERPRINT_SPOTS = 24
FINGERPRINT_SPOT_BYTES = 64

# How long a buffer must hold still before its picture counts as finished.
# Measured on the board at 704x480: writes within one picture pause for up to
# 23.5 ms (p95 20.3 ms) as the memory arbiter serves the display path, while
# consecutive pictures are ~133 ms apart. 35 ms sits between the two.
STABLE_S = 0.035
IDLE_GIVE_UP_S = 1.5            # nothing moved this long: the stream is done

# Captured frames are held in RAM until the decode finishes, then sent. Sending
# from inside the capture loop costs pictures: not because the link is slow (it
# does 18.5 MB/s over plain HTTP) but because half a megabyte of socket write
# lands in the middle of the 133 ms the decoder gives us per picture.
MAX_FRAMES = 240
MAX_CAPTURE_BYTES = 160 << 20


class Capture:
    """One picture read out of a frame buffer."""

    __slots__ = ("display_index", "decode_index", "picture_type", "buffer",
                 "geometry", "planes")

    def __init__(self, picture, buffer, geometry, planes):
        self.display_index = picture.display_index
        self.decode_index = picture.index
        self.picture_type = picture.coding_type
        self.buffer = buffer
        self.geometry = geometry
        self.planes = planes


def _fingerprint(region, geometry):
    step = max(FINGERPRINT_SPOT_BYTES, geometry.luma_bytes // FINGERPRINT_SPOTS)
    at = geometry.luma_offset
    return b"".join(region.read(at + i * step, FINGERPRINT_SPOT_BYTES)
                    for i in range(FINGERPRINT_SPOTS))


def decode(data, on_frame, on_progress=None, on_capture_progress=None,
           control=None, reset=False):
    """Decode `data`, calling on_frame(Capture) per picture in decode order.

    on_capture_progress(captured, total) is called from *this* thread while the
    capture runs, so a caller can report progress without putting a socket write
    inside the capture loop, where it would cost frames.

    `control` is a decoder_control backend (the kernel driver's sysfs interface
    when the module is bound, raw UIO otherwise); one is opened here if not
    given. The previous stream is cleared out of the input buffer with
    flush_vbuf instead of by resetting the core.
    That is what the decoder is designed for -- see trick_mode.py -- and it is
    both faster and closer to how a real player behaves. `reset=True` forces the
    old behaviour: pulse core enable and poison the framestore, which is worth
    doing once at startup or to recover from a wedged decoder.

    Returns a summary dict. Raises ValueError if the stream has no pictures.
    """
    sequence = elementary_stream.parse(data)
    if not sequence.pictures:
        raise ValueError("no picture start codes in this stream")

    width, height = sequence.width, sequence.height
    summary = {}
    captures = []
    started = time.time()

    def run():
        try:
            own_control = control is None
            control_ = control or decoder_control.open_control()
            with DDRRegion(FRAMESTORE_DEVICE) as fs:
                if reset:
                    # The sledgehammer: hold the core in reset and poison the
                    # framestore so "never written" is distinguishable from
                    # "reconstructed to mid-grey". Costs ~0.6 s, almost all of
                    # it in two conservative sleeps.
                    control_.set_enable(False)
                    time.sleep(0.2)
                    block = bytes([POISON]) * (1 << 20)
                    for offset in range(0, framestore.FRAMESTORE_BYTES,
                                        len(block)):
                        fs.write(offset, block)
                    control_.set_enable(True)
                    time.sleep(0.3)
                else:
                    # What the decoder is actually designed for: drop the tail
                    # of the previous stream and carry on. The frame buffers
                    # keep their contents, which is fine -- capture watches for
                    # *changes*, and the display keeps showing the last picture
                    # instead of flashing black between streams.
                    control_.set_freeze(False)
                    control_.set_source_select(trick_mode.SOURCE_LAST_DECODED)
                    control_.flush_vbuf()
                control_.clear_status()

                geometries = [framestore.PlaneGeometry(f, width, height)
                              for f in range(framestore.NUM_FRAMES)]
                marks = [_fingerprint(fs, g) for g in geometries]
                dirty = [False] * framestore.NUM_FRAMES
                last_change = [0.0] * framestore.NUM_FRAMES

                # Start the transfer, do NOT wait for it. dma_push's push_dma()
                # blocks until the DMA reports done, and the DMA is throttled by
                # the decoder's own backpressure, so it only returns once most
                # of the stream has already been decoded -- watching from there
                # catches the tail of the clip and nothing else. (That is
                # exactly what the first version did: on a 60 picture stream it
                # returned pictures 31 to 59, correctly captured and all
                # mislabelled as 0 to 28.)
                with DDRRegion(STAGING_DEVICE) as staging:
                    staging.write(STAGE_OFFSET, data)
                sync_for_device(len(data))
                control_.dma_start(STAGE_OFFSET, len(data))

                held = 0
                last_activity = time.time()
                wanted = min(len(sequence.pictures), MAX_FRAMES)
                while (len(captures) < wanted
                       and time.time() - last_activity < IDLE_GIVE_UP_S):
                    now = time.time()
                    for buffer, geometry in enumerate(geometries):
                        mark = _fingerprint(fs, geometry)
                        if mark != marks[buffer]:
                            marks[buffer] = mark
                            dirty[buffer] = True
                            last_change[buffer] = now
                            last_activity = now
                        elif dirty[buffer] and now - last_change[buffer] >= STABLE_S:
                            dirty[buffer] = False
                            picture = sequence.pictures[len(captures)]
                            planes = geometry.read(fs)
                            captures.append(Capture(picture, buffer, geometry, planes))
                            held += sum(len(p) for p in planes)
                            last_activity = time.time()
                            # re-mark: the read took a few ms, during which the
                            # decoder may have started on this buffer again
                            marks[buffer] = _fingerprint(fs, geometry)
                            if len(captures) >= wanted or held > MAX_CAPTURE_BYTES:
                                break
                    else:
                        continue
                    break

                # Status is read once, at the end: the driver's IRQ handler
                # accumulates the read-to-clear bits, so there is no need to
                # keep polling the register the way the raw path had to.
                status = control_.status()
                geom = control_.geometry()
                summary.update({
                    "width": width,
                    "height": height,
                    "backend": control_.backend,
                    "decoder_size": [geom["width"], geom["height"]],
                    "frame_rate": round(sequence.frame_rate, 3),
                    "pictures": len(sequence.pictures),
                    "captured": len(captures),
                    "sticky": "0x%04x" % status.get("sticky", 0),
                    "error": bool(status.get("error")),
                    "watchdog": bool(status.get("watchdog")),
                    "capture_seconds": round(time.time() - started, 2),
                    "reset": bool(reset),
                })
        except Exception as exc:                # noqa: BLE001 - hand it to the caller
            summary["exception"] = repr(exc)
        finally:
            if own_control:
                try:
                    control_.close()
                except Exception:               # noqa: BLE001
                    pass

    # The capture runs on its own thread only so that a slow client cannot
    # stall it; nothing is sent until it has finished.
    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    reported = -1
    while worker.is_alive():
        worker.join(timeout=0.25)
        if on_capture_progress and len(captures) != reported:
            reported = len(captures)
            on_capture_progress(reported, len(sequence.pictures))

    if "exception" not in summary:
        for delivered, capture in enumerate(captures, 1):
            on_frame(capture)
            if on_progress:
                on_progress(delivered, len(captures))

    if "exception" in summary:
        raise RuntimeError(summary["exception"])
    summary["seconds"] = round(time.time() - started, 2)
    # A short capture means the loop lost a picture, which also means every
    # frame after the loss carries the wrong display index. Say so rather than
    # quietly serving a scrambled sequence.
    summary["complete"] = summary.get("captured") == len(sequence.pictures)
    return summary
