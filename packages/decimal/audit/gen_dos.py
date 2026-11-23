#!/usr/bin/env python3
"""Hostile one-line corpora (DoS / resource exhaustion) in the probe protocol.

usage: gen_dos.py <out_dir>   -> writes <out_dir>/dos_<name>.tsv (one hostile line each, x REPEAT lines)
"""
import os
import sys

MAXM = (1 << 96) - 1


def hs(s):
    return s.encode().hex()


def enc(m, scale, neg):
    flags = (scale << 16) | (0x80000000 if neg else 0)
    return "".join(w.to_bytes(4, "little").hex() for w in [flags, m & 0xFFFFFFFF, (m >> 32) & 0xFFFFFFFF, m >> 64])


CASES = {
    # name: (line, repeat)
    "frac_200k_zeros": ("FS\t" + hs("0." + "0" * 200_000 + "1"), 20),
    "frac_200k_zeros_exact": ("FSX\t" + hs("0." + "0" * 200_000 + "1"), 20),
    "int_100k_nines": ("FS\t" + hs("9" * 100_000), 20),
    "lead_1m_zeros": ("FS\t" + hs("0" * 1_000_000 + "1"), 5),
    "underscores_1m": ("FS\t" + hs("1" + "_" * 1_000_000), 5),
    "frac_1m_digits": ("FS\t" + hs("1." + "3" * 1_000_000), 5),
    "frac_1m_then_e": ("FS\t" + hs("1." + "3" * 1_000_000 + "e5"), 5),
    "sci_1m_mantissa": ("SCI\t" + hs("1." + "3" * 1_000_000 + "e-5"), 5),
    "exp_17_nines": ("SCI\t" + hs("1e99999999999999999"), 1000),
    "exp_neg_17_nines": ("SCI\t" + hs("1e-99999999999999999"), 1000),
    "exp_1m_digits": ("SCI\t" + hs("1e" + "9" * 1_000_000), 5),
    "radix2_1m": ("RADIX\t" + hs("0" * 1_000_000 + "1") + "\t2", 5),
    "powi_1e9_two": ("POWI\t" + enc(2, 0, False) + "\t1000000000", 1000),
    "powi_1e9_near_one": ("POWI\t" + enc(10 ** 27 + 1, 27, False) + "\t1000000000", 1000),
    "powi_i64_min_half": ("POWI\t" + enc(5, 1, False) + "\t-9223372036854775808", 1000),
    "powi_i64_max_one_tenth": ("POWI\t" + enc(1, 1, False) + "\t9223372036854775807", 1000),
    "rem_max_by_1e-28": ("REM\t" + enc(MAXM, 0, False) + "\t" + enc(1, 28, False), 100000),
    "div_max_by_1e-28": ("DIV\t" + enc(MAXM, 0, False) + "\t" + enc(1, 28, False), 100000),
    "sqrt_max": ("SQRT\t" + enc(MAXM, 0, False), 20000),
    "sqrt_1e-28": ("SQRT\t" + enc(1, 28, False), 20000),
}


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, (line, rep) in CASES.items():
        with open(os.path.join(out, f"dos_{name}.tsv"), "w") as f:
            f.write((line + "\n") * rep)
    print(" ".join(CASES))


if __name__ == "__main__":
    main()
