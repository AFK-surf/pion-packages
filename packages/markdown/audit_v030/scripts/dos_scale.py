#!/usr/bin/env python3
"""Super-linear scaling probe for Document AST construction (native --release harness).

Times `gen <case> N` (parse_document + 2x plain_text) against `gen <case> N events` (flat parse()),
for N and 4N.  Gate: at 4N the AST path must stay within 10x of the flat event path (or under
0.25 s).  Linear code is ~1-2x; the quadratic Text coalescing is ~50-100x.  Best of 3 runs.
usage: dos_scale.py <harness_rel_bin>
"""
import subprocess, sys, time

H = sys.argv[1]
CASES = [("escapes", 16000), ("brackets", 32000), ("inline_html", 32000), ("cjk", 16000),
         ("table_rows", 32000), ("html_lt", 100000)]


def best(args):
    b = 1e9
    for _ in range(3):
        t0 = time.time()
        subprocess.run([H, *args], check=True, capture_output=True, timeout=600)
        b = min(b, time.time() - t0)
    return b


bad = 0
for case, n in CASES:
    a1, a4 = best(["gen", case, str(n)]), best(["gen", case, str(4 * n)])
    e1, e4 = best(["gen", case, str(n), "events"]), best(["gen", case, str(4 * n), "events"])
    ratio = a4 / max(a1, 0.001)
    vs_ev = a4 / max(e4, 0.001)
    ok = a4 < 0.25 or vs_ev < 10
    bad += not ok
    print(f"  {'OK ' if ok else 'BAD'} {case:12s} N={n:6d}: AST {a1:6.3f}s -> 4N {a4:6.3f}s (x{ratio:5.1f});"
          f" events {e1:6.3f}s -> {e4:6.3f}s; AST/events at 4N = {vs_ev:6.1f}x")
print(f"scaling probes: {len(CASES)} total, {bad} super-linear")
sys.exit(1 if bad else 0)
