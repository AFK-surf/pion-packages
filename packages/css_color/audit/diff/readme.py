#!/usr/bin/env python3
"""Claims of packages/css_color/README.md, parsed at audit time (nothing is hard-coded in run_audit.sh).
  python3 -I readme.py <README.md> <key>
keys: smoke_line | smoke_sha | wasm_sizes (debug release, bytes) | diff_counts (total parse mix gamut) |
      diff_maxerr (parse mix, float) | bench <A|B> (pion_median rust_median pion_speedup)"""
import re
import sys


def main():
    t = open(sys.argv[1], encoding="utf-8").read()
    k = sys.argv[2]
    if k == "smoke_line":
        print(re.search(r"Output: `([^`]+)`", t).group(1))
    elif k == "smoke_sha":
        print(re.search(r"SHA-256[^`]*`([0-9a-f]{64})`", t).group(1))
    elif k == "wasm_sizes":
        m = re.search(r"Wasm32 binary size: `([\d,]+) B` \(debug\), `([\d,]+) B`", t)
        print(m.group(1).replace(",", ""), m.group(2).replace(",", ""))
    elif k == "diff_counts":
        total = re.search(r"\*\*([\d,]+)\*\* deterministic test cases", t).group(1).replace(",", "")
        rows = re.findall(r"^\| (Parse \+ Space Convert|`color-mix\(\)`|W3C Oklch)[^|]*\| ([\d,]+) \|", t, re.M)
        print(total, " ".join(r[1].replace(",", "") for r in rows))
    elif k == "diff_maxerr":
        rows = re.findall(r"^\| (?:Parse \+ Space Convert|`color-mix\(\)`)[^|]*\| [\d,]+ \| `([0-9.]+)`", t, re.M)
        print(" ".join(rows))
    elif k == "bench":
        sc = sys.argv[3]
        sec = t.split("#### Scenario %s" % sc, 1)[1].split("####", 1)[0]
        p = re.search(r"^\| `pion_css_color`[^|]*\| ([\d.]+) \|.*\| ([\d.]+)x \|\s*$", sec, re.M)
        r = re.search(r"^\| `rust_color`[^|]*\| ([\d.]+) \|", sec, re.M)
        print(p.group(1), r.group(1), p.group(2))
    else:
        sys.exit("unknown key " + k)


if __name__ == "__main__":
    main()
