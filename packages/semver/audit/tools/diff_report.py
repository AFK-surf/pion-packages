#!/usr/bin/env python3
"""Compare Pion vs Rust oracle outputs for the same corpus; bucket and print counterexamples.

Usage: diff_report.py <corpus> <pion_out> <rust_out> [max_examples_per_bucket]
Exit code 1 when any mismatch exists.
"""

import re
import sys
from collections import OrderedDict

KIND_NAMES = {
    "V": "Version::parse", "R": "VersionReq::parse", "C": "Comparator::parse",
    "P": "Prerelease::new", "B": "BuildMetadata::new", "M": "VersionReq::matches",
    "K": "Comparator::matches", "O": "Ord/cmp_precedence/Eq",
}


def dec(h):
    return bytes.fromhex(h).decode("utf-8")


def bucket(kind, inp, p, r):
    big = re.search(r"\d{19,}", inp) is not None
    if big and ("exceeds" in p or "exceeds" in r):
        nums = [int(x) for x in re.findall(r"\d{19,}", inp)]
        if any(9223372036854775807 < n <= 18446744073709551615 for n in nums):
            return "u64-range-rejected (Int64::MAX < n <= u64::MAX)"
        return "overflow-message (Int64::MAX vs u64::MAX)"
    if p.startswith("err|") and r.startswith("err|"):
        return "error-message/char-escaping"
    if kind in "MK" and ("verr" in p or "rerr" in p):
        return "u64-range-rejected (Int64::MAX < n <= u64::MAX)" if big else "parse-diff-in-match"
    return "semantic"


def main():
    corpus = [l for l in open(sys.argv[1], encoding="utf-8").read().split("\n") if l]
    pion = open(sys.argv[2], encoding="utf-8", errors="surrogateescape").read().split("\n")
    rust = open(sys.argv[3], encoding="utf-8").read().split("\n")
    maxn = int(sys.argv[4]) if len(sys.argv) > 4 else 6
    pion = pion[: len(corpus)]
    rust = rust[: len(corpus)]
    if len(pion) != len(corpus) or len(rust) != len(corpus):
        print(f"LINE COUNT MISMATCH corpus={len(corpus)} pion={len(pion)} rust={len(rust)}")
        return 1
    total = {}
    buckets = OrderedDict()
    for line, p, r in zip(corpus, pion, rust):
        f = line.split(" ")
        k = f[0]
        total[k] = total.get(k, 0) + 1
        if p == r:
            continue
        inp = " | ".join(repr(dec(x)) for x in f[1:])
        b = (KIND_NAMES[k], bucket(k, inp, p, r))
        buckets.setdefault(b, []).append((inp, p, r))
    nm = sum(len(v) for v in buckets.values())
    print(f"cases: {sum(total.values())} ({', '.join(f'{KIND_NAMES[k]}={n}' for k, n in sorted(total.items()))})")
    print(f"mismatches: {nm}")
    for (api, why), items in buckets.items():
        print(f"\n## {api} :: {why} -- {len(items)} mismatches")
        for inp, p, r in items[:maxn]:
            print(f"  input: {inp}")
            print(f"    pion: {p!r}")
            print(f"    rust: {r!r}")
    return 1 if nm else 0


if __name__ == "__main__":
    sys.exit(main())
