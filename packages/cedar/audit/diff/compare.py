#!/usr/bin/env python3
"""Compare a Pion transcript against the cedar-policy =4.15.0 transcript.

usage: compare.py <rust.txt> <pion.txt> [--label L] [--details OUT]
Exit 0 iff every case agrees, except where Pion fails CLOSED (PERR/EERR/RERR) on a case the
corpus marks tolerant (`gap.*` documented scope gaps, `lim.*` documented CedarLimits, `tol.*`
reference-is-laxer, `*.depth_*` parse-time depth rejection): those are reported, not gated.
"""
import sys


def load(p):
    lines = open(p, encoding="utf-8").read().split("\n")
    d, order = {}, []
    for i in range(0, len(lines) - 1, 2):
        assert lines[i].startswith("## "), (p, i, lines[i])
        k = lines[i][3:]
        d[k] = lines[i + 1]
        order.append(k)
    return d, order


def main():
    args = sys.argv[1:]
    label, details = "diff", None
    if "--label" in args:
        j = args.index("--label"); label = args[j + 1]; del args[j:j + 2]
    if "--details" in args:
        j = args.index("--details"); details = args[j + 1]; del args[j:j + 2]
    r, order = load(args[0])
    p, _ = load(args[1])
    bad, gaps = [], []
    for k in order:
        if p.get(k) == r[k]:
            continue
        tolerant = k.startswith(("gap.", "lim.", "tol.")) or ".depth_" in k
        if tolerant and p.get(k) in ("PERR", "EERR", "RERR"):
            gaps.append(k)
        else:
            bad.append(k)
    groups = {}
    for k in bad:
        g = ".".join(k.split(".")[:2])
        groups.setdefault(g, []).append(k)
    print("  %-10s %d cases: %d agree, %d MISMATCH, %d tolerated fail-closed gaps"
          % (label, len(order), len(order) - len(bad) - len(gaps), len(bad), len(gaps)))
    for g, ks in sorted(groups.items()):
        k = ks[0]
        print("    %-26s %3d  e.g. %s: rust=%s | pion=%s" % (g, len(ks), k, r[k], p.get(k)))
    if details:
        with open(details, "w", encoding="utf-8") as f:
            for k in bad:
                f.write("MISMATCH %s\trust=%s\tpion=%s\n" % (k, r[k], p.get(k)))
            for k in gaps:
                f.write("GAP %s\trust=%s\tpion=%s\n" % (k, r[k], p.get(k)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
