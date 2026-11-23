#!/usr/bin/env python3
"""Bucket a run_diff.py mismatch file by root cause. usage: classify.py <x.mismatch.txt> [--examples N]"""
import re
import sys
from collections import OrderedDict

BUCKETS = [
    ("checker-cross-type-numeric (Pion accepts int/uint/double mixes cel-go's default checker rejects; design choice)",
     lambda e, p, g: p.startswith("OK") and g.startswith("CERR") and re.search(r"applied to '\((int|uint|double), (int|uint|double)\)'", g)),
    ("checker-too-lenient (other CERR in cel-go, accepted by Pion) [P2-5]",
     lambda e, p, g: not p.startswith("CERR") and g.startswith("CERR")),
    ("negative-zero lost (`-x` computed as `0.0 - x`) [P2-9]",
     lambda e, p, g: p.startswith("OK") and g.startswith("OK") and ("8000000000000000" in g or "-0.0" in e) and p != g),
    ("double literal / double() rounding (naive decimal->binary) [P1-1]",
     lambda e, p, g: p.startswith("OK") and g.startswith("OK") and re.search(r"\d(e[-+]?\d+|\.\d{6,})", e)),
    ("string(double) formatting [P1-9]",
     lambda e, p, g: p.startswith("OK string") and g.startswith("OK string") and "string(" in e),
    ("NaN ordering returns false instead of error [P2-4]",
     lambda e, p, g: "NaN values cannot be ordered" in g),
    ("exact int/uint vs double comparison: cel-go converts int->double lossily (Pion exact; FAIRNESS)",
     lambda e, p, g: p.startswith("OK bool") and g.startswith("OK bool") and re.search(r"dyn\((9007199254740993|9223372036854775807|18446744073709551615u)\)", e) is not None),
    ("double literal out of range / huge literal rounding [P1-1]",
     lambda e, p, g: re.search(r"\d{15,}\.\d|\de[-+]?\d{3}", e) is not None),
    ("regex dialect: Rust regex instead of RE2 [P1-6]",
     lambda e, p, g: "matches(" in e),
    ("time zones: IANA / sign-less offsets unsupported [P1-7]",
     lambda e, p, g: re.search(r"get\w+\('", e) is not None),
    ("duration.getMilliseconds total vs component [P1-8]",
     lambda e, p, g: "getMilliseconds" in e),
    ("duration range / silent wrap / int(duration) [P1-2, P1-3, P2-6]",
     lambda e, p, g: "duration(" in e),
    ("timestamp range / RFC 3339 strictness / string(ts) offset [P1-4, P2-6, P2-7]",
     lambda e, p, g: "timestamp(" in e),
    ("map literal duplicate keys / invalid key types [P1-5, P2-8]",
     lambda e, p, g: e.startswith("{")),
    ("grammar: reserved words, rb'', nested then-ternary, cel-go `[,]` quirk [P2-1, P2-2]",
     lambda e, p, g: p.startswith("OK") != g.startswith("OK") and (g.startswith("PERR") or p.startswith("PERR"))),
    ("double() string parsing gaps (infinity / INF / 1_000 / hex float) [P2-6]",
     lambda e, p, g: e.startswith("double('")),
    ("list index by double / has() on non-map [P2-6]",
     lambda e, p, g: "[1.0]" in e or e.startswith("has(")),
    ("int/uint vs double equality: cel-go lossy int->double (Pion exact; fairness)",
     lambda e, p, g: p.startswith("OK bool") and g.startswith("OK bool")),
    ("non-bool logical operand not absorbed [P2-3]",
     lambda e, p, g: "requires bool" in p and g.startswith("OK")),
    ("other", lambda e, p, g: True),
]


def main():
    path = sys.argv[1]
    nex = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == "--examples" else 2
    txt = open(path).read().split("\n")
    cases = []
    i = 0
    while i + 2 < len(txt) + 1 and i < len(txt):
        if txt[i].startswith("#"):
            hdr = txt[i]
            expr = hdr.split("] ", 1)[1] if "] " in hdr else hdr
            p = txt[i + 1].strip()[len("pion: "):]
            g = txt[i + 2].strip()[len("go:   "):].strip() if txt[i + 2].strip().startswith("go:") else txt[i + 2]
            g = txt[i + 2].strip()[len("go:"):].strip()
            cases.append((expr, p, g))
            i += 3
        else:
            i += 1
    out = OrderedDict((b[0], []) for b in BUCKETS)
    for e, p, g in cases:
        for name, f in BUCKETS:
            if f(e, p, g):
                out[name].append((e, p, g))
                break
    for name, xs in out.items():
        if not xs:
            continue
        print("%5d  %s" % (len(xs), name))
        for e, p, g in xs[:nex]:
            print("         e.g. %s  | pion: %s | go: %s" % (e[:90], p[:70], g[:70]))


if __name__ == "__main__":
    main()
