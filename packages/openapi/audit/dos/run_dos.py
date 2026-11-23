#!/usr/bin/env python3
"""Run every DoS probe stage through Pion (and Go kin-openapi where the stage exists) with a timeout + RSS cap.

usage: run_dos.py <probe_dir> --pion CMD [--go CMD] [--timeout S] [--rss-mb N] [--only SUBSTR] [--tsv OUT]
Cell: VERDICT wall peakRSS. A Pion cell is a DEFECT when it crashed (signal / trap / non-zero rc),
timed out, or exceeded --rss-mb (default 1024 MiB) under default OpenApiLimits.
Exit code: 1 when any Pion cell is a DEFECT, else 0.
"""
import argparse
import os
import re
import subprocess
import time

ap = argparse.ArgumentParser()
ap.add_argument("dir")
ap.add_argument("--pion", required=True)
ap.add_argument("--go", default="")
ap.add_argument("--timeout", type=float, default=60)
ap.add_argument("--rss-mb", type=float, default=1024)
ap.add_argument("--only", default="")
ap.add_argument("--tsv", default="")
a = ap.parse_args()


def run(cmd, args):
    t0 = time.time()
    try:
        p = subprocess.run(f"/usr/bin/time -l {cmd} {args}", shell=True, capture_output=True, text=True,
                           timeout=a.timeout)
    except subprocess.TimeoutExpired:
        return "TIMEOUT", a.timeout, None, True
    wall = time.time() - t0
    m = re.search(r"(\d+)\s+maximum resident set size", p.stderr)
    rss = int(m.group(1)) / 1048576 if m else None
    lines = p.stdout.strip().splitlines()
    if p.returncode != 0 or not lines:
        tail = [l for l in p.stderr.strip().splitlines() if "maximum resident" not in l and l.strip()]
        return f"CRASH(rc={p.returncode}:{(tail or ['?'])[0][:48]})", wall, rss, True
    v = lines[-1].split("\t")
    verdict = (v[1] + (" " + v[2] if len(v) > 2 else ""))[:60]
    return verdict, wall, rss, rss is not None and rss > a.rss_mb


rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(a.dir, "INDEX.tsv"), encoding="utf-8")]
defects = 0
tsv = []
print(f"  {'probe':<22} {'stage':<10} {'pion (default limits)':<70} {'go kin-openapi':<50}")
for name, fn, stages, op_id, path, desc in rows:
    if a.only and a.only not in name:
        continue
    spec = os.path.join(a.dir, fn)
    for st in stages.split(","):
        if "@" in st:
            continue
        pv, pw, pr, bad = run(a.pion, f"{st} {spec} {op_id} '{path}'")
        cell_p = f"{pv} {pw:.2f}s {pr:.0f}MB" if pr is not None else f"{pv} {pw:.2f}s"
        if bad:
            defects += 1
            cell_p = "DEFECT " + cell_p
        cell_g = "-"
        if a.go and st in ("parse", "validate", "from_doc"):
            gv, gw, gr, _ = run(a.go, f"{st} {spec}")
            cell_g = f"{gv[:30]} {gw:.2f}s {gr:.0f}MB" if gr is not None else f"{gv[:30]} {gw:.2f}s"
        print(f"  {name:<22} {st:<10} {cell_p:<70} {cell_g:<50}", flush=True)
        tsv.append("\t".join([name, st, cell_p, cell_g, desc]))
if a.tsv:
    with open(a.tsv, "w", encoding="utf-8") as f:
        f.write("\n".join(tsv) + "\n")
print(f"  DoS defects (crash / timeout / >{a.rss_mb:.0f}MB RSS under default limits): {defects}")
raise SystemExit(1 if defects else 0)
