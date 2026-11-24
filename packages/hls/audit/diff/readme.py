#!/usr/bin/env python3
"""Read the numbers packages/hls/README.md claims (nothing is hard-coded in run_audit.sh).

usage: readme.py <README.md> <key>
keys: smoke_sha | wasm_dbg | wasm_rel | diff_playlists | diff_records | bench_sha | speedup | throughput
"""
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
pat = {
    "smoke_sha": r"SHA-256 \(all 4 modes\): `([0-9a-f]{64})`",
    "wasm_dbg": r"Wasm32 binary size: `([0-9,]+) B` \(debug\)",
    "wasm_rel": r"`([0-9,]+) B` \(`--release`\)",
    "diff_playlists": r"across \*\*([0-9,]+)\*\* synthetic",
    "diff_records": r"\(\*\*([0-9,]+)\*\* field records\)",
    "bench_sha": r"stdout SHA-256 `([0-9a-f]{64})`",
    "speedup": r"\| `pion_hls`[^\n]*\*\*([0-9.]+)x\*\*",
    "throughput": r"\| `pion_hls`(?:[^|\n]*\|){4}\s*([0-9.]+)\s*\|",
}[sys.argv[2]]
m = re.search(pat, text)
if not m:
    sys.exit("README.md: no match for " + sys.argv[2])
print(m.group(1).replace(",", ""))
