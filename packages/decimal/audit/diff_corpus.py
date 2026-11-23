#!/usr/bin/env python3
"""Compare probe outputs line by line and classify every mismatch.

usage: diff_corpus.py <corpus.tsv> <reference.out> <candidate.out> [examples_per_class=4] [--json out.json]

Prints per-op totals, then mismatch classes (op + a coarse "kind" of divergence) with decoded
counterexamples: the operands as decimal strings, the reference result and the candidate result.
Exit status 1 when any mismatch exists.
"""
import collections
import json
import sys


def dec_of_hex(h):
    w = [int.from_bytes(bytes.fromhex(h[i:i + 8]), "little") for i in range(0, 32, 8)]
    flags, m = w[0], w[1] | (w[2] << 32) | (w[3] << 64)
    sc, neg = (flags >> 16) & 0xFF, flags >> 31
    s = str(m).rjust(sc + 1, "0")
    if sc:
        s = s[:-sc] + "." + s[-sc:]
    return ("-" if neg else "") + s


def show_args(fields):
    op, args = fields[0], fields[1:]
    out = []
    for i, a in enumerate(args):
        if op in ("FS", "FSX", "SCI", "RADIX") and i == 0:
            out.append(repr(bytes.fromhex(a).decode(errors="replace")))
        elif op == "DES":
            out.append("bytes=" + a)
        elif len(a) == 32 and op not in ("NEW",):
            out.append(dec_of_hex(a))
        else:
            out.append(a)
    return op + "(" + ", ".join(out) + ")"


def kind(op, ref, cand):
    rk, ck = ref.split(" ")[0], cand.split(" ")[0]
    if rk != ck:
        return f"{rk}->{ck}"
    if rk == "D":
        rh, ch = ref.split(" ")[1], cand.split(" ")[1]
        rv, cv = ref.split(" ", 2)[2], cand.split(" ", 2)[2]
        if rh[8:] == ch[8:] and rh[:8] != ch[:8]:
            rf, cf = int(rh[:8], 16), int(ch[:8], 16)
            if (rf ^ cf) == 0x80000000:
                return "D sign-bit"
            return "D scale/flags"
        try:
            from decimal import Decimal, getcontext
            getcontext().prec = 80
            if Decimal(rv) == Decimal(cv):
                return "D same-value/diff-scale"
            return "D value"
        except Exception:
            return "D value"
    if rk == "E":
        return "E class"
    return rk + " value"


def main():
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    jpath = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    if jpath in argv:
        argv.remove(jpath)
    corpus, ref, cand = argv[:3]
    nex = int(argv[3]) if len(argv) > 3 else 4
    lines = open(corpus).read().splitlines()
    r = open(ref).read().splitlines()
    c = open(cand).read().splitlines()
    if not (len(lines) == len(r) == len(c)):
        print(f"LENGTH MISMATCH corpus={len(lines)} ref={len(r)} cand={len(c)}")
        sys.exit(2)
    per_op = collections.Counter()
    per_op_bad = collections.Counter()
    classes = collections.OrderedDict()
    for ln, a, b in zip(lines, r, c):
        f = ln.split("\t")
        per_op[f[0]] += 1
        if a == b:
            continue
        per_op_bad[f[0]] += 1
        key = (f[0], kind(f[0], a, b))
        classes.setdefault(key, []).append((f, a, b))
    total, bad = len(lines), sum(per_op_bad.values())
    print(f"total {total} cases, {total - bad} identical, {bad} mismatching ({100.0 * bad / total:.3f}%)")
    print("per op (mismatch / total): " + ", ".join(
        f"{op} {per_op_bad[op]}/{per_op[op]}" for op in sorted(per_op)))
    report = []
    for (op, k), items in sorted(classes.items(), key=lambda kv: -len(kv[1])):
        print(f"\n[{op} | {k}] {len(items)} cases")
        for f, a, b in items[:nex]:
            print(f"  {show_args(f)}")
            print(f"     rust_decimal: {a}")
            print(f"     pion        : {b}")
        report.append({"op": op, "kind": k, "count": len(items),
                       "examples": [{"input": show_args(f), "line": "\t".join(f), "rust": a, "pion": b}
                                    for f, a, b in items[:nex]]})
    if jpath:
        json.dump({"total": total, "mismatch": bad, "classes": report}, open(jpath, "w"), indent=1)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
