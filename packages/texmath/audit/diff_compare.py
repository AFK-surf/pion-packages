#!/usr/bin/env python3
"""Compare `OK <mathml>` / `ERR <msg>` streams from KaTeX and Pion texmath line by line.

usage: diff_compare.py <cases.txt> <katex.out> <pion.out> [--show N]
Exit status 1 when any case diverges.
"""
import sys
from collections import Counter

cases_path, katex_path, pion_path = sys.argv[1:4]
show = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 1000000
cases = [l for l in open(cases_path, encoding="utf-8").read().split("\n") if len(l) >= 2]
kat = open(katex_path, encoding="utf-8", errors="replace").read().split("\n")
pio = open(pion_path, encoding="utf-8", errors="replace").read().split("\n")
count = Counter()
shown = 0
for i, case in enumerate(cases):
    k = kat[i] if i < len(kat) else "<missing>"
    p = pio[i] if i < len(pio) else "<missing: pion crashed/aborted before this line>"
    if k == p:
        count["identical"] += 1
        continue
    if p.startswith("ERR") and k.startswith("OK"):
        kind = "PION_REJECTS_VALID"
    elif p.startswith("OK") and k.startswith("ERR"):
        kind = "PION_ACCEPTS_INVALID"
    elif p.startswith("ERR") and k.startswith("ERR"):
        kind = "error_message_differs"
    elif p.startswith("<missing"):
        kind = "PION_CRASH"
    else:
        kind = "MATHML_DIFFERS"
    count[kind] += 1
    if shown < show:
        shown += 1
        print(f"--- [{kind}] #{i}: {case}")
        print(f"  katex: {k[:400]}")
        print(f"  pion : {p[:400]}")
print("SUMMARY", dict(count), "total", len(cases))
sys.exit(0 if len(count) == 1 and "identical" in count else 1)
