#!/usr/bin/env python3
"""Line-by-line comparison of case results for the packages/encoding audit.

  compare.py same <a> <b>                      -> exit 1 if two result files differ (mode consistency)
  compare.py diff <cases> <pion> <oracle> [max] -> print every mismatch class with examples;
                                                 exit 1 on any unexplained (P0) divergence, 3 if only known open ones
"""
import collections
import sys


def lines(p):
    with open(p) as f:
        return f.read().split("\n")[:-1]


def same(a, b):
    la, lb = lines(a), lines(b)
    if la == lb:
        return 0
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            print("    line %d: %s | %s" % (i + 1, x[:120], y[:120]))
            break
    print("    %d vs %d lines" % (len(la), len(lb)))
    return 1


def klass(case):
    p = case.split(" ")
    if p[0] == "D":
        return "D %s %s %s" % (p[1], p[2], p[3] if p[3][0] not in "ke" else p[3][0])
    if p[0] in ("E",):
        return "E %s %s" % (p[1], p[2])
    return p[0] + " " + (p[1] if p[0] == "S" else "")


def known(case):
    """Divergence classes that are open findings (REPORT.md) rather than P0."""
    p = case.split(" ")
    if p[0] == "E" and p[1] == "ISO-2022-JP" and p[2] == "h":
        s = bytes.fromhex(p[3]).decode() if p[3] != "-" else ""
        if "\u00a5" in s or "\u203e" in s:
            return "P2-1"
    return None


def diff(cases, pion, oracle, mx):
    c, a, b = lines(cases), lines(pion), lines(oracle)
    if not (len(c) == len(a) == len(b)):
        print("    LENGTH MISMATCH cases=%d pion=%d oracle=%d" % (len(c), len(a), len(b)))
        return 1
    bad = collections.OrderedDict()
    for i in range(len(c)):
        if a[i] != b[i]:
            k = known(c[i])
            bad.setdefault((k or "P0") + " " + klass(c[i]), []).append(i)
    total = sum(len(v) for v in bad.values())
    print("    %d/%d cases identical, %d divergent" % (len(c) - total, len(c), total))
    for k, idx in bad.items():
        print("    DIVERGE [%s] x%d" % (k, len(idx)))
        for i in idx[:mx]:
            print("      case:   %s" % c[i][:160])
            print("      pion:   %s" % a[i][:160])
            print("      oracle: %s" % b[i][:160])
    p0 = sum(len(v) for k, v in bad.items() if k.startswith("P0"))
    if p0:
        return 1
    return 3 if total else 0


if __name__ == "__main__":
    if sys.argv[1] == "same":
        sys.exit(same(sys.argv[2], sys.argv[3]))
    sys.exit(diff(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]) if len(sys.argv) > 5 else 3))
