#!/usr/bin/env python3
"""Three-way verdict diff of oracle outputs ("<label>\t<result>" per line).

  compare.py <pion.out> <rust.out> <go.out> [--strict-prefix P ...] [--md out.md]

Lines whose label starts with a --strict-prefix (crypto / base64) must be identical
between Pion and Rust (RustCrypto / strict `base64`), otherwise the script exits 1; a
Go-only deviation there is listed as GO_ONLY_DEVIATION (e.g. Go's base64 decoder
silently skipping CR/LF even in Strict mode). For JWT verdicts every
divergence is listed and classified:
  PION_ONLY_ACCEPTS   Pion accepts a token both references reject   (security-relevant)
  PION_ONLY_REJECTS   Pion rejects a token both references accept   (interop)
  SPLIT               references disagree with each other
  SUB_MISMATCH        all accept but disagree on the decoded "sub"
"""

import sys


def load(path):
    rows = []
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            label, _, res = line.partition("\t")
            rows.append((label, res))
    return rows


def main():
    args = sys.argv[1:]
    md = None
    strict = []
    pos = []
    i = 0
    while i < len(args):
        if args[i] == "--md":
            md = args[i + 1]
            i += 2
        elif args[i] == "--strict-prefix":
            strict.append(args[i + 1])
            i += 2
        else:
            pos.append(args[i])
            i += 1
    p, r, g = (load(x) for x in pos)
    if not (len(p) == len(r) == len(g)):
        print(f"LINE COUNT MISMATCH pion={len(p)} rust={len(r)} go={len(g)}")
        return 1
    strict_bad = []
    go_dev = []
    cls = {"PION_ONLY_ACCEPTS": [], "PION_ONLY_REJECTS": [], "SPLIT": [], "SUB_MISMATCH": []}
    agree = 0
    for (lp, vp), (lr, vr), (lg, vg) in zip(p, r, g):
        assert lp == lr == lg, (lp, lr, lg)
        if any(lp.startswith(s) for s in strict):
            if vp != vr:
                strict_bad.append((lp, vp, vr, vg))
            elif vp != vg:
                go_dev.append((lp, vp, vr, vg))
            else:
                agree += 1
            continue
        if vp == vr == vg:
            agree += 1
            continue
        okp, okr, okg = (v.startswith("OK") for v in (vp, vr, vg))
        if okp and not okr and not okg:
            cls["PION_ONLY_ACCEPTS"].append((lp, vp, vr, vg))
        elif not okp and okr and okg:
            cls["PION_ONLY_REJECTS"].append((lp, vp, vr, vg))
        elif okp and okr and okg:
            cls["SUB_MISMATCH"].append((lp, vp, vr, vg))
        else:
            cls["SPLIT"].append((lp, vp, vr, vg))

    out = []
    out.append(f"total={len(p)} identical={agree} strict_mismatch={len(strict_bad)}")
    out.append(f"GO_ONLY_DEVIATION={len(go_dev)}")
    for lab, (lp, vp, vr, vg) in [("STRICT_MISMATCH", x) for x in strict_bad[:50]] + [("GO_ONLY_DEVIATION", x) for x in go_dev[:50]]:
        out.append(f"{lab}\t{lp}\tpion={vp[:80]}\trust={vr[:80]}\tgo={vg[:80]}")
    for k, items in cls.items():
        out.append(f"{k}={len(items)}")
        for lp, vp, vr, vg in items:
            out.append(f"  {lp:<44} pion={vp[:40]:<12} rust={vr[:40]:<12} go={vg[:40]}")
    text = "\n".join(out)
    print(text)
    if md:
        with open(md, "w") as f:
            f.write("```\n" + text + "\n```\n")
    return 1 if strict_bad else 0


if __name__ == "__main__":
    sys.exit(main())
