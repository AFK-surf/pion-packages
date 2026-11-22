#!/usr/bin/env python3
"""Adversarial / DoS performance corpora for the semver red-team audit (deterministic).

Usage: gen_perf.py <out_dir>
Writes:
  long_pre.txt     200 versions, each with a ~10k-segment prerelease + build (~60 KB/line)
  scale_<N>.txt    one version whose prerelease is N bytes (N = 10k, 100k, 1M) for O(N) checks
  long_cmp.txt     400 long prerelease versions differing only in the last segment (cmp mode)
  req32.txt        20k requirements with 32 comparators each (half with prereleases)
  dirty.txt        100k malformed version / requirement strings (error paths)
"""

import os
import random
import sys


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    r = random.Random(424242)

    with open(os.path.join(out, "long_pre.txt"), "w") as f:
        for i in range(200):
            segs = [r.choice(["a1", "1", "beta", "x-y", "0", "rc"]) for _ in range(10000)]
            build = ".".join(r.choice(["001", "sha", "a-b"]) for _ in range(5000))
            f.write(f"{i}.0.0-{'.'.join(segs)}+{build}\n")

    for n in (10_000, 100_000, 1_000_000):
        seg = "alpha1."
        pre = (seg * (n // len(seg) + 1))[:n].strip(".")
        with open(os.path.join(out, f"scale_{n}.txt"), "w") as f:
            f.write(f"1.0.0-{pre}\n")

    with open(os.path.join(out, "long_cmp.txt"), "w") as f:
        base = ".".join(r.choice(["a", "1", "b2"]) for _ in range(5000))
        for i in range(400):
            f.write(f"1.0.0-{base}.{r.randint(0, 50)}\n")

    ops = ["", "=", ">", ">=", "<", "<=", "~", "^"]
    with open(os.path.join(out, "req32.txt"), "w") as f:
        for i in range(20000):
            cs = []
            for _ in range(32):
                c = f"{r.choice(ops)}{r.randint(0, 3)}.{r.randint(0, 9)}.{r.randint(0, 9)}"
                if i % 2 == 0 and r.random() < 0.5:
                    c += f"-alpha.{r.randint(0, 9)}"
                cs.append(c)
            f.write(", ".join(cs) + "\n")

    alph = "0123456789.-+*xX^~<>=, abz\t"
    with open(os.path.join(out, "dirty.txt"), "w") as f:
        for _ in range(100000):
            n = r.randint(1, 40)
            f.write("".join(r.choice(alph) for _ in range(n)).replace("\n", "") + "\n")


if __name__ == "__main__":
    main()
