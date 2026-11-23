#!/usr/bin/env python3
"""Separate graph-construction cost from algorithm cost: total(algo) - total(algo=none), median of 7 runs.

    python3 split_bench.py ORACLE RUNNER family:n:algo ...
Both binaries build the identical DiGraph + UnGraph from the same edge list before running `algo`.
"""
import statistics, subprocess, sys, time

oracle, runner, specs = sys.argv[1], sys.argv[2], sys.argv[3:]


def t(cmd):
    xs = []
    for _ in range(7):
        s = time.perf_counter()
        subprocess.run(cmd, stdout=subprocess.DEVNULL, check=True)
        xs.append((time.perf_counter() - s) * 1000)
    return statistics.median(xs)


print(f"{'workload':24s} {'build pion':>10s} {'build rust':>10s} {'algo pion':>10s} {'algo rust':>10s} {'algo rust/pion':>14s}")
for spec in specs:
    f, n, a = spec.split(":")
    pb, rb = t([runner, "stress", f, n, "none"]), t([oracle, "stress", f, n, "none"])
    pa, ra = t([runner, "stress", f, n, a]), t([oracle, "stress", f, n, a])
    ap, ar = max(pa - pb, 0.05), max(ra - rb, 0.05)
    print(f"{spec:24s} {pb:10.1f} {rb:10.1f} {ap:10.1f} {ar:10.1f} {ar / ap:13.2f}x")
