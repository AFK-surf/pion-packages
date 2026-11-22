#!/usr/bin/env python3
"""Differential fuzzer: Pion `packages/diff` vs real Rust `imara-diff v0.2.0`.

usage: fuzz.py --oracle BIN --runner BIN [--seed N] [--cases N] [--out DIR] [--families a,b]

Every case is diffed by both implementations for Histogram + Myers:
  P   = hunks after slider postprocessing (diff_lines / postprocess_lines)
  R   = raw hunks (diff_lines_raw / Diff::compute)
  S   = Pion non-windowed `diff_slices(split_lines(..))` vs imara postprocessed hunks
  U<c>= unified diff text for context c in {0,1,3,25}
Mismatches are written to OUT/mismatch_<family>_<i>.{before,after} plus a summary json.
"""
import argparse, json, os, random, subprocess, sys, collections

FIELDS = []
for t in "HM":
    FIELDS += [t + "P", t + "R", t + "S"] + [f"{t}U{c}" for c in (0, 1, 3, 25)]

# ---------------------------------------------------------------- generators
def g_small_alpha(r):
    alpha = ["a\n", "b\n", "c\n", "\n", "  x\n", "}\n", "{\n"]
    n = r.randint(0, 30)
    b = [r.choice(alpha) for _ in range(n)]
    a = mutate(r, b, alpha)
    return "".join(b), "".join(a)

def mutate(r, lines, alpha, k=None):
    a = list(lines)
    for _ in range(k if k is not None else r.randint(0, 5)):
        op = r.random()
        pos = r.randint(0, len(a))
        if op < 0.4:
            a.insert(pos, r.choice(alpha))
        elif op < 0.8 and a:
            del a[min(pos, len(a) - 1)]
        elif a:
            a[min(pos, len(a) - 1)] = r.choice(alpha)
    return a

CODE = ["fn f() {\n", "    let x = 1;\n", "    if x {\n", "        y();\n", "    }\n", "}\n",
        "\n", "\n", "    // c\n", "        return;\n", "\tz();\n", "impl A {\n"]

def g_window(r):
    """Long identical prefix/suffix (> 21-line margin) around a blank/indent-heavy edit:
    attacks `intern_lines_windowed(margin=21)` + `hit_pre || hit_suf` fallback."""
    pre_n = r.randint(15, 45)
    suf_n = r.randint(15, 45)
    blanky = ["\n"] * 6 + CODE
    pre = [r.choice(blanky) for _ in range(pre_n)]
    suf = [r.choice(blanky) for _ in range(suf_n)]
    if r.random() < 0.5:  # long blank runs that straddle the window edge
        pre += ["\n"] * r.randint(10, 30)
    if r.random() < 0.5:
        suf = ["\n"] * r.randint(10, 30) + suf
    mid = [r.choice(blanky) for _ in range(r.randint(0, 6))]
    mid2 = mutate(r, mid, blanky, r.randint(1, 4))
    if mid == mid2:
        mid2 = mid + [r.choice(blanky)]
    return "".join(pre + mid + suf), "".join(pre + mid2 + suf)

def g_code(r):
    n = r.randint(0, 120)
    b = [r.choice(CODE) for _ in range(n)]
    a = mutate(r, b, CODE, r.randint(0, 12))
    return "".join(b), "".join(a)

def g_eol(r):
    """EOF without newline, CRLF, empty files, multibyte UTF-8."""
    alpha = ["a", "b", "é", "日本", "", " x", "\r"]
    def mk(n):
        s = "".join(r.choice(alpha) + r.choice(["\n", "\r\n", "\n"]) for _ in range(n))
        if r.random() < 0.5 and s:
            s = s.rstrip("\n")
        return s
    b = mk(r.randint(0, 8))
    if r.random() < 0.3:
        a = b + r.choice(["\n", "x", "\r\n", ""])
    else:
        a = mk(r.randint(0, 8))
    return b, a

def g_repeat(r):
    """Highly repetitive input: Histogram >63-occurrence Myers fallback paths."""
    n = r.randint(60, 300)
    b = [r.choice(["x\n", "y\n", "\n"]) for _ in range(n)]
    a = mutate(r, b, ["x\n", "y\n", "z\n", "\n"], r.randint(1, 20))
    return "".join(b), "".join(a)

GENS = dict(small=g_small_alpha, window=g_window, code=g_code, eol=g_eol, repeat=g_repeat)

# ---------------------------------------------------------------- unified-diff classification
def split_lines(t):
    parts = t.split("\n")
    return [x + "\n" for x in parts[:-1]] + ([parts[-1]] if parts[-1] else [])

def parse_hunks(s):
    out = []
    for h in s.split():
        b, a = h.split(":")
        b0, b1 = map(int, b.split("-")); a0, a1 = map(int, a.split("-"))
        out.append((b0, b1, a0, a1))
    return out

def fmt_unified(hunks, B, A, ctx, marker=False, gnu_zero=False, fix_first=False):
    """Re-implementation of imara-diff 0.2.0 `UnifiedDiff` + `BasicLineDiffPrinter`
    with three switches for the conventions Pion uses instead:
      marker    : emit `\\ No newline at end of file` (GNU) instead of a bare newline
      gnu_zero  : `@@ -N,0` uses N = start (GNU) instead of start + 1
      fix_first : first hunk context starts at `start - ctx` (imara starts at 0 when ctx < start <= 2*ctx)"""
    if not hunks:
        return ""
    out = []
    def eol(line):
        if line.endswith("\n"):
            return ""
        return "\n\\ No newline at end of file\n" if marker else "\n"
    def header(bs, as_, bl, al):
        b1 = bs if (gnu_zero and bl == 0) else bs + 1
        a1 = as_ if (gnu_zero and al == 0) else as_ + 1
        out.append(f"@@ -{b1},{bl} +{a1},{al} @@\n")
    b0 = hunks[0][0]; a0 = hunks[0][2]
    bcs, acs = max(b0 - ctx, 0), max(a0 - ctx, 0)
    pos = bcs if fix_first else 0
    bcl = acl = 0
    buf = []
    def ctx_lines(lo, hi, dst):
        for i in range(lo, hi):
            dst.append(" " + B[i] + eol(B[i]))
    for (hb0, hb1, ha0, ha1) in hunks:
        if hb0 - pos > 2 * ctx:
            if buf:
                end = min(pos + ctx, len(B))
                header(bcs, acs, bcl + end - pos, acl + end - pos)
                out.extend(buf); ctx_lines(pos, end, out); buf = []
            pos = hb0 - ctx; bcs = pos; acs = ha0 - ctx; bcl = acl = 0
        ctx_lines(pos, hb0, buf)
        cl = hb0 - pos
        bcl += hb1 - hb0 + cl; acl += ha1 - ha0 + cl
        if hb1 > hb0:
            buf.extend("-" + B[i] for i in range(hb0, hb1))
            if not marker:
                buf.append(eol(B[hb1 - 1]))
            else:
                buf[-1] += eol(B[hb1 - 1])
        if ha1 > ha0:
            buf.extend("+" + A[i] for i in range(ha0, ha1))
            if not marker:
                buf.append(eol(A[ha1 - 1]))
            else:
                buf[-1] += eol(A[ha1 - 1])
        pos = hb1
    if buf:
        end = min(pos + ctx, len(B))
        header(bcs, acs, bcl + end - pos, acl + end - pos)
        out.extend(buf); ctx_lines(pos, end, out)
    return "".join(out)

def classify_unified(case, fld, x, y):
    """For a U<ctx> mismatch, name the formatting conventions that explain it."""
    algo, ctx = fld[0], int(fld[2:])
    if x[algo + "P"] != y[algo + "P"]:
        return "hunks-differ"
    B, A = split_lines(case[0]), split_lines(case[1])
    hunks = parse_hunks(x[algo + "P"])
    assert fmt_unified(hunks, B, A, ctx).encode() == x[fld], "imara formatter model is wrong"
    names = []
    for marker in (False, True):
        for zero in (False, True):
            for first in (False, True):
                if fmt_unified(hunks, B, A, ctx, marker, zero, first).encode() == y[fld]:
                    tag = "+".join(n for n, on in (("no-newline-marker", marker), ("gnu-zero-len-header", zero), ("first-hunk-context", first)) if on)
                    names.append(tag or "identical?")
    return min(names, key=lambda t: t.count("+")) if names else "unified-inconsistent-with-own-diff_lines"

# ---------------------------------------------------------------- harness
def write_cases(path, cases):
    with open(path, "wb") as f:
        for b, a in cases:
            bb, ab = b.encode(), a.encode()
            f.write(f"{len(bb)} {len(ab)}\n".encode() + bb + ab)

def parse_dump(buf):
    out, p = [], 0
    while p < len(buf):
        nl = buf.index(b"\n", p); p = nl + 1
        rec = {}
        for fld in FIELDS:
            nl = buf.index(b"\n", p)
            line = buf[p:nl].decode(); p = nl + 1
            tag, _, rest = line.partition(" ")
            assert tag == fld, (tag, fld)
            if "U" in fld:
                n = int(rest); rec[fld] = buf[p:p + n]; p += n
            else:
                rec[fld] = rest
        out.append(rec)
    return out

def run(bin_, path):
    return parse_dump(subprocess.run([bin_, "cases", path], check=True, capture_output=True).stdout)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--oracle", required=True)
    ap.add_argument("--runner", required=True)
    ap.add_argument("--seed", type=int, default=20261123)
    ap.add_argument("--cases", type=int, default=200, help="cases per family")
    ap.add_argument("--families", default=",".join(GENS))
    ap.add_argument("--out", default="/tmp/diff-redteam")
    ap.add_argument("--keep", type=int, default=5, help="mismatch samples kept per family/field")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    summary = {}
    for fam in args.families.split(","):
        r = random.Random(f"{args.seed}-{fam}")
        cases = [GENS[fam](r) for _ in range(args.cases)]
        path = os.path.join(args.out, f"cases_{fam}.bin")
        write_cases(path, cases)
        ro, pi = run(args.oracle, path), run(args.runner, path)
        cnt, any_bad, kept = collections.Counter(), 0, collections.Counter()
        ucls = collections.Counter()
        for i, (x, y) in enumerate(zip(ro, pi)):
            bad = [f for f in FIELDS if x[f] != y[f]]
            if bad:
                any_bad += 1
            for f in bad:
                cnt[f] += 1
                if "U" in f:
                    ucls[classify_unified(cases[i], f, x, y)] += 1
                if kept[f] < args.keep:
                    kept[f] += 1
                    base = os.path.join(args.out, f"mm_{fam}_{f}_{i}")
                    open(base + ".before", "w", newline="").write(cases[i][0])
                    open(base + ".after", "w", newline="").write(cases[i][1])
                    open(base + ".rust", "wb").write(x[f] if isinstance(x[f], bytes) else x[f].encode())
                    open(base + ".pion", "wb").write(y[f] if isinstance(y[f], bytes) else y[f].encode())
        summary[fam] = dict(cases=len(cases), mismatching_cases=any_bad, by_field=dict(cnt), unified_causes=dict(ucls))
        print(f"{fam:8s} cases={len(cases):5d} mismatching={any_bad:5d} {dict(sorted(cnt.items()))}")
        print(f"{'':8s} unified-diff mismatch causes: {dict(ucls.most_common())}")
    json.dump(summary, open(os.path.join(args.out, "summary.json"), "w"), indent=1)

if __name__ == "__main__":
    main()
