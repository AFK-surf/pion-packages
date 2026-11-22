#!/usr/bin/env python3
"""Join pion / httparse / Go differential outputs; flag rows where Pion disagrees.

usage: compare.py pion.out rust.out go.out [--md out.md]
Framing is compared against Go only (httparse does not compute framing: `OK -`).
"""
import sys


def load(p):
    rows = {}
    for line in open(p, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        rows[parts[0]] = (parts[1], parts[2] if len(parts) > 2 else "")
    return rows


def kind(v):
    return v.split(" ")[0]


args = [a for a in sys.argv[1:] if not a.startswith("--")]
md = sys.argv[sys.argv.index("--md") + 1] if "--md" in sys.argv else None
if md in args:
    args.remove(md)
p, r, g = (load(x) for x in args[:3])
lines = ["| case | pion | httparse | go net/http | note |", "|---|---|---|---|---|"]
nd = 0
for name in p:
    pv, pd = p[name]
    rv, rd = r.get(name, ("?", ""))
    gv, gd = g.get(name, ("?", ""))
    notes = []
    if kind(pv) != kind(gv) or (kind(pv) == "OK" and pv != gv):
        notes.append("≠go")
    if kind(pv) != kind(rv) or (kind(pv) == "OK" and rv != "OK -" and pv != rv):
        notes.append("≠httparse")
    flag = " ".join(notes)
    if flag:
        nd += 1
    lines.append(f"| `{name}` | {pv} {pd} | {rv} {rd} | {gv} {gd} | {flag} |")
    print(f"{name:22s} pion={pv:12s} rust={rv:10s} go={gv:12s} {flag}")
print(f"\n{nd} of {len(p)} cases where Pion disagrees with at least one reference")
if md:
    open(md, "w").write("\n".join(lines) + "\n")
