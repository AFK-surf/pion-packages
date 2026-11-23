#!/usr/bin/env python3
"""Line-by-line differential: Pion `cli` vs Rust clap 4.5.32 (reference) vs Go pflag 1.0.6 (secondary).

usage: compare.py cases.json pion.out rust.out [go.out]
Prints every case where Pion != clap, with pflag's answer for context, and a summary.
"""
import json, sys

cases = json.load(open(sys.argv[1]))
def load(p):
    d = {}
    for line in open(p, encoding="utf-8", errors="replace"):
        n, _, r = line.rstrip("\n").partition("\t")
        d[int(n)] = r
    return d
pion, rust = load(sys.argv[2]), load(sys.argv[3])
go = load(sys.argv[4]) if len(sys.argv) > 4 else {}
diff = 0
for i, (spec, env, argv) in enumerate(cases):
    p, r = pion.get(i, "<missing>"), rust.get(i, "<missing>")
    if p != r:
        diff += 1
        envs = " ".join(f"{k}={v!r}" for k, v in env.items())
        print(f"#{i} [{spec}] {envs + ' ' if envs else ''}argv={argv!r}")
        print(f"    pion : {p}")
        print(f"    clap : {r}")
        if spec == "basic" and go:
            print(f"    pflag: {go.get(i)}")
print(f"\nSUMMARY: {diff}/{len(cases)} cases differ from clap 4.5.32")
print("RESULT: " + ("PASS" if diff == 0 else "DIVERGENT"))
