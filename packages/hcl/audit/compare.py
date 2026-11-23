#!/usr/bin/env python3
"""Compare Go-oracle output with Pion-driver output, case by case.

A case matches when the verdicts (OK/ERR) agree and, for OK, the JSON values are equal with
numbers compared as exact decimals (so `1e+21` == `1000000000000000000000`, but
`9007199254740992` != `9007199254740993`).

usage: compare.py GO.out PION.out [--modes OTHER.out ...] [--quiet]
       compare.py --robust NATIVE_REL.out OTHER.out ...   (fuzz gate, no Go oracle)

PION.out is the native_rel run. Each `--modes` file (native_dbg, wasm_rel, wasm_dbg runs) must be
byte-identical to PION.out line by line; a differing line is a `MODE-FAIL`.
Prints `PASS`/`FAIL` lines and a summary; exit 1 on any FAIL. A `CRASH` verdict never passes.
"""
import json
import os
import sys
from decimal import Decimal


def load(path):
    out = {}
    order = []
    with open(path, encoding="utf-8", errors="surrogateescape") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            cid, verdict, payload = line.split("\t", 2)
            out[cid] = (verdict, payload)
            order.append(cid)
    return out, order


def parse(payload):
    try:
        return json.loads(payload, parse_float=Decimal, parse_int=Decimal)
    except Exception:
        return ("<unparseable>", payload)


def norm(v):
    if isinstance(v, dict):
        return {k: norm(x) for k, x in v.items()}
    if isinstance(v, list):
        return [norm(x) for x in v]
    if isinstance(v, Decimal):
        return v.normalize() if v == v else v
    return v


def raw_lines(path):
    out = {}
    with open(path, "rb") as fh:
        for line in fh:
            if line.strip():
                out[line.split(b"\t", 1)[0]] = line
    return out


def robust(paths):
    """Fuzz gate: no CRASH in any mode, every mode line-identical to the first (native_rel)."""
    runs = [raw_lines(p) for p in paths]
    base = runs[0]
    fails = 0
    for k in base:
        lines = [r.get(k, b"MISSING") for r in runs]
        crashed = [os.path.basename(paths[i]) for i, l in enumerate(lines) if b"\tCRASH\t" in l or l == b"MISSING"]
        differ = len(set(lines)) > 1
        if crashed or differ:
            fails += 1
            what = ("CRASH in " + ", ".join(crashed)) if crashed else "modes differ"
            print(f"FAIL {k.decode()}: {what}")
            for p, l in zip(paths, lines):
                print(f"    {os.path.basename(p)}: {l.strip()[:200]!r}")
    print(f"fuzz: {len(base) - fails}/{len(base)} PASS, {fails} FAIL (no crash, 4 modes identical)")
    return 1 if fails else 0


def main():
    args = sys.argv[1:]
    if args and args[0] == "--robust":
        sys.exit(robust(args[1:]))
    quiet = "--quiet" in args
    args = [a for a in args if a != "--quiet"]
    modes = []
    if "--modes" in args:
        i = args.index("--modes")
        modes = args[i + 1:]
        args = args[:i]
    go, order = load(args[0])
    pion, _ = load(args[1])
    fails = 0
    mode_fails = 0
    if modes:
        base = raw_lines(args[1])
        for m in modes:
            other = raw_lines(m)
            bad = [k for k in base if other.get(k) != base[k]] + [k for k in other if k not in base]
            for k in bad:
                mode_fails += 1
                print(f"MODE-FAIL {k.decode()} ({os.path.basename(m)})\n    native_rel: {base.get(k, b'MISSING').strip()[:200]!r}\n    this mode:  {other.get(k, b'MISSING').strip()[:200]!r}")
            print(f"4-mode: {os.path.basename(m)}: {len(base) - len(bad)}/{len(base)} lines identical to native_rel")
    for cid in order:
        g = go[cid]
        p = pion.get(cid, ("MISSING", "-"))
        if cid.startswith("crash/"):
            ok = p[0] in ("OK", "ERR")
        else:
            ok = g[0] == p[0] and (g[0] != "OK" or norm(parse(g[1])) == norm(parse(p[1])))
        if not ok:
            fails += 1
            print(f"FAIL {cid}\n    go:   {g[0]} {g[1][:300]}\n    pion: {p[0]} {p[1][:300]}")
        elif not quiet:
            print(f"PASS {cid}")
    print(f"differential: {len(order) - fails}/{len(order)} PASS, {fails} FAIL")
    sys.exit(1 if fails or mode_fails else 0)


if __name__ == "__main__":
    main()
