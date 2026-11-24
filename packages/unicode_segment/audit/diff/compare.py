"""Comparators for the RT-unicode-segment audit (stdlib only).

    compare.py ucd   <ucd.expect> <pion_dump>                 official UAX #29 16.0.0 vectors vs Pion
    compare.py rust  <cases> <pion_dump> <rust_dump>          Pion vs a Rust unicode-segmentation oracle
    compare.py inv   <pion_dump>...                           Pion in-process invariants (`I ok`)

Exit status 1 on any unexplained difference. A Pion/Rust difference is explained only when the oracle reports
Unicode 17.0.0 (unicode-segmentation 1.13.x) and the input contains a code point whose segmentation-relevant
properties changed between Unicode 16.0.0 and 17.0.0 (diff/ucd.py drift_set): that is Unicode-version drift,
reported as INFO. Against the Unicode 16.0.0 oracle (1.12.0) nothing is explained.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def parse_dump(path):
    """name -> {tag: rest-of-line}"""
    out = {}
    cur = None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("="):
            cur = {}
            out[line[1:]] = cur
        elif cur is not None and line:
            tag, _, rest = line.partition(" ")
            cur[tag] = rest
    return out


def parse_cases(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        name, _, h = line.rstrip("\n").partition("\t")
        out[name] = b"" if h == "-" else bytes.fromhex(h)
    return out


def scalars(b):
    """Code points as packages/unicode_segment decodes them (ill-formed byte -> U+FFFD of length 1)."""
    out = []
    i = 0
    while i < len(b):
        for ln in (1, 2, 3, 4):
            try:
                s = b[i:i + ln].decode("utf-8")
            except UnicodeDecodeError:
                continue
            if len(s) == 1:
                out.append(ord(s))
                i += ln
                break
        else:
            out.append(0xFFFD)
            i += 1
    return out


def cmd_ucd(expect, dump):
    d = parse_dump(dump)
    tot = {"G": [0, 0], "W": [0, 0], "S": [0, 0]}
    bad = []
    for line in open(expect, encoding="utf-8"):
        name, tag, offs = line.rstrip("\n").split("\t")
        got = d.get(name, {})
        tot[tag][1] += 1
        if got.get(tag, None) == offs and got.get("I") == "ok":
            tot[tag][0] += 1
        else:
            bad.append("%s %s: want [%s] got [%s] I=%s" % (name, tag, offs, got.get(tag), got.get("I")))
    names = {"G": "GraphemeBreakTest", "W": "WordBreakTest", "S": "SentenceBreakTest"}
    for t in "GWS":
        print("  %-18s %5d / %5d" % (names[t], tot[t][0], tot[t][1]))
    print("  total              %5d / %5d (boundaries + tiling + concat + cursor at every byte + limits)"
          % (sum(v[0] for v in tot.values()), sum(v[1] for v in tot.values())))
    for b in bad[:20]:
        print("    FAIL " + b)
    return not bad


def cmd_rust(cases, pion, rust):
    c = parse_cases(cases)
    p = parse_dump(pion)
    r = parse_dump(rust)
    ver = next(iter(r.values())).get("V", "?") if r else "?"
    drift = None
    explained = 0
    unexplained = []
    fields = 0
    for name, b in c.items():
        pp, rr = p.get(name), r.get(name)
        if pp is None or rr is None:
            unexplained.append("%s: missing output" % name)
            continue
        diffs = [t for t in "GWUS" if pp.get(t) != rr.get(t)]
        fields += 4
        if not diffs:
            continue
        if ver.startswith("17."):
            if drift is None:
                import ucd
                drift = ucd.drift_set()
            hit = sorted({cp for cp in scalars(b) if cp in drift})
            if hit:
                explained += 1
                continue
        unexplained.append("%s %s: %s\n        pion %s\n        rust %s" % (
            name, ",".join(diffs), b.hex(), " | ".join("%s %s" % (t, pp.get(t)) for t in diffs),
            " | ".join("%s %s" % (t, rr.get(t)) for t in diffs)))
    print("  vs Rust unicode-segmentation (Unicode %s): %d inputs x 4 APIs (G/W/U/S) = %d comparisons, "
          "%d identical inputs, %d Unicode 16->17 drift (INFO), %d unexplained"
          % (ver, len(c), fields, len(c) - explained - len(unexplained), explained, len(unexplained)))
    for u in unexplained[:15]:
        print("    DIFF " + u)
    return not unexplained


def cmd_inv(paths):
    ok = True
    for path in paths:
        d = parse_dump(path)
        bad = [(n, v.get("I")) for n, v in d.items() if v.get("I") != "ok"]
        print("  %s: %d inputs, %d with invariant violations" % (os.path.basename(path), len(d), len(bad)))
        for n, i in bad[:10]:
            print("    INV %s: %s" % (n, (i or "")[:200]))
        ok = ok and not bad
    return ok


if __name__ == "__main__":
    m = sys.argv[1]
    if m == "ucd":
        r = cmd_ucd(sys.argv[2], sys.argv[3])
    elif m == "rust":
        r = cmd_rust(sys.argv[2], sys.argv[3], sys.argv[4])
    elif m == "inv":
        r = cmd_inv(sys.argv[2:])
    else:
        raise SystemExit("unknown mode " + m)
    sys.exit(0 if r else 1)
