#!/usr/bin/env python3
"""Replays upstream globset's own `matches!`/`nmatches!` vectors (src/glob.rs, unix) on Pion,
and reports which Pion "ported" tests assert the opposite polarity.
usage: upstream_vectors.py <pion_driver> <globset_src_dir> <pion_glob_test_file> <work_dir>"""
import ast, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from differential import hx

OPT = {"SLASHLIT": 2, "CASEI": 1, "BSESC": 0, "BSNOESC": 4, "EALTRE": 8}
RX = re.compile(r'^\s*(n?)matches!\((\w+),\s*(r?"(?:[^"\\]|\\.)*"),\s*(r?"(?:[^"\\]|\\.)*")(?:,\s*(\w+))?\s*\);')


def s(tok):
    return tok[2:-1] if tok.startswith("r") else ast.literal_eval(tok)


def main():
    pion, src, ported, wd = sys.argv[1:5]
    os.makedirs(wd, exist_ok=True)
    cases, skip, prev = [], 0, ""
    for line in open(os.path.join(src, "src", "glob.rs"), encoding="utf-8"):
        m = RX.match(line)
        if m:
            if "not(unix)" in prev or (m[5] and m[5] not in OPT):
                skip += 1
            else:
                cases.append((m[2], m[1] != "n", s(m[3]), s(m[4]), OPT.get(m[5], 0)))
        if line.strip():
            prev = line
    f = os.path.join(wd, "upstream.txt")
    with open(f, "w") as o:
        for _, _, pat, path, op in cases:
            o.write(f"G {op} {hx(pat)}\nQ {hx(path)}\n")
    got = subprocess.run([pion, "diff", f], capture_output=True, check=True, text=True).stdout.split("\n")
    fails = []
    for (name, want, pat, path, op), g in zip(cases, got):
        if g == "E" or (g[0] == "1") != want or (g[1] == "1") != want:
            fails.append((name, pat, path, op, want, g))
    print(f"upstream vectors: {len(cases)} replayed, {skip} skipped (non-unix/other opts), {len(fails)} FAIL on Pion")
    for x in fails:
        print("  FAIL %s pat=%r path=%r opts=%d upstream_expects=%s pion(glob,set)=%s" % x)
    text = open(ported, encoding="utf-8").read()
    for name, want, pat, path, op in cases:
        lit = '"' + pat.replace("\\", "\\\\") + '", "' + path.replace("\\", "\\\\") + '"'
        flipped = ("check_nmatch(" if want else "check_match(") + lit
        if flipped in text and (("check_match(" if want else "check_nmatch(") + lit) not in text:
            print(f"  INVERTED-IN-PORT {name}: upstream {'matches' if want else 'nmatches'} {pat!r} {path!r}; Pion test asserts the opposite")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
