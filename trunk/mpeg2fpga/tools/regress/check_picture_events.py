#!/usr/bin/env python3
"""
Check webserver/picture_events.py's capture against the reference decoder.

The picture-ready interrupt claims two things: one event per finished
picture, and events in display order. Both are checked here, with the
reference decoder as the judge rather than our own expectations: every
captured picture is scored against every reference frame, and the i-th
event must best-match reference frame i (frame_NN_out_ is display order).

It also catches a third thing the RTL review could not settle: whether the
picture is completely written when the interrupt fires. motcomp_picbuf hands
a frame to the display as soon as the next picture's update token reaches
motion compensation, which may be a few macroblock writes before the last of
them lands in DRAM. A torn read shows up as a large error confined to the
bottom macroblock rows, reported per event as bottom_mad.

    check_picture_events.py CAPTURE_PREFIX STREAM [--ref REFDIR]

CAPTURE_PREFIX is picture_events.py's -o (CAPTURE_PREFIX.bin/.json, copied
back from the board).
"""

import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, os.pardir, "framecmp"))
import framecmp  # noqa: E402


def native_plane(raw, width, height):
    """Framestore bytes -> uint8 image: undo the per-word byte reversal and
    the -128 offset (see framecmp.extract_plane), then crop the macroblock
    stride."""
    stride = ((width + 15) // 16) * 16 if len(raw) > 0 else 0
    rows = len(raw) // stride
    a = np.frombuffer(raw, dtype=np.uint8).reshape(rows, stride // 8, 8)[:, :, ::-1]
    return (a.reshape(rows, stride) ^ 0x80)[:height, :width]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("stream")
    ap.add_argument("--ref", help="reference frames dir (default: decode STREAM into CAPTURE.ref)")
    ap.add_argument("--max-mad", type=float, default=2.0,
                    help="best-match MAD(Y) above this counts as a wrong picture")
    args = ap.parse_args()

    meta = json.load(open(args.capture + ".json"))
    summary, events = meta["summary"], meta["events"]
    w, h = summary["width"], summary["height"]
    ref = args.ref or args.capture + ".ref"
    if not os.path.isdir(ref):
        framecmp.run_reference(args.stream, ref)
    refs = framecmp.load_reference_frames(ref)

    blob = open(args.capture + ".bin", "rb").read()
    at = 0
    bad = []
    bottom_rows = 32
    rows_out = []
    for i, ev in enumerate(events):
        ysz, csz, _ = ev["plane_bytes"]
        y = native_plane(blob[at:at + ysz], w, h)
        at += sum(ev["plane_bytes"])
        scores = [framecmp.score(y, r["Y"])[0] for _, r in refs]
        best = int(np.argmin(scores))
        mad = scores[best]
        expected = refs[i][1]["Y"] if i < len(refs) else None
        bottom = (float(np.abs(y[-bottom_rows:].astype(int) - expected[-bottom_rows:].astype(int)).mean())
                  if expected is not None else None)
        ok = best == i and mad <= args.max_mad
        if not ok:
            bad.append(i)
        rows_out.append((i, ev["frame"], ev["hw_count"], ev["flags"], best, mad, bottom, ok))

    print("%-5s %-6s %-8s %-6s %-10s %-9s %-11s" %
          ("event", "buffer", "hw_count", "flags", "best_ref", "MAD(Y)", "bottom_mad"))
    for i, frame, cnt, flags, best, mad, bottom, ok in rows_out:
        print("%-5d %-6d %-8d %-6d %-10d %-9.3f %-11s%s" %
              (i, frame, cnt, flags, best, mad,
               "-" if bottom is None else "%.3f" % bottom, "" if ok else "  <-- WRONG"))
    print()
    print("summary: %s" % json.dumps(summary, sort_keys=True))
    print("reference frames: %d, events: %d" % (len(refs), len(events)))
    problems = []
    if len(events) != len(refs):
        problems.append("event count %d != reference frame count %d" % (len(events), len(refs)))
    if summary["hw_count_gaps"] or summary["overrun"] or summary["lost"]:
        problems.append("missed pictures (gaps/overrun/lost)")
    if bad:
        problems.append("%d event(s) not matching display-order reference: %s" % (len(bad), bad[:10]))
    if problems:
        print("FAIL: " + "; ".join(problems))
        return 1
    print("OK: one event per picture, in display order, each matching its reference frame")
    return 0


if __name__ == "__main__":
    sys.exit(main())
