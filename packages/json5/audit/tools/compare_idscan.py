#!/usr/bin/env python3
"""Compare `idscan` bitmaps of Pion vs Node json5@2.2.3 (Unicode 10) vs Rust json5 1.3.8 (Unicode 17).

usage: compare_idscan.py id_pion.txt id_node.txt id_rust.txt [--examples N]

Bits per code point (0x80..0x10FFFF, surrogates skipped):
  1 `{X:1}` raw start, 2 `{aX:1}` raw part, 4 `[X1]` whitespace, 8 `{\\uXXXX:1}`, 16 `{a\\uXXXX:1}`.

"STRONG" rows are code points where Node AND Rust agree with each other and Pion disagrees:
both references (7 Unicode versions apart) give the same verdict, so it is not a Unicode-version
artefact.
"""
import sys
import unicodedata

BITS = [(1, "raw IdentifierStart  {X:1}"), (2, "raw IdentifierPart   {aX:1}"), (4, "whitespace           [X1]"),
        (8, "escaped start  {\\uXXXX:1}"), (16, "escaped part  {a\\uXXXX:1}")]


def load(p):
    s = "".join(open(p).read().split("\n"))
    cps = [cp for cp in range(0x80, 0x110000) if not 0xD800 <= cp <= 0xDFFF]
    assert len(s) == len(cps), (p, len(s), len(cps))
    return {cp: ord(ch) - 65 for cp, ch in zip(cps, s)}


def ranges(cps):
    out = []
    for cp in cps:
        if out and cp == out[-1][1] + 1:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return out


def cat(cp):
    try:
        return unicodedata.category(chr(cp))
    except ValueError:
        return "??"


def main():
    pion, node, rust = (load(p) for p in sys.argv[1:4])
    nex = int(sys.argv[sys.argv.index("--examples") + 1]) if "--examples" in sys.argv else 12
    print(f"(Python unicodedata {unicodedata.unidata_version} used only to label categories)")
    total_strong = 0
    for bit, label in BITS:
        acc_bad, rej_bad, vs_node, vs_rust = [], [], 0, 0
        for cp, m in pion.items():
            p, n, r = bool(m & bit), bool(node[cp] & bit), bool(rust[cp] & bit)
            vs_node += p != n
            vs_rust += p != r
            if n == r and p != n:
                (acc_bad if p else rej_bad).append(cp)
        total_strong += len(acc_bad) + len(rej_bad)
        print(f"\n== {label}: Pion != Node on {vs_node} cps, Pion != Rust on {vs_rust} cps")
        for kind, lst in (("STRONG wrongly ACCEPTED (both refs reject)", acc_bad),
                          ("STRONG wrongly REJECTED (both refs accept)", rej_bad)):
            rs = ranges(lst)
            print(f"   {kind}: {len(lst)} code points in {len(rs)} ranges")
            # show the largest ranges first
            for a, b in sorted(rs, key=lambda r: r[0] - r[1])[:nex]:
                cats = sorted({cat(c) for c in range(a, min(b, a + 4096) + 1)})
                name = unicodedata.name(chr(a), "?")
                print(f"     U+{a:04X}..U+{b:04X} ({b - a + 1:6d})  gc={','.join(cats):12s} first={name}")
    print(f"\nTOTAL strong (both-reference) disagreements over all 5 probes: {total_strong}")


if __name__ == "__main__":
    main()
