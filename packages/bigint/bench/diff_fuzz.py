#!/usr/bin/env python3
"""Differential fuzzer for packages/bigint against Python arbitrary-precision int.

Tests truncating division toward zero (sign * (abs(a) // abs(b))), addition, subtraction,
multiplication, bitwise AND/OR/XOR/NOT (two's complement), shifts (flooring right shift),
GCD, radix 16/36 formatting, and single-limb fast paths across 600+ deterministic random
and adversarial cases on both Native and Wasm32 builds.
"""

import math
import os
import random
import subprocess
import sys
import tempfile


def trunc_div_rem(a: int, b: int):
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    r = a - q * b
    return q, r


def to_radix(n: int, base: int) -> str:
    if n == 0:
        return "0"
    neg = n < 0
    v = -n if neg else n
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = []
    while v > 0:
        out.append(digits[v % base])
        v //= base
    if neg:
        out.append("-")
    return "".join(reversed(out))


def gen_cases():
    rng = random.Random(20261125)
    specials = [
        0, 1, -1, 2, -2, 3, -3, 7, -7, 13, -13,
        (1 << 31) - 1, -(1 << 31), (1 << 31), (1 << 32) - 1, -(1 << 32), (1 << 32),
        (1 << 63) - 1, -(1 << 63), (1 << 63), (1 << 64) - 1, -(1 << 64), (1 << 64),
        (1 << 128) - 1, -(1 << 128), (1 << 128) + 1,
        0x7fffffff800000000000000000000000,
        0x80000000ffffffffffffffff,
        0x80000000ffffffff00000001,
        0xffffffffffffffffffffffffffffffff,
        0x10000000100000001,
    ]
    cases = []
    expected = []

    # Pairwise adversarial specials (subset)
    for i in range(len(specials)):
        a = specials[i]
        b = specials[(i * 7 + 3) % len(specials)]
        sh = (i * 13) % 130
        cases.append(f"bin\t{a}\t{b}\t{sh}")
        expected.append(oracle_bin(a, b, sh))

    # 450 randomized multi-limb cases (0..1024 bits, all sign combos)
    for idx in range(450):
        ba = rng.choice([0, 1, 8, 31, 32, 33, 63, 64, 65, 96, 128, 192, 256, 384, 512, 768, 1024])
        bb = rng.choice([0, 1, 8, 31, 32, 33, 63, 64, 65, 96, 128, 192, 256, 384, 512])
        a = rng.getrandbits(ba) if ba > 0 else 0
        b = rng.getrandbits(bb) if bb > 0 else 0
        if rng.random() < 0.5:
            a = -a
        if rng.random() < 0.5:
            b = -b
        sh = rng.choice([0, 1, 2, 15, 31, 32, 33, 63, 64, 65, 100, 200])
        cases.append(f"bin\t{a}\t{b}\t{sh}")
        expected.append(oracle_bin(a, b, sh))

    # 150 single-limb fast-path cases
    for idx in range(150):
        ba = rng.choice([0, 1, 31, 32, 64, 128, 256, 512])
        bb = rng.choice([0, 1, 31, 32, 64, 128, 256])
        a = rng.getrandbits(ba) if ba > 0 else 0
        b = rng.getrandbits(bb) if bb > 0 else 0
        if rng.random() < 0.5:
            a = -a
        if rng.random() < 0.5:
            b = -b
        k = rng.choice([0, 1, -1, 2, -2, 7, -7, 1000000000, -1000000000, 2147483647, -2147483647, rng.randint(-1000000, 1000000)])
        cases.append(f"small\t{a}\t{b}\t{k}")
        expected.append(oracle_small(a, b, k))

    return cases, expected


def oracle_bin(a: int, b: int, sh: int) -> str:
    if b != 0:
        q, r = trunc_div_rem(a, b)
        div_str = f"{q},{r}"
    else:
        div_str = "DIV0"
    return "|".join([
        str(a + b),
        str(a - b),
        str(a * b),
        div_str,
        str(a & b),
        str(a | b),
        str(a ^ b),
        str(math.gcd(abs(a), abs(b))),
        str(a << sh),
        str(a >> sh),
        str(~a),
        to_radix(a, 16),
        to_radix(a, 36),
    ])


def oracle_small(a: int, b: int, k: int) -> str:
    d = 1 if k == 0 else abs(k)
    q = abs(a) // d
    if a < 0:
        q = -q
    r = abs(a) % d
    return "|".join([
        str(a + k),
        str(a * k),
        str(a + b * k),
        f"{q},{r}",
    ])


def main():
    if len(sys.argv) < 2:
        print("usage: diff_fuzz.py <native_bin> [wasm_cmd...]", file=sys.stderr)
        return 2
    native_bin = sys.argv[1]
    wasm_cmd = sys.argv[2:] if len(sys.argv) > 2 else None

    cases, expected = gen_cases()
    with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as f:
        f.write("\n".join(cases) + "\n")
        case_file = f.name

    try:
        for label, cmd in [("native", [native_bin, case_file])] + ([("wasm32", wasm_cmd + [case_file])] if wasm_cmd else []):
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if proc.returncode != 0:
                print(f"FAIL [{label}]: exit {proc.returncode}\n{proc.stderr}", file=sys.stderr)
                return 1
            got = proc.stdout.splitlines()
            if len(got) != len(expected):
                print(f"FAIL [{label}]: expected {len(expected)} lines, got {len(got)}", file=sys.stderr)
                return 1
            mismatches = 0
            for idx, (g, e) in enumerate(zip(got, expected)):
                if g != e:
                    print(f"MISMATCH [{label}] case #{idx}: {cases[idx]}", file=sys.stderr)
                    print(f"  expected: {e}", file=sys.stderr)
                    print(f"  got:      {g}", file=sys.stderr)
                    mismatches += 1
                    if mismatches >= 5:
                        break
            if mismatches > 0:
                return 1
            print(f"PASS [{label}]: {len(cases)} cases ({len(cases)*12}+ ops) 0 mismatches")
    finally:
        os.unlink(case_file)
    return 0


if __name__ == "__main__":
    sys.exit(main())
