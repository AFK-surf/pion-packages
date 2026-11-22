#!/usr/bin/env python3
"""Deterministic data generator for packages/uuid benchmarks."""

import os
import sys

CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def splitmix64(x: int) -> int:
    x = (x + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
    z = x
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
    return z ^ (z >> 31)


def gen_uuids(path: str, count: int) -> None:
    state = 0x123456789ABCDEF0
    lines = []
    for i in range(count):
        state = (state + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        hi = splitmix64(state)
        state = (state + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        lo = splitmix64(state)
        # Set RFC 9562 v4 / variant bits for realistic UUIDs
        hi = (hi & 0xFFFFFFFFFFFF0FFF) | 0x0000000000004000
        lo = (lo & 0x3FFFFFFFFFFFFFFF) | 0x8000000000000000
        h = f"{hi:016x}{lo:016x}"
        hyph = f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"
        m = i % 20
        if m < 14:
            lines.append(hyph)
        elif m < 16:
            lines.append(hyph.upper())
        elif m < 18:
            lines.append(h)
        elif m == 18:
            lines.append("{" + hyph + "}")
        else:
            lines.append("urn:uuid:" + hyph)
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def encode_ulid(hi: int, lo: int) -> str:
    val = (hi << 64) | lo
    chars = ["0"] * 26
    for idx in range(25, -1, -1):
        chars[idx] = CROCKFORD[val & 31]
        val >>= 5
    return "".join(chars)


def gen_ulids(path: str, count: int) -> None:
    state = 0xCAFEBABE1337C0DE
    lines = []
    for i in range(count):
        state = (state + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        r1 = splitmix64(state)
        state = (state + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        lo = splitmix64(state)
        ts = (1700000000000 + (r1 & 0xFFFFFFFFFF)) & 0xFFFFFFFFFFFF
        hi = (ts << 16) | ((r1 >> 40) & 0xFFFF)
        s = encode_ulid(hi, lo)
        if (i & 7) == 7:
            s = s.lower()
        lines.append(s)
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: gen_data.py <out_dir> <count>", file=sys.stderr)
        return 1
    out_dir = sys.argv[1]
    count = int(sys.argv[2])
    os.makedirs(out_dir, exist_ok=True)
    gen_uuids(os.path.join(out_dir, f"uuids_{count}.txt"), count)
    gen_ulids(os.path.join(out_dir, f"ulids_{count}.txt"), count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
