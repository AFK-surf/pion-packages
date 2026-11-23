#!/usr/bin/env python3
"""Native vs Wasm32 4-mode consistency of the red-team harness.

usage: wasm32_modes.py <corpus_dir> <bin_dir> <pion_wasm_rt.mjs>

Runs `harness check` (verdict + FNV-1a of re-encoded bytes + FNV-1a of WAT text) in
native-debug, native-release, wasm32-debug and wasm32-release over the corpus and diffs
the per-file lines.  Aborted runs are resumed on the next file (CRASH lines recorded).
"""
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from diff import load_tsv, run_pion  # noqa: E402


def main():
    d, bindir, rt = sys.argv[1:4]
    ids = sorted(load_tsv(open(os.path.join(d, "manifest.tsv")).read()))
    modes = {
        "native-debug": ((), os.path.join(bindir, "harness_debug")),
        "native-release": ((), os.path.join(bindir, "harness")),
        "wasm32-debug": (("node", "--stack-size=8000", rt), os.path.join(bindir, "harness_debug.wasm")),
        "wasm32-release": (("node", "--stack-size=8000", rt), os.path.join(bindir, "harness_release.wasm")),
    }
    res = {}
    for m, (prefix, b) in modes.items():
        res[m] = run_pion(d, b, ids, 900, prefix)
    # A crash is a crash in every mode; only the runtime's message format differs.
    for m in res:
        for i, v in res[m].items():
            if v[0].startswith("CRASH"):
                res[m][i] = ["CRASH"] + v[1:]
    base = res["native-release"]
    diffs = Counter()
    examples = {}
    for i in ids:
        ref = base.get(i)
        for m in modes:
            got = res[m].get(i)
            if got != ref:
                diffs[m] += 1
                examples.setdefault(m, (i, ref, got))
    crashes = {m: sorted(i for i, v in res[m].items() if v[0] in ("CRASH", "TIMEOUT")) for m in modes}
    print(f"corpus={d} files={len(ids)}")
    for m in modes:
        print(f"  {m:15} lines={len(res[m])} crash_or_trap={crashes[m]} diff_vs_native_release={diffs[m]}")
    for m, (i, a, b) in examples.items():
        print(f"  first diff {m}: #{i}\n    native-release={a}\n    {m}={b}")


if __name__ == "__main__":
    main()
