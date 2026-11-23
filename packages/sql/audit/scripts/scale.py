#!/usr/bin/env python3
"""Time-complexity probe: each workload at n and 2n..8n (native release). A ratio near 2 per doubling is
linear, near 4 is quadratic. `driver adv <workload> <file> 1` does one pass.

usage: scale.py <bin dir>
"""
import os
import subprocess
import sys
import time

B = sys.argv[1]
OUT = os.environ.get("OUT", "/private/tmp/pion-sql-audit")

GEN = {
    "extract_tables, n distinct tables": ("tables", lambda n: "SELECT * FROM " + ", ".join(f"tbl_{i}" for i in range(n))),
    "extract_tables, n CTEs referenced": ("tables", lambda n: "WITH " + ", ".join(f"c{i} AS (SELECT 1)" for i in range(n)) +
                                          " SELECT * FROM " + ", ".join(f"c{i}" for i in range(n))),
    "parse, n distinct tables": ("parse", lambda n: "SELECT * FROM " + ", ".join(f"tbl_{i}" for i in range(n))),
    "parse, IN list of n": ("parse", lambda n: "SELECT 1 FROM t WHERE x IN (" + ", ".join(str(i) for i in range(n)) + ")"),
    "parse, n-term OR chain": ("parse", lambda n: "SELECT 1 FROM t WHERE " + " OR ".join(f"a = {i}" for i in range(n))),
    "parse, string with n '' escapes": ("parse", lambda n: "SELECT '" + "''" * n + "'"),
    "split, n statements": ("split", lambda n: "SELECT 'a;b', $$;$$ FROM t; " * n),
    "parse, n statements in one script": ("script", lambda n: "SELECT 1 FROM t; " * n),
}


def once(wl, path):
    t = time.perf_counter()
    r = subprocess.run([f"{B}/drv", "adv", wl, path, "1"], capture_output=True, text=True)
    return time.perf_counter() - t, r.stdout.strip()


print("| workload | n | 2n | 4n | 8n | time 8n / time n |")
print("|---|---:|---:|---:|---:|---:|")
for name, (wl, gen) in GEN.items():
    base = 10000
    ts = []
    for k in (1, 2, 4, 8):
        path = os.path.join(OUT, "scale.sql")
        with open(path, "w") as f:
            f.write(gen(base * k) + "\n")
        best = min(once(wl, path)[0] for _ in range(3))
        ts.append(best)
    print(f"| {name} (n={base}) | " + " | ".join(f"{t * 1000:.0f} ms" for t in ts) + f" | {ts[-1] / max(ts[0], 1e-4):.1f}x |", flush=True)
print("(linear: ~8x; quadratic: ~64x)")
