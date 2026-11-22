#!/usr/bin/env python3
"""Deterministic inputs for the red-team fairness benchmarks: ISO 8601 durations and IMF-fixdate HTTP-dates."""
import email.utils, random, sys

def main():
    out_dir, n = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 200000
    rng = random.Random(20261123)
    with open(f"{out_dir}/durations.txt", "w") as f:
        for _ in range(n):
            h, m, s = rng.randrange(0, 200000), rng.randrange(0, 60), rng.randrange(0, 60)
            frac = rng.choice(["", ".5", ".123", ".000456", ".123456789", ".000000001", ".25"])
            parts = []
            if rng.random() < 0.8: parts.append(f"{h}H")
            if rng.random() < 0.8: parts.append(f"{m}M")
            parts.append(f"{s}{frac}S")
            f.write(("-" if rng.random() < 0.3 else "") + "PT" + "".join(parts) + "\n")
    with open(f"{out_dir}/http_dates.txt", "w") as f:
        for _ in range(n):
            f.write(email.utils.formatdate(rng.randrange(0, 4102444800), usegmt=True) + "\n")

main()
