#!/usr/bin/env python3
"""Property check on the `R` (round-trip) suite: for every input that parses,
re-parsing its serialization must yield an identical URL record. Reports
violations for Pion and Rust `url v2.5.9` independently (no oracle needed).
Usage: roundtrip.py <roundtrip.in> <pion_bin> <rust_bin> <out.txt>
"""
import json
import subprocess
import sys

N = 12  # fields after the status in dump()


def run(binary, data):
    p = subprocess.run([binary], input=data, capture_output=True, timeout=300)
    assert p.returncode == 0
    return [[bytes.fromhex(x).decode("utf-8", "replace") for x in l.split("\t")]
            for l in p.stdout.decode().splitlines()]


def main():
    path, pion, rust, out = sys.argv[1:5]
    data = open(path, "rb").read()
    lines = [l for l in data.decode().splitlines() if l]
    res = {"pion": run(pion, data), "rust": run(rust, data)}
    bad = {"pion": [], "rust": []}
    parsed = {"pion": 0, "rust": 0}
    for who, rows in res.items():
        for ln, r in zip(lines, rows):
            if r[0] == "REPARSE-ERR":
                parsed[who] += 1
                bad[who].append((ln, "serialization does not re-parse: %r" % r[1]))
            elif r[0] == "OK":
                parsed[who] += 1
                a, b = r[1:1 + N], r[1 + N:]
                if a != b:
                    bad[who].append((ln, "href %r -> re-parsed %r" % (a[0], b[0]) +
                                     ("" if a[0] != b[0] else "  (component drift: %s)" % json.dumps(
                                         [(i, x, y) for i, (x, y) in enumerate(zip(a, b)) if x != y]))))
    with open(out, "w", encoding="utf-8") as f:
        for who in ("pion", "rust"):
            f.write("== %s: %d non-idempotent of %d parsed\n" % (who, len(bad[who]), parsed[who]))
            for ln, msg in bad[who]:
                case = [None if x == "~" else bytes.fromhex(x).decode("utf-8", "replace")
                        for x in ln.split("\t")]
                f.write("  %s\n    %s\n" % (json.dumps(case[1:], ensure_ascii=True), msg))
    for who in ("pion", "rust"):
        print("round-trip %-4s: %d non-idempotent / %d parsed" % (who, len(bad[who]), parsed[who]))


if __name__ == "__main__":
    main()
