"""Independent UAX #29 16.0.0 word-boundary reference (stdlib only), written rule by rule from tr29-45 §4.1.

Used only to arbitrate Pion / Rust disagreements: Rust unicode-segmentation (1.12.0 and 1.13.3) mishandles
`AHLetter|Numeric (MidLetter|MidNum|MidNumLetQ) ZWJ ExtPict` (it keeps the whole run in one word); Pion and this
reference break before the punctuation as WB6 / WB12 require (the next non-ignorable is not AHLetter / Numeric).

    python3 -I -B wbref.py selftest          # must reproduce every line of the official WordBreakTest.txt
"""

import gzip
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ucd  # noqa: E402

IGN = {"Extend", "Format", "ZWJ"}
NL = {"CR", "LF", "Newline"}
AH = {"ALetter", "Hebrew_Letter"}
MNLQ = {"MidNumLet", "Single_Quote"}


def _p():
    return ucd.props("16.0.0")


def bounds(cps):
    """Boundary indices (in code points) of the UAX #29 word segmentation of `cps`."""
    p = _p()
    n = len(cps)
    if n == 0:
        return []
    w = [p.wb[c] for c in cps]

    def base(j):
        # WB4: X (Extend | Format | ZWJ)* -> X, except after sot / CR / LF / Newline
        k = j
        while k > 0 and w[k] in IGN and w[k - 1] not in NL:
            k -= 1
        return k

    def nxt(i):
        k = i
        while k < n and w[k] in IGN:
            k += 1
        return w[k] if k < n else None

    out = [0]
    for i in range(1, n):
        a, b = w[i - 1], w[i]
        if a == "CR" and b == "LF":                      # WB3
            continue
        if a in NL or b in NL:                           # WB3a / WB3b
            out.append(i)
            continue
        if a == "ZWJ" and p.ep[cps[i]]:                  # WB3c
            continue
        if a == "WSegSpace" and b == "WSegSpace":        # WB3d
            continue
        if b in IGN:                                     # WB4
            continue
        pk = base(i - 1)
        pv = w[pk]
        p2 = None
        if pk > 0 and w[pk - 1] not in NL:
            p2 = w[base(pk - 1)]
        nx = nxt(i + 1)
        if pv in AH and b in AH:                                             # WB5
            continue
        if pv in AH and (b == "MidLetter" or b in MNLQ) and nx in AH:      # WB6
            continue
        if p2 in AH and (pv == "MidLetter" or pv in MNLQ) and b in AH:     # WB7
            continue
        if pv == "Hebrew_Letter" and b == "Single_Quote":                   # WB7a
            continue
        if pv == "Hebrew_Letter" and b == "Double_Quote" and nx == "Hebrew_Letter":   # WB7b
            continue
        if p2 == "Hebrew_Letter" and pv == "Double_Quote" and b == "Hebrew_Letter":   # WB7c
            continue
        if pv == "Numeric" and b == "Numeric":                              # WB8
            continue
        if pv in AH and b == "Numeric":                                     # WB9
            continue
        if pv == "Numeric" and b in AH:                                     # WB10
            continue
        if p2 == "Numeric" and (pv == "MidNum" or pv in MNLQ) and b == "Numeric":     # WB11
            continue
        if pv == "Numeric" and (b == "MidNum" or b in MNLQ) and nx == "Numeric":      # WB12
            continue
        if pv == "Katakana" and b == "Katakana":                            # WB13
            continue
        if (pv in AH or pv in ("Numeric", "Katakana", "ExtendNumLet")) and b == "ExtendNumLet":  # WB13a
            continue
        if pv == "ExtendNumLet" and (b in AH or b in ("Numeric", "Katakana")):  # WB13b
            continue
        if pv == "Regional_Indicator" and b == "Regional_Indicator":       # WB15 / WB16
            cnt, k = 0, pk
            while w[k] == "Regional_Indicator":
                cnt += 1
                if k == 0 or w[k - 1] in NL:
                    break
                k = base(k - 1)
            if cnt % 2 == 1:
                continue
        out.append(i)                                                        # WB999
    out.append(n)
    return out


def dump_lines(b, scalars_fn):
    """(`W` line, `U` line) in the audit dump format for raw bytes `b` (ill-formed byte = U+FFFD of length 1)."""
    p = _p()
    cps = scalars_fn(b)
    lens = []
    i = 0
    while i < len(b):
        for ln in (1, 2, 3, 4):
            try:
                s = b[i:i + ln].decode("utf-8")
            except UnicodeDecodeError:
                continue
            if len(s) == 1:
                lens.append(ln)
                i += ln
                break
        else:
            lens.append(1)
            i += 1
    pos = [0]
    for ln in lens:
        pos.append(pos[-1] + ln)
    bd = bounds(cps)
    wl = " ".join(str(pos[k]) for k in bd)
    us = []
    for a, z in zip(bd, bd[1:]):
        if any(p.alnum[c] for c in cps[a:z]):
            us.append("%d-%d" % (pos[a], pos[z]))
    return wl, " ".join(us)


def selftest():
    tot = bad = 0
    with gzip.open(os.path.join(ucd.UCD_ROOT, "16.0.0", "WordBreakTest.txt.gz"), "rt", encoding="utf-8") as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            toks = line.split()
            cps = [int(t, 16) for t in toks if t not in ("÷", "×")]
            flags = [t == "÷" for t in toks if t in ("÷", "×")]
            tot += 1
            if bounds(cps) != [i for i, fl in enumerate(flags) if fl]:
                bad += 1
    print("  independent WB reference (diff/wbref.py) vs official WordBreakTest 16.0.0: %d/%d" % (tot - bad, tot))
    return bad == 0


if __name__ == "__main__":
    if sys.argv[1] == "selftest":
        sys.exit(0 if selftest() else 1)
