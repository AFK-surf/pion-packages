#!/usr/bin/env python3
"""Condense a run_diff.py mismatch file: per pattern, count mismatching cases and show the
first case's differing fields only (rust vs pion). usage: triage.py <x.mismatch.txt> [max]"""
import sys

path = sys.argv[1]
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 10**9
groups = {}
order = []
for blk in ("\n" + open(path, encoding="utf-8").read()).split("\n== ")[1:]:
    lines = blk.split("\n")
    head = lines[0]
    pat = head.split(": ", 1)[1].split(" hay=")[0]
    rust = dict(l[8:].split("=", 1) for l in lines if l.startswith("   rust ") and "=" in l)
    pion = dict(l[8:].split("=", 1) for l in lines if l.startswith("   pion ") and "=" in l)
    diff = [(k, rust.get(k), pion.get(k)) for k in list(rust) + [k for k in pion if k not in rust]
            if rust.get(k) != pion.get(k)]
    if pat not in groups:
        groups[pat] = [0, head, diff]
        order.append(pat)
    groups[pat][0] += 1
order.sort(key=lambda p: -groups[p][0])
for pat in order[:limit]:
    n, head, diff = groups[pat]
    print(f"[{n}] {head}")
    for k, a, b in diff:
        print(f"     {k}: rust={a!s:.160}\n     {' ' * len(k)}  pion={b!s:.160}")
