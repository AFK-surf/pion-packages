#!/usr/bin/env python3
"""Complexity probe: wall time + peak RSS of pion vs Rust on growing adversarial inputs.

usage: python3 -I scaling.py BIN_DIR ADV_DIR [OUT_MD]

For each series the input grows 2x per step; a linear implementation's time/RSS grows ~2x,
a quadratic one ~4x. Output stdout of both sides must match (same counts) or the row is flagged.
"""
import os
import resource
import subprocess
import sys
import time

BIN, ADV = sys.argv[1], sys.argv[2]
OUT = sys.argv[3] if len(sys.argv) > 3 else None


def measure_rss(cmd):
    """Run cmd, return (stdout, seconds, peak RSS MiB) using wait4 rusage of that child only."""
    t0 = time.perf_counter()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    out = p.stdout.read()
    _, _, ru = os.wait4(p.pid, 0)
    dt = time.perf_counter() - t0
    rss = ru.ru_maxrss / (1024 * 1024) if sys.platform == "darwin" else ru.ru_maxrss / 1024
    return out, dt, rss


series = [
    ("P0-1 Text/CDATA merge (DOM)", "dom", "rust_perf", "dom", sorted(
        (f for f in os.listdir(ADV) if f.startswith("merge_") and f[6:-4].isdigit()), key=lambda f: int(f[6:-4]))),
]

rows = ["| series | input | bytes | pion ms | pion peak RSS | Rust ms | Rust peak RSS | stdout equal |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | :---: |"]
for title, pmode, rtool, rmode, files in series:
    for f in files:
        path = os.path.join(ADV, f)
        # one untimed warm-up of each binary (page cache / first-exec cost)
        measure_rss([os.path.join(BIN, "pion_perf"), pmode, path, "1"])
        measure_rss([os.path.join(BIN, rtool), rmode, path, "1"])
        po, pt, pr = measure_rss([os.path.join(BIN, "pion_perf"), pmode, path, "1"])
        ro, rt, rr = measure_rss([os.path.join(BIN, rtool), rmode, path, "1"])
        rows.append("| %s | `%s` | %d | %.1f | %.1f MiB | %.1f | %.1f MiB | %s |" % (
            title, f, os.path.getsize(path), pt * 1000, pr, rt * 1000, rr, "yes" if po == ro else "**NO**"))
text = "\n".join(rows)
print(text)
if OUT:
    with open(OUT, "w") as fh:
        fh.write(text + "\n")
