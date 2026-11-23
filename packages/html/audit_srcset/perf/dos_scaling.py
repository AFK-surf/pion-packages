#!/usr/bin/env python3
"""DoS scaling probe for parse_srcset / select_srcset_candidate: time n vs 4n (median of 3).
Usage: dos_scaling.py DRIVER [REPORT]   (DRIVER = audit_srcset/diff/pion build)"""
import statistics, subprocess, sys, time

DRIVER = sys.argv[1]
P = ""   # parse only
S = "s"  # parse + select_srcset_candidate

SHAPES = [
    ("parse: commas ,", P, lambda n: "," * n),
    ("parse: spaces", P, lambda n: " " * n),
    ("parse: open parens a (", P, lambda n: "a " + "(" * n),
    ("parse: balanced parens", P, lambda n: "a " + "()" * (n // 2)),
    ("parse: comma-URL a,", P, lambda n: "a," * n),
    ("parse: descriptors 1x", P, lambda n: "a" + " 1x" * n),
    ("parse: candidates a Nw", P, lambda n: ",".join("a %dw" % (i + 1) for i in range(n))),
    ("select: distinct widths", S, lambda n: ",".join("a%d %dw" % (i, i + 1) for i in range(n))),
    ("select: distinct densities desc", S, lambda n: ",".join("a%d %dx" % (i, n - i) for i in range(n))),
    ("select: same density", S, lambda n: ",".join("a%d 1x" % i for i in range(n))),
]


def run(prefix, value):
    line = (prefix + value.encode("latin1").hex() + "\n").encode()
    ts = []
    for _ in range(3):
        t = time.perf_counter()
        p = subprocess.run([DRIVER], input=line, capture_output=True, timeout=900)
        ts.append(time.perf_counter() - t)
        if p.returncode != 0:
            return None, p.returncode
    return statistics.median(ts), 0


rows = ["| shape | n | t(n) ms | t(4n) ms | ratio | verdict |", "|---|---|---|---|---|---|"]
for name, prefix, gen in SHAPES:
    n = 25000
    a, r1 = run(prefix, gen(n))
    b, r2 = run(prefix, gen(4 * n))
    if a is None or b is None:
        rows.append("| %s | %d | rc=%s | rc=%s | - | **CRASH** |" % (name, n, r1, r2))
    else:
        ratio = b / a
        rows.append("| %s | %d | %.1f | %.1f | %.1f | %s |" % (
            name, n, a * 1e3, b * 1e3, ratio, "QUADRATIC" if ratio > 8 else "linear"))
    print(rows[-1], flush=True)
if len(sys.argv) > 2:
    open(sys.argv[2], "w").write("\n".join(rows) + "\n")
