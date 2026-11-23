#!/usr/bin/env python3
"""Fairness probe: split the package's W1/W2 batch timings into fixed cost (process start, file read, JSON parse,
schema compile = run with 0 iterations) and steady-state validation cost (slope between 0 and N iterations).

usage: steady_state.py <bin_dir> <data_dir> <node_modules> <pkg_bench_dir> [N]
The package README's W1/W2 runs last only ~25-100 ms, so fixed cost dominates its ranking.
"""
import os
import subprocess
import sys
import time

bins, data, node_modules, pkg_bench = sys.argv[1:5]
N = int(sys.argv[5]) if len(sys.argv) > 5 else 2000
impls = {"pion": [f"{bins}/pion_jsonschema"], "rust_jsonschema": [f"{bins}/rust_jsonschema"],
         "node_ajv": ["node", f"{pkg_bench}/node_bench/bench.js"]}
env = dict(os.environ, NODE_PATH=node_modules)


def med(cmd):
    ts = []
    for _ in range(5):
        t = time.perf_counter()
        subprocess.run(cmd, capture_output=True, env=env, check=True)
        ts.append((time.perf_counter() - t) * 1000)
    return sorted(ts)[2]


for w, n in (("w1", 500), ("w2", 200)):
    args = ["batch", f"{data}/{w}_schema.json", f"{data}/{w}_instances.jsonl"]
    row = {}
    for k, c in impls.items():
        f0 = med(c + args + ["0"])  # bench.js maps 0 -> 1 iteration: negligible
        fN = med(c + args + [str(N)])
        row[k] = (f0, (fN - f0) * 1e6 / (n * N))
    base = row["rust_jsonschema"][1]
    print(f"  {w}: " + "  ".join(f"{k}: fixed {f0:.1f} ms, steady {ns:.0f} ns/op ({base / ns:.2f}x vs rust)"
                                  for k, (f0, ns) in row.items()))
