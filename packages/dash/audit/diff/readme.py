#!/usr/bin/env python3
"""Numbers README.md claims, parsed at run time so the gates follow a fixed README (nothing hard-coded).

readme.py <README.md> <key>   keys: smoke_sha bench_sha speedup throughput tests diff_manifests
                                    wasm_dbg_kib wasm_rel_kib rss_pion rss_rust send_claim
Exit 2 (and no output) when the claim is not found.
"""
import re
import sys


def main():
    t = open(sys.argv[1], encoding="utf-8").read()
    k = sys.argv[2]
    pats = {
        "smoke_sha": r"wasm_smoke[\s\S]*?SHA-256: `([0-9a-f]{64})`",
        "bench_sha": r"SHA-256 verified identical across all implementations and rounds: `([0-9a-f]{64})`",
        "speedup": r"\| \*\*([0-9.]+)x\*\* \|",
        "throughput": r"\| ([0-9.]+) MB/s \([0-9,.]+ ns/op\) \|",
        "tests": r"\*\*([0-9]+)\*\* test groups passing",
        "diff_manifests": r"\*\*([0-9]+) / [0-9]+\*\* synthetic MPD manifests",
        "wasm_dbg_kib": r"`wasm32 debug` \(\*\*([0-9.]+) KiB\*\*\)",
        "wasm_rel_kib": r"`wasm32 --release` \(\*\*([0-9.]+) KiB\*\*\)",
        "rss_pion": r"\*\*([0-9.]+) MiB\*\* / [0-9.]+ MiB",
        "rss_rust": r"\*\*[0-9.]+ MiB\*\* / ([0-9.]+) MiB",
    }
    if k == "send_claim":
        # a blanket claim ("`Send`-safe" for the whole package) versus a per-type list
        head = "\n".join(t.splitlines()[:5])
        if re.search(r"`Send`-safe", head):
            print("all")
            return 0
        m = re.findall(r"`([A-Za-z]+)` (?:is|are) `Send`", t)
        if m:
            print(" ".join(m))
            return 0
        print("none")
        return 0
    m = re.search(pats[k], t)
    if not m:
        return 2
    print(m.group(1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
