#!/usr/bin/env python3
"""Deterministic red-team corpus generator for the semver differential audit.

Every output line is `<K> <hex>[ <hex>]` (UTF-8, hex-encoded so NUL / whitespace /
multi-byte input survives the line format). Kinds:

  V  Version::parse            R  VersionReq::parse         C  Comparator::parse
  P  Prerelease::new           B  BuildMetadata::new
  M  VersionReq::matches(req, ver)                            K  Comparator::matches(cmp, ver)
  O  Ord::cmp / cmp_precedence / Eq (ver, ver)

Usage: gen_corpus.py <out_file> [seed] [scale]
"""

import random
import sys

I64_MAX = 9223372036854775807
U64_MAX = 18446744073709551615

# --------------------------------------------------------------------------- edges

U64_NUMS = [
    I64_MAX - 1, I64_MAX, I64_MAX + 1, I64_MAX + 2, 12345678901234567890,
    U64_MAX - 1, U64_MAX,
]
OVERFLOW_NUMS = ["18446744073709551616", "99999999999999999999", "184467440737095516150"]

EDGE_VERSIONS = [
    "", " ", "1", "1.", "1.2", "1.2.", "1.2.3", " 1.2.3", "1.2.3 ", "1.2.3\t", "\t1.2.3",
    "01.2.3", "1.02.3", "1.2.03", "0.0.0", "00.0.0", "v1.2.3", "=1.2.3", "1.2.3.4",
    "1.2.3-", "1.2.3+", "1.2.3-+", "1.2.3-.", "1.2.3+.", "1.2.3-a.", "1.2.3+a.", "1.2.3-.a",
    "1.2.3-a..b", "1.2.3+a..b", "1.2.3-01", "1.2.3-0", "1.2.3-00", "1.2.3-0a", "1.2.3-a01",
    "1.2.3+001", "1.2.3+1", "1.2.3+01.001", "1.2.3+0", "1.2.3+00",
    "1.2.3--", "1.2.3---", "1.2.3-a--b", "1.2.3-a-", "1.2.3--a", "1.2.3+-", "1.2.3+--",
    "1.2.3+a-", "1.2.3+-a", "1.2.3-alpha+-", "1.2.3-α", "1.2.3+β", "1.2.3-aé",
    "1.2.3-中文", "1.2.3+\U0001F600", "\U0001F600.2.3", "1.é.3",
    "1.2.3-a\x00", "1.2.3\x00", "\x00", "1.2.3-a\x01", "1.2.3\x01", "1.2.3\x7f", "1.2.3\x1b",
    "1.2.3­", "1.2.3́", "1.2.3​", "1.2.3 ", "1.2.3﻿", "1.2.3'",
    "1.2.3\\", "1.2.3\"", "1.2.3\n", "1.2.3\r", "1.2.3 ", "１.2.3", "1.2.3-ａ",
    "1.2.3-alpha.1+build.5", "1.2.3+build-5", "1.2.3-x.7.z.92", "1.2.3-0.3.7",
    "1.2.3-alpha.01", "1.2.3+exp.sha.5114f85",
]
for n in U64_NUMS + [int(x) for x in OVERFLOW_NUMS]:
    EDGE_VERSIONS += [f"{n}.0.0", f"0.{n}.0", f"0.0.{n}", f"{n}.{n}.{n}", f"{n}.0.0-alpha+{n}"]

EDGE_REQS = [
    "", " ", "*", "x", "X", " * ", "*, 1.0.0", "1.0.0, *", "*.1", "x.x", "1.*", "1.*.*",
    "1.x", "1.X", "1.2.*", "1.*.2", "=1.*", ">1.*", "^1.*", "~1.*", "<1.*", "1.2.x",
    "0.*", "0.0.*", "^0", "^0.0", "^0.0.0", "^0.0.0-alpha", "~0.0.0-alpha", "~0", "~0.0",
    "=1.0.0-alpha, >=1.0.0-alpha", "<1.0.0-0", ">=1.0.0-0, <2.0.0-0", ">=1.0.0-0",
    "> 1.0.0", ">  1.0.0", "> =1.0.0", ">= 1.0.0", "1.0.0 ,2.0.0", "1.0.0 , 2.0.0",
    "1.0.0,2.0.0", "1.0.0,", "1.0.0, ", ",1.0.0", "1.0.0 2.0.0", "1.0.0 || 2.0.0",
    ">=1.0.0 <2.0.0", "1.0.0-alpha+build", "1.0.0+build", "1.0+build", "1+build",
    "1.0-alpha", "1-alpha", "1.0.0-", "1.0.0+", "1.0.0-01", "01.0.0", "1.00", "1.0.00",
    "=", ">", ">=", "<", "<=", "~", "^", "~>1.0", "=>1.0.0", "!=1.0.0", "==1.0.0",
    "\t1.0.0", "1.0.0\t", "1.0.0\x00", "\U0001F600", "1.0.0, \U0001F600", "1.0.0é",
    "^1.2.3\x01", "1.2.3\x7f",
    ",".join(["1.0.0"] * 31), ",".join(["1.0.0"] * 32), ",".join(["1.0.0"] * 33),
    ", ".join(["*"] * 2), ",".join(["1"] * 32) + ",*",
]
for n in U64_NUMS:
    for op in ["", "=", ">", ">=", "<", "<=", "~", "^"]:
        EDGE_REQS += [f"{op}{n}", f"{op}{n}.0", f"{op}{n}.0.0", f"{op}0.{n}", f"{op}0.{n}.0",
                      f"{op}0.0.{n}", f"{op}{n}.{n}.{n}", f"{op}{n}.{n}.{n}-alpha", f"{op}{n}.*"]
for n in OVERFLOW_NUMS:
    EDGE_REQS += [f"^{n}.0.0", f"~0.{n}", f">=0.0.{n}"]

EDGE_IDENTS = [
    "", "a", "-", "--", "a-", "-a", ".", "a.", ".a", "a..b", "0", "00", "01", "001", "0a", "a0",
    "1.01", "alpha.1", "é", "\x00", "a\x00", " ", "a b", "+", "a+b", "1" * 300, "a." * 50 + "a",
    "\U0001F600", "\x7f", "\x01",
]

# --------------------------------------------------------------------------- random

ALPH_MUT = "0123456789.-+*xX^~<>=, \t\x00\x01\x7fé\U0001F600abzAZ|!"
PRES = ["", "alpha", "alpha.1", "alpha.2", "beta", "beta.11", "rc.1", "0", "1", "2", "10", "a",
        "0a", "x.7.z.92", "alpha.beta", "-", "--", "a-b", "99999999999999999999999"]
BUILDS = ["", "1", "01", "001", "0", "00", "build", "build.5", "exp.sha.5114f85", "-", "a-b",
          "2", "10", "02", "1.01", "1.1"]


def rnd_num(r, big):
    x = r.random()
    if big and x < 0.15:
        return r.choice([I64_MAX - 1, I64_MAX])
    if x < 0.5:
        return r.randint(0, 3)
    if x < 0.85:
        return r.randint(0, 20)
    return r.randint(0, 100000)


def rnd_version(r, big=True):
    s = f"{rnd_num(r, big)}.{rnd_num(r, big)}.{rnd_num(r, big)}"
    p = r.choice(PRES)
    if p:
        s += "-" + p
    b = r.choice(BUILDS) if r.random() < 0.3 else ""
    if b:
        s += "+" + b
    return s


def rnd_small_version(r):
    s = f"{r.randint(0, 3)}.{r.randint(0, 3)}.{r.randint(0, 3)}"
    if r.random() < 0.45:
        s += "-" + r.choice(["alpha", "alpha.1", "beta", "0", "1", "rc.1", "a", "alpha.beta"])
    return s


def rnd_comparator(r, small=False):
    op = r.choice(["", "=", ">", ">=", "<", "<=", "~", "^"])
    num = (lambda: r.randint(0, 3)) if small else (lambda: rnd_num(r, True))
    shape = r.random()
    if shape < 0.15:
        return f"{op}{num()}"
    if shape < 0.3:
        return f"{op}{num()}.{num()}"
    if shape < 0.38:
        return f"{op}{num()}.{r.choice('*xX')}"
    if shape < 0.44:
        return f"{op}{num()}.{num()}.{r.choice('*xX')}"
    s = f"{op}{num()}.{num()}.{num()}"
    if r.random() < 0.45:
        s += "-" + r.choice(["alpha", "alpha.1", "beta", "0", "1", "rc.1", "a"] if small else PRES[1:])
    return s


def rnd_req(r, small=False):
    n = r.choice([1, 1, 2, 2, 3, 4])
    sep = r.choice([",", ", ", " , ", ","])
    return sep.join(rnd_comparator(r, small) for _ in range(n))


def mutate(r, s):
    s = list(s)
    for _ in range(r.randint(1, 3)):
        op = r.random()
        if op < 0.4 and s:
            del s[r.randrange(len(s))]
        elif op < 0.8:
            s.insert(r.randint(0, len(s)), r.choice(ALPH_MUT))
        elif s:
            s[r.randrange(len(s))] = r.choice(ALPH_MUT)
    return "".join(s)


def rnd_ident(r):
    n = r.randint(0, 4)
    segs = []
    for _ in range(n):
        segs.append("".join(r.choice("0123456789abc-Z") for _ in range(r.randint(0, 4))))
    s = ".".join(segs)
    if r.random() < 0.2:
        s = mutate(r, s)
    return s


def hx(s):
    return s.encode("utf-8").hex()


def main():
    out_path = sys.argv[1]
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 20261123
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    r = random.Random(seed)
    lines = []

    for s in EDGE_VERSIONS:
        lines.append(f"V {hx(s)}")
    for s in EDGE_REQS:
        lines.append(f"R {hx(s)}")
        lines.append(f"C {hx(s)}")
    for s in EDGE_IDENTS:
        lines.append(f"P {hx(s)}")
        lines.append(f"B {hx(s)}")

    for _ in range(8000 * scale):
        v = rnd_version(r)
        lines.append(f"V {hx(v)}")
        lines.append(f"V {hx(mutate(r, v))}")
    for _ in range(8000 * scale):
        q = rnd_req(r)
        lines.append(f"R {hx(q)}")
        lines.append(f"R {hx(mutate(r, q))}")
        c = rnd_comparator(r)
        lines.append(f"C {hx(c)}")
        lines.append(f"C {hx(mutate(r, c))}")
    for _ in range(3000 * scale):
        i = rnd_ident(r)
        lines.append(f"P {hx(i)}")
        lines.append(f"B {hx(i)}")

    # VersionReq::matches: dense small-domain fuzz (stresses the precompiled interval /
    # single-major prerelease fast path), plus Int64::MAX boundary domain.
    small_vers = [rnd_small_version(r) for _ in range(400)]
    for _ in range(60000 * scale):
        lines.append(f"M {hx(rnd_req(r, small=True))} {hx(r.choice(small_vers))}")
    for _ in range(20000 * scale):
        lines.append(f"M {hx(rnd_req(r))} {hx(rnd_version(r))}")
    for _ in range(10000 * scale):
        lines.append(f"K {hx(rnd_comparator(r, small=r.random() < 0.6))} {hx(r.choice(small_vers) if r.random() < 0.6 else rnd_version(r))}")
    # Explicit boundary matches (prerelease intersections, empty intervals, I64 edges, u64 range).
    bound_reqs = [
        "=1.0.0-alpha, >=1.0.0-alpha", "^0.0.0-alpha", "~0.0.0-alpha", "<1.0.0-0",
        ">=1.0.0-0, <2.0.0-0", ">=1.0.0-alpha, <1.0.0", ">1.0.0-alpha, <1.0.0-beta",
        ">=1.0.0-alpha, <2.0.0-alpha", ">=1.0.0-alpha, >=2.0.0-alpha", "<=1.0.0-alpha",
        ">1.0.0, <1.0.1", ">1.0.0, <=1.0.0", "1.*", "0.*", "0.0.*", ">=0.0.0", "<0.0.0",
        "<0.0.0-0", ">=0.0.0-0", "<0", "<0.0", ">9223372036854775807", ">9223372036854775807.0",
        ">9223372036854775807.9223372036854775807.9223372036854775807",
        "<=9223372036854775807.9223372036854775807.9223372036854775807",
        "^9223372036854775807", "~9223372036854775807.9223372036854775807",
        ">=9223372036854775807.0.0-alpha", "^0.9223372036854775807",
    ]
    bound_vers = ["0.0.0", "0.0.0-0", "0.0.0-alpha", "0.0.1", "0.1.0", "1.0.0", "1.0.0-0",
                  "1.0.0-alpha", "1.0.0-beta", "1.0.1", "1.0.1-alpha", "2.0.0-alpha", "2.0.0",
                  "9223372036854775807.0.0", "9223372036854775807.0.0-alpha",
                  "9223372036854775807.9223372036854775807.9223372036854775807",
                  "9223372036854775806.9223372036854775807.0", "0.9223372036854775807.1"]
    for q in bound_reqs:
        for v in bound_vers:
            lines.append(f"M {hx(q)} {hx(v)}")
    u64_reqs = [f"{op}{n}.0.0" for n in U64_NUMS for op in ["^", "~", "<", ">", "=", ">=", "<="]]
    u64_reqs += [f"~0.{U64_MAX}.0", f"^0.0.{U64_MAX}", f"^{U64_MAX}", f"^0.{U64_MAX}", "*", ">=0.0.0"]
    u64_vers = [f"{n}.0.0" for n in U64_NUMS] + [f"0.{U64_MAX}.0", f"0.0.{U64_MAX}", "1.0.0"]
    for q in u64_reqs:
        for v in u64_vers:
            lines.append(f"M {hx(q)} {hx(v)}")

    # Ordering / equality.
    for _ in range(20000 * scale):
        a = rnd_version(r, big=r.random() < 0.3)
        b = rnd_version(r, big=r.random() < 0.3) if r.random() < 0.5 else (a.split("+")[0] + ("+" + r.choice(BUILDS[1:]) if r.random() < 0.7 else ""))
        lines.append(f"O {hx(a)} {hx(b)}")

    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"corpus: {len(lines)} lines -> {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
