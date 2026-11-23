#!/usr/bin/env python3
"""Line-by-line differential of driver/oracle outputs.

usage: compare.py <cases file> <name>=<output file> [<name>=<output file> ...] [--show N] [--ordered]

The first named output is the subject (Pion). Each row is decoded back to readable form:
canonical numbers `d<bits>` become repr(float), strings/keys are decoded from hex.
Object key order is ignored unless --ordered (JS reorders integer-like keys).
Prints a summary per reference plus up to N disagreement rows.
"""
import struct
import sys


def parse_canon(s, i=0):
    c = s[i]
    if c == "n":
        return None, i + 1
    if c == "t":
        return True, i + 1
    if c == "f":
        return False, i + 1
    if c == "d":
        if s.startswith("dNaN", i):
            return ("num", "NaN"), i + 4
        x = struct.unpack(">d", bytes.fromhex(s[i + 1:i + 17]))[0]
        return ("num", repr(x)), i + 17
    if c == "s":
        j = s.index(";", i)
        return bytes.fromhex(s[i + 1:j]).decode("utf-8", "replace"), j + 1
    if c == "[":
        out, i = [], i + 1
        if s[i] == "]":
            return ("arr", tuple(out)), i + 1
        while True:
            v, i = parse_canon(s, i)
            out.append(v)
            if s[i] == "]":
                return ("arr", tuple(out)), i + 1
            i += 1
    if c == "{":
        out, i = [], i + 1
        if s[i] == "}":
            return ("obj", tuple(out)), i + 1
        while True:
            j = s.index(":", i)
            k = bytes.fromhex(s[i:j]).decode("utf-8", "replace")
            v, i = parse_canon(s, j + 1)
            out.append((k, v))
            if s[i] == "}":
                return ("obj", tuple(out)), i + 1
            i += 1
    raise ValueError(s[i:i + 20])


def norm(v, ordered):
    if isinstance(v, tuple) and v and v[0] == "arr":
        return ("arr", tuple(norm(x, ordered) for x in v[1]))
    if isinstance(v, tuple) and v and v[0] == "obj":
        items = tuple((k, norm(x, ordered)) for k, x in v[1])
        return ("obj", items if ordered else tuple(sorted(items, key=lambda kv: kv[0])))
    return v


def show(v):
    if isinstance(v, tuple) and v and v[0] == "num":
        return v[1]
    if isinstance(v, tuple) and v and v[0] == "arr":
        return "[" + ",".join(show(x) for x in v[1]) + "]"
    if isinstance(v, tuple) and v and v[0] == "obj":
        return "{" + ",".join(f"{k!r}:{show(x)}" for k, x in v[1]) + "}"
    if v is None:
        return "null"
    if isinstance(v, bool):
        return str(v).lower()
    return repr(v)


def decode_row(row, ordered):
    if row.startswith("OK "):
        return "OK " + show(norm(parse_canon(row[3:])[0], ordered))
    return row.strip()


def decode_case(line):
    parts = line.split(" ")
    out = []
    for p in parts:
        try:
            out.append(bytes.fromhex(p).decode("utf-8", "replace"))
        except ValueError:
            out.append(p)
    return "  |  ".join(repr(x) for x in out)


def main():
    args = [a for a in sys.argv[1:]]
    nshow = 40
    if "--show" in args:
        k = args.index("--show")
        nshow = int(args[k + 1])
        del args[k:k + 2]
    ordered = "--ordered" in args
    args = [a for a in args if a != "--ordered"]
    cases = open(args[0]).read().split("\n")
    outs = []
    for spec in args[1:]:
        name, path = spec.split("=", 1)
        outs.append((name, open(path).read().split("\n")))
    subj_name, subj = outs[0]
    rows = []
    for ref_name, ref in outs[1:]:
        bad = 0
        for i, case in enumerate(cases):
            if not case:
                continue
            a, b = decode_row(subj[i], ordered), decode_row(ref[i], ordered)
            if a != b:
                bad += 1
                rows.append((i, case))
        print(f"{subj_name} vs {ref_name}: {bad} / {sum(1 for c in cases if c)} rows differ")
    seen = set()
    shown = 0
    for i, case in rows:
        if i in seen or shown >= nshow:
            continue
        seen.add(i)
        shown += 1
        print(f"\n#{i + 1}: {decode_case(case)}")
        for name, o in outs:
            print(f"   {name:6s} {decode_row(o[i], ordered)[:200]}")


if __name__ == "__main__":
    main()
