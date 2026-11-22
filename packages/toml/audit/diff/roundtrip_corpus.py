#!/usr/bin/env python3
"""stringify round-trip fidelity over the official toml-test valid corpus (TOML 1.0.0 list).

For every valid file F:  pion parse(F) -> pion stringify -> T ;  then a *correct third party*
(Rust toml 1.2) decodes T and must yield the same data as decoding F.  Same procedure for
Rust's own to_string for comparison.
usage: roundtrip_corpus.py <toml-test checkout>
"""
import os, subprocess, sys, tempfile, json
sys.path.insert(0, os.path.dirname(__file__))
from difflib_toml import run, same, BIN

root = sys.argv[1]
files = [l.strip() for l in open(os.path.join(root, "tests/files-toml-1.0.0")) if l.startswith("valid/") and l.strip().endswith(".toml")]
stats = {"pion": [0, []], "rust_toml_1.2": [0, []]}
mode = {"pion": [f"{BIN}/pion_cli", "roundtrip"], "rust_toml_1.2": [f"{BIN}/rust_ref", "roundtrip"]}
for rel in files:
    data = open(os.path.join(root, "tests", rel), "rb").read()
    st, want = run("rust_toml_1.2", data)
    if st != "ok":
        continue
    for impl in stats:
        r = subprocess.run(mode[impl] + [os.path.join(root, "tests", rel)], capture_output=True)
        if r.returncode != 0:
            stats[impl][1].append((rel, "stringify failed: " + r.stderr.decode()[:100]))
            continue
        st2, got = run("rust_toml_1.2", r.stdout)
        if st2 != "ok":
            stats[impl][1].append((rel, "re-parse failed: " + got[:120]))
            continue
        d = same(want, got)
        if d:
            stats[impl][1].append((rel, d))
        else:
            stats[impl][0] += 1
for impl, (ok, bad) in stats.items():
    print(f"{impl}: {ok} faithful, {len(bad)} broken")
    for rel, why in bad:
        print(f"   {rel}: {why}")
