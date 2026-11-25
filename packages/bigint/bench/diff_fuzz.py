#!/usr/bin/env python3
"""Differential fuzzer for packages/bigint against Python arbitrary-precision int.

Uses boundary-limb-biased generation (0, 1, 2, 0x7FFFFFFF, 0x80000000, 0x80000001,
0xFFFFFFFE, 0xFFFFFFFF) covering div/rem/div_rem (truncating toward zero), pow,
radix 2..36 roundtrips, from_hex, to_int/to_int64/to_uint64/bit_len/signum roundtrips,
shifts, two's-complement bitwise ops, gcd/cmp/add/sub/mul, single-limb fast paths,
all BigIntBuf methods (including div_small_uint valid + >= 2^32 overflow cases), and
strict parse rejection on both Native and Wasm32 builds.
"""

import math
import os
import random
import subprocess
import sys
import tempfile

LIMBS = [0, 1, 2, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFE, 0xFFFFFFFF]
DIG = "0123456789abcdefghijklmnopqrstuvwxyz"


def tdiv(a: int, b: int):
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return q, a - q * b


def to_radix(n: int, base: int) -> str:
    if n == 0:
        return "0"
    s = "-" if n < 0 else ""
    v = abs(n)
    o = []
    while v:
        o.append(DIG[v % base])
        v //= base
    return s + "".join(reversed(o))


def opt(v: int, lo: int, hi: int) -> str:
    return str(v) if lo <= v <= hi else "N"


def gen_cases(seed: int = 20261125, n_div: int = 3000, maxl: int = 6):
    rng = random.Random(seed)

    def rlimb():
        if rng.random() < 0.6:
            return rng.choice(LIMBS)
        return rng.getrandbits(32)

    def rnum(ml=8, allow0=True):
        n = rng.randint(0 if allow0 else 1, ml)
        v = 0
        for i in range(n):
            v |= rlimb() << (32 * i)
        if not allow0 and v == 0:
            v = rng.getrandbits(32) | 1
        if rng.random() < 0.5:
            v = -v
        return v

    cases = []
    exp = []
    op_count = 0

    def add(cols, expected_str, ops_in_case):
        nonlocal op_count
        cases.append("\t".join(cols))
        exp.append(expected_str)
        op_count += ops_in_case

    # 1. Adversarial division (div, div_rem, rem) + Knuth D6 add-back
    for u_d6, v_d6 in [
        ((1 << 96) + 1, (1 << 95) + 1),
        (-((1 << 96) + 1), (1 << 95) + 1),
        ((1 << 96) + 1, -((1 << 95) + 1)),
        (-((1 << 96) + 1), -((1 << 95) + 1)),
    ]:
        q, r = tdiv(u_d6, v_d6)
        add(["dr", str(u_d6), str(v_d6)], f"{q}|{q}|{r}|{r}", 4)

    for _ in range(n_div):
        b = rnum(maxl, False)
        kind = rng.random()
        if kind < 0.3:
            q = rnum(4, True)
            r = rng.randint(0, abs(b) - 1) if abs(b) > 1 else 0
            a = q * b + (r if q * b >= 0 else -r)
        elif kind < 0.5:
            a = b * rng.choice([1, 2, 0xFFFFFFFF, 0x100000000, 0xFFFFFFFFFFFFFFFF]) + rng.choice([-1, 0, 1])
        else:
            a = rnum(maxl + 4)
        q, r = tdiv(a, b)
        add(["dr", str(a), str(b)], f"{q}|{q}|{r}|{r}", 4)

    # 2. Bitwise, arithmetic, shifts, radix 2..36, conversions, single-limb fast paths, BigIntBuf
    for _ in range(n_div // 3):
        a = rnum(6)
        b = rnum(6)
        bw = (
            f"{a & b}|{a | b}|{a ^ b}|{~a}|{math.gcd(abs(a), abs(b))}|"
            f"{(a > b) - (a < b)}|{a + b}|{a - b}|{a * b}"
        )
        add(["bw", str(a), str(b)], bw, 9)

        k = rng.choice([0, 1, 31, 32, 33, 63, 64, 65, 100, 257, rng.randint(0, 400)])
        add(["sh", str(a), str(k)], f"{a << k}|{a >> k}", 2)

        rr = rng.randint(2, 36)
        add(["rx", str(a), str(rr)], to_radix(a, rr), 2)  # to_radix + from_radix roundtrip

        add(
            ["cv", str(a)],
            f"{opt(a, -2**31, 2**31 - 1)}|{opt(a, -2**63, 2**63 - 1)}|{opt(a, 0, 2**64 - 1)}|{abs(a).bit_length()}|{(a > 0) - (a < 0)}",
            5,
        )

        ki = rng.choice([0, 1, -1, 2**31 - 1, -2**31, rng.randint(-2**31, 2**31 - 1)])
        du = rng.choice([1, 2, 10, 10**9, 0xFFFFFFFF, 0x80000000, rng.randint(1, 2**32 - 1)])
        qd = abs(a) // du
        qd = -qd if a < 0 else qd
        add(
            ["sm", str(a), str(b), str(ki), str(du)],
            f"{a + ki}|{a * ki}|{a + b * ki}|{a * du}|{qd},{abs(a) % du}",
            5,
        )

        ku = rng.choice([0, 1, 2, 10, 0xFFFFFFFF, rng.randint(0, 2**32 - 1)])
        x1 = a + b * ku - b * ku
        add(
            ["buf", str(a), str(b), str(ku)],
            f"{a - b * ku}|{a * ku}|{a + b}|{a - b}|{b}|{x1}|{((a + b) > (a - b)) - ((a + b) < (a - b))}",
            8,
        )

    # 3. Exponentiation
    for _ in range(200):
        a = rnum(3)
        e = rng.randint(-2, 40)
        add(["pw", str(a), str(e)], "E:negexp" if e < 0 else str(a ** e), 1)

    # 4. BigIntBuf::div_small_uint (both valid <= 0xFFFFFFFF and overflow >= 2^32 -> None)
    for _ in range(n_div // 3):
        d = abs(rnum(6, False))
        if rng.random() < 0.7:
            q = rng.choice([0, 1, 2, 3, 9, 0xFFFFFFFF, rng.getrandbits(32)])
        else:
            q = rng.choice([0x100000000, 0x100000001, 0x123456789abcdef, rng.getrandbits(48) | (1 << 32)])
        a = d * q + rng.randint(0, d - 1)
        if rng.random() < 0.5:
            a = -a
        true_q = abs(a) // d
        add(["dsu", str(a), str(d)], str(true_q) if true_q <= 0xFFFFFFFF else "N", 1)

    # 5. Strict parse rejection & edge inputs
    for s, r, e in [
        ("", 10, "E:empty"), ("+", 10, "E:digit"), ("-", 10, "E:digit"),
        (" 1", 10, "E:digit"), ("1 ", 10, "E:digit"), ("1_0", 10, "E:digit"),
        ("-0", 10, "0"), ("+000", 10, "0"), ("--1", 10, "E:digit"), ("+-1", 10, "E:digit"),
        ("12a", 10, "E:digit"), ("zz", 36, str(35 * 36 + 35)), ("ZZ", 36, str(35 * 36 + 35)),
        ("2", 2, "E:digit"), ("1", 1, "E:radix"), ("1", 37, "E:radix"),
        ("é", 10, "E:digit"), ("0", 2, "0"),
        ("-" + "9" * 100, 10, "-" + "9" * 100),
        ("1" + "0" * 200, 10, "1" + "0" * 200),
        ("0x10", 16, "E:digit"),
    ]:
        add(["ps", s, str(r)], e, 1)

    for s, e in [
        ("0x", "E:digit"), ("-0x", "E:digit"), ("0X1F", "31"), ("-0x0", "0"),
        ("ff", "255"), ("0x-1", "E:digit"), ("0xx1", "E:digit"), ("", "E:empty"),
        ("-", "E:digit"), ("0", "0"), ("00x1", "E:digit"),
    ]:
        add(["hx", s], e, 1)

    return cases, exp, op_count


def main():
    if len(sys.argv) < 2:
        print("usage: diff_fuzz.py <native_bin> [wasm_cmd...]", file=sys.stderr)
        return 2
    native_bin = sys.argv[1]
    wasm_cmd = sys.argv[2:] if len(sys.argv) > 2 else None

    cases, expected, total_ops = gen_cases()
    with tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False) as f:
        f.write("\n".join(cases) + "\n")
        case_file = f.name

    try:
        targets = [("native", [native_bin, case_file])]
        if wasm_cmd:
            targets.append(("wasm32", wasm_cmd + [case_file]))
        for label, cmd in targets:
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
            print(f"PASS [{label}]: {len(cases)} cases, 0 mismatches")
    finally:
        os.unlink(case_file)
    return 0


if __name__ == "__main__":
    sys.exit(main())
