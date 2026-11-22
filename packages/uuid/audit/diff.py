#!/usr/bin/env python3
"""Classify every Pion-vs-Rust differential mismatch.

Usage: python3 diff.py <corpus.tsv> <rust.out> <pion.out>

Classes:
  DEFECT      Pion is wrong (fails the audit, exit 1)
  DIVERGENCE  Pion differs from Rust uuid 1.29.3 / ulid 1.2.1 in a documented, arguable way (reported, exit 0)
  POLICY      Pion is stricter than Rust and the stricter behaviour is spec-correct (reported, exit 0)
  UNEXPECTED  anything not explained by the above (fails the audit, exit 1)
"""

import sys
from collections import Counter, defaultdict

CROCK = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def load(path):
    out = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line:
            continue
        no, op, res = line.split("\t", 2)
        out[int(no)] = (op, res)
    return out


def main():
    corpus = open(sys.argv[1], encoding="utf-8").read().split("\n")
    rust = load(sys.argv[2])
    pion = load(sys.argv[3])
    if rust.keys() != pion.keys():
        print("UNEXPECTED: case sets differ (crash or early exit?)")
        print("  missing in pion:", sorted(set(rust) - set(pion))[:20])
        return 1
    stats = Counter()
    examples = defaultdict(list)

    def add(cls, tag, no, op, args, r, p):
        stats[(cls, tag)] += 1
        if len(examples[(cls, tag)]) < 4:
            examples[(cls, tag)].append(f"line {no} {op} {' '.join(args)[:90]} | rust={r} | pion={p}")

    for no in sorted(rust):
        op, r = rust[no]
        _, p = pion[no]
        args = corpus[no - 1].split("\t")[1:]
        if r == p:
            stats[("MATCH", op)] += 1
            continue
        if p.startswith("INTERNAL_MISMATCH"):
            add("DEFECT", f"{op}: typed vs raw API disagree", no, op, args, r, p)
            continue
        raw = bytes.fromhex(args[0]) if op in ("uparse", "ulparse", "lines", "lines_fixed", "ullines", "ullines_fixed") else b""
        if op in ("lines", "ullines") and r.startswith("ok") and p == "err":
            fixed = pion.get(no + 1, ("", ""))[1]
            if fixed == r:
                add("DEFECT", f"P1 {op}_raw look-ahead fast path rejects valid blank-line input (_fixed variant OK)", no, op, args, r, p)
                continue
        if op.startswith(("lines", "ullines")) and raw == b"\r" and r == "err" and p.startswith("ok"):
            add("DIVERGENCE", "P2 bare trailing CR treated as blank line (Rust str::lines keeps it)", no, op, args, r, p)
            continue
        if op.startswith("ullines") and r.startswith("ok") and p == "err" and any(
            ln[:1] and ln[:1].upper() in "89ABCDEFGHJKMNPQRSTVWXYZ" for ln in raw.decode("latin-1").split("\n")
        ):
            add("POLICY", "ULID > 128-bit ('8'..'Z' first char): Pion rejects, Rust silently truncates", no, op, args, r, p)
            continue
        if op.startswith("ullines") and r == "err" and p.startswith("ok") and any(c in raw for c in b"ILOilo"):
            add("DIVERGENCE", "P2 ULID I/L/O aliases accepted (Rust ulid rejects)", no, op, args, r, p)
            continue
        if op in ("v7", "ulparts") and p == "err" and int(args[0]) > 0xFFFFFFFFFFFF:
            add("POLICY", f"{op}: timestamp > 48 bits rejected (Rust truncates silently)", no, op, args, r, p)
            continue
        if op in ("v1", "v6") and p == "err" and (int(args[0]) >= 1 << 60 or int(args[1]) > 0x3FFF):
            add("POLICY", f"{op}: ticks >= 2^60 or clock_seq > 14 bits rejected (Rust masks silently)", no, op, args, r, p)
            continue
        if op == "ulparse":
            s = raw.decode("latin-1")
            if r.startswith("ok") and p == "err" and s[:1].upper() in "89ABCDEFGHJKMNPQRSTVWXYZ":
                add("POLICY", "ULID > 128-bit ('8'..'Z' first char): Pion rejects, Rust silently truncates", no, op, args, r, p)
                continue
            if r == "err" and p.startswith("ok") and any(c in s for c in "ILOilo"):
                add("DIVERGENCE", "P2 ULID I/L/O aliases accepted (Rust ulid rejects): many strings -> one ULID", no, op, args, r, p)
                continue
        if op == "uinfo":
            rf = dict(kv.split("=") for kv in r.split())
            pf = dict(kv.split("=") for kv in p.split())
            tags = []
            if rf["vnum"] != pf["vnum"] or rf["var"] != pf["var"]:
                tags = None
            else:
                if rf["ver"] != pf["ver"]:
                    if pf["ver"] == "none" and pf["var"] != "Rfc4122":
                        tags.append("P2 version() gated on RFC variant (Rust get_version() is variant-agnostic)")
                    else:
                        tags = None
                if tags is not None and rf["ts"] != pf["ts"]:
                    if pf["ts"] == "none" and rf["vnum"] in ("1", "6"):
                        tags.append("P2 no v1/v6 timestamp decoding (Rust get_timestamp() supports v1/v6/v7)")
                    elif pf["ts"] == "none" and pf["var"] != "Rfc4122" and rf["vnum"] == "7":
                        tags.append("P2 v7 timestamp hidden for non-RFC variant")
                    else:
                        tags = None
            if tags:
                for t in tags:
                    add("DIVERGENCE", t, no, op, args, r, p)
                continue
        add("UNEXPECTED", op, no, op, args, r, p)

    order = ["DEFECT", "UNEXPECTED", "DIVERGENCE", "POLICY"]
    total = len(rust)
    matched = sum(v for (c, _), v in stats.items() if c == "MATCH")
    print(f"cases={total} identical={matched} mismatched={total - matched}")
    for (c, op), v in sorted(stats.items()):
        if c == "MATCH":
            print(f"  identical {op}: {v}")
    for cls in order:
        for (c, tag), v in sorted(stats.items()):
            if c != cls:
                continue
            print(f"[{cls}] x{v}: {tag}")
            for e in examples[(c, tag)]:
                print(f"    {e}")
    bad = sum(v for (c, _), v in stats.items() if c in ("DEFECT", "UNEXPECTED"))
    print("RESULT:", "FAIL" if bad else "PASS", f"({bad} defect/unexpected mismatches)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
