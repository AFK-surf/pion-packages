#!/usr/bin/env python3
"""Deterministic mutation fuzzer: derives a fixed crash-freedom corpus from cases.py.

usage: fuzz.py OUT.tsv [COUNT] [SEED]
Every generated input is run through the Pion driver in all four build modes; a fuzz case
PASSes when no mode crashes (panic, SIGSEGV, wasm trap) and all four modes print the same line.
No Go comparison: mutants are mostly invalid HCL and the point is robustness.
"""
import random
import sys
import os

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cases  # noqa: E402

TOKENS = [
    "${", "}", "%{", "~}", "${~", "%{~", "if ", "else", "endif", "for ", " in ", "endfor", "[*]",
    ".*", "...", "=>", "?", ":", "(", ")", "[", "]", "{", "}", '"', "<<EOF\n", "<<-EOF\n", "\nEOF\n",
    "\n", "\r\n", "\r", "\t", " ", "#", "//", "/*", "*/", "\\", "\\u", "\\U0010FFFF", "$$", "%%",
    "1e308", "4294967296", "-2147483648", "1e-400", "0.5", "-", "!", "&&", "||", "==", "%", "/ 0",
    "null", "true", "nul", "l", "o", "objs", "s", "n", "﻿", "é", "\U0001F600", "\x00",
    "substr(s, ", "element(l, ", "range(", "format(\"%d\", ", "l[", "o.", "e[0]", "floor(", "join(\"\", ",
]


def mutate(rng, src):
    s = src
    for _ in range(rng.randint(1, 4)):
        op = rng.randrange(5)
        pos = rng.randint(0, len(s))
        if op == 0:
            s = s[:pos] + rng.choice(TOKENS) + s[pos:]
        elif op == 1 and s:
            end = min(len(s), pos + rng.randint(1, 4))
            s = s[:pos] + s[end:]
        elif op == 2 and s:
            a = rng.randint(0, len(s))
            b = min(len(s), a + rng.randint(1, 12))
            s = s[:pos] + s[a:b] + s[pos:]
        elif op == 3:
            s = s[:pos] + rng.choice(TOKENS) * rng.randint(2, 40) + s[pos:]
        else:
            other = rng.choice(cases.C)[2]
            s = s[:pos] + other[: rng.randint(0, len(other))] + s[pos:]
    return s


def main():
    out = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 20261123
    rng = random.Random(seed)
    modes = ["expr", "tmpl", "body", "json", "fmt"]
    with open(out, "w") as fh:
        for i in range(count):
            _, mode, src = rng.choice(cases.C)
            if rng.random() < 0.2:
                mode = rng.choice(modes)
            m = mutate(rng, src)
            fh.write(f"fuzz/{i:05d}\t{mode}\t{m.encode('utf-8', 'surrogatepass').hex()}\n")


if __name__ == "__main__":
    main()
