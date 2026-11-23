#!/usr/bin/env python3
"""Compare Pion vs spec-reference srcset outputs. Usage: compare.py CASES PION REF REPORT [N_HANDPICKED]"""
import sys

cases = open(sys.argv[1]).read().split("\n")[:-1]
pion = open(sys.argv[2]).read().split("\n")[:-1]
ref = open(sys.argv[3]).read().split("\n")[:-1]
assert len(cases) == len(pion) == len(ref), (len(cases), len(pion), len(ref))


def parse(line):
    res = []
    for item in line.split("\t") if line else []:
        u, d = item.split(" ")
        res.append((bytes.fromhex(u).decode("latin1"), d[0], float(d[1:])))
    return res


def same(a, b):
    return len(a) == len(b) and all(
        x[0] == y[0] and x[1] == y[1] and abs(x[2] - y[2]) <= 1e-12 * max(1.0, abs(y[2])) for x, y in zip(a, b))


mism = [(bytes.fromhex(c).decode("latin1"), parse(p), parse(r))
        for c, p, r in zip(cases, pion, ref) if not same(parse(p), parse(r))]
with open(sys.argv[4], "w") as f:
    f.write("%d cases, %d mismatches\n\n" % (len(cases), len(mism)))
    for c, p, r in mism:
        f.write("input %r\n  pion %r\n  spec %r\n\n" % (c, p, r))
print("%d cases, %d mismatches -> %s" % (len(cases), len(mism), sys.argv[4]))
