#!/usr/bin/env python3
"""Delta-debug multi-pattern GlobSet divergences to minimal reproducers.
usage: minimize_sets.py <pion_driver> <rust_oracle> <work_dir>"""
import os, random, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from differential import PATTERNS, PATHS, hx


def ask(tool, f):
    return subprocess.run([tool, "diff", f], capture_output=True, check=True).stdout.decode("latin-1").split("\n")[:-1]


def batch(pion, rust, wd, items):
    f = os.path.join(wd, "min.txt")
    with open(f, "w") as o:
        for op, pats, path in items:
            o.write(f"M {op} " + ",".join(hx(x) for x in pats) + f"\nQ {hx(path)}\n")
    return [a != b for a, b in zip(ask(pion, f), ask(rust, f))]


def clean(p):
    return "[:" not in p and all(ord(c) < 128 for c in p)


def main():
    pion, rust, wd = sys.argv[1:4]
    os.makedirs(wd, exist_ok=True)
    pool = [p for p in PATTERNS if clean(p)]
    paths = [p for p in PATHS if isinstance(p, str) and p.isascii()]
    rnd = random.Random(7)
    found = {}
    for _ in range(40):
        cand = []
        for _ in range(400):
            cand.append((rnd.choice([0, 0, 1, 8]), rnd.sample(pool, rnd.randint(2, 16)), rnd.choice(paths)))
        for (op, pats, path), bad in zip(cand, batch(pion, rust, wd, cand)):
            if not bad:
                continue
            cur = list(pats)
            i = 0
            while i < len(cur) and len(cur) > 1:
                t = cur[:i] + cur[i + 1:]
                if batch(pion, rust, wd, [(op, t, path)])[0]:
                    cur = t
                else:
                    i += 1
            found.setdefault((op, tuple(cur)), path)
    f = os.path.join(wd, "min.txt")
    for (op, pats), path in sorted(found.items(), key=lambda kv: (len(kv[0][1]), str(kv[0]))):
        with open(f, "w") as o:
            o.write(f"M {op} " + ",".join(hx(x) for x in pats) + f"\nQ {hx(path)}\n")
        print(f"opts={op} set={list(pats)!r} path={path!r} rust=[{ask(rust, f)[0]}] pion=[{ask(pion, f)[0]}]")


if __name__ == "__main__":
    main()
