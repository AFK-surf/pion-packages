#!/usr/bin/env python3
"""Error-location quality over the official toml-test *invalid* corpus (TOML 1.0.0 list).

Collects (line, col) reported by Pion, Rust toml 1.2 and Go BurntSushi for every invalid file
and reports how often Pion's line disagrees with BOTH references (both of which agree with each other).
usage: errpos_corpus.py <toml-test checkout>
"""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from difflib_toml import BIN

root = sys.argv[1]
files = [l.strip() for l in open(os.path.join(root, "tests/files-toml-1.0.0")) if l.startswith("invalid/") and l.strip().endswith(".toml")]
def pos(cmd, path):
    out = subprocess.run(cmd + [path], capture_output=True).stdout.decode(errors="replace").strip()
    if not out.startswith("ERR"):
        return None
    p = out.split(" ", 4)
    return int(p[1]), int(p[2]), p[4] if len(p) > 4 else ""
n = same_line = both_ref_agree = pion_off = 0
examples = []
for rel in files:
    path = os.path.join(root, "tests", rel)
    pi = pos([f"{BIN}/pion_cli", "errpos"], path)
    ru = pos([f"{BIN}/rust_ref", "errpos"], path)
    go = pos([f"{BIN}/go_ref", "errpos"], path)
    if not (pi and ru and go) or ru[0] == 0 or go[0] == 0:
        continue
    n += 1
    same_line += pi[0] == ru[0]
    if ru[0] == go[0]:
        both_ref_agree += 1
        if pi[0] != ru[0]:
            pion_off += 1
            if len(examples) < 15:
                examples.append((rel, pi, ru[:2], go[:2]))
print(f"invalid files with positions from all three: {n}")
print(f"pion line == rust line: {same_line}/{n}")
print(f"rust & go agree on line: {both_ref_agree}; of those pion reports a DIFFERENT line: {pion_off}")
for e in examples:
    print("  ", e)
