#!/usr/bin/env python3
"""Read the numbers packages/hls/README.md claims (nothing is hard-coded in run_audit.sh).

usage: readme.py <README.md> <key>
keys: smoke_sha | wasm_dbg | wasm_rel | diff_playlists | diff_records | bench_sha | speedup | throughput
      send_claims   -> `send <types>` / `notsend <types>` / `mutex 0|1` / `move 0|1` lines, read from the sentence
                       of README.md that says which public types are `Send` and which are `!Send`
"""
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
if sys.argv[2] == "send_claims":
    para = next((p for p in re.split(r"\n\s*\n", text) if "`!Send`" in p), "")
    names = lambda t: [n for n in re.findall(r"`([A-Z][A-Za-z0-9]*)`", t) if n not in ("Send", "Array", "Mutex")]
    i = para.find("are `Send`")
    j = para.find("are `!Send`")
    st = max(para.rfind(";", 0, i), para.rfind("(", 0, i), para.rfind(".", 0, i)) + 1 if i >= 0 else 0
    print("send " + " ".join(names(para[st:i]) if i >= 0 else []))
    print("notsend " + " ".join(names(para[i + 10:j]) if j > i >= 0 else []))
    tail = para[j:] if j >= 0 else ""
    print("mutex %d" % ("Mutex" in tail))
    print("move %d" % ("`move`" in tail or " move " in tail))
    sys.exit(0)
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
