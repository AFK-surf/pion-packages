#!/usr/bin/env python3
"""Generate deterministic mixed decimal corpus (50,000 lines) for packages/decimal benchmarks."""

import os
import sys


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/pion-decimal-bench"
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "decimals_50k.txt")

    # Deterministic LCG so corpus is 100% reproducible across machines
    state = 0x123456789ABCDEF0

    def next_u64() -> int:
        nonlocal state
        state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 64) - 1)
        return state

    lines = []
    n = 50_000
    for i in range(n):
        r = next_u64()
        kind = i % 10
        sign = "-" if (r & 1) == 1 else ""
        r >>= 1
        if kind < 4:
            # Typical currency / invoice amounts (2 dp): e.g. 1299.99, -42.50
            whole = r % 1_000_000
            frac = (r >> 20) % 100
            lines.append(f"{sign}{whole}.{frac:02d}")
        elif kind < 6:
            # Token / micro-billing rates (6 dp): e.g. 0.000015, 12.345678
            whole = r % 100
            frac = (r >> 10) % 1_000_000
            lines.append(f"{sign}{whole}.{frac:06d}")
        elif kind == 6:
            # Integer quantities / counts
            whole = r % 100_000_000
            lines.append(f"{sign}{whole}")
        elif kind == 7:
            # FX / interest rates (8 dp)
            whole = r % 10
            frac = (r >> 8) % 100_000_000
            lines.append(f"{sign}{whole}.{frac:08d}")
        elif kind == 8:
            # Large 64-bit / 96-bit ledger balances (4 dp)
            hi = (r % 900_000_000) + 100_000_000
            lo = (r >> 30) % 1_000_000_000
            frac = (r >> 12) % 10_000
            lines.append(f"{sign}{hi}{lo:09d}.{frac:04d}")
        else:
            # High-precision 18-digit fraction
            whole = r % 1000
            f1 = (r >> 10) % 1_000_000_000
            f2 = (next_u64() >> 10) % 1_000_000_000
            lines.append(f"{sign}{whole}.{f1:09d}{f2:09d}")

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
        f.write("\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
