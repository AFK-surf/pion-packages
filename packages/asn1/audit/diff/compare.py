#!/usr/bin/env python3
"""Three-way diff of oracle outputs ("<label>\t<result>" per line).

  compare.py <pion.out> <go.out> <rust.out> [--md out.md] [--show N]

Every vector where the three oracles do not print the same result is classified:
  PION_ONLY_ACCEPTS  Pion accepts, Go and Rust both reject       (malleability / laxness)
  PION_ONLY_REJECTS  Pion rejects, Go and Rust both accept       (interop)
  VALUE_MISMATCH     all three accept but decode different values (semantic divergence)
  PION_VS_GO         Pion != Go while Pion == Rust
  PION_VS_RUST       Pion != Rust while Pion == Go
  REFS_SPLIT         Go and Rust disagree and Pion matches neither
Counts are reported per (kind, class); the --show N first labels of each bucket are listed.
"""

import collections
import sys


def load(path):
    rows = []
    with open(path, encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            line = line.rstrip("\n")
            if line:
                label, _, res = line.partition("\t")
                rows.append((label, res, "ERR" if res.startswith("ERR") else res))
    return rows


def kind_of(label):
    parts = label.split(".")
    if parts[0] in ("hand", "hdr", "mut"):
        return parts[1]
    if parts[0] == "x509" and len(parts) > 1 and parts[1] in ("real", "realmut"):
        return "x509." + parts[1]
    if parts[0] == "tree":
        return "tree"
    return parts[0]


def ok(v):
    return v.startswith("OK")


def classify(p, g, r):
    if p == g == r:
        return None
    if ok(p) and not ok(g) and not ok(r):
        return "PION_ONLY_ACCEPTS"
    if not ok(p) and ok(g) and ok(r):
        return "PION_ONLY_REJECTS"
    if ok(p) and ok(g) and ok(r) and g == r:
        return "VALUE_MISMATCH"
    if p == r:
        return "PION_VS_GO"
    if p == g:
        return "PION_VS_RUST"
    return "REFS_SPLIT"


def main():
    args = sys.argv[1:]
    md, show, pos = None, 6, []
    i = 0
    while i < len(args):
        if args[i] == "--md":
            md = args[i + 1]
            i += 2
        elif args[i] == "--show":
            show = int(args[i + 1])
            i += 2
        else:
            pos.append(args[i])
            i += 1
    P, G, R = (load(x) for x in pos)
    if not (len(P) == len(G) == len(R)):
        print(f"LINE COUNT MISMATCH pion={len(P)} go={len(G)} rust={len(R)}")
        return 1
    per_kind = collections.Counter()
    same_kind = collections.Counter()
    buckets = collections.defaultdict(list)
    for (lp, vp, np_), (lg, vg, ng), (lr, vr, nr) in zip(P, G, R):
        assert lp == lg == lr, (lp, lg, lr)
        k = kind_of(lp)
        per_kind[k] += 1
        c = classify(np_, ng, nr)
        if c is None:
            same_kind[k] += 1
        else:
            buckets[(k, c)].append((lp, vp, vg, vr))
    out = [f"vectors={len(P)} identical_3way={sum(same_kind.values())}", "",
           "| kind | vectors | identical | " + " | ".join(
               ["PION_ONLY_ACCEPTS", "PION_ONLY_REJECTS", "VALUE_MISMATCH", "PION_VS_GO", "PION_VS_RUST", "REFS_SPLIT"]) + " |",
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    classes = ["PION_ONLY_ACCEPTS", "PION_ONLY_REJECTS", "VALUE_MISMATCH", "PION_VS_GO", "PION_VS_RUST", "REFS_SPLIT"]
    for k in sorted(per_kind):
        out.append(f"| {k} | {per_kind[k]} | {same_kind[k]} | " +
                   " | ".join(str(len(buckets.get((k, c), []))) for c in classes) + " |")
    out.append("")
    clip = lambda s: s if len(s) <= 90 else s[:87] + "..."  # noqa: E731
    for (k, c), items in sorted(buckets.items()):
        out.append(f"### {k} / {c} ({len(items)})")
        for lp, vp, vg, vr in items[:show]:
            out.append(f"- `{lp}` pion=`{clip(vp)}` go=`{clip(vg)}` rust=`{clip(vr)}`")
        out.append("")
    text = "\n".join(out)
    print(text)
    if md:
        with open(md, "w") as f:
            f.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
