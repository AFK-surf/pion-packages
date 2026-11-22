#!/usr/bin/env python3
"""Three-way differential report: Pion `packages/time` vs Rust jiff (reference) vs Go stdlib.

usage: diff.py <jiff.tsv> <pion.tsv> <go.tsv> [--md out.md]
Each TSV row is `kind\\tinput\\tRESULT`. RESULT may be `canon || display`; a difference only in
`display` is reported as a FORMAT divergence, a difference in `canon` (or OK vs ERR) as SEMANTIC.
Pion rows carrying `!!` markers are internal inconsistencies (raw/packed vs typed API).
"""
import sys

def load(p):
    rows = []
    for line in open(p, encoding="utf-8"):
        line = line.rstrip("\n")
        if line:
            rows.append(line.split("\t"))
    return rows

def split(r):
    canon, _, disp = r.partition(" || ")
    return canon.strip(), disp.strip()

def main():
    jiff, pion, go = (load(p) for p in sys.argv[1:4])
    md = sys.argv[sys.argv.index("--md") + 1] if "--md" in sys.argv else None
    assert len(jiff) == len(pion) == len(go), "probe outputs differ in length"
    sem, fmt, internal = [], [], []
    for j, p, g in zip(jiff, pion, go):
        assert j[:2] == p[:2] == g[:2], f"case mismatch {j[:2]} {p[:2]}"
        if "!!" in p[2]:
            internal.append((j, p, g))
        jc, jd = split(j[2])
        pc, pd = split(p[2].split(" !!")[0])
        if jc != pc:
            sem.append((j, p, g))
        elif jd != pd:
            fmt.append((j, p, g))
    lines = [f"cases={len(jiff)} semantic_divergences={len(sem)} format_divergences={len(fmt)} internal_inconsistencies={len(internal)}", ""]
    def table(title, rows):
        lines.append(f"### {title} ({len(rows)})")
        lines.append("")
        lines.append("| kind | input | jiff 0.2 | Pion | Go |")
        lines.append("| --- | --- | --- | --- | --- |")
        for j, p, g in rows:
            esc = lambda s: s.replace("|", "\\|")
            lines.append(f"| {j[0]} | `{esc(j[1])}` | {esc(j[2])} | **{esc(p[2])}** | {esc(g[2])} |")
        lines.append("")
    table("Semantic divergences from jiff", sem)
    table("Format-only divergences from jiff", fmt)
    table("Internal inconsistencies (raw/packed vs typed)", internal)
    text = "\n".join(lines)
    print(text)
    if md:
        open(md, "w", encoding="utf-8").write(text + "\n")
    # Non-zero exit = evidence found.
    sys.exit(1 if (sem or fmt or internal) else 0)

main()
