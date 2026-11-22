#!/usr/bin/env python3
"""Score Pion against pulldown-cmark 0.13.1's *own* generated test suite (tests/suite/*.rs).

Each upstream test runs with pulldown's full option set (tables, strikethrough, tasklists, GFM,
footnotes, heading attributes, math, deflists, superscript, + per-test smart/metadata/old-footnotes/
subscript/wikilinks) and compares with upstream's html_standardize().  Pion is run with the nearest
options it has (tables+strikethrough+tasklists, +smart_punctuation when the test asks for it).
The Rust oracle is run on the same inputs as a sanity check (must be 100%).

usage: suite_score.py <rust_ref_bin> <pion_harness_bin> <pulldown_crate_dir> <out_dir>
"""
import json, os, re, subprocess, sys, collections

RUST, PION, CRATE, OUT = sys.argv[1:5]
os.makedirs(OUT, exist_ok=True)
FN = re.compile(r'fn (\w+)\(\) \{\s*let original = r##"(.*?)"##;\s*let expected = r##"(.*?)"##;\s*'
                r'test_markdown_html\(original, expected, (\w+), (\w+), (\w+), (\w+), (\w+)\);', re.S)


def std(s):
    return (s.replace("<br>", "<br />").replace("<br/>", "<br />").replace("<hr>", "<hr />")
            .replace("<hr/>", "<hr />").replace(">\n<", "><"))


def frames(data, per):
    res, i = [], 0
    while i < len(data):
        nl = data.index(b"\n", i)
        ln = int(data[i:nl])
        res.append(data[nl + 1:nl + 1 + ln])
        i = nl + 1 + ln
    return [res[j:j + per] for j in range(0, len(res), per)]


def batch(path, cases):
    with open(path, "wb") as f:
        for mask, src in cases:
            b = src.encode()
            f.write(f"{mask}\t{len(b)}\n".encode() + b)


tests = []
d = os.path.join(CRATE, "tests", "suite")
for fn in sorted(os.listdir(d)):
    if fn.endswith(".rs") and fn != "mod.rs":
        for m in FN.finditer(open(os.path.join(d, fn), encoding="utf-8").read()):
            name, orig, exp, smart, meta, oldfn, sub, wiki = m.groups()
            T = lambda x: x == "true"
            rmask = 1 | 2 | 4 | 128 | 1024 | 2048 | 4096 | 8192
            rmask |= 65536 if T(oldfn) else 64
            if T(smart): rmask |= 16
            if T(meta): rmask |= 256 | 512
            if T(sub): rmask |= 16384
            if T(wiki): rmask |= 32768
            pmask = 7 | (16 if T(smart) else 0)
            tests.append((fn[:-3], name, orig, exp, rmask, pmask))

bp = os.path.join(OUT, "suite.bin")
batch(bp, [(t[4], t[2]) for t in tests])
rust = [f[0].decode() for f in frames(subprocess.run([RUST, "batch", bp], capture_output=True, check=True).stdout, 1)]
batch(bp, [(t[5], t[2]) for t in tests])
pion = [f[0].decode("utf-8", "replace") for f in frames(subprocess.run([PION, "batch", bp], capture_output=True, check=True).stdout, 4)]
score = collections.OrderedDict()
fails = []
for t, r, p in zip(tests, rust, pion):
    s = score.setdefault(t[0], [0, 0, 0])
    s[0] += 1
    s[1] += std(r) == std(t[3])
    ok = std(p) == std(t[3])
    s[2] += ok
    if not ok:
        fails.append({"suite": t[0], "test": t[1], "src": t[2], "expected": t[3], "pion": p})
print(f"{'suite':22s} {'tests':>5s} {'rust':>6s} {'pion':>6s}")
tot = [0, 0, 0]
for k, (n, r, p) in score.items():
    print(f"{k:22s} {n:5d} {r:6d} {p:6d}  ({100.0 * p / n:5.1f}%)")
    tot = [tot[0] + n, tot[1] + r, tot[2] + p]
print(f"{'TOTAL':22s} {tot[0]:5d} {tot[1]:6d} {tot[2]:6d}  ({100.0 * tot[2] / tot[0]:5.1f}%)")
json.dump({"score": score, "fails": fails}, open(os.path.join(OUT, "suite_results.json"), "w"), ensure_ascii=False, indent=1)
