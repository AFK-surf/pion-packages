#!/usr/bin/env python3
"""Compare Pion vs Node(fetch) data: URL outputs. Usage: compare.py CASES PION_OUT NODE_OUT REPORT"""
import sys

cases = [l.strip() for l in open(sys.argv[1]) if l.strip()]
pion = open(sys.argv[2]).read().splitlines()
node = open(sys.argv[3]).read().splitlines()
assert len(cases) == len(pion) == len(node), (len(cases), len(pion), len(node))


def show(line):
    p = line.split("\t")
    if p[0] != "OK":
        return "ERR(" + p[1] + ")"
    mime = bytes.fromhex(p[1]).decode("latin1")
    body = bytes.fromhex(p[2]) if len(p) > 2 else b""
    return "OK mime=%r body=%r" % (mime, body)


def norm(line):
    p = line.split("\t")
    return ("ERR",) if p[0] != "OK" else tuple(p[:3] + [""] * (3 - len(p)))


mism = []
for c, a, b in zip(cases, pion, node):
    if norm(a) != norm(b):
        mism.append((bytes.fromhex(c).decode("utf-8"), show(a), show(b)))
with open(sys.argv[4], "w") as f:
    f.write("%d cases, %d mismatches\n\n" % (len(cases), len(mism)))
    for c, a, b in mism:
        f.write("input %r\n  pion %s\n  node %s\n\n" % (c, a, b))
print("%d cases, %d mismatches -> %s" % (len(cases), len(mism), sys.argv[4]))
