#!/usr/bin/env python3
"""End-to-end release check: decode through mpeg2fpgad with the client library.

What tools/regress cannot see -- it drives the decoder directly -- this checks
through the product as a customer uses it: daemon, protocol, client library.

For each stream: decode it RUNS times; every run must deliver the expected
number of frames, complete, each frame byte-identical to the recorded
baseline (the hardware is deterministic -- tools/regress's determinism suite --
so any difference is a regression, not noise), and the median end-to-end fps
must reach the floor. Correctness against the reference decoder is
tools/regress's job (framecmp); this pins the delivered bytes to a release
that passed it.

    e2e_check.py --host 192.168.18.5 --token-file token [--fps-floor 18]
    e2e_check.py ... --record          # (re)write the baseline from this board

The streams and the baseline are in release/e2e_baseline.json; stream paths
are relative to --streams-root (a hardware_development checkout's
trunk/mpeg2fpga/tools).
"""

import argparse
import hashlib
import json
import os
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, os.pardir, "api", "python", "src"))
import mpeg2fpga  # noqa: E402

BASELINE = os.path.join(HERE, "e2e_baseline.json")
DEFAULT_STREAMS = {
    "tek60": "framecmp/baselines/c069e3b_tek60/stream.bits",
    "tek-5-long": "streams/tek/Tek-5-long/conf4.bit",
}


def run_once(dev, path):
    t0 = time.time()
    result = dev.decode(path)
    hashes = [hashlib.sha1(bytes(f.y) + bytes(f.u) + bytes(f.v)).hexdigest() for f in result]
    seconds = time.time() - t0
    return {"frames": len(hashes), "fps": len(hashes) / seconds, "hashes": hashes,
            "complete": bool(result.summary.complete),
            "decoder_error": bool(result.summary.decoder.error),
            "capture_lag_max": result.summary.get("capture_lag_max")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--token-file", required=True)
    ap.add_argument("--streams-root", required=True)
    ap.add_argument("--fps-floor", type=float, default=18.0)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--record", action="store_true")
    ap.add_argument("--json", help="write the results here")
    args = ap.parse_args()

    dev = mpeg2fpga.Device(args.host, token=open(args.token_file).read().strip(), timeout=60)
    info = dev.info()
    baseline = json.load(open(BASELINE)) if os.path.exists(BASELINE) and not args.record else None
    streams = baseline["streams"] if baseline else DEFAULT_STREAMS
    print("device: bitstream %s, daemon %s, driver %s"
          % (info.versions.bitstream, info.versions.daemon, info.versions.driver))

    results, failures, record = {}, [], {"streams": streams, "frames": {}}
    for name, rel in streams.items():
        path = os.path.join(args.streams_root, rel)
        runs = [run_once(dev, path) for _ in range(args.runs)]
        fps = statistics.median(r["fps"] for r in runs)
        expect = baseline["frames"][name] if baseline else runs[0]["hashes"]
        record["frames"][name] = runs[0]["hashes"]
        problems = []
        for i, r in enumerate(runs):
            if not r["complete"] or r["decoder_error"]:
                problems.append("run %d incomplete or decoder error" % i)
            if r["hashes"] != expect:
                bad = [k for k, (a, b) in enumerate(zip(r["hashes"], expect)) if a != b]
                problems.append("run %d: %d frames (expected %d), %d differ from baseline (first %s)"
                                % (i, r["frames"], len(expect), len(bad), bad[:3]))
        if fps < args.fps_floor:
            problems.append("median %.2f fps below the %.2f floor" % (fps, args.fps_floor))
        results[name] = {"frames": runs[0]["frames"], "fps_median": round(fps, 2),
                         "fps_runs": [round(r["fps"], 2) for r in runs],
                         "capture_lag_max": max(r["capture_lag_max"] or 0 for r in runs),
                         "problems": problems}
        print("%-11s %3d frames  median %.2f fps %s  %s"
              % (name, runs[0]["frames"], fps, results[name]["fps_runs"],
                 "OK" if not problems else "FAIL: " + "; ".join(problems)))
        failures += ["%s: %s" % (name, p) for p in problems]

    if args.record:
        json.dump(record, open(BASELINE, "w"), indent=1)
        print("recorded %s" % BASELINE)
    out = {"device": dict(info.versions), "fps_floor": args.fps_floor, "runs": args.runs,
           "streams": results, "ok": not failures}
    if args.json:
        json.dump(out, open(args.json, "w"), indent=1)
    if failures:
        print("FAIL")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
