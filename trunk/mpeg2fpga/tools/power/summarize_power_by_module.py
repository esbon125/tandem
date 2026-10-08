#!/usr/bin/env python3
"""Roll a SmartPower per-instance CSV report up into per-module totals.

SmartPower's instance breakdown lists leaf cells and nets by their full
hierarchical path; this sums them by path prefix so each RTL module gets
one number.

usage: summarize_power_by_module.py REPORT.csv [PREFIX] [--depth N]

PREFIX restricts the rollup to one subtree (e.g. the decoder,
FIC_3_PERIPHERALS_0/MPEG2FPGA_APB_PERIPHERAL_0/u_mpeg2) and groups by the
next N path components below it (default 1).
"""
import argparse
import csv
from collections import defaultdict


def read_instances(path):
    with open(path, newline="") as f:
        rows = list(csv.reader(f))
    start = next(i for i, r in enumerate(rows) if r and r[0] == "Breakdown by Instance")
    for r in rows[start + 2:]:
        if len(r) < 3 or not r[0]:
            break
        yield r[0], r[1], float(r[2])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("prefix", nargs="?", default="")
    ap.add_argument("--depth", type=int, default=1)
    args = ap.parse_args()

    prefix = args.prefix.rstrip("/")
    total = 0.0
    groups = defaultdict(lambda: defaultdict(float))
    for name, kind, mw in read_instances(args.report):
        total += mw
        if prefix:
            if not name.startswith(prefix + "/"):
                continue
            rest = name[len(prefix) + 1:]
        else:
            rest = name
        parts = rest.split("/")
        key = "/".join(parts[:args.depth]) if len(parts) > args.depth else "(leaf cells)"
        groups[key][kind] += mw

    sub = sum(sum(k.values()) for k in groups.values())
    kinds = sorted({k for g in groups.values() for k in g})
    print(f"design total: {total:9.3f} mW")
    print(f"{prefix or '(top)'}: {sub:9.3f} mW ({100 * sub / total:.1f}% of design)\n")
    print(f"{'module':<60} {'mW':>9} {'%':>6}  " + "  ".join(f"{k:>7}" for k in kinds))
    for key, by_kind in sorted(groups.items(), key=lambda kv: -sum(kv[1].values())):
        mw = sum(by_kind.values())
        print(f"{key:<60} {mw:9.3f} {100 * mw / sub:6.1f}  "
              + "  ".join(f"{by_kind.get(k, 0):7.3f}" for k in kinds))


if __name__ == "__main__":
    main()
