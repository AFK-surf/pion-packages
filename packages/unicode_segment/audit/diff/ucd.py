"""Independent Unicode Character Database reader for the RT-unicode-segment audit (stdlib only).

Written from UAX #44 file formats, not from packages/unicode_segment/tools/gen_tables.py. Reads the vendored,
gzip-compressed official files in audit/ucd/<version>/ (16.0.0 is the package's target, 17.0.0 is what Rust
unicode-segmentation 1.13.3 embeds and is only used to classify oracle drift).

    python3 -I -B ucd.py tables <tables.pion> <pion_dump>  # compare the in-Pion lookup of all code points
"""

import gzip
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UCD_ROOT = os.path.join(os.path.dirname(HERE), "ucd")
NCP = 0x110000


def _open(ver, name):
    return gzip.open(os.path.join(UCD_ROOT, ver, name + ".gz"), "rt", encoding="utf-8")


def _ranges(ver, name):
    """Yield (lo, hi, fields) for every data line of a semicolon-separated UCD file."""
    with _open(ver, name) as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            fields = [x.strip() for x in line.split(";")]
            cps = fields[0]
            if ".." in cps:
                a, b = cps.split("..")
                lo, hi = int(a, 16), int(b, 16)
            else:
                lo = hi = int(cps, 16)
            yield lo, hi, fields[1:]


def enum_prop(ver, name, default="Other"):
    arr = [default] * NCP
    for lo, hi, fs in _ranges(ver, name):
        for cp in range(lo, hi + 1):
            arr[cp] = fs[0]
    return arr


def binary_prop(ver, name, prop):
    s = bytearray(NCP)
    for lo, hi, fs in _ranges(ver, name):
        if fs[0] == prop:
            for cp in range(lo, hi + 1):
                s[cp] = 1
    return s


def incb(ver):
    arr = ["None"] * NCP
    for lo, hi, fs in _ranges(ver, "DerivedCoreProperties.txt"):
        if fs[0] == "InCB":
            for cp in range(lo, hi + 1):
                arr[cp] = fs[1]
    return arr


def numeric_gc(ver):
    """General_Category N* (Nd | Nl | No), with <..., First> / <..., Last> ranges expanded."""
    s = bytearray(NCP)
    first = None
    with _open(ver, "UnicodeData.txt") as f:
        for raw in f:
            fs = raw.rstrip("\n").split(";")
            if len(fs) < 3:
                continue
            cp, name, gc = int(fs[0], 16), fs[1], fs[2]
            if name.endswith(", First>"):
                first = cp
                continue
            lo = first if name.endswith(", Last>") else cp
            first = None
            if gc in ("Nd", "Nl", "No"):
                for c in range(lo, cp + 1):
                    s[c] = 1
    return s


class Props:
    """All properties UAX #29 (and unicode_words' alphanumeric filter) depend on, for one Unicode version."""

    def __init__(self, ver):
        self.ver = ver
        self.gcb = enum_prop(ver, "GraphemeBreakProperty.txt")
        self.wb = enum_prop(ver, "WordBreakProperty.txt")
        self.sb = enum_prop(ver, "SentenceBreakProperty.txt")
        self.ep = binary_prop(ver, "emoji-data.txt", "Extended_Pictographic")
        self.incb = incb(ver)
        alpha = binary_prop(ver, "DerivedCoreProperties.txt", "Alphabetic")
        num = numeric_gc(ver)
        self.alnum = bytearray(a | b for a, b in zip(alpha, num))

    def key(self, cp):
        return (self.gcb[cp], self.wb[cp], self.sb[cp], self.ep[cp], self.incb[cp], self.alnum[cp])


_cache = {}


def props(ver):
    if ver not in _cache:
        _cache[ver] = Props(ver)
    return _cache[ver]


def drift_set():
    """Code points whose segmentation-relevant properties differ between Unicode 16.0.0 and 17.0.0."""
    p16, p17 = props("16.0.0"), props("17.0.0")
    return {cp for cp in range(NCP) if p16.key(cp) != p17.key(cp)}


def pion_constants(tables_pion):
    """Name -> value of the `let gcb_* / incb_* / wb_* / sb_* : Int = N` constants (only used to read values)."""
    out = {}
    for line in open(tables_pion, encoding="utf-8"):
        if line.startswith("let ") and ": Int =" in line:
            name = line[4:].split(":")[0].strip()
            out[name] = int(line.split("=")[1])
    return out


def check_tables(tables_pion, dump_path):
    """The in-Pion lookup dump has 6 hex digits per code point (grapheme packed, word packed, sentence)."""
    p = props("16.0.0")
    k = pion_constants(tables_pion)
    norm = lambda s: s.lower()
    gname = {v: n[4:] for n, v in k.items() if n.startswith("gcb_")}
    iname = {v: n[5:] for n, v in k.items() if n.startswith("incb_")}
    wname = {v: n[3:] for n, v in k.items() if n.startswith("wb_")}
    sname = {v: n[3:] for n, v in k.items() if n.startswith("sb_")}
    data = open(dump_path, encoding="ascii").read().split("\n")
    body = data[0]
    extra = data[1] if len(data) > 1 else ""
    assert len(body) == NCP * 6, "dump has %d code points" % (len(body) // 6)
    bad = {"gcb": 0, "extpict(G)": 0, "incb": 0, "wb": 0, "extpict(W)": 0, "alnum": 0, "sb": 0}
    examples = []
    for cp in range(NCP):
        g = int(body[cp * 6:cp * 6 + 2], 16)
        w = int(body[cp * 6 + 2:cp * 6 + 4], 16)
        s = int(body[cp * 6 + 4:cp * 6 + 6], 16)
        got = {
            "gcb": gname.get(g & 15, "?"), "extpict(G)": (g >> 4) & 1, "incb": iname.get((g >> 5) & 3, "?"),
            "wb": wname.get(w & 31, "?"), "extpict(W)": (w >> 5) & 1, "alnum": (w >> 6) & 1, "sb": sname.get(s, "?"),
        }
        want = {
            "gcb": norm(p.gcb[cp]), "extpict(G)": p.ep[cp], "incb": norm(p.incb[cp]),
            "wb": norm(p.wb[cp]), "extpict(W)": p.ep[cp], "alnum": p.alnum[cp], "sb": norm(p.sb[cp]),
        }
        for f in bad:
            if got[f] != want[f]:
                bad[f] += 1
                if len(examples) < 10:
                    examples.append("U+%04X %s: pion %s, UCD %s" % (cp, f, got[f], want[f]))
    total = sum(bad.values())
    print("  in-Pion lookup of all %d code points x 7 properties vs Unicode 16.0.0: %d mismatches %s"
          % (NCP, total, "" if total == 0 else bad))
    for e in examples:
        print("    " + e)
    # out-of-range code points must read as the default class
    ok_extra = extra.strip() == "000000 000000 000000 000000"
    print("  out-of-range lookups (-1, 0x110000, 0x7FFFFFFF, Int min): %s" % ("default" if ok_extra else extra))
    return total == 0 and ok_extra


if __name__ == "__main__":
    if sys.argv[1] == "tables":
        sys.exit(0 if check_tables(sys.argv[2], sys.argv[3]) else 1)
    if sys.argv[1] == "drift":
        d = drift_set()
        print(len(d))
