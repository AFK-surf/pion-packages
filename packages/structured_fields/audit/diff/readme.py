#!/usr/bin/env python3
"""Claims of packages/structured_fields/README.md, parsed at audit time (nothing is hard-coded in run_audit.sh).
usage: readme.py <README.md> <key>
keys: tests vectors smoke_sha smoke_bytes size_<native_dbg|native_rel|wasm_dbg|wasm_rel> bench_sha1 bench_sha2
      speedup1 speedup2 rss1 rss2 send notsend
"""
import re
import sys

t = open(sys.argv[1], encoding="utf-8").read()
k = sys.argv[2]


def one(pat, g=1):
    m = re.search(pat, t)
    if not m:
        sys.exit("README.md: no match for %s" % k)
    return m.group(g)


if k == "tests":
    print(one(r"\*\*(\d+) / \d+ tests passing"))
elif k == "vectors":
    print(one(r"\*\*(\d+) / \d+\*\* core vectors"))
elif k == "smoke_sha":
    print(one(r"identical `\d+ B` stdout SHA-256 \(`([0-9a-f]{64})`\)"))
elif k == "smoke_bytes":
    print(one(r"identical `(\d+) B` stdout SHA-256"))
elif k.startswith("size_"):
    row = {"native_dbg": "Native Debug", "native_rel": "Native Release", "wasm_dbg": "Wasm32 Debug",
           "wasm_rel": "Wasm32 Release"}[k[5:]]
    print(one(r"\| %s \| `([\d,]+) B`" % row).replace(",", ""))
elif k in ("bench_sha1", "bench_sha2"):
    shas = re.findall(r"Stdout SHA-256 verified identical across all rounds: `([0-9a-f]{64})`", t)
    print(shas[int(k[-1]) - 1])
elif k in ("speedup1", "speedup2"):
    rows = re.findall(r"\| `pion` \(`--release`\) \|.*\| ([\d.]+)x \|", t)
    print(rows[int(k[-1]) - 1])
elif k in ("rss1", "rss2"):
    rows = re.findall(r"\| `pion` \(`--release`\) \|(?:[^|]*\|){5} \*{0,2}([\d.]+) MiB", t)
    print(rows[int(k[-1]) - 1])
elif k in ("rrss1", "rrss2"):
    rows = re.findall(r"\| `rust_sfv` \(`[^`]*`\) \|(?:[^|]*\|){5} \*{0,2}([\d.]+) MiB", t)
    print(rows[int(k[-1]) - 1])
elif k in ("send", "notsend"):
    out = []
    for row in re.findall(r"^\| (.*?) \| (\*\*`Send`\*\*|`!Send`) \|", t, re.M):
        if (row[1] == "`!Send`") == (k == "notsend"):
            out += re.findall(r"`([A-Za-z]+)`", row[0])
    print(" ".join(out))
else:
    sys.exit("unknown key " + k)
