#!/usr/bin/env python3
"""Side-by-side geometric defect + quality table: Pion scenes vs dagre re-layout of the same graphs.

Usage: compare_geom.py pion_scenes.tsv dagre_scenes.tsv [--md out.md]
Exit code: number of cases where Pion has strictly more defects than dagre.
"""
import json
import math
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
from geom_check import audit  # noqa: E402


def load(p):
    out = {}
    order = []
    for ln in open(p, encoding="utf-8"):
        ln = ln.rstrip("\n")
        if not ln:
            continue
        name, status, payload = (ln.split("\t", 2) + ["", ""])[:3]
        out[name] = json.loads(payload) if status == "OK" else None
        order.append(name)
    return out, order


def metrics(sc):
    segs = []
    length = 0.0
    for i, e in enumerate(sc["edges"]):
        p = e["pts"]
        for k in range(len(p) - 1):
            segs.append((p[k], p[k + 1], i))
            length += math.dist(p[k], p[k + 1])

    def orient(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

    cross = 0
    for i in range(len(segs)):
        a, b, ei = segs[i]
        for j in range(i + 1, len(segs)):
            c, d, ej = segs[j]
            if ei == ej:
                continue
            o1, o2, o3, o4 = orient(a, b, c), orient(a, b, d), orient(c, d, a), orient(c, d, b)
            if ((o1 > 1e-6 and o2 < -1e-6) or (o1 < -1e-6 and o2 > 1e-6)) and ((o3 > 1e-6 and o4 < -1e-6) or (o3 < -1e-6 and o4 > 1e-6)):
                cross += 1
    return cross, round(length), round(sc["width"] * sc["height"])


def main():
    pion, order = load(sys.argv[1])
    dag, _ = load(sys.argv[2])
    rows = []
    worse = 0
    for name in order:
        p, d = pion.get(name), dag.get(name)
        if p is None or d is None:
            continue
        pa, da = audit(p), audit(d)
        pdef = sum(len(v) for v in pa.values())
        ddef = sum(len(v) for v in da.values())
        pm, dm = metrics(p), metrics(d)
        kinds = ",".join(sorted(k for k, v in pa.items() if v)) or "-"
        if pdef > ddef:
            worse += 1
        rows.append((name, pdef, ddef, kinds, pm, dm))
    hdr = "| case | Pion defects | dagre defects | Pion defect kinds | crossings P/D | edge length P/D | area P/D |"
    lines = [hdr, "|---|---:|---:|---|---|---|---|"]
    for name, pdef, ddef, kinds, pm, dm in rows:
        lines.append(f"| `{name}` | {pdef} | {ddef} | {kinds} | {pm[0]}/{dm[0]} | {pm[1]}/{dm[1]} | {pm[2]}/{dm[2]} |")
    print("\n".join(lines))
    print(f"\ncases where Pion has more geometric defects than dagre: {worse}/{len(rows)}")
    if "--md" in sys.argv:
        with open(sys.argv[sys.argv.index("--md") + 1], "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    sys.exit(min(worse, 100))


if __name__ == "__main__":
    main()
