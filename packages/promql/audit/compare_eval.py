#!/usr/bin/env python3
"""Compare Pion probe vs Go promql.Engine eval outputs, case by case.

usage: compare_eval.py <eval.tsv (gen_eval.py output)> <pion.out> <go.out> <eval_groups.txt> [--details FILE]

A case matches when the result kind, the series/label sets and every value agree
(floats: NaN==NaN, equal infinities, otherwise |a-b| <= 1e-9 * max(1,|a|,|b|)).
Prints one "CHECK <PASS|FAIL> <finding> <severity> <matched>/<total> <description>" line per
finding group of eval_groups.txt, one for the remaining control cases, then every mismatch.
"""
import math
import sys


def load(path):
    res = {}
    order = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line:
            continue
        c = line.split("\t")
        cid = c[0]
        if cid not in res:
            res[cid] = {"head": None, "rows": []}
            order.append(cid)
        if len(c) >= 2 and c[1] == "":
            res[cid]["rows"].append(c[2:])
        else:
            res[cid]["head"] = c[1:]
    return res, order


def fnum(s):
    s = s.strip()
    if s in ("NaN", "nan"):
        return math.nan
    return float(s)


def feq(a, b):
    x, y = fnum(a), fnum(b)
    if math.isnan(x) or math.isnan(y):
        return math.isnan(x) and math.isnan(y)
    if math.isinf(x) or math.isinf(y):
        return x == y
    return abs(x - y) <= 1e-9 * max(1.0, abs(x), abs(y))


def row_eq(kind, r1, r2):
    if r1[0] != r2[0]:
        return False
    if kind == "vector":
        return feq(r1[1], r2[1])
    p1, p2 = r1[1].split(" ") if r1[1] else [], r2[1].split(" ") if r2[1] else []
    if len(p1) != len(p2):
        return False
    for a, b in zip(p1, p2):
        ta, va = a.split(":", 1)
        tb, vb = b.split(":", 1)
        if ta != tb or not feq(va, vb):
            return False
    return True


def same(p, g):
    if p is None or g is None:
        return False
    ph, gh = p["head"], g["head"]
    if ph[0] != gh[0]:
        return False
    k = ph[0]
    if k == "scalar":
        return feq(ph[1], gh[1])
    if k == "string":
        return ph[1] == gh[1]
    if k in ("vector", "matrix"):
        if len(p["rows"]) != len(g["rows"]):
            return False
        return all(row_eq(k, a, b) for a, b in zip(p["rows"], g["rows"]))
    return True  # ERR / PARSE_ERR


def render(r):
    if r is None:
        return "MISSING"
    s = "/".join(r["head"])
    if r["rows"]:
        s += " " + " ; ".join(" ".join(x) for x in r["rows"])
    return s


def main():
    queries = {}
    for raw in open(sys.argv[1], encoding="utf-8"):
        c = raw.rstrip("\n").split("\t")
        if c[0] == "instant":
            queries[c[1]] = "@%s %s" % (c[2], bytes.fromhex(c[3]).decode("utf-8"))
        elif c[0] == "range":
            queries[c[1]] = "[%s..%s step %s] %s" % (c[2], c[3], c[4], bytes.fromhex(c[5]).decode("utf-8"))
    pion, _ = load(sys.argv[2])
    go, _ = load(sys.argv[3])
    details = None
    if "--details" in sys.argv:
        details = open(sys.argv[sys.argv.index("--details") + 1], "w", encoding="utf-8")
    bad = [cid for cid in queries if not same(pion.get(cid), go.get(cid))]
    groups, grouped = [], set()
    for raw in open(sys.argv[4], encoding="utf-8"):
        if raw.startswith("#") or not raw.strip():
            continue
        fid, sev, desc, ids = raw.rstrip("\n").split("\t")
        ids = ids.split(",")
        grouped.update(ids)
        groups.append((fid, sev, desc, ids))
    controls = [c for c in queries if c not in grouped]
    groups.append(("EVAL-CONTROLS", "-", "all other eval cases keep matching Go", controls))
    for fid, sev, desc, ids in groups:
        nbad = sum(1 for c in ids if c in bad)
        print("CHECK %s %s %s %d/%d %s" % ("PASS" if nbad == 0 else "FAIL", fid, sev, len(ids) - nbad, len(ids), desc))
    print("eval cases %d, mismatching %d" % (len(queries), len(bad)))
    for cid in bad:
        line = "  [%s] %s\n      pion: %s\n      go:   %s" % (cid, queries[cid], render(pion.get(cid)), render(go.get(cid)))
        print(line)
        if details:
            details.write(line + "\n")


if __name__ == "__main__":
    main()
