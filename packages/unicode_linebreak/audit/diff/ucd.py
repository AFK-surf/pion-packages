"""Independent Unicode 16.0.0 property loader for the RT-unicode-linebreak audit (stdlib only).

Written from the UCD file formats (UAX #44), not from tools/gen_tables.py: every `# @missing` line is
honoured in file order, explicit entries override them, `<..., First>` / `<..., Last>` ranges expand, and the
vendored files are pinned by SHA-256 so a silently swapped data file is caught.

  ucd.py <ucd_dir> verify                      SHA-256 + version header of the vendored files
  ucd.py <ucd_dir> table <public_dump> <whitebox_dump>
        compare, for all 1,114,112 code points, the public line_break_class dump and the white-box
        (raw class, resolved class, flag bits) dump of the package's tables against this loader
  ucd.py <ucd_dir> defaults <gen_tables.py>    the hard-coded block defaults of tools/gen_tables.py vs the
                                                explicit 16.0.0 entries (dead or contradicting?)
"""
import gzip
import hashlib
import os
import re
import sys

PINNED = {
    "LineBreak.txt": "e97e4259d0d20fab150b9c7b4b28abfae5cd78ca97e7f4ac6ed20d685d5f4a7c",
    "EastAsianWidth.txt": "43adc76c0686a42cb370764eb8cfe2b2a45b10b855e5572a2db4a0eecce15d5b",
    "UnicodeData.txt": "ff58e5823bd095166564a006e47d111130813dcf8bf234ef79fa51a870edb48f",
    "emoji-data.txt": "f1365a5173eee18e1f98b240cdc492e84a25f1ce7e0c9d1094eb29c41a22696a",
    "LineBreakTest.txt": "910759a611a479f37df4f535d2e64d7589be3c5ac5f7491cf1fb4fa4cdb211e9",
    "DerivedLineBreak.txt": "4be1c18e7b121d951018065b453bb05083f624c8f905ce8be7c0f354c9097c95",
    "DerivedEastAsianWidth.txt": "372e34de237e5a644ce8379a0d02b91a1f584f04d4fb240ea6ccc87c5767f926",
    "DerivedGeneralCategory.txt": "7676ab755a41ef82108460238569e60ad65c191ddafe61b36c6765ec1353f293",
    # Unicode 15.1.0, used only to explain Rust icu_segmenter 2.4.0 (which still segments with 15.1 Line_Break data)
    "LineBreak-15.1.0.txt": "a55cdc118493491e0a9c885b48eda953a6258a1e218f6050a11891231c79683f",
}
LONG = {"Unknown": "XX", "Ideographic": "ID", "Prefix_Numeric": "PR", "Neutral": "N", "Wide": "W",
        "Unassigned": "Cn"}
N = 0x110000


def read(ucd_dir, name):
    p = os.path.join(ucd_dir, name)
    if os.path.exists(p + ".gz"):
        with gzip.open(p + ".gz", "rb") as f:
            return f.read()
    with open(p, "rb") as f:
        return f.read()


def ranges(text):
    """Yield (lo, hi, fields) for data lines, and ('@missing', lo, hi, fields) for @missing lines."""
    for line in text.split("\n"):
        m = re.match(r"#\s*@missing:\s*([0-9A-F]+)\.\.([0-9A-F]+)\s*;\s*(.*)$", line)
        if m:
            yield ("@missing", int(m.group(1), 16), int(m.group(2), 16), [x.strip() for x in m.group(3).split(";")])
            continue
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        f = [x.strip() for x in s.split(";")]
        r = f[0]
        if ".." in r:
            lo, hi = (int(x, 16) for x in r.split(".."))
        else:
            lo = hi = int(r, 16)
        yield (None, lo, hi, f[1:])


def enumerated(text, default):
    out = [default] * N
    for kind, lo, hi, f in ranges(text):
        v = LONG.get(f[0], f[0]) if kind else f[0]
        out[lo:hi + 1] = [v] * (hi - lo + 1)
    return out


class Props:
    def __init__(self, ucd_dir):
        self.lb = enumerated(read(ucd_dir, "LineBreak.txt").decode("utf-8"), "XX")
        self.eaw = enumerated(read(ucd_dir, "EastAsianWidth.txt").decode("utf-8"), "N")
        self.gc = ["Cn"] * N
        first = None
        for line in read(ucd_dir, "UnicodeData.txt").decode("utf-8").split("\n"):
            p = line.split(";")
            if len(p) < 3:
                continue
            cp = int(p[0], 16)
            if p[1].endswith(", First>"):
                first = cp
            elif p[1].endswith(", Last>"):
                self.gc[first:cp + 1] = [p[2]] * (cp + 1 - first)
            else:
                self.gc[cp] = p[2]
        self.ep = bytearray(N)
        for kind, lo, hi, f in ranges(read(ucd_dir, "emoji-data.txt").decode("utf-8")):
            if kind is None and f[0] == "Extended_Pictographic":
                for c in range(lo, hi + 1):
                    self.ep[c] = 1

    def ea(self, cp):
        return self.eaw[cp] in ("F", "W", "H")

    def resolved(self, cp):
        """LB1 (no tailoring): AI, SG, XX -> AL; SA -> CM if Mn/Mc else AL; CJ -> NS."""
        c = self.lb[cp]
        if c in ("AI", "SG", "XX"):
            return "AL"
        if c == "SA":
            return "CM" if self.gc[cp] in ("Mn", "Mc") else "AL"
        if c == "CJ":
            return "NS"
        return c

    def flags(self, cp):
        """Same bit layout the package documents for its private combo flags."""
        f = 0
        if self.ea(cp):
            f |= 1
        if self.lb[cp] == "QU" and self.gc[cp] == "Pi":
            f |= 2
        if self.lb[cp] == "QU" and self.gc[cp] == "Pf":
            f |= 4
        if self.ep[cp] and self.gc[cp] == "Cn":
            f |= 8
        if cp == 0x2010:
            f |= 16
        if cp == 0x25CC:
            f |= 32
        return f


def runs(path):
    """Run-length dump `<lo> <hi> <field...>` (hex lo/hi) -> dict lo..hi expanded lazily as a list."""
    out = [None] * N
    extra = {}
    with open(path) as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "X":  # out-of-range probe: X <decimal cp> <class>
                extra[int(p[1])] = p[2:]
                continue
            lo, hi = int(p[0], 16), int(p[1], 16)
            v = tuple(p[2:])
            out[lo:hi + 1] = [v] * (hi - lo + 1)
    return out, extra


def cmd_verify(ucd_dir):
    bad = 0
    for name, want in sorted(PINNED.items()):
        data = read(ucd_dir, name)
        got = hashlib.sha256(data).hexdigest()
        head = data[:200].decode("utf-8", "replace")
        ver = re.search(r"(16\.0\.0|Emoji Version 16\.0)" if "15.1" not in name else r"15\.1\.0",
                        data[:2000].decode("utf-8", "replace"))
        if name == "UnicodeData.txt":  # no header: pinned by SHA-256 only (and cross-checked below)
            ver = True
        ok = got == want and ver is not None
        bad += not ok
        print("  %-20s %s %s %s" % (name, got[:16], "16.0.0" if ver else "NO-VERSION", "ok" if ok else "MISMATCH"))
        del head
    # the loader's view of the raw files must equal Unicode's own derived (extracted/) files everywhere
    P = Props(ucd_dir)
    for name, mine, default in (("DerivedLineBreak.txt", P.lb, "XX"), ("DerivedEastAsianWidth.txt", P.eaw, "N"),
                                ("DerivedGeneralCategory.txt", P.gc, "Cn")):
        d = enumerated(read(ucd_dir, name).decode("utf-8"), default)
        diff = sum(1 for c in range(N) if d[c] != mine[c])
        bad += diff != 0
        print("  loader vs %-27s %d / 1,114,112 code points differ" % (name, diff))
    return 1 if bad else 0


def p2_1_set(P):
    """REPORT.md P2-1: code points of U+1F000..U+1FAFF that Unicode 16.0.0 leaves at the XX default (all in
    Supplemental Arrows-C, U+1F800..U+1F8FF) but tools/gen_tables.py pre-fills with ID."""
    return set(c for c in range(0x1F000, 0x1FB00) if P.lb[c] == "XX")


def cmd_table(ucd_dir, pub_path, wb_path):
    P = Props(ucd_dir)
    pub, pub_extra = runs(pub_path)
    wb, _ = runs(wb_path)
    names = ["ea", "qu_pi", "qu_pf", "ep_cn", "u2010", "u25cc"]
    stats = dict((k, 0) for k in ["lb", "res", "missing"] + names)
    counts = dict((k, 0) for k in names[:4])
    bad_cps = {}
    for cp in range(N):
        a = pub[cp]
        w = wb[cp]
        if a is None or w is None:
            stats["missing"] += 1
            bad_cps[cp] = "missing"
            continue
        raw = P.lb[cp]
        f = P.flags(cp)
        for i, k in enumerate(names[:4]):
            counts[k] += (f >> i) & 1
        errs = []
        if a[0] != raw:
            stats["lb"] += 1
            errs.append("line_break_class %s, want %s" % (a[0], raw))
        if w[0] != raw:
            errs.append("table raw %s, want %s" % (w[0], raw))
        if w[1] != P.resolved(cp):
            stats["res"] += 1
            errs.append("resolved %s, want %s" % (w[1], P.resolved(cp)))
        got = int(w[2])
        for i, k in enumerate(names):
            if ((got >> i) & 1) != ((f >> i) & 1):
                stats[k] += 1
                errs.append("%s %d, want %d" % (k, (got >> i) & 1, (f >> i) & 1))
        if errs:
            bad_cps[cp] = "; ".join(errs)
    oor = {k: v[0] for k, v in pub_extra.items()}
    oor_bad = [k for k, v in oor.items() if v != "XX"]
    print("  code points compared: %d (U+0000..U+10FFFF), missing from dumps: %d" % (N, stats["missing"]))
    print("  Line_Break mismatches (public line_break_class): %d, LB1-resolved class mismatches: %d" % (stats["lb"], stats["res"]))
    print("  flag mismatches: EA(F/W/H) %d, QU_Pi %d, QU_Pf %d, ExtPict&Cn %d, U+2010 %d, U+25CC %d" %
          tuple(stats[k] for k in names))
    print("  (independent counts: EA %d, QU_Pi %d, QU_Pf %d, ExtPict&Cn %d code points)" %
          tuple(counts[k] for k in names[:4]))
    print("  out-of-range inputs %s -> %s (want XX, no panic)" % (sorted(oor), sorted(set(oor.values()))))
    known = p2_1_set(P)
    explained = set(c for c in bad_cps if c in known and pub[c] is not None and pub[c][0] == "ID")
    rest = sorted(set(bad_cps) - explained)
    if explained:
        lo = min(explained)
        print("  %d mismatches are REPORT.md P2-1 (XX in Unicode 16.0.0, ID in the table): e.g. U+%04X %s" %
              (len(explained), lo, bad_cps[lo]))
        print("FINDINGS P2-1")
    for c in rest[:20]:
        print("  UNEXPLAINED U+%04X: %s" % (c, bad_cps[c]))
    print("  unexplained mismatching code points: %d" % len(rest))
    return 1 if rest or oor_bad or len(oor) < 6 else 0


def cmd_defaults(ucd_dir, gen_path):
    """tools/gen_tables.py pre-fills ID / PR / W block defaults by hand; are they dead (overridden by explicit
    16.0.0 entries), consistent, or contradicting the data?"""
    src = open(gen_path).read()
    lb_text = read(ucd_dir, "LineBreak.txt").decode("utf-8")
    ea_text = read(ucd_dir, "EastAsianWidth.txt").decode("utf-8")
    explicit_lb = bytearray(N)
    explicit_ea = bytearray(N)
    for kind, lo, hi, f in ranges(lb_text):
        if kind is None:
            explicit_lb[lo:hi + 1] = b"\x01" * (hi - lo + 1)
    for kind, lo, hi, f in ranges(ea_text):
        if kind is None:
            explicit_ea[lo:hi + 1] = b"\x01" * (hi - lo + 1)
    missing = [(lo, hi, f[0]) for kind, lo, hi, f in ranges(lb_text) if kind == "@missing"]
    missing_ea = [(lo, hi, f[0]) for kind, lo, hi, f in ranges(ea_text) if kind == "@missing"]
    blocks = re.findall(r"\(0x([0-9A-F]+), 0x([0-9A-F]+)\)", src)
    live = 0
    for lo, hi in blocks:
        lo, hi = int(lo, 16), int(hi, 16)
        live += sum(1 for c in range(lo, hi + 1) if not explicit_lb[c] and not explicit_ea[c])
    unl = sum(1 for c in range(N) if not explicit_lb[c])
    unl_ea = sum(1 for c in range(N) if not explicit_ea[c])
    print("  LineBreak.txt @missing: %s; code points not listed explicitly: %d" % (missing, unl))
    print("  EastAsianWidth.txt @missing: %s; code points not listed explicitly: %d" % (missing_ea, unl_ea))
    print("  gen_tables.py hard-coded default blocks: %d; code points where they are not overridden: %d" % (len(blocks), live))
    return 0


def main(argv):
    ucd_dir, cmd = argv[0], argv[1]
    if cmd == "verify":
        return cmd_verify(ucd_dir)
    if cmd == "table":
        return cmd_table(ucd_dir, argv[2], argv[3])
    if cmd == "defaults":
        return cmd_defaults(ucd_dir, argv[2])
    print("unknown command", cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
