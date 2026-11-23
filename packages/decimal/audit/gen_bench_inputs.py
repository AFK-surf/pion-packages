#!/usr/bin/env python3
"""Inputs for the adversarial benchmarks (deterministic).

usage: gen_bench_inputs.py <out_dir>
  sci_50k.txt     50,000 scientific-notation strings valid for both sides (<= 20 mantissa digits,
                  exponent -28..+12, total scale <= 28, no value-dependent parser quirks)
  random_50k.txt  50,000 distinct 2dp amounts in random order (baseline for the sort killer)
"""
import os
import random
import sys

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
r = random.Random(1372)
with open(os.path.join(out, "sci_50k.txt"), "w") as f:
    for _ in range(50_000):
        digits = r.randint(1, 20)
        mant = str(r.randint(10 ** (digits - 1), 10 ** digits - 1))
        dot = r.randint(0, min(digits - 1, 8))
        m = mant if dot == 0 else mant[:-dot] + "." + mant[-dot:]
        exp = r.randint(-(28 - dot), min(12, 28 - digits + dot))
        f.write(("-" if r.random() < 0.3 else "") + m + r.choice("eE") + str(exp) + "\n")
vals = list(range(50_000))
r.shuffle(vals)
with open(os.path.join(out, "random_50k.txt"), "w") as f:
    for v in vals:
        f.write(f"{1000 + v}.{v % 100:02d}\n")
