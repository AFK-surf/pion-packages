#!/usr/bin/env python3
"""Run every DoS probe through Pion / Rust / ajv with a timeout; report verdict, wall time and peak RSS.
Cell format: VERDICT[compile/is_valid/validate ms] wall peakRSS   (ajv: [total ms]).

usage: run_dos.py <probe_dir> --pion CMD --rust CMD --node CMD [--timeout S] [--only SUBSTR]
"""
import argparse
import os
import re
import subprocess
import time

ap = argparse.ArgumentParser()
ap.add_argument("dir")
ap.add_argument("--pion", required=True)
ap.add_argument("--rust", required=True)
ap.add_argument("--node", required=True)
ap.add_argument("--timeout", type=float, default=60)
ap.add_argument("--only", default="")
a = ap.parse_args()


def run(cmd, path):
    t0 = time.time()
    try:
        p = subprocess.run(f"/usr/bin/time -l {cmd} {path}", shell=True, capture_output=True, text=True,
                           timeout=a.timeout)
    except subprocess.TimeoutExpired:
        return f"TIMEOUT>{a.timeout:.0f}s", "-", "-"
    wall = time.time() - t0
    m = re.search(r"(\d+)\s+maximum resident set size", p.stderr)
    rss = f"{int(m.group(1)) / 1048576:.0f}MB" if m else "?"
    line = p.stdout.strip().splitlines()
    if p.returncode != 0 or not line:
        sig = -p.returncode if p.returncode < 0 else p.returncode
        tail = (p.stderr.strip().splitlines() or ["?"])[0][:40]
        return f"CRASH(rc={sig}:{tail})", f"{wall:.2f}s", rss
    v = line[-1].split("\t")
    return f"{v[1][:14]}[{v[3]}]", f"{wall:.2f}s", rss


index = [l.rstrip("\n").split("\t") for l in open(os.path.join(a.dir, "INDEX.tsv"))]
print(f"  {'probe':<26} {'pion':<42} {'rust':<42} {'node':<34}")
for name, desc in index:
    if a.only and a.only not in name:
        continue
    path = os.path.join(a.dir, name + ".jsonl")
    cells = []
    for cmd in (a.pion, a.rust, a.node):
        v, w, r = run(cmd, path)
        cells.append(f"{v} {w} {r}")
    print(f"  {name:<26} {cells[0]:<42} {cells[1]:<42} {cells[2]:<34}", flush=True)
