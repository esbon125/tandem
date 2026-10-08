#!/usr/bin/env python3
"""
regress -- hardware regression, robustness and decode-rate benchmarks.

Runs the decoder on the PolarFire board from the host, over ssh, and scores
what comes out with tools/framecmp. Four suites, each usable on its own:

  conformance  every stream in streams.txt, cut to a few pictures, pushed
               through webserver/capture_framestore.py and scored against
               tools/mpeg2dec; then checked against baseline.json, so a
               stream that was already off (the upstream prediction drift,
               plan item 1) does not fail, but one that *changes* does.
  determinism  the same stream K times, with and without a core reset in
               between; every dump in a mode must hash identically.
  robustness   damaged input (truncated mid-picture, bit flips in slice data,
               random bytes) and, after each, a clean stream switched in with
               flush_vbuf only -- no reset. The clean stream must still decode
               bit exact: that is the claim "a bad stream does not wedge the
               decoder".
  perf         webserver/bench_decode.py: whole streams decoded N times
               through the same path as server.py's /decode, fps and pixel
               rate per stream.

Usage
-----
  regress.py all                      # everything, ~15 min
  regress.py conformance [--only tek-5.2 ...] [--record]
  regress.py determinism | robustness | perf [--reps N]

Each run writes runs/<timestamp>-<rev>/results.json and report.md. --record
rewrites baseline.json from the conformance results of this run; do that only
after a run you have looked at and agree with.

Exit status is 1 if any suite found a regression.

Prerequisites: tools/mpeg2dec built (`make` there), the conformance streams
(tools/streams/retrieve), the board reachable as $REGRESS_BOARD (default
root@192.168.18.5) with webserver/ from firmware_development in
/root/webserver and either overlay applied.
"""

from __future__ import print_function

import argparse
import datetime
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)
FRAMECMP = os.path.join(TOOLS, "framecmp", "framecmp.py")
sys.path.insert(0, os.path.join(TOOLS, "framecmp"))
import framecmp  # noqa: E402

BOARD = os.environ.get("REGRESS_BOARD", "root@192.168.18.5")
BOARD_DIR = "/root/webserver"
BOARD_TMP = "/tmp/regress"
WORK = os.path.join(HERE, "work")            # cut streams and reference frames, cached
BASELINE = os.path.join(HERE, "baseline.json")

# A stream whose dump hashes like the baseline's is the same picture bit for
# bit. One that does not is scored: a buffer may drift by this much from its
# baseline MAD before it counts as a regression. The hardware is deterministic
# (see the determinism suite), so in practice this only absorbs a different
# buffer rotation, not noise.
MAD_TOLERANCE = 0.05

# The recovery probe for the robustness suite: bit exact on hardware, small,
# frame pictures only, so "still decodes correctly" has no slack in it.
PROBE = "mcp10ccett"


# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------

def sh(cmd, check=True, timeout=300):
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          timeout=timeout)
    out = proc.stdout.decode("utf-8", "replace")
    if check and proc.returncode != 0:
        raise RuntimeError("%s failed (%d):\n%s" % (" ".join(cmd), proc.returncode, out[-2000:]))
    return proc.returncode, out


def ssh(command, timeout=300):
    return sh(["ssh", "-o", "BatchMode=yes", BOARD, command], check=False, timeout=timeout)


def scp_to(local, remote):
    sh(["scp", "-q", local, "%s:%s" % (BOARD, remote)])


def scp_from(remote, local):
    sh(["scp", "-q", "%s:%s" % (BOARD, remote), local])


def result_lines(out, tag="RESULT"):
    return [json.loads(line[len(tag) + 1:]) for line in out.splitlines()
            if line.startswith(tag + " ")]


def sha1_file(path):
    h = hashlib.sha1()
    with open(path, "rb") as fp:
        for chunk in iter(lambda: fp.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def picture_digest(dump):
    """Hash of the decoded pictures, independent of which buffer holds which.

    The raw dump's sha1 is not stable across stream switches: after
    flush_vbuf the next stream starts in whichever buffer the rotation is up
    to, so the same four pictures land in a different order (seen as two
    alternating hashes in the first run of this suite). Hashing each buffer's
    planes and sorting the hashes is what "decoded the same pictures" means.
    Buffers still holding the poison pattern are left out.
    """
    meta = framecmp.read_metadata(dump[:-4] + ".txt")
    width, height = meta["horizontal_size"], meta["vertical_size"]
    data, base = framecmp.load_words(dump, meta.get("base_word_address", 0))
    frames = framecmp.extract_frames(data, base, meta["mb_width"], meta["mb_height"],
                                     width, height, framecmp.FrameStoreMap())
    hashes = sorted(hashlib.sha1(b"".join(p[c].tobytes() for c in ("Y", "CR", "CB"))).hexdigest()
                    for p in frames.values() if not framecmp.is_blank(p["Y"]))
    return hashlib.sha1("".join(hashes).encode()).hexdigest()


def count_pictures(data):
    n, at = 0, data.find(b"\x00\x00\x01\x00")
    while at >= 0:
        n += 1
        at = data.find(b"\x00\x00\x01\x00", at + 1)
    return n


def load_manifest(path):
    streams = []
    for line in open(path):
        line = line.split("#", 1)[0].split()
        if not line:
            continue
        name, rel = line[0], line[1]
        pictures = int(line[2]) if len(line) > 2 else 8
        streams.append({"name": name, "path": os.path.join(TOOLS, "streams", rel),
                        "pictures": pictures})
    return streams


def prepare(stream):
    """Cut a stream and decode it with the reference; cached under work/."""
    src = open(stream["path"], "rb").read()
    key = "%s-%s-%d" % (stream["name"], hashlib.sha1(src).hexdigest()[:8], stream["pictures"])
    cut = os.path.join(WORK, key + ".bits")
    ref = os.path.join(WORK, key + ".ref")
    pictures = min(stream["pictures"], count_pictures(src))
    if not os.path.exists(cut):
        framecmp.cut_stream(stream["path"], pictures, cut)
    if not os.path.isdir(ref):
        tmp = ref + ".tmp"
        shutil.rmtree(tmp, ignore_errors=True)
        try:
            framecmp.run_reference(cut, tmp)
        except SystemExit as exc:
            shutil.rmtree(tmp, ignore_errors=True)
            return cut, None, pictures, str(exc)
        os.rename(tmp, ref)
    return cut, ref, pictures, None


def capture(local_stream, outdir, tag, no_reset=False):
    """Push a stream on the board, bring the framestore dump back. Returns the RESULT dict."""
    remote_stream = "%s/%s" % (BOARD_TMP, os.path.basename(local_stream))
    scp_to(local_stream, remote_stream)
    remote_bin = "%s/%s.bin" % (BOARD_TMP, tag)
    rc, out = ssh("cd %s && python3 capture_framestore.py %s -o %s --json%s"
                  % (BOARD_DIR, remote_stream, remote_bin, " --no-reset" if no_reset else ""),
                  timeout=120)
    results = result_lines(out)
    result = results[-1] if results else {"exception": out[-1500:]}
    result["exit"] = rc
    if result.get("dump"):
        local_bin = os.path.join(outdir, tag + ".bin")
        scp_from(remote_bin, local_bin)
        scp_from(remote_bin[:-4] + ".txt", local_bin[:-4] + ".txt")
        ssh("rm -f %s %s" % (remote_bin, remote_bin[:-4] + ".txt"))
        result["local_dump"] = local_bin
    return result


def compare(dump, ref):
    js = dump[:-4] + ".cmp.json"
    sh([sys.executable, FRAMECMP, "compare", dump, ref, "--json", js], check=False)
    return json.load(open(js)) if os.path.exists(js) else None


def classify(scores):
    """Absolute verdict against the reference, independent of any baseline."""
    written = [b for b in scores["buffers"] if b["written"]]
    if not written:
        return "nothing-written"
    worst = max(b["mad"] for b in written)
    peak = max(b["peak"] for b in written)
    if worst == 0.0:
        return "bit-exact"
    if worst < 0.02 and peak <= 1:
        return "idct-slack"
    if worst <= 1.0:
        return "close"
    return "drift"


# ---------------------------------------------------------------------------
# suites
# ---------------------------------------------------------------------------

def suite_conformance(args, rundir):
    streams = load_manifest(args.manifest)
    if args.only:
        streams = [s for s in streams if s["name"] in args.only]
    baseline = json.load(open(BASELINE)) if os.path.exists(BASELINE) else {}
    rows = []
    for s in streams:
        t0 = time.time()
        row = {"name": s["name"]}
        try:
            cut, ref, pictures, ref_error = prepare(s)
            row["pictures"] = pictures
            if ref_error:
                row.update(verdict="no-reference", note=ref_error)
            else:
                cap = capture(cut, rundir, s["name"])
                row["capture"] = {k: cap.get(k) for k in (
                    "width", "height", "settled", "settle_seconds", "dma_seconds",
                    "sticky", "error", "watchdog", "sha1", "exception")}
                if not cap.get("local_dump"):
                    row["verdict"] = "no-decode"
                else:
                    scores = compare(cap["local_dump"], ref)
                    row["scores"] = scores["buffers"]
                    row["capture"]["pictures_sha1"] = picture_digest(cap["local_dump"])
                    row["verdict"] = classify(scores)
                    if not args.keep_dumps:
                        os.remove(cap["local_dump"])
        except Exception as exc:                # noqa: BLE001 - record it, keep going
            row.update(verdict="harness-error", note=repr(exc)[-1500:])
        row["against_baseline"] = against_baseline(row, baseline.get(s["name"]))
        row["seconds"] = round(time.time() - t0, 1)
        print("  %-22s %-14s %-12s %5.1fs" % (s["name"], row["verdict"],
                                              row["against_baseline"], row["seconds"]))
        sys.stdout.flush()
        rows.append(row)
    if args.record:
        json.dump({r["name"]: {k: r.get(k) for k in ("verdict", "pictures", "capture", "scores")}
                   for r in rows}, open(BASELINE, "w"), indent=1, sort_keys=True)
        print("  recorded %s" % BASELINE)
    return {"rows": rows,
            "regressions": [r["name"] for r in rows if r["against_baseline"] == "REGRESSION"]}


def against_baseline(row, base):
    if base is None:
        return "new"
    if row["verdict"] == "harness-error":
        return "harness-error"
    if base.get("scores") is None:
        return "IMPROVED" if row.get("scores") else "same"
    if row.get("scores") is None:
        return "REGRESSION"
    sha = (row.get("capture") or {}).get("pictures_sha1")
    base_sha = (base.get("capture") or {}).get("pictures_sha1")
    if sha and sha == base_sha:
        return "identical"
    now = sorted(b["mad"] for b in row["scores"] if b["written"])
    was = sorted(b["mad"] for b in base["scores"] if b["written"])
    if len(now) < len(was):
        return "REGRESSION"
    if any(n > w + MAD_TOLERANCE for n, w in zip(now, was)):
        return "REGRESSION"
    if any(n < w - MAD_TOLERANCE for n, w in zip(now, was)):
        return "IMPROVED"
    return "within-tolerance"


def suite_determinism(args, rundir):
    probe = [s for s in load_manifest(args.manifest) if s["name"] == args.det_stream][0]
    cut, ref, _, _ = prepare(probe)
    out = {"stream": probe["name"], "runs": args.det_runs, "modes": {}}
    all_hashes = []
    for mode, no_reset in (("reset", False), ("flush_vbuf", True)):
        hashes = []
        for i in range(args.det_runs):
            cap = capture(cut, rundir, "det-%s-%d" % (mode, i), no_reset=no_reset)
            digest = None
            if cap.get("local_dump"):
                digest = picture_digest(cap["local_dump"])
                os.remove(cap["local_dump"])
            hashes.append(digest)
        out["modes"][mode] = {"hashes": hashes, "distinct": len(set(hashes)),
                              "ok": len(set(hashes)) == 1 and hashes[0] is not None}
        all_hashes += hashes
        print("  %-10s %d runs, %d distinct picture hash(es)" % (mode, len(hashes), len(set(hashes))))
    # and both ways of starting a stream must decode the same pictures
    out["same_across_modes"] = len(set(all_hashes)) == 1
    print("  same pictures with and without reset: %s" % out["same_across_modes"])
    if not out["same_across_modes"]:
        out["modes"]["across"] = {"hashes": [], "distinct": len(set(all_hashes)), "ok": False}
    out["regressions"] = [m for m, r in out["modes"].items() if not r["ok"]]
    return out


def damaged_streams(clean, outdir):
    """Three kinds of bad input, deterministic (fixed seed) so runs compare."""
    data = open(clean, "rb").read()
    rng = random.Random(1180)
    cases = {}

    # 1. cut in the middle of a picture's slice data, with no sequence end:
    #    the decoder is left waiting for bytes that never come.
    cases["truncated"] = data[:int(len(data) * 0.6)]

    # 2. bit flips in slice data only -- headers intact, so the decoder
    #    locks on and then meets garbage VLC codes and impossible motion.
    first_slice = data.find(b"\x00\x00\x01\x01")
    flipped = bytearray(data)
    for _ in range(200):
        at = rng.randrange(first_slice + 4, len(data) - 4)
        flipped[at] ^= 1 << rng.randrange(8)
    cases["bitflips"] = bytes(flipped)

    # 3. no MPEG at all.
    cases["random"] = bytes(rng.randrange(256) for _ in range(256 * 1024))

    paths = {}
    for name, blob in cases.items():
        paths[name] = os.path.join(outdir, "damaged-%s.bits" % name)
        open(paths[name], "wb").write(blob)
    return paths


def suite_robustness(args, rundir):
    probe = [s for s in load_manifest(args.manifest) if s["name"] == PROBE][0]
    clean, ref, _, _ = prepare(probe)
    cases = []
    # start from a known-good decode, with a reset, so the first case does not
    # inherit whatever the previous suite left behind
    capture(clean, rundir, "rob-start")
    for name, path in sorted(damaged_streams(clean, rundir).items()):
        bad = capture(path, rundir, "rob-%s" % name, no_reset=True)
        if bad.get("local_dump"):
            os.remove(bad["local_dump"])
        good = capture(clean, rundir, "rob-%s-recover" % name, no_reset=True)
        verdict = None
        if good.get("local_dump"):
            verdict = classify(compare(good["local_dump"], ref))
            os.remove(good["local_dump"])
        case = {"case": name,
                "damaged": {k: bad.get(k) for k in ("settled", "settle_seconds", "error",
                                                    "watchdog", "sticky", "width", "height",
                                                    "exit", "exception")},
                "recovery_without_reset": verdict,
                "ok": verdict == "bit-exact"}
        print("  %-10s error=%s watchdog=%s settled=%s -> clean stream after flush_vbuf: %s"
              % (name, bad.get("error"), bad.get("watchdog"), bad.get("settled"), verdict))
        cases.append(case)
    return {"probe": PROBE, "cases": cases,
            "regressions": [c["case"] for c in cases if not c["ok"]]}


def suite_perf(args, rundir):
    streams = {s["name"]: s for s in load_manifest(args.manifest)}
    rows = []
    for name in args.perf_streams:
        s = streams[name]
        remote = "%s/perf-%s.bits" % (BOARD_TMP, name)
        scp_to(s["path"], remote)
        rc, out = ssh("cd %s && python3 bench_decode.py %s --reps %d --json"
                      % (BOARD_DIR, remote, args.reps), timeout=120 + 150 * args.reps)
        summary = result_lines(out, "SUMMARY")
        if not summary:
            rows.append({"name": name, "error": out[-1500:]})
            print("  %-22s FAILED" % name)
            continue
        row = dict(summary[0], name=name, runs=result_lines(out))
        w, h = row["width"], row["height"]
        row["mpix_per_s"] = round(row["fps_mean"] * w * h / 1e6, 2)
        row["realtime_ratio"] = round(row["fps_mean"] / row["frame_rate"], 2) if row["frame_rate"] else None
        print("  %-16s %4dx%-4d %4d frames  %6.2f fps (sd %.2f)  %5.2f Mpix/s  x%.2f real time%s"
              % (name, w, h, row["frames"], row["fps_mean"], row["fps_stdev"], row["mpix_per_s"],
                 row["realtime_ratio"] or 0, "  (%d failed)" % row["failed"] if row["failed"] else ""))
        sys.stdout.flush()
        rows.append(row)
    return {"reps": args.reps, "rows": rows,
            "regressions": [r["name"] for r in rows if r.get("error") or r.get("failed")]}


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

def write_report(rundir, meta, results):
    lines = ["# Regression run %s" % meta["started"], "",
             "- commit: `%s`%s" % (meta["rev"], " (dirty)" if meta["dirty"] else ""),
             "- board: `%s`, backend `%s`" % (BOARD, meta.get("backend", "?")),
             "- duration: %.0f s" % meta["seconds"], ""]
    c = results.get("conformance")
    if c:
        lines += ["## Conformance (cut streams vs tools/mpeg2dec)", "",
                  "| stream | pictures | size | verdict | vs baseline | worst MAD(Y) | peak | error | watchdog |",
                  "|---|---|---|---|---|---|---|---|---|"]
        for r in c["rows"]:
            cap = r.get("capture") or {}
            written = [b for b in (r.get("scores") or []) if b["written"]]
            lines.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                r["name"], r.get("pictures", ""),
                "%sx%s" % (cap.get("width"), cap.get("height")) if cap else "",
                r["verdict"], r["against_baseline"],
                "%.3f" % max(b["mad"] for b in written) if written else "",
                max(b["peak"] for b in written) if written else "",
                cap.get("error", ""), cap.get("watchdog", "")))
        counts = {}
        for r in c["rows"]:
            counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
        lines += ["", "Verdicts: " + ", ".join("%s %d" % kv for kv in sorted(counts.items())), ""]
    d = results.get("determinism")
    if d:
        lines += ["## Determinism (%s, %d runs per mode)" % (d["stream"], d["runs"]), ""]
        for mode, r in d["modes"].items():
            lines.append("- %s: %d distinct picture hash(es) -> %s"
                         % (mode, r["distinct"], "OK" if r["ok"] else "FAIL"))
        lines.append("")
    rb = results.get("robustness")
    if rb:
        lines += ["## Robustness (damaged stream, then %s via flush_vbuf, no reset)" % rb["probe"], "",
                  "| case | error | watchdog | settled | recovery without reset |", "|---|---|---|---|---|"]
        for cse in rb["cases"]:
            dmg = cse["damaged"]
            lines.append("| %s | %s | %s | %s | %s |" % (cse["case"], dmg.get("error"),
                         dmg.get("watchdog"), dmg.get("settled"), cse["recovery_without_reset"]))
        lines.append("")
    p = results.get("perf")
    if p:
        lines += ["## Decode rate (%d timed runs per stream, after a warm-up)" % p["reps"], "",
                  "Decode time is DMA start to the last framestore write (webserver/bench_decode.py).", "",
                  "| stream | size | frames | fps mean | sd | min | max | Mpix/s | x real time |",
                  "|---|---|---|---|---|---|---|---|---|"]
        for r in p["rows"]:
            if r.get("error"):
                lines.append("| %s | failed | | | | | | | |" % r["name"])
                continue
            lines.append("| %s | %dx%d | %d | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f |" % (
                r["name"], r["width"], r["height"], r["frames"],
                r["fps_mean"], r["fps_stdev"], r["fps_min"], r["fps_max"],
                r["mpix_per_s"], r["realtime_ratio"] or 0))
        lines.append("")
    regressions = {k: v["regressions"] for k, v in results.items() if v.get("regressions")}
    lines += ["## Result", "", "REGRESSIONS: %s" % json.dumps(regressions) if regressions
              else "No regressions.", ""]
    open(os.path.join(rundir, "report.md"), "w").write("\n".join(lines))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("suite", choices=["all", "conformance", "determinism", "robustness", "perf"])
    ap.add_argument("--manifest", default=os.path.join(HERE, "streams.txt"))
    ap.add_argument("--only", nargs="+", help="conformance: just these stream names")
    ap.add_argument("--record", action="store_true", help="conformance: rewrite baseline.json")
    ap.add_argument("--keep-dumps", action="store_true", help="keep the 12 MiB framestore dumps")
    ap.add_argument("--det-stream", default="tek-5.2")
    ap.add_argument("--det-runs", type=int, default=5)
    ap.add_argument("--reps", type=int, default=5, help="perf: timed runs per stream")
    ap.add_argument("--perf-streams", nargs="+",
                    default=["tek60", "tek-5-long", "mei-2-60f", "nokia6-60", "tcela-7",
                             "hhi-burst-long", "sony-ct2", "att-mismatch"])
    args = ap.parse_args(argv)

    for d in (WORK,):
        if not os.path.isdir(d):
            os.makedirs(d)
    rev = sh(["git", "-C", HERE, "rev-parse", "--short", "HEAD"])[1].strip()
    dirty = bool(sh(["git", "-C", HERE, "status", "--porcelain", "--", TOOLS + "/.."])[1].strip())
    started = datetime.datetime.now()
    rundir = os.path.join(HERE, "runs", started.strftime("%Y%m%d-%H%M%S") + "-" + rev)
    os.makedirs(rundir)
    ssh("mkdir -p %s" % BOARD_TMP)
    rc, out = ssh("cd %s && python3 -c 'import decoder_control as d; c=d.open_control(); print(c.backend)'"
                  % BOARD_DIR, timeout=30)
    meta = {"started": started.isoformat(timespec="seconds"), "rev": rev, "dirty": dirty,
            "board": BOARD, "backend": out.strip().splitlines()[-1] if rc == 0 else "unreachable"}
    if rc != 0:
        raise SystemExit("board %s not reachable or webserver/ missing:\n%s" % (BOARD, out))
    print("run %s on %s (%s)" % (os.path.basename(rundir), BOARD, meta["backend"]))

    suites = [args.suite] if args.suite != "all" else ["conformance", "determinism", "robustness", "perf"]
    results = {}
    t0 = time.time()
    for name in suites:
        print("[%s]" % name)
        results[name] = globals()["suite_" + name](args, rundir)
    meta["seconds"] = time.time() - t0
    json.dump({"meta": meta, "results": results}, open(os.path.join(rundir, "results.json"), "w"),
              indent=1, sort_keys=True)
    write_report(rundir, meta, results)
    print("wrote %s" % os.path.join(rundir, "report.md"))
    failed = any(r.get("regressions") for r in results.values())
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
