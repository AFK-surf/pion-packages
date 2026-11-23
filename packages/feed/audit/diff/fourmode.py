#!/usr/bin/env python3
"""4-mode consistency: every request file through native rel/dbg and wasm32 rel/dbg; stdout SHA-256 must match.
usage: fourmode.py <bin_dir> <wasm_rt> <requests.tsv>...   exit 1 on any mismatch / non-zero exit / crash."""
import hashlib
import subprocess
import sys


def main():
    b, rt = sys.argv[1:3]
    modes = [("native_rel", [b + "/probe"]), ("native_dbg", [b + "/probe_dbg"]),
             ("wasm_rel", ["node", rt, b + "/probe.wasm"]), ("wasm_dbg", ["node", rt, b + "/probe_dbg.wasm"])]
    bad = 0
    for req in sys.argv[3:]:
        n = sum(1 for _ in open(req))
        res = {}
        for mode, cmd in modes:
            p = subprocess.run(cmd + ["batch", req], capture_output=True, timeout=900)
            res[mode] = (p.returncode, hashlib.sha256(p.stdout).hexdigest(), len(p.stdout))
        same = len({v[1] for v in res.values()}) == 1 and all(v[0] == 0 for v in res.values())
        bad += not same
        print("  %-28s %5d requests  %s" % (req.split("/")[-1], n, "IDENTICAL" if same else "MISMATCH"))
        for mode, (rc, h, ln) in res.items():
            print("      %-10s rc=%d sha256=%s bytes=%d" % (mode, rc, h, ln))
    print("4-mode mismatches: %d" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
