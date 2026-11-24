#!/usr/bin/env python3
"""Claims of packages/zstd/README.md, parsed at audit time (nothing is hard-coded in run_audit.sh).
usage: readme.py <README.md> <key> [args]
keys: smoke_sha                 the 4-mode wasm_smoke stdout SHA-256
      send_table                exit 0 iff the Send table lists exactly the 5 rows the static probe checks
      bench_check <bench.log>   cross-check counts (64 + 1 + 128 = 193) and compressed sizes of the 1 MiB corpora
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


if k == "smoke_sha":
    print(one(r"identical stdout SHA-256 \(`([0-9a-f]{64})`\)"))
elif k == "send_table":
    rows = re.findall(r"^\| `([^`]+)`(?: / `([^`]+)`)?(?: \(`[^`]+`\))? \| \*\*`(!?Send)`\*\*", t, re.M)
    got = sorted((a, b, s) for a, b, s in rows)
    want = sorted([("ZstdLimits", "", "Send"), ("ZstdError", "", "Send"), ("Int64", "", "Send"),
                   ("Bytes", "Result[Bytes, ZstdError]", "!Send")])
    print("  README.md Send table rows: %s" % got)
    sys.exit(0 if got == want else 1)
elif k == "bench_check":
    log = open(sys.argv[3]).read()
    rc = 0
    m = re.search(r"PASS: bidirectional parity verified \((\d+) byte-exact cross-checks, 0 mismatches\)", log)
    claim = one(r"Bidirectional Byte-Exact Parity \(`(\d+)` Cross-Checks, `0` Mismatches\)")
    print("  parity cross-checks: bench %s, README.md %s" % (m.group(1) if m else "NOT PASSED", claim))
    rc |= (not m) or m.group(1) != claim
    for corpus, label in (("web_1m.bin", "Web HTML/CSS/JS/JSON"), ("binlog_1m.bin", "Structured Binary Log")):
        b = re.search(r"Ratio %s \(\d+ B\): zstd-L3=(\d+) B .*pion-L3=(\d+) B .*pion-L6=(\d+) B" % re.escape(corpus), log)
        r = re.search(r"\| %s \| [\d,]+ B \| ([\d,]+) B \([\d.]+%%\) \| ([\d,]+) B \([\d.]+%%\) \| ([\d,]+) B" % re.escape(label), t)
        if not b or not r:
            print("  %s: sizes not found (bench %s, README.md %s)" % (corpus, bool(b), bool(r)))
            rc = 1
            continue
        got = tuple(int(x) for x in b.groups())
        want = tuple(int(x.replace(",", "")) for x in r.groups())
        print("  %s: zstd -3 / pion L3 / pion L6 = %s, README.md %s %s" % (corpus, got, want,
                                                                         "reproduced" if got == want else "DIFFERENT"))
        rc |= got != want
    sys.exit(1 if rc else 0)
else:
    sys.exit("unknown key " + k)
