#!/usr/bin/env python3
"""
framecmp -- compare an mpeg2fpga framestore against the reference decoder.

Why this exists
---------------
Until now there was no trustworthy way to say whether a frame the decoder
produced is correct.  Taking a full-frame MAD of a framestore dump against
tools/mpeg2dec output does not work: it scored the known-good simulation
(MAD ~94) no better than the hardware (MAD ~121), so the *method* was wrong.
The traps that made it wrong, all of them handled here:

  * The framestore stores pixels as *signed* 8-bit values, offset by -128
    (see rtl/mpeg2/motcomp_recon.v: "-128 corresponding to 0 and 127
    corresponding to 255").  Read as unsigned, every pixel is off by 128.
  * Within a 64-bit word the leftmost pixel is bits [63:56], so in a
    little-endian byte dump the eight pixels of a word appear reversed.
  * The frame store holds four frame buffers which the decoder rotates
    through, and MPEG-2 decode order is not display order.  There is no fixed
    mapping from "buffer N" to "reference frame N", so this tool never assumes
    one: it scores every buffer against every reference frame and reports the
    best match.  A correct decode gives one near-zero score per buffer.
  * Field pictures: two coded pictures make one frame, so a dump taken between
    the two fields holds half a frame.  Use a frame-picture stream, or accept
    that odd dumps are half-written.
  * The reference decoder's decoded output is frame_NN_out_, not frame_NN_aux_
    (aux is a scratch buffer).
  * mpeg2fpga's COMP_CR / COMP_CB carry MPEG-2 block 4 / block 5, i.e. Cb / Cr:
    the internal names are swapped relative to the standard.  --chroma-order
    defaults to autodetecting this rather than trusting either name.

The other design point: simulation and hardware are compared with *the same
code*.  bench/iverilog/mem_ctl.v dumps the framestore as raw little-endian
64-bit words, byte-for-byte what a DDR dump of that region looks like on the
board, so `extract` has one implementation and is validated once, in
simulation, against the reference decoder.

Usage
-----
  # reference frames for a stream (runs tools/mpeg2dec/mpeg2decode)
  framecmp.py ref STREAM -o refdir/

  # simulation: bench/iverilog writes fs_NNNN.bin + fs_NNNN.txt
  framecmp.py compare bench/iverilog/fs_0003.bin refdir/

  # hardware: a raw dump of the framestore region of DDR
  framecmp.py compare hw.bin refdir/ --geometry 352x224 --base-word 0

  # just look at it
  framecmp.py extract fs_0003.bin -o out/ --pgm

Exit status is 0 if every frame buffer that holds a picture matched a
reference frame within --threshold, 1 otherwise.
"""

from __future__ import print_function

import argparse
import os
import re
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
MPEG2DEC = os.path.join(HERE, os.pardir, "mpeg2dec", "mpeg2decode")

# ---------------------------------------------------------------------------
# frame store geometry -- keep in sync with rtl/mpeg2/mem_codes.v
# ---------------------------------------------------------------------------

# (WIDTH_Y, WIDTH_C): luminance / chrominance region size is 2**WIDTH words.
MEMORY_MAPS = {
    "MP_AT_HL": (18, 16),   # HDTV map, up to 1920x1088.  The default in mem_codes.v.
    "MP_AT_ML": (16, 14),   # SDTV map, up to 768x576.
}


class FrameStoreMap(object):
    """Word addresses of the twelve planes, exactly as mem_codes.v computes them."""

    def __init__(self, memory_map="MP_AT_HL"):
        width_y, width_c = MEMORY_MAPS[memory_map]
        self.name = memory_map
        self.y_words = 1 << width_y
        self.c_words = 1 << width_c
        self.planes = {}
        for f in range(4):
            frame_base = f * (self.y_words + 2 * self.c_words)
            self.planes[(f, "Y")] = frame_base
            self.planes[(f, "CR")] = frame_base + self.y_words
            self.planes[(f, "CB")] = frame_base + self.y_words + self.c_words
        self.osd = 4 * (self.y_words + 2 * self.c_words)

    def base(self, frame, component):
        return self.planes[(frame, component)]


# ---------------------------------------------------------------------------
# reading a dump
# ---------------------------------------------------------------------------

def read_metadata(path):
    """Parse an fs_NNNN.txt sidecar written by bench/iverilog/mem_ctl.v."""
    meta = {}
    with open(path) as fp:
        for line in fp:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            key = parts[0]
            value = parts[1].strip() if len(parts) > 1 else ""
            try:
                meta[key] = int(value)
            except ValueError:
                meta[key] = value
    return meta


def load_words(path, base_word):
    """Memory-map a raw dump as unsigned bytes, remembering its base word address."""
    data = np.fromfile(path, dtype=np.uint8)
    if data.size % 8:
        raise ValueError("%s: %d bytes is not a whole number of 64-bit words"
                         % (path, data.size))
    return data, base_word


def extract_plane(data, base_word, plane_base, words_per_row, rows, width, height):
    """Pull one plane out of the raw dump.

    The address arithmetic is the one in rtl/mpeg2/mem_addr.v:

        address = pixel_y * mb_width * (2 if luma else 1) + (pixel_x >> 3)

    i.e. plain raster order, `words_per_row` 64-bit words per line, eight
    pixels to a word.  Pixel (0) of a word is bits [63:56], so in the
    little-endian byte order of the dump the eight bytes of a word run right
    to left; hence the reshape-and-flip below.  Stored values are signed and
    offset by -128, which `^ 0x80` undoes.
    """
    start = (plane_base - base_word) * 8
    stop = start + rows * words_per_row * 8
    if start < 0 or stop > data.size:
        raise ValueError("plane at word 0x%x (bytes %d..%d) is outside the %d byte dump"
                         % (plane_base, start, stop, data.size))
    plane = data[start:stop].reshape(rows, words_per_row, 8)
    plane = plane[:, :, ::-1]                       # 64-bit word is little-endian
    plane = plane.reshape(rows, words_per_row * 8)
    plane = plane ^ 0x80                            # signed, offset by -128
    return plane[:height, :width]


def extract_frames(data, base_word, mb_width, mb_height, width, height,
                   fsmap, frames=(0, 1, 2, 3)):
    """Return {frame index: {'Y':.., 'CR':.., 'CB':..}} of uint8 planes."""
    out = {}
    for f in frames:
        planes = {}
        planes["Y"] = extract_plane(
            data, base_word, fsmap.base(f, "Y"),
            words_per_row=2 * mb_width, rows=16 * mb_height,
            width=width, height=height)
        for comp in ("CR", "CB"):
            planes[comp] = extract_plane(
                data, base_word, fsmap.base(f, comp),
                words_per_row=mb_width, rows=8 * mb_height,
                width=width // 2, height=height // 2)
        out[f] = planes
    return out


# ---------------------------------------------------------------------------
# the reference decoder
# ---------------------------------------------------------------------------

def run_reference(stream, outdir, decoder=None, frames=None, reference_idct=True):
    """Run tools/mpeg2dec over `stream`, leaving frame_NN_out_.{y,u,v}.ppm in outdir."""
    decoder = decoder or MPEG2DEC
    if not os.path.exists(decoder):
        raise SystemExit("reference decoder not built: %s\n"
                         "run `make` in tools/mpeg2dec first" % decoder)
    if not os.path.isdir(outdir):
        os.makedirs(outdir)
    # -o0 writes ascii pgm planes.  -r selects the double precision reference
    # IDCT: that makes the reference an absolute yardstick rather than one
    # particular conformant decoder, so a difference is ours.  Dropping it
    # (--fast-idct) tells you how much of a difference is just two conformant
    # 8-bit IDCTs disagreeing, which matters on the streams that exist to
    # stress exactly that.
    cmd = [os.path.abspath(decoder), "-b", os.path.abspath(stream), "-q", "-o0", "rec%d%c"]
    if reference_idct:
        cmd.insert(4, "-r")
    proc = subprocess.Popen(cmd, cwd=outdir, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    out, err = proc.communicate()
    found = sorted(f for f in os.listdir(outdir) if f.endswith("_out_.y.ppm"))
    if proc.returncode != 0:
        # mpeg2decode is old C and falls over at end of sequence on some
        # conformance streams. The frames it wrote before that are still good,
        # so only treat the crash as fatal if it produced nothing.
        sys.stderr.write(err.decode("utf-8", "replace")[-2000:])
        if not found:
            raise SystemExit("reference decoder failed (exit %d) and wrote no frames"
                             % proc.returncode)
        sys.stderr.write("warning: reference decoder exited %d after writing %d frames; "
                         "using them anyway\n" % (proc.returncode, len(found)))
    if frames is not None:
        found = found[:frames]
    return found


_PGM_HEADER = re.compile(br"^\s*P2\s+(\d+)\s+(\d+)\s+(\d+)\s")


def read_ascii_pgm(path):
    """Read the ascii (P2) pgm that mpeg2dec's store_yuv1 writes."""
    with open(path, "rb") as fp:
        blob = fp.read()
    match = _PGM_HEADER.match(blob)
    if not match:
        raise ValueError("%s: not an ascii pgm" % path)
    width, height = int(match.group(1)), int(match.group(2))
    values = np.array(blob[match.end():].split(), dtype=np.int32)
    if values.size < width * height:
        raise ValueError("%s: %d samples, expected %d"
                         % (path, values.size, width * height))
    return values[:width * height].astype(np.uint8).reshape(height, width)


def load_reference_frames(refdir, limit=None):
    """Return [(name, {'Y':.., 'U':.., 'V':..}), ...] in display order."""
    names = sorted(f[:-len(".y.ppm")] for f in os.listdir(refdir)
                   if f.endswith("_out_.y.ppm"))
    if limit is not None:
        names = names[:limit]
    frames = []
    for name in names:
        planes = {}
        for key, suffix in (("Y", ".y.ppm"), ("U", ".u.ppm"), ("V", ".v.ppm")):
            planes[key] = read_ascii_pgm(os.path.join(refdir, name + suffix))
        frames.append((name, planes))
    return frames


# ---------------------------------------------------------------------------
# scoring
# ---------------------------------------------------------------------------

def score(a, b):
    """MAD, peak error and PSNR between two same-shaped uint8 planes."""
    if a.shape != b.shape:
        rows = min(a.shape[0], b.shape[0])
        cols = min(a.shape[1], b.shape[1])
        a, b = a[:rows, :cols], b[:rows, :cols]
    diff = a.astype(np.int32) - b.astype(np.int32)
    mad = float(np.abs(diff).mean())
    peak = int(np.abs(diff).max())
    mse = float((diff.astype(np.float64) ** 2).mean())
    psnr = float("inf") if mse == 0.0 else 10.0 * np.log10(255.0 * 255.0 / mse)
    return mad, peak, psnr


def print_macroblock_map(plane, ref, mb_width, mb_height, tolerance=2):
    """Show which macroblocks are wrong.

    Whether the damage is diffuse or localised is the first thing worth
    knowing: a couple of units of MAD spread evenly over the picture is drift,
    the same MAD concentrated in a few macroblocks is a coding mode the decoder
    gets wrong, and a solid block of them is a whole plane in the wrong place.
    """
    rows = min(plane.shape[0], ref.shape[0]) // 16 * 16
    cols = min(plane.shape[1], ref.shape[1]) // 16 * 16
    diff = np.abs(plane[:rows, :cols].astype(np.int32) - ref[:rows, :cols].astype(np.int32))
    bad = (diff > tolerance).reshape(rows // 16, 16, cols // 16, 16).sum(axis=(1, 3))
    print("          %d of %d macroblocks differ by more than %d "
          "(. none, + some, # over a quarter of the pixels)"
          % (int((bad > 0).sum()), bad.size, tolerance))
    for row in bad:
        print("          " + "".join("#" if v > 64 else ("+" if v else ".") for v in row))


def is_blank(plane):
    """A frame buffer nothing has been written to is one uniform value."""
    return int(plane.max()) == int(plane.min())


# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------

def write_pgm(path, plane):
    with open(path, "wb") as fp:
        fp.write(b"P5\n%d %d\n255\n" % (plane.shape[1], plane.shape[0]))
        fp.write(plane.tobytes())


def write_i420(path, y, u, v):
    with open(path, "wb") as fp:
        fp.write(y.tobytes())
        fp.write(u.tobytes())
        fp.write(v.tobytes())


# ---------------------------------------------------------------------------
# geometry resolution
# ---------------------------------------------------------------------------

def resolve_geometry(args, dump_path):
    """Work out image geometry from the sidecar, from --geometry, or complain."""
    meta = {}
    sidecar = args.meta
    if sidecar is None:
        guess = os.path.splitext(dump_path)[0] + ".txt"
        if os.path.exists(guess):
            sidecar = guess
    if sidecar:
        meta = read_metadata(sidecar)

    if args.geometry:
        width, height = (int(v) for v in args.geometry.lower().split("x"))
    elif "horizontal_size" in meta:
        width, height = meta["horizontal_size"], meta["vertical_size"]
    else:
        raise SystemExit("no geometry: pass --geometry WxH or --meta fs_NNNN.txt")

    mb_width = meta.get("mb_width", (width + 15) // 16)
    mb_height = meta.get("mb_height", (height + 15) // 16)
    base_word = args.base_word
    if base_word is None:
        base_word = meta.get("base_word_address", 0)
    return meta, width, height, mb_width, mb_height, base_word


# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------

def cut_stream(stream, pictures, out):
    """Cut an elementary stream after a whole number of pictures.

    Truncating a test stream at an arbitrary byte leaves both decoders holding
    half a picture, and they do not hold the same half: the reference gives up
    with "premature end of picture" and writes nothing for it, while the
    hardware writes the macroblocks it did get into the frame buffer it is
    rotating into -- overwriting the top of a frame that was otherwise perfect.
    That shows up as a puzzling localised error in a buffer that has no
    reference frame to be scored against. Cutting on a picture boundary and
    appending a sequence end code removes the whole class of confusion.
    """
    data = open(stream, "rb").read()
    picture_start = b"\x00\x00\x01\x00"
    offsets = []
    at = data.find(picture_start)
    while at >= 0:
        offsets.append(at)
        at = data.find(picture_start, at + 1)
    if len(offsets) < pictures:
        raise SystemExit("%s has only %d pictures, cannot cut after %d"
                         % (stream, len(offsets), pictures))
    # cutting after every picture there is means keeping the whole file
    end = offsets[pictures] if pictures < len(offsets) else len(data)
    with open(out, "wb") as fp:
        fp.write(data[:end])
        fp.write(b"\x00\x00\x01\xb7")   # sequence_end_code, so the last picture flushes
    return end, len(offsets)


def cmd_cut(args):
    end, total = cut_stream(args.stream, args.pictures, args.out)
    print("%s: %d pictures; wrote first %d as %s (%d bytes + sequence end code)"
          % (args.stream, total, args.pictures, args.out, end))
    return 0


def cmd_ref(args):
    names = run_reference(args.stream, args.out, args.decoder, args.frames,
                          reference_idct=not args.fast_idct)
    print("wrote %d reference frames to %s" % (len(names), args.out))
    for name in names:
        print("  %s" % name)
    return 0


def cmd_extract(args):
    meta, width, height, mb_width, mb_height, base_word = resolve_geometry(args, args.dump)
    fsmap = FrameStoreMap(args.memory_map)
    data, base_word = load_words(args.dump, base_word)
    frames = extract_frames(data, base_word, mb_width, mb_height, width, height, fsmap)

    if not os.path.isdir(args.out):
        os.makedirs(args.out)
    for f, planes in sorted(frames.items()):
        write_i420(os.path.join(args.out, "frame%d.yuv" % f),
                   planes["Y"], planes["CR"], planes["CB"])
        if args.pgm:
            for comp, plane in sorted(planes.items()):
                write_pgm(os.path.join(args.out, "frame%d_%s.pgm" % (f, comp)), plane)
        print("frame buffer %d: %dx%d  mean %6.2f  min %3d  max %3d%s"
              % (f, width, height, planes["Y"].mean(),
                 planes["Y"].min(), planes["Y"].max(),
                 "  (blank)" if is_blank(planes["Y"]) else ""))
    print("wrote %s/frame{0..3}.yuv (planar 4:2:0, %dx%d)" % (args.out, width, height))
    return 0


def cmd_compare(args):
    meta, width, height, mb_width, mb_height, base_word = resolve_geometry(args, args.dump)
    fsmap = FrameStoreMap(args.memory_map)
    data, _ = load_words(args.dump, base_word)
    frames = extract_frames(data, base_word, mb_width, mb_height, width, height, fsmap)

    refs = load_reference_frames(args.refdir, args.frames)
    if not refs:
        raise SystemExit("no frame_NN_out_.y.ppm in %s -- run `framecmp.py ref` first"
                         % args.refdir)

    print("dump      %s" % args.dump)
    if meta:
        described = ["source %s" % meta.get("source", "?")]
        if "frame_number" in meta:
            described.append("decoded frame %s" % meta["frame_number"])
        if "frame_picture" in meta:
            described.append("%s picture" % ("frame" if meta["frame_picture"] else "field"))
        if "output_frame" in meta:
            described.append("output_frame %s" % meta["output_frame"])
        if "stream" in meta:
            described.append("stream %s" % meta["stream"])
        print("dump info %s" % ", ".join(described))
    print("geometry  %dx%d (%dx%d macroblocks), memory map %s, base word 0x%x"
          % (width, height, mb_width, mb_height, fsmap.name, base_word))
    print("reference %s (%d frames)" % (args.refdir, len(refs)))
    print("")

    # Chroma naming: mpeg2fpga's COMP_CR holds MPEG-2 block 4 (Cb) and COMP_CB
    # block 5 (Cr), so the plain reading of the names is the swapped one.  Do
    # not trust either: score both assignments on the best-matching buffer and
    # keep whichever is better.
    orders = {"cr-is-cb": {"U": "CR", "V": "CB"},
              "cr-is-cr": {"U": "CB", "V": "CR"}}
    if args.chroma_order != "auto":
        orders = {args.chroma_order: orders[args.chroma_order]}

    failures = []
    chosen_order = None
    print("%-8s  %-22s  %8s  %8s  %6s   %s"
          % ("buffer", "best reference frame", "MAD(Y)", "PSNR(Y)", "peak", "chroma MAD (U/V)"))
    print("-" * 92)

    for f in sorted(frames):
        planes = frames[f]
        if is_blank(planes["Y"]):
            print("%-8d  %-22s" % (f, "(never written)"))
            continue

        best = None
        for name, ref in refs:
            mad, peak, psnr = score(planes["Y"], ref["Y"])
            if best is None or mad < best[1]:
                best = (name, mad, peak, psnr, ref)
        name, mad, peak, psnr, ref = best

        # pick the chroma assignment on this buffer, keeping it stable afterwards
        if chosen_order is None:
            order_scores = {}
            for label, mapping in orders.items():
                u = score(planes[mapping["U"]], ref["U"])[0]
                v = score(planes[mapping["V"]], ref["V"])[0]
                order_scores[label] = u + v
            chosen_order = min(order_scores, key=order_scores.get)
        mapping = orders[chosen_order]
        u_mad = score(planes[mapping["U"]], ref["U"])[0]
        v_mad = score(planes[mapping["V"]], ref["V"])[0]

        print("%-8d  %-22s  %8.3f  %8.2f  %6d   %.3f / %.3f"
              % (f, name, mad, psnr, peak, u_mad, v_mad))
        if args.detail and mad > 0.0:
            print_macroblock_map(planes["Y"], ref["Y"], mb_width, mb_height)
        if mad > args.threshold:
            failures.append((f, name, mad))

    print("")
    if chosen_order:
        print("chroma order: %s (%s)"
              % (chosen_order,
                 "framestore CR plane holds Cb, CB plane holds Cr"
                 if chosen_order == "cr-is-cb" else
                 "framestore plane names match the standard"))
    if failures:
        print("FAIL: %d frame buffer(s) above the MAD threshold of %.3f"
              % (len(failures), args.threshold))
        for f, name, mad in failures:
            print("  buffer %d vs %s: MAD %.3f" % (f, name, mad))
        return 1
    print("OK: every written frame buffer matches a reference frame "
          "within MAD %.3f" % args.threshold)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.split("Usage")[0].strip(),
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")
    sub.required = True

    p = sub.add_parser("cut", help="cut a stream after a whole number of pictures")
    p.add_argument("stream")
    p.add_argument("pictures", type=int)
    p.add_argument("-o", "--out", required=True)
    p.set_defaults(func=cmd_cut)

    p = sub.add_parser("ref", help="decode a stream with tools/mpeg2dec")
    p.add_argument("stream")
    p.add_argument("-o", "--out", default="ref", help="output directory")
    p.add_argument("--decoder", help="path to mpeg2decode")
    p.add_argument("-n", "--frames", type=int, help="keep only the first N frames")
    p.add_argument("--fast-idct", action="store_true",
                   help="let the reference use its own 8-bit IDCT instead of the "
                        "double precision one")
    p.set_defaults(func=cmd_ref)

    def add_dump_args(p):
        p.add_argument("dump", help="raw framestore dump (fs_NNNN.bin, or a DDR dump)")
        p.add_argument("--meta", help="metadata sidecar (default: <dump>.txt)")
        p.add_argument("--geometry", help="WxH, if there is no sidecar")
        p.add_argument("--base-word", type=lambda s: int(s, 0),
                       help="word address the dump starts at (default: from "
                            "sidecar, else 0)")
        p.add_argument("--memory-map", default="MP_AT_HL", choices=sorted(MEMORY_MAPS),
                       help="which mem_codes.v mapping the design was built with")

    p = sub.add_parser("extract", help="write frame buffers as yuv/pgm")
    add_dump_args(p)
    p.add_argument("-o", "--out", default="frames", help="output directory")
    p.add_argument("--pgm", action="store_true", help="also write per-plane pgm")
    p.set_defaults(func=cmd_extract)

    p = sub.add_parser("compare", help="score frame buffers against reference frames")
    add_dump_args(p)
    p.add_argument("refdir", help="directory of frame_NN_out_.*.ppm")
    p.add_argument("-n", "--frames", type=int, help="use only the first N reference frames")
    p.add_argument("-t", "--threshold", type=float, default=1.0,
                   help="MAD above which a buffer counts as wrong (default 1.0; "
                        "the hardware and reference IDCTs are both IEEE 1180 "
                        "compliant but not bit-identical, so an exact 0 is not "
                        "expected)")
    p.add_argument("--chroma-order", default="auto",
                   choices=["auto", "cr-is-cb", "cr-is-cr"])
    p.add_argument("-d", "--detail", action="store_true",
                   help="print a map of which macroblocks differ")
    p.set_defaults(func=cmd_compare)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
