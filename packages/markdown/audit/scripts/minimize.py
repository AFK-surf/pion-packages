#!/usr/bin/env python3
"""Batch delta-debugging of divergent cases from diff_results.json.

usage: minimize.py <rust_ref_bin> <pion_harness_bin> <diff_results.json> <out.json> [--max N]
A candidate "still diverges" when Pion to_html_pulldown != Rust, or the two Pion paths differ.
"""
import json, os, subprocess, sys, tempfile, collections

RUST, PION, INP, OUTP = sys.argv[1:5]
MAX = int(sys.argv[sys.argv.index("--max") + 1]) if "--max" in sys.argv else 400
tmp = tempfile.mkdtemp()


def write_batch(path, cases):
    with open(path, "wb") as f:
        for mask, src in cases:
            b = src.encode("utf-8")
            f.write(f"{mask}\t{len(b)}\n".encode() + b)


def frames(data, per):
    res, i = [], 0
    while i < len(data):
        nl = data.index(b"\n", i)
        ln = int(data[i:nl])
        res.append(data[nl + 1:nl + 1 + ln])
        i = nl + 1 + ln
    return [res[j:j + per] for j in range(0, len(res), per)]


def evaluate(cases):
    p = os.path.join(tmp, "b.bin")
    write_batch(p, cases)
    r = frames(subprocess.run([RUST, "batch", p], capture_output=True, check=True).stdout, 1)
    q = frames(subprocess.run([PION, "batch", p], capture_output=True, check=True).stdout, 4)
    return [(rr[0], qq) for rr, qq in zip(r, q)]


def bad(res):
    r, (d, e, t, rp) = res
    return d != r or e != r or d != e or t != rp


def main():
    diffs = [d for d in json.load(open(INP))["diffs"] if d["rust"] is not None]
    seen, todo = set(), []
    for d in diffs:
        k = (d["mask"], d["src"])
        if k not in seen and len(todo) < MAX:
            seen.add(k)
            todo.append([d["mask"], d["src"]])
    active = list(range(len(todo)))
    rnd = 0
    while active and rnd < 60:
        rnd += 1
        cands, owner = [], []
        for ci in active:
            m, s = todo[ci]
            n = len(s)
            size = max(1, n // 2)
            while True:
                for off in range(0, n, size):
                    t = s[:off] + s[off + size:]
                    if t != s:
                        cands.append((m, t))
                        owner.append(ci)
                if size == 1:
                    break
                size = max(1, size // 2)
        res = evaluate(cands)
        best = {}
        for (m, t), ci, rr in zip(cands, owner, res):
            if bad(rr) and (ci not in best or len(t) < len(best[ci])):
                best[ci] = t
        nxt = []
        for ci in active:
            if ci in best:
                todo[ci][1] = best[ci]
                nxt.append(ci)
        active = nxt
        print(f"round {rnd}: {len(active)} still shrinking", file=sys.stderr)
    uniq = sorted({(m, s) for m, s in todo}, key=lambda x: (len(x[1]), x))
    res = evaluate(uniq)
    out = []
    for (m, s), (r, (d, e, t, rp)) in zip(uniq, res):
        out.append({"mask": m, "src": s, "rust": r.decode("utf-8", "replace"),
                    "pion_direct": d.decode("utf-8", "replace"),
                    "pion_events": e.decode("utf-8", "replace"),
                    "pion_to_html": t.decode("utf-8", "replace"),
                    "pion_render_html_parse": rp.decode("utf-8", "replace")})
    json.dump(out, open(OUTP, "w"), ensure_ascii=False, indent=1)
    print(f"{len(out)} unique minimized divergences -> {OUTP}")


main()
