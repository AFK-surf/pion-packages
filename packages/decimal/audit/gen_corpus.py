#!/usr/bin/env python3
"""Deterministic differential corpus for packages/decimal vs rust_decimal =1.37.2.

usage: gen_corpus.py <out.tsv> [random_count=60000] [seed=1372]

Line format (see oracle/src/main.rs): OP<TAB>args. Decimal args are the 32-hex raw wire
form [flags, lo, mid, hi] (little endian, canonical flags only); string args are hex(UTF-8).
The corpus = a fixed edge-case matrix (parse / arithmetic / rounding / math / serde) +
`random_count` randomly drawn operations.
"""
import random
import sys

MAXM = (1 << 96) - 1
OPS2 = ["ADD", "SUB", "MUL", "DIV", "REM", "CMP"]


def enc(m, scale, neg):
    flags = (scale << 16) | (0x80000000 if neg else 0)
    words = [flags, m & 0xFFFFFFFF, (m >> 32) & 0xFFFFFFFF, (m >> 64) & 0xFFFFFFFF]
    return "".join(w.to_bytes(4, "little").hex() for w in words)


def hs(s):
    return s.encode().hex()


def dstr(m, scale, neg):
    s = str(m).rjust(scale + 1, "0")
    if scale:
        s = s[:-scale] + "." + s[-scale:]
    return ("-" if neg else "") + s


# ---------------------------------------------------------------------------
EDGE_M = sorted(set(
    [0, 1, 2, 3, 5, 7, 9, 10, 11, 15, 25, 49, 50, 51, 99, 100, 101, 12345, 999999999, 1000000000]
    + [(1 << k) + d for k in (31, 32, 63, 64, 95) for d in (-1, 0, 1)]
    + [MAXM, MAXM - 1, MAXM // 2, MAXM // 10, MAXM // 10 + 1, MAXM // 3]
    + [10 ** k + d for k in (9, 18, 19, 20, 27, 28) for d in (-1, 0, 1)]
    + [5 * 10 ** k + d for k in (0, 1, 9, 18, 27) for d in (-1, 0, 1)]
    + [int("1" * 28), int("3" * 28), int("7" * 28), int("9" * 28), int("9" * 29) % (MAXM + 1)]
))
EDGE_S = [0, 1, 2, 5, 9, 10, 18, 19, 20, 27, 28]


def rand_m(r):
    c = r.random()
    if c < 0.25:
        return r.choice(EDGE_M)
    bits = r.choice([0, 1, 8, 16, 31, 32, 33, 40, 53, 63, 64, 65, 80, 95, 96]) if c < 0.5 else r.randint(0, 96)
    return r.getrandbits(bits) if bits else 0


def rand_s(r):
    return r.choice(EDGE_S) if r.random() < 0.4 else r.randint(0, 28)


def rand_dec(r):
    return (rand_m(r), rand_s(r), r.random() < 0.45)


def rand_digits(r, n):
    return "".join(r.choice("0123456789") for _ in range(n))


def mutate_str(r, s):
    k = r.randint(0, 17)
    if k == 0:
        return "+" + s.lstrip("-")
    if k == 1:
        neg = s.startswith("-")
        return ("-" if neg else "") + "0" * r.randint(1, 40) + s.lstrip("-")
    if k == 2:
        return (s if "." in s else s + ".") + "0" * r.randint(1, 40)
    if k == 3:  # underscores
        out = []
        for ch in s:
            out.append(ch)
            if r.random() < 0.2:
                out.append("_" * r.randint(1, 2))
        return "".join(out)
    if k == 4:
        return r.choice([" ", "\t", "  "]) + s
    if k == 5:
        return s + r.choice([" ", "\n".replace("\n", " "), "x", "_", ".", "e", "E", "e5", "-", "+"])
    if k == 6:
        return s + "e" + str(r.choice([0, 1, -1, 5, -5, 27, 28, 29, -27, -28, -29, 30, -30]))
    if k == 7:
        return s + r.choice(["e", "E"]) + r.choice(["+", "-", ""]) + str(
            r.choice([0, 2, 9, 19, 20, 28, 4294967295, 4294967296, 99999999999999999999]))
    if k == 8:
        i = r.randint(0, len(s))
        return s[:i] + r.choice(["_", ".", "-", "+", "a", "e", " ", "__"]) + s[i:]
    if k == 9:
        return "0." + rand_digits(r, r.randint(25, 40))
    if k == 10:  # >28 fractional digits on a big integer part
        return rand_digits(r, r.randint(1, 29)) + "." + rand_digits(r, r.randint(20, 45))
    if k == 11:
        return r.choice(["-", ""]) + rand_digits(r, r.randint(28, 31))
    if k == 12:
        return r.choice(["", ".", "-", "+", "_", "-.", "+.", "._", "_1", "1_", "1__2", ".5", "5.", "-.5", "+5.",
                         "-0", "-0.00", "+0", "00", "0.", ".0", "0e0", "-0e0", "1e", "e1", "1e+", "1e-", "1.2.3",
                         "--1", "+-1", "1..2", "0x10", "1,5", "NaN", "inf", "½", "1٠"])
    if k == 13:  # rounding position patterns at the 28/29th fractional digit
        ip = r.choice(["0", "1", "7", "79228162514264337593543950335"[: r.randint(1, 29)]])
        frac = rand_digits(r, 28)
        tail = r.choice(["5", "50", "500000001", "49999999", "4", "6", "5_1", "51", "50_0", "9" * 10])
        return r.choice(["", "-"]) + ip + "." + frac[: max(0, 28 - (len(ip) - 1))] + tail
    if k == 14:
        return s.replace(".", "") + "." if "." in s else s + "."
    if k == 15:
        return r.choice(["+", "-", ""]) + "." + rand_digits(r, r.randint(1, 35))
    if k == 16:
        return r.choice(["-", ""]) + "79228162514264337593543950" + r.choice(
            ["335", "336", "335.4", "335.5", "335.49999", "335.50001", "334.5", "335_", "3350", "335.0"])
    return s


def rand_str(r):
    m, sc, neg = rand_dec(r)
    s = dstr(m, sc, neg)
    for _ in range(r.choice([0, 1, 1, 2])):
        s = mutate_str(r, s)
    return s


def emit_rand(r, out):
    op = r.choices(
        ["FS", "FSX", "SCI", "RADIX", "NEW", "ADD", "SUB", "MUL", "DIV", "REM", "CMP", "RDS", "RND", "RDP",
         "NORM", "TRUNC", "TRUNCS", "FRACT", "FLOOR", "CEIL", "NEG", "ABS", "ISINT", "RESCALE", "SETSCALE",
         "SQRT", "POWI", "POWU", "SER", "DES", "TOI64", "TOU64", "TOF64"],
        weights=[10, 4, 6, 2, 1, 7, 7, 7, 8, 6, 2, 8, 1, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 3, 3, 2, 1, 2, 1, 1, 1])[0]
    if op in ("FS", "FSX"):
        out.append(f"{op}\t{hs(rand_str(r))}")
    elif op == "SCI":
        s = rand_str(r)
        if "e" not in s.lower():
            s += r.choice(["e", "E"]) + r.choice(["", "-", "+"]) + str(r.choice([0, 1, 3, 10, 18, 27, 28, 29, r.randint(0, 40)]))
        out.append(f"SCI\t{hs(s)}")
    elif op == "RADIX":
        radix = r.choice([2, 8, 10, 16, 36, r.randint(2, 36), 1, 37])
        digs = "0123456789abcdefghijklmnopqrstuvwxyz"[: max(2, min(radix, 36))]
        s = "".join(r.choice(digs) for _ in range(r.randint(1, 100 if radix == 2 else 30)))
        if r.random() < 0.3:
            i = r.randint(0, len(s))
            s = s[:i] + "." + s[i:]
        if r.random() < 0.2:
            s = r.choice(["-", "+", "_"]) + s
        if r.random() < 0.2:
            s = s.upper()
        out.append(f"RADIX\t{hs(s)}\t{radix}")
    elif op == "NEW":
        v = r.choice([0, 1, -1, 2 ** 63 - 1, -2 ** 63, r.randint(-2 ** 63, 2 ** 63 - 1)])
        out.append(f"NEW\t{v}\t{r.choice([0, 1, 28, 29, 255, r.randint(0, 30)])}")
    elif op in OPS2:
        a, b = rand_dec(r), rand_dec(r)
        if r.random() < 0.15:  # same magnitude different scale / near-equal operands
            b = (a[0], r.randint(0, 28), r.random() < 0.5)
        out.append(f"{op}\t{enc(*a)}\t{enc(*b)}")
    elif op == "RDS":
        out.append(f"RDS\t{enc(*rand_dec(r))}\t{r.choice([0, 1, 2, 27, 28, 29, 100, r.randint(0, 28)])}\t{r.randint(0, 6)}")
    elif op in ("RDP", "TRUNCS", "RESCALE", "SETSCALE"):
        out.append(f"{op}\t{enc(*rand_dec(r))}\t{r.choice([0, 1, 2, 28, 29, 255, r.randint(0, 30)])}")
    elif op == "POWI":
        e = r.choice([0, 1, 2, 3, -1, -2, -3, r.randint(-60, 60), r.randint(-300, 300), -2 ** 63, 2 ** 63 - 1])
        m, sc, neg = rand_dec(r)
        if abs(e) > 300:
            m, sc = r.choice([(0, 0), (1, 0), (10, 1), (2, 0), (5, 1), (100, 2)]), 0
            m, sc = m
        out.append(f"POWI\t{enc(m, sc, neg)}\t{e}")
    elif op == "POWU":
        e = r.choice([0, 1, 2, 3, 4, 5, r.randint(0, 64), r.randint(0, 400)])
        out.append(f"POWU\t{enc(*rand_dec(r))}\t{e}")
    elif op == "DES":
        b = bytearray(r.getrandbits(8) for _ in range(16))
        if r.random() < 0.5:  # mostly-valid flags with random scale byte / reserved bits
            b[0] = r.choice([0, 0, 0, 1, 0xFF])
            b[1] = r.choice([0, 0, 0, 0x80])
            b[2] = r.choice([r.randint(0, 31), r.randint(0, 255), 28, 29, 30, 31, 32, 60])
            b[3] = r.choice([0, 0x80, 0x01, 0x7F, 0xFF])
        out.append(f"DES\t{bytes(b).hex()}")
    else:
        out.append(f"{op}\t{enc(*rand_dec(r))}")


def edge_matrix(out):
    # Parsing / formatting edge strings
    strs = ["0", "-0", "-0.00", "+0.000", "0.0000000000000000000000000000", "-0.0000000000000000000000000000",
            "0e0", "1e-28", "1e-29", "1e28", "1e29", "1e-0", "1E5", "1.5e+3", "-1.5E-3", ".5", "5.", "-.5", "+5.",
            " 1", "1 ", "1_000", "_1", "1_", "1__0", "1._5", "1.5_", "", "-", "+", ".", "1.2.3",
            "79228162514264337593543950335", "79228162514264337593543950336", "-79228162514264337593543950335",
            "-79228162514264337593543950336", "79228162514264337593543950335.4", "79228162514264337593543950335.5",
            "79228162514264337593543950335.49999999999", "7922816251426433759354395033.55",
            "7922816251426433759354395033.45", "7.9228162514264337593543950335", "7.92281625142643375935439503355",
            "7.92281625142643375935439503345", "7.92281625142643375935439503365", "0.00000000000000000000000000005",
            "0.00000000000000000000000000015", "0.00000000000000000000000000025", "0.000000000000000000000000000049",
            "0.000000000000000000000000000050", "0.0000000000000000000000000000500001",
            "0.0000000000000000000000000001", "0.00000000000000000000000000001", "1.00000000000000000000000000005",
            "1.00000000000000000000000000015", "1.000000000000000000000000000049999",
            "1.0000000000000000000000000000_5", "1.0000000000000000000000000000_4", "1.00000000000000000000000000004_9",
            "9.99999999999999999999999999995", "0.99999999999999999999999999995", "-0.99999999999999999999999999995",
            "99999999999999999999999999999", "9999999999999999999999999999.9", "9999999999999999999999999999.5",
            "0." + "0" * 200 + "1", "1." + "0" * 100, "0" * 300 + "1", "1" + "_" * 50 + "2",
            "18446744073709551615", "18446744073709551616", "18446744073709551615.5", "1844674407370955161.6",
            "1844674407370955161.5", "184467440737095516.15", "4294967296.4294967296"]
    for s in strs:
        for op in ("FS", "FSX"):
            out.append(f"{op}\t{hs(s)}")
    sci = ["1e0", "1e-0", "1e+0", "1e28", "1e29", "1e-28", "1e-29", "1.0e-28", "10e-29", "0e-29", "0e29", "0e100",
           "1.5e-27", "1.55e-27", "123.456e-26", "-1e-28", "-0e0", "9.7e-7", "1.2e10", "1.2E+10", "7.9228162514264337593543950335e28",
           "7.9228162514264337593543950336e28", "79228162514264337593543950335e0", "79228162514264337593543950335e1",
           "1e4294967295", "1e-4294967295", "1e4294967296", "1e-4294967296", "1e99999999999999999",
           "1e-99999999999999999", "1e", "e1", "1e+", "1e-", "1e--1", "1e+-1", "1ee1", "1e1e1", "1e 1", " 1e1",
           "1e1 ", "1E5", "1.e5", ".1e1", "1_000e3", "1e1_0", "0.0000000000000000000000000001e1",
           "0.0000000000000000000000000001e-1", "12345678901234567890123456789e-1", "1.5e4294967296",
           "-20165.4676_e-+4294967292", "5e-28", "5e-29", "15e-29", "25e-29", "-15e-29"]
    for s in sci:
        out.append(f"SCI\t{hs(s)}")
        out.append(f"FS\t{hs(s)}")

    # Arithmetic edge matrix: a subset of edge mantissas x scales x signs, all pairs, all ops
    vals = []
    for m in [0, 1, 5, 9, 10, 15, 25, 50, (1 << 32) - 1, 1 << 32, (1 << 64) - 1, 1 << 64, 10 ** 19, 10 ** 28,
              5 * 10 ** 27, MAXM // 10, MAXM - 1, MAXM]:
        for sc in (0, 1, 28):
            for neg in (False, True):
                vals.append((m, sc, neg))
    for a in vals:
        for b in vals:
            for op in ("ADD", "SUB", "MUL", "DIV", "REM"):
                out.append(f"{op}\t{enc(*a)}\t{enc(*b)}")
    # MAX + 0.4 / 0.5 / 0.6 and friends
    for frac in ("0.4", "0.5", "0.6", "0.49999999999999999999999999", "0.5000000000000000000000000001", "1", "1.5", "2.5"):
        m = int(frac.replace(".", ""))
        sc = len(frac.split(".")[1]) if "." in frac else 0
        for neg in (False, True):
            out.append(f"ADD\t{enc(MAXM, 0, neg)}\t{enc(m, sc, neg)}")
            out.append(f"SUB\t{enc(MAXM, 0, neg)}\t{enc(m, sc, not neg)}")
            out.append(f"ADD\t{enc(MAXM - 1, 0, neg)}\t{enc(m, sc, neg)}")
    out.append(f"REM\t{enc(MAXM, 0, False)}\t{enc(1, 28, False)}")
    out.append(f"REM\t{enc(MAXM, 0, True)}\t{enc(1, 28, False)}")
    out.append(f"REM\t{enc(MAXM, 0, False)}\t{enc(3, 28, True)}")
    out.append(f"REM\t{enc(MAXM, 1, False)}\t{enc(7, 28, False)}")

    # 7-strategy rounding matrix: exact midpoints (odd/even), +-epsilon, dp > scale, dp = 0, -0.00
    for q in (0, 1, 2, 3, 12, 13, 99, 10 ** 18 + 1, MAXM // 10 ** 5):
        for diff in (1, 2, 5, 10, 19, 20, 27, 28):
            for tail in ("mid", "mid+", "mid-", "zero", "small"):
                half = 5 * 10 ** (diff - 1)
                t = {"mid": half, "mid+": half + 1, "mid-": half - 1, "zero": 0, "small": 1}[tail]
                m = q * 10 ** diff + t
                if m > MAXM or diff > 28:
                    continue
                for dp in (0, 1, 28):
                    sc = min(28, dp + diff) if dp < 28 else 28
                    if sc - dp != diff and dp != 28:
                        continue
                    for neg in (False, True):
                        for strat in range(7):
                            out.append(f"RDS\t{enc(m, sc, neg)}\t{dp}\t{strat}")
    for neg in (False, True):
        for sc in (0, 2, 28):
            for dp in (0, 1, 2, 29, 4294967295):
                for strat in range(7):
                    out.append(f"RDS\t{enc(0, sc, neg)}\t{dp}\t{strat}")
                    out.append(f"RDS\t{enc(MAXM, sc, neg)}\t{dp}\t{strat}")

    # floor / ceil / trunc / fract / normalize / sqrt / to_* on every edge value
    for m in EDGE_M:
        for sc in (0, 1, 2, 9, 19, 27, 28):
            for neg in (False, True):
                for op in ("FLOOR", "CEIL", "TRUNC", "FRACT", "NORM", "ISINT", "SQRT", "TOI64", "TOU64", "TOF64",
                           "RND", "NEG", "ABS", "SER"):
                    out.append(f"{op}\t{enc(m, sc, neg)}")
                for s in (0, 1, 2, 27, 28, 29):
                    out.append(f"RESCALE\t{enc(m, sc, neg)}\t{s}")
                    out.append(f"TRUNCS\t{enc(m, sc, neg)}\t{s}")
    # powi
    for m, sc in [(0, 0), (0, 2), (1, 0), (10, 1), (100, 2), (2, 0), (5, 1), (3, 1), (11, 1), (110, 2), (15, 1),
                  (25, 1), (12345, 3), (MAXM, 0), (MAXM, 28), (1, 28), (3, 0), (7, 0), (999, 3)]:
        for neg in (False, True):
            for e in (0, 1, 2, 3, 4, 5, 7, 10, 28, 29, 64, 95, 96, 97, -1, -2, -3, -10, -28, -29, -95, -96,
                      -1000, -2 ** 63, 2 ** 63 - 1):
                if abs(e) > 200 and (m, sc) not in [(0, 0), (0, 2), (1, 0), (10, 1), (100, 2), (2, 0), (MAXM, 0), (3, 0), (7, 0)]:
                    continue
                out.append(f"POWI\t{enc(m, sc, neg)}\t{e}")
    # deserialize malformed
    for sc in range(0, 256, 1):
        for m in (0, 1, 15, 149, 150, 151, 12345, 10 ** 28 + 7, MAXM):
            for res_bits in (0, 0x0000_00FF, 0x0000_8000, 0x7F00_0000):
                flags = (sc << 16) | res_bits | (0x80000000 if m & 1 else 0)
                words = [flags, m & 0xFFFFFFFF, (m >> 32) & 0xFFFFFFFF, (m >> 64) & 0xFFFFFFFF]
                out.append("DES\t" + "".join(w.to_bytes(4, "little").hex() for w in words))
    for v, sc in [(0, 0), (1, 28), (-1, 28), (2 ** 63 - 1, 0), (-2 ** 63, 0), (-2 ** 63, 28), (5, 29), (5, 4294967295)]:
        out.append(f"NEW\t{v}\t{sc}")
    for s, rdx in [("ff", 16), ("FF", 16), ("-z", 36), ("1.1", 2), ("0.1", 3), ("10", 1), ("10", 37), ("", 16),
                   ("1" * 96, 2), ("1" * 97, 2), ("0." + "1" * 29, 2), ("_1", 16), ("1_", 16), (".", 16), ("g", 16)]:
        out.append(f"RADIX\t{hs(s)}\t{rdx}")


def main():
    path = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 60000
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1372
    r = random.Random(seed)
    out = []
    edge_matrix(out)
    n_edge = len(out)
    for _ in range(count):
        emit_rand(r, out)
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"corpus: {len(out)} lines ({n_edge} edge-matrix + {count} random, seed {seed}) -> {path}")


if __name__ == "__main__":
    main()
