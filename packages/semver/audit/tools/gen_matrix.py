#!/usr/bin/env python3
"""Exhaustive small-domain VersionReq::matches matrix (precompiled-interval fast path audit).

Comparators: every op x every shape over numbers {0,1} and prerelease {"", "0", "a"};
reqs = every single comparator + every ordered pair + a deterministic sample of triples.
Versions: {0,1,2}^3 x prerelease {"", "0", "a", "b", "a.0"}.

Usage: gen_matrix.py <reqs_out> <vers_out> [triples]
"""
import os
import random
import sys

# MATRIX_NUMS / MATRIX_VNUMS override the domains (e.g. Int64::MAX boundary run).
NUMS = os.environ.get("MATRIX_NUMS", "0,1").split(",")
VNUMS = os.environ.get("MATRIX_VNUMS", "0,1,2").split(",")
PRES = ["", "0", "a"]


def comparators():
    out = []
    for op in ["", "=", ">", ">=", "<", "<=", "~", "^"]:
        for a in NUMS:
            out.append(f"{op}{a}")
            out.append(f"{op}{a}.*")
            for b in NUMS:
                out.append(f"{op}{a}.{b}")
                out.append(f"{op}{a}.{b}.*")
                for c in NUMS:
                    for p in PRES:
                        out.append(f"{op}{a}.{b}.{c}" + (f"-{p}" if p else ""))
    return out


def main():
    cs = comparators()
    reqs = list(cs)
    reqs += [f"{x}, {y}" for x in cs for y in cs]
    r = random.Random(7)
    n3 = int(sys.argv[3]) if len(sys.argv) > 3 else 200000
    reqs += [", ".join(r.choice(cs) for _ in range(3)) for _ in range(n3)]
    vers = []
    for a in VNUMS:
        for b in VNUMS:
            for c in VNUMS:
                for p in ["", "0", "a", "b", "a.0"]:
                    vers.append(f"{a}.{b}.{c}" + (f"-{p}" if p else ""))
    open(sys.argv[1], "w").write("\n".join(reqs) + "\n")
    open(sys.argv[2], "w").write("\n".join(vers) + "\n")
    print(f"matrix: {len(reqs)} reqs x {len(vers)} versions = {len(reqs) * len(vers)} matches", file=sys.stderr)


if __name__ == "__main__":
    main()
