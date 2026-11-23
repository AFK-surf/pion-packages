#!/usr/bin/env python3
"""Run Pion / Rust jsonschema 0.29.1 / ajv 8.17.1 over a cases JSONL file and compare.

usage: run_diff.py <cases.jsonl> <out_prefix> --pion CMD --rust CMD --node CMD [--timeout S] [--quiet]
Each CMD is a shell command prefix; the cases path is appended.
Writes <out_prefix>.<impl>.tsv (raw transcripts) and <out_prefix>.report.txt (every disagreement).
Prints a one-screen summary.
"""
import argparse
import json
import shlex
import subprocess
import sys

ap = argparse.ArgumentParser()
ap.add_argument("cases")
ap.add_argument("out")
ap.add_argument("--pion", required=True)
ap.add_argument("--rust", required=True)
ap.add_argument("--node", required=True)
ap.add_argument("--timeout", type=float, default=600)
ap.add_argument("--quiet", action="store_true")
a = ap.parse_args()

cases = [json.loads(l) for l in open(a.cases) if l.strip()]
ids = [c["id"] for c in cases]


def run(name, cmd):
    try:
        p = subprocess.run(cmd + " " + shlex.quote(a.cases), shell=True, capture_output=True,
                           text=True, timeout=a.timeout)
        txt, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        txt, rc = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "TIMEOUT"
    open(f"{a.out}.{name}.tsv", "w").write(txt)
    res = {}
    for line in txt.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            res[parts[0]] = {"is": parts[1], "val": parts[2], "ms": parts[3] if len(parts) > 3 else "?"}
    return res, rc


R = {}
RC = {}
for name, cmd in (("pion", a.pion), ("rust", a.rust), ("node", a.node)):
    R[name], RC[name] = run(name, cmd)


def verdict(r):
    if r is None:
        return "CRASH"
    v = r["is"]
    return "E" if v.startswith("E") else v


lines = []
stats = {k: 0 for k in ("pion", "rust", "node")}
n_exp = sum(1 for c in cases if "expect" in c)
pion_vs_rust = pion_vs_node = pion_inconsistent = 0
for c in cases:
    cid = c["id"]
    pv = {k: verdict(R[k].get(cid)) for k in R}
    exp = c.get("expect")
    if exp:
        for k in pv:
            stats[k] += pv[k] == exp
    pr = R["pion"].get(cid)
    incons = pr is not None and not pr["is"].startswith("E") and pr["is"] != pr["val"]
    pion_inconsistent += incons
    pion_vs_rust += pv["pion"] != pv["rust"]
    pion_vs_node += pv["pion"] != pv["node"]
    pion_wrong = exp is not None and pv["pion"] != exp
    if pion_wrong or pv["pion"] != pv["rust"] or incons:
        tag = []
        if exp is not None:
            tag.append("PION-WRONG" if pion_wrong else "pion-ok")
            tag.append("rust-ok" if pv["rust"] == exp else "RUST-WRONG")
            tag.append("node-ok" if pv["node"] == exp else "NODE-WRONG")
        if incons:
            tag.append("IS_VALID!=VALIDATE")
        detail = " | ".join(f"{k}={R[k].get(cid, {}).get('is', 'CRASH')}" for k in R)
        lines.append(f"{cid}\texpect={exp}\t{detail}\t{' '.join(tag)}\t{c.get('desc', '')}")

open(f"{a.out}.report.txt", "w").write("\n".join(lines) + ("\n" if lines else ""))
n = n_exp
print(f"  cases={len(cases)} (with spec verdict: {n})", end="")
if n:
    print(f"  pass: pion={stats['pion']}/{n} ({100*stats['pion']/n:.2f}%)  "
          f"rust={stats['rust']}/{n} ({100*stats['rust']/n:.2f}%)  node={stats['node']}/{n} ({100*stats['node']/n:.2f}%)", end="")
print()
print(f"  disagreements: pion!=rust {pion_vs_rust}  pion!=node {pion_vs_node}  "
      f"pion is_valid!=validate {pion_inconsistent}  exit codes {RC}")
if not a.quiet:
    for l in lines[:400]:
        print("   ", l[:260])
