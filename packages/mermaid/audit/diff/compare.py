#!/usr/bin/env python3
"""Diff `probe parse` (Pion) against `mermaid_ref.mjs` (official mermaid) case by case.

Usage: compare.py ref.tsv pion.tsv [--md out.md]
Exit code: number of divergent cases (capped at 100).
"""
import json
import sys
from collections import Counter


def load(p):
    rows = {}
    order = []
    for ln in open(p, encoding="utf-8"):
        ln = ln.rstrip("\n")
        if not ln:
            continue
        name, status, payload = (ln.split("\t", 2) + ["", ""])[:3]
        rows[name] = (status, payload)
        order.append(name)
    return rows, order


def ms(items):
    return Counter(json.dumps(x, sort_keys=True, ensure_ascii=False) for x in items)


def diff_lists(a, b):
    ca, cb = ms(a), ms(b)
    only_ref = list((ca - cb).elements())
    only_pion = list((cb - ca).elements())
    return only_ref, only_pion


def main():
    ref, order = load(sys.argv[1])
    pion, _ = load(sys.argv[2])
    md = None
    if "--md" in sys.argv:
        md = open(sys.argv[sys.argv.index("--md") + 1], "w", encoding="utf-8")
    counts = Counter()
    lines = []
    for name in order:
        rs, rp = ref[name]
        ps, pp = pion.get(name, ("MISSING", ""))
        if rs == "OK" and ps == "ERR":
            verdict = "PION_REJECTS_VALID"
            detail = "pion: " + pp
        elif rs == "ERR" and ps == "OK":
            verdict = "PION_ACCEPTS_INVALID"
            detail = "mermaid: " + rp[:160]
        elif rs == "ERR" and ps == "ERR":
            verdict = "BOTH_REJECT"
            detail = ""
        else:
            r, p = json.loads(rp), json.loads(pp)
            parts = []
            for key in ("nodes", "edges", "notes"):
                o_ref, o_pion = diff_lists(r.get(key, []), p.get(key, []))
                if o_ref:
                    parts.append(f"{key} only in mermaid: {o_ref}")
                if o_pion:
                    parts.append(f"{key} only in pion: {o_pion}")
            verdict = "MISMATCH" if parts else "MATCH"
            detail = " | ".join(parts)
        counts[verdict] += 1
        lines.append((name, verdict, detail))
    for name, verdict, detail in lines:
        if verdict in ("MATCH", "BOTH_REJECT"):
            print(f"{verdict:22} {name}")
        else:
            print(f"{verdict:22} {name}\n    {detail}")
    print("\nsummary:", dict(counts))
    if md:
        md.write("| case | verdict | detail |\n|---|---|---|\n")
        for name, verdict, detail in lines:
            d = detail.replace("|", "\\|")
            md.write(f"| `{name}` | {verdict} | {d} |\n")
    bad = sum(v for k, v in counts.items() if k not in ("MATCH", "BOTH_REJECT"))
    sys.exit(min(bad, 100))


if __name__ == "__main__":
    main()
