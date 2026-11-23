#!/usr/bin/env python3
"""4-mode consistency: run the Pion probe as native debug / native release / wasm32 debug / wasm32 release
(node) over the HPACK, frame and connection corpora, with crash/trap isolation, and require byte-identical
per-case output (aborts must hit the same cases in every mode).

usage: four_modes.py <bin_dir> <wasm_rt.mjs> <hpack.txt> <frames.txt> <scenarios.txt>
expects <bin_dir>/probe_{debug,release} and <bin_dir>/probe_{debug,release}.wasm
"""
import hashlib
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import run_pion  # noqa: E402

bind, rt, hp, frm, scen = sys.argv[1:6]
modes = {
    "native-debug": [os.path.join(bind, "probe_debug")],
    "native-release": [os.path.join(bind, "probe_release")],
    "wasm32-debug": ["node", rt, os.path.join(bind, "probe_debug.wasm")],
    "wasm32-release": ["node", rt, os.path.join(bind, "probe_release.wasm")],
}
ok = True
print("| corpus | cases | mode | aborts | sha256(per-case output) |")
print("|---|---:|---|---:|---|")
for label, mode, path in [("hpack", "hpack", hp), ("frames", "frames", frm), ("conn", "conn", scen)]:
    n = len(open(path).read().splitlines())
    digests = set()
    for m, cmd in modes.items():
        out, crashes = run_pion(cmd, mode, path, n)
        # abort messages differ by platform (pion panic vs wasm trap); compare *where* aborts happen
        canon = "\n".join("<ABORT>" if l is None else l for l in out)
        d = hashlib.sha256(canon.encode("latin-1")).hexdigest()
        digests.add(d)
        print(f"| {label} | {n} | {m} | {len(crashes)} | `{d[:16]}` |")
    if len(digests) != 1:
        ok = False
print()
print("4-mode result:", "IDENTICAL" if ok else "MISMATCH")
sys.exit(0 if ok else 1)
