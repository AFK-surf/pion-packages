#!/usr/bin/env python3
"""Arbitrate value mismatches against an exact reference (Python `fractions` / 120-digit `decimal`).

usage: judge_exact.py <corpus.tsv> <rust.out> <pion.out>

For every line where both sides return a Decimal (or an f64) but the *values* differ, computes the
exact mathematical result and reports which side is closer (in units of the last place of the
result's scale). Covers POWI / POWU / SQRT / DIV / FS / SCI / TOF64.
"""
import collections
import struct
import sys
from decimal import Decimal, getcontext
from fractions import Fraction

getcontext().prec = 120


def dec_hex(h):
    w = [int.from_bytes(bytes.fromhex(h[i:i + 8]), "little") for i in range(0, 32, 8)]
    m = w[1] | (w[2] << 32) | (w[3] << 64)
    sc, neg = (w[0] >> 16) & 0xFF, w[0] >> 31
    return Fraction(-m if neg else m, 10 ** sc)


def out_val(s):
    p = s.split(" ")
    if p[0] == "D":
        h = p[1]
        flags = int(h[:8], 16)
        m = int(h[24:32], 16) << 64 | int(h[16:24], 16) << 32 | int(h[8:16], 16)
        sc = (flags >> 16) & 0xFF
        return Fraction(-m if flags >> 31 else m, 10 ** sc), sc
    if p[0] == "F":
        return Fraction(struct.unpack(">d", bytes.fromhex(p[1]))[0]), None
    return None, None


def exact(f):
    op = f[0]
    try:
        if op == "POWI" or op == "POWU":
            b, e = dec_hex(f[1]), int(f[2])
            if abs(e) > 400 or b == 0:
                return None
            return b ** e
        if op == "SQRT":
            v = dec_hex(f[1])
            return Fraction(Decimal(v.numerator) / Decimal(v.denominator)).limit_denominator(10 ** 60) if v < 0 else \
                Fraction((Decimal(v.numerator) / Decimal(v.denominator)).sqrt())
        if op == "DIV":
            return dec_hex(f[1]) / dec_hex(f[2])
        if op == "TOF64":
            return dec_hex(f[1])
        if op in ("FS", "SCI"):
            s = bytes.fromhex(f[1]).decode().replace("_", "")
            return Fraction(Decimal(s))
    except Exception:
        return None
    return None


def main():
    corpus, rpath, ppath = sys.argv[1:4]
    lines = open(corpus).read().splitlines()
    rs = open(rpath).read().splitlines()
    ps = open(ppath).read().splitlines()
    tally = collections.Counter()
    worst = collections.defaultdict(list)
    for ln, r, p in zip(lines, rs, ps):
        if r == p:
            continue
        f = ln.split("\t")
        rv, rsc = out_val(r)
        pv, psc = out_val(p)
        if rv is None or pv is None or rv == pv:
            continue
        ex = exact(f)
        if ex is None:
            continue
        er, ep = abs(rv - ex), abs(pv - ex)
        if f[0] == "TOF64":
            who = "pion closer" if ep < er else ("rust closer" if er < ep else "tie")
        else:
            ulp = Fraction(1, 10 ** max(rsc, psc))
            who = "pion closer" if ep < er else ("rust closer" if er < ep else "tie")
            worst[(f[0], who)].append((float(max(er, ep) / ulp), ln, r, p, float(er / ulp), float(ep / ulp)))
        tally[(f[0], who)] += 1
        if f[0] == "TOF64":
            worst[(f[0], who)].append((0.0, ln, r, p, float(er), float(ep)))
    print("value mismatches arbitrated against the exact result:")
    for (op, who), n in sorted(tally.items()):
        print(f"  {op:6s} {who:12s} {n}")
    for (op, who), items in sorted(worst.items()):
        items.sort(key=lambda t: -t[0])
        for _, ln, r, p, er, ep in items[:2]:
            print(f"  e.g. [{op} {who}] {ln}\n       rust {r}  (err {er:.3g} ulp)\n       pion {p}  (err {ep:.3g} ulp)")


if __name__ == "__main__":
    main()
