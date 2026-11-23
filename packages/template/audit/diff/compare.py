#!/usr/bin/env python3
"""Compare probe outputs: pion (native) vs rust minijinja 3.1.0 [vs pion wasm32].

    python3 compare.py <pion.out> <rust.out> [--wasm <wasm.out>] [--md <report.md>]

A case matches when both engines agree on OK/ERR and, for OK, on the exact output
bytes. Error messages/kinds are reported but not required to match.
"""
import sys


def load(path):
    data = open(path, "rb").read().decode("utf-8", "replace")
    out = {}
    order = []
    for rec in data.split("\x1e"):
        if not rec.strip("\n"):
            continue
        parts = rec.split("\x1f", 2)
        if len(parts) < 3:
            continue
        out[parts[0]] = (parts[1], parts[2])
        order.append(parts[0])
    return out, order


def short(s, n=160):
    s = s.replace("\n", "\\n")
    return s if len(s) <= n else s[:n] + "..."


def main():
    args = sys.argv[1:]
    md = None
    wasm = None
    if "--md" in args:
        i = args.index("--md")
        md = args[i + 1]
        del args[i : i + 2]
    if "--wasm" in args:
        i = args.index("--wasm")
        wasm = args[i + 1]
        del args[i : i + 2]
    pion, order = load(args[0])
    rust, rorder = load(args[1])
    names = order + [n for n in rorder if n not in pion]
    rows = []
    for n in names:
        p = pion.get(n, ("MISSING", ""))
        r = rust.get(n, ("MISSING", ""))
        same = p[0] == r[0] and (p[0] != "OK" or p[1] == r[1])
        if not same:
            rows.append((n, p, r))
    lines = [f"pion vs rust minijinja 3.1.0: {len(names) - len(rows)}/{len(names)} agree, {len(rows)} differ", ""]
    for n, p, r in rows:
        lines.append(f"DIFF {n}")
        lines.append(f"  pion: {p[0]} {short(p[1])}")
        lines.append(f"  rust: {r[0]} {short(r[1])}")
    if wasm:
        w, _ = load(wasm)
        bad = [n for n in order if w.get(n) != pion.get(n)]
        lines.append("")
        lines.append(f"pion native vs pion wasm32: {len(order) - len(bad)}/{len(order)} byte-identical")
        for n in bad:
            lines.append(f"WASM-DIFF {n}: native={short(str(pion.get(n)))} wasm={short(str(w.get(n)))}")
    text = "\n".join(lines)
    print(text)
    if md:
        open(md, "w").write("```\n" + text + "\n```\n")


if __name__ == "__main__":
    main()
