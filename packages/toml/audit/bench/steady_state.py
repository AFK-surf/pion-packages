#!/usr/bin/env python3
"""B2 evidence: per-parse cost vs number of parses in one process (parse only, no tree walk).
usage: steady_state.py <bin dir> <file.toml>"""
import subprocess, sys, time

bindir, f = sys.argv[1], sys.argv[2]
for it in (1, 10, 30):
    for b in ("pion_cli", "rust_ref"):
        best = 1e9
        for _ in range(3):
            t = time.perf_counter()
            subprocess.run([f"{bindir}/{b}", "bench-parse-only", f, str(it)], capture_output=True, check=True)
            best = min(best, time.perf_counter() - t)
        print(f"  {b:9s} parses/process={it:3d}  {best * 1000 / it:7.1f} ms/parse")
