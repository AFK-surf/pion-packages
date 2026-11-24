"""Independent Unicode 16.0.0 UAX #14 (revision 53) reference model for the RT-unicode-linebreak audit.

Written rule by rule from https://www.unicode.org/reports/tr14/tr14-53.html section 6 (stdlib only), in the
most literal form possible and deliberately unlike the package's single-pass state machine: the input is first
split into LB9 units (X (CM | ZWJ)*), LB10 gives remaining CM / ZWJ *all* the properties of U+0041 (AL, Lu,
East_Asian_Width=Na, not Extended_Pictographic), and every boundary is then decided by walking backwards and
forwards over the unit list. Each decision records the rule that made it, so a divergence from Rust
icu_segmenter can be attributed to a rule.

  model.py <ucd_dir> selftest                 decoder vs Python's UTF-8 codec + all LineBreakTest.txt vectors
  model.py <ucd_dir> dump <cases> [rules]     one line per case: `<off><a|m>,...` (`-` for empty input);
                                              with `rules`, every entry is `<off><a|m>:<rule>`

Cases file: `<name>\\t<hex bytes>` per line (arbitrary bytes; ill-formed UTF-8 decodes to U+FFFD per the
Unicode "maximal subpart" practice, the same one Python's codec uses).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ucd  # noqa: E402

HARD = ("BK", "CR", "LF", "NL")


def decode(b):
    """[(cp, byte_start)] with maximal-subpart U+FFFD replacement."""
    out = []
    i, n = 0, len(b)
    while i < n:
        b0 = b[i]
        if b0 < 0x80:
            out.append((b0, i))
            i += 1
            continue
        if 0xC2 <= b0 <= 0xDF:
            need, lo, hi, cp = 1, 0x80, 0xBF, b0 & 0x1F
        elif 0xE0 <= b0 <= 0xEF:
            need, cp = 2, b0 & 0x0F
            lo, hi = (0xA0, 0xBF) if b0 == 0xE0 else (0x80, 0x9F) if b0 == 0xED else (0x80, 0xBF)
        elif 0xF0 <= b0 <= 0xF4:
            need, cp = 3, b0 & 0x07
            lo, hi = (0x90, 0xBF) if b0 == 0xF0 else (0x80, 0x8F) if b0 == 0xF4 else (0x80, 0xBF)
        else:
            out.append((0xFFFD, i))
            i += 1
            continue
        j = i + 1
        ok = True
        for k in range(need):
            l, h = (lo, hi) if k == 0 else (0x80, 0xBF)
            if j >= n or not (l <= b[j] <= h):
                ok = False
                break
            cp = (cp << 6) | (b[j] & 0x3F)
            j += 1
        out.append((cp if ok else 0xFFFD, i))
        i = j
    return out


class Unit:
    __slots__ = ("cls", "cp", "ea", "gc", "ep")

    def __init__(self, cls, cp, ea, gc, ep):
        self.cls, self.cp, self.ea, self.gc, self.ep = cls, cp, ea, gc, ep


class Model:
    """`emulate`: set of REPORT.md finding ids whose defect the model reproduces on purpose, used only to attribute
    a Pion divergence to a finding (a divergence is explained by finding X iff the model with X emulated gives
    Pion's exact output): P2-1 Line_Break=ID for the 94 XX code points of 1F800..1F8FF, P2-2 LB21a without the
    [BA - $EastAsian] exclusion, P2-3 LB10 keeping the mark's own East_Asian_Width.
    `ICU` is not a finding: it reproduces what Rust icu_segmenter 2.4.0 demonstrably implements (the Unicode
    15.1.0 Line_Break values wherever 16.0.0 changed them; SA as plain AL (boundaries next to SA are
    implementation-defined anyway and are not compared, see compare.py); the pre-15.1 LB19 `x QU`, `QU x` without LB19a's East Asian exception; the
    pre-16.0 LB21a `HL (HY | BA) x`; its break after a U+25CC U+25CC pair), only to tell ICU-side lag from real divergences."""

    def __init__(self, ucd_dir, emulate=(), props=None):
        self.P = props if props is not None else ucd.Props(ucd_dir)
        self.emu = frozenset(emulate)
        self.lb_override = {}
        if "ICU" in self.emu:
            old = ucd.enumerated(ucd.read(ucd_dir, "LineBreak-15.1.0.txt").decode("utf-8"), "XX")
            for cp in range(ucd.N):
                v = old[cp] if old[cp] != self.P.lb[cp] else self.P.lb[cp]
                if v == "SA":
                    v = "AL"
                if v != self.P.lb[cp] or self.P.lb[cp] == "SA":
                    self.lb_override[cp] = {"AI": "AL", "SG": "AL", "XX": "AL", "CJ": "NS"}.get(v, v)
        if "P2-1" in self.emu:
            for cp in range(0x1F000, 0x1FB00):
                if self.P.lb[cp] == "XX":
                    self.lb_override[cp] = "ID"

    def resolved(self, cp):
        if cp in self.lb_override:
            return self.lb_override[cp]
        return self.P.resolved(cp)

    def decisions(self, data):
        """[(byte_offset, 'x' | 'a' | 'm', rule)] for every code point boundary of `data` (eot included)."""
        return self._run(data)[0]

    def keys(self, data):
        """{byte_offset: '<rule>:<class before>><class after>'} (LB9-unit classes; raw classes for LB4..LB9)."""
        return self._run(data)[1]

    def _run(self, data):
        P = self.P
        cps = decode(data)
        n = len(cps)
        if n == 0:
            return [], {}
        raw = [self.resolved(cp) for cp, _ in cps]  # LB1
        # LB9 / LB10: units
        units = []
        unit_of = [0] * n
        absorbed = [False] * n
        for i, (cp, _) in enumerate(cps):
            c = raw[i]
            if c in ("CM", "ZWJ") and i > 0 and raw[i - 1] not in ("BK", "CR", "LF", "NL", "SP", "ZW") \
                    and units:
                # X (CM | ZWJ)* -> X; the previous char is X itself or already part of X's unit
                absorbed[i] = True
                unit_of[i] = len(units) - 1
                continue
            if c in ("CM", "ZWJ"):  # LB10: properties of U+0041
                units.append(Unit("AL", 0x41, P.ea(cp) if "P2-3" in self.emu else False, "Lu", False))
            else:
                units.append(Unit(c, cp, P.ea(cp), P.gc[cp], bool(P.ep[cp])))
            unit_of[i] = len(units) - 1
        out = []
        keys = {}
        for i in range(1, n):
            d, rule = self.decide(raw, absorbed, units, unit_of, i)
            out.append((cps[i][1], d, rule))
            if absorbed[i] or rule in ("LB4", "LB5", "LB6", "LB7", "LB8", "LB8a"):
                keys[cps[i][1]] = "%s:%s>%s" % (rule, raw[i - 1], raw[i])
            else:
                k = unit_of[i]
                keys[cps[i][1]] = "%s:%s>%s" % (rule, units[k - 1].cls, units[k].cls)
        out.append((len(data), "m", "LB3"))
        return out, keys

    def breaks(self, data):
        """[(byte_offset, 'a' | 'm', rule)] for the bytes `data`."""
        return [t for t in self.decisions(data) if t[1] != "x"]

    def decide(self, raw, absorbed, U, unit_of, i):
        p, c = raw[i - 1], raw[i]
        if p == "BK":
            return "m", "LB4"
        if p == "CR" and c == "LF":
            return "x", "LB5"
        if p in ("CR", "LF", "NL"):
            return "m", "LB5"
        if "ICU" in self.emu and not absorbed[i]:
            # icu_segmenter 2.4.0 quirk (measured by diff/gen.py's icuprobe corpus): right after exactly two
            # consecutive U+25CC units it breaks before anything but VF / CM / ZWJ, even before SP or LF
            k = unit_of[i]
            if k >= 2 and U[k - 1].cp == 0x25CC and U[k - 2].cp == 0x25CC and (k < 3 or U[k - 3].cp != 0x25CC) \
                    and U[k].cls != "VF":
                return "a", "ICU-25CC"
        if c in HARD:
            return "x", "LB6"
        if c in ("SP", "ZW"):
            return "x", "LB7"
        j = i - 1
        while j >= 0 and raw[j] == "SP":
            j -= 1
        if j >= 0 and raw[j] == "ZW":
            return "a", "LB8"
        if p == "ZWJ":
            return "x", "LB8a"
        if absorbed[i]:
            return "x", "LB9"
        k = unit_of[i]
        A = U[k - 1]  # unit before the boundary
        B = U[k]  # unit after the boundary
        nxt = U[k + 1] if k + 1 < len(U) else None
        nxt2 = U[k + 2] if k + 2 < len(U) else None
        a, b = A.cls, B.cls

        def back_sp(j):
            while j >= 0 and U[j].cls == "SP":
                j -= 1
            return j

        if a == "WJ" or b == "WJ":
            return "x", "LB11"
        if a == "GL":
            return "x", "LB12"
        if b == "GL" and a not in ("SP", "BA", "HY"):
            return "x", "LB12a"
        if b in ("CL", "CP", "EX", "SY"):
            return "x", "LB13"
        j = back_sp(k - 1)
        if j >= 0 and U[j].cls == "OP":
            return "x", "LB14"
        if j >= 0 and U[j].cls == "QU" and U[j].gc == "Pi" and (
                j == 0 or U[j - 1].cls in ("BK", "CR", "LF", "NL", "OP", "QU", "GL", "SP", "ZW")):
            return "x", "LB15a"
        if b == "QU" and B.gc == "Pf" and (nxt is None or nxt.cls in (
                "SP", "GL", "WJ", "CL", "QU", "CP", "EX", "IS", "SY", "BK", "CR", "LF", "NL", "ZW")):
            return "x", "LB15b"
        if a == "SP" and b == "IS" and nxt is not None and nxt.cls == "NU":
            return "a", "LB15c"
        if b == "IS":
            return "x", "LB15d"
        if j >= 0 and U[j].cls in ("CL", "CP") and b == "NS":
            return "x", "LB16"
        if j >= 0 and U[j].cls == "B2" and b == "B2":
            return "x", "LB17"
        if a == "SP":
            return "a", "LB18"
        if "ICU" in self.emu and (a == "QU" or b == "QU"):
            return "x", "LB19"
        if b == "QU" and B.gc != "Pi":
            return "x", "LB19"
        if a == "QU" and A.gc != "Pf":
            return "x", "LB19"
        if b == "QU" and not A.ea:
            return "x", "LB19a"
        if b == "QU" and (nxt is None or not nxt.ea):
            return "x", "LB19a"
        if a == "QU" and not B.ea:
            return "x", "LB19a"
        if a == "QU" and (k - 2 < 0 or not U[k - 2].ea):
            return "x", "LB19a"
        if b == "CB" or a == "CB":
            return "a", "LB20"
        if (a == "HY" or A.cp == 0x2010) and b == "AL" and (
                k - 2 < 0 or U[k - 2].cls in ("BK", "CR", "LF", "NL", "SP", "ZW", "CB", "GL")):
            return "x", "LB20a"
        if b in ("BA", "HY", "NS") or a == "BB":
            return "x", "LB21"
        if k >= 2 and U[k - 2].cls == "HL" and (a == "HY" or (a == "BA" and (
                not A.ea or "P2-2" in self.emu))) and b != "HL":
            return "x", "LB21a"
        if "ICU" in self.emu and k >= 2 and U[k - 2].cls == "HL" and a in ("HY", "BA"):
            return "x", "LB21a"
        if a == "SY" and b == "HL":
            return "x", "LB21b"
        if b == "IN":
            return "x", "LB22"
        if (a in ("AL", "HL") and b == "NU") or (a == "NU" and b in ("AL", "HL")):
            return "x", "LB23"
        if (a == "PR" and b in ("ID", "EB", "EM")) or (a in ("ID", "EB", "EM") and b == "PO"):
            return "x", "LB23a"
        if (a in ("PR", "PO") and b in ("AL", "HL")) or (a in ("AL", "HL") and b in ("PR", "PO")):
            return "x", "LB24"
        if b in ("PO", "PR"):
            j = k - 1
            if U[j].cls in ("CL", "CP"):
                j -= 1
            while j >= 0 and U[j].cls in ("SY", "IS"):
                j -= 1
            if j >= 0 and U[j].cls == "NU":
                return "x", "LB25"
        if a in ("PO", "PR") and b == "OP" and nxt is not None and (
                nxt.cls == "NU" or (nxt.cls == "IS" and nxt2 is not None and nxt2.cls == "NU")):
            return "x", "LB25"
        if a in ("PO", "PR", "HY", "IS") and b == "NU":
            return "x", "LB25"
        if b == "NU":
            j = k - 1
            while j >= 0 and U[j].cls in ("SY", "IS"):
                j -= 1
            if j >= 0 and U[j].cls == "NU":
                return "x", "LB25"
        if (a == "JL" and b in ("JL", "JV", "H2", "H3")) or (a in ("JV", "H2") and b in ("JV", "JT")) or (
                a in ("JT", "H3") and b == "JT"):
            return "x", "LB26"
        hangul = ("JL", "JV", "JT", "H2", "H3")
        if (a in hangul and b == "PO") or (a == "PR" and b in hangul):
            return "x", "LB27"
        if a in ("AL", "HL") and b in ("AL", "HL"):
            return "x", "LB28"

        def akd(u):  # (AK | [◌] | AS)
            return u.cls in ("AK", "AS") or u.cp == 0x25CC

        def ak(u):  # (AK | [◌])
            return u.cls == "AK" or u.cp == 0x25CC

        if a == "AP" and akd(B):
            return "x", "LB28a"
        if akd(A) and b in ("VF", "VI"):
            return "x", "LB28a"
        if k >= 2 and akd(U[k - 2]) and a == "VI" and ak(B):
            return "x", "LB28a"
        if akd(A) and akd(B) and nxt is not None and nxt.cls == "VF":
            return "x", "LB28a"
        if a == "IS" and b in ("AL", "HL"):
            return "x", "LB29"
        if a in ("AL", "HL", "NU") and b == "OP" and not B.ea:
            return "x", "LB30"
        if a == "CP" and not A.ea and b in ("AL", "HL", "NU"):
            return "x", "LB30"
        if a == "RI" and b == "RI":
            r = 0
            j = k - 1
            while j >= 0 and U[j].cls == "RI":
                r += 1
                j -= 1
            if r % 2 == 1:
                return "x", "LB30a"
        if b == "EM" and (a == "EB" or (A.ep and A.gc == "Cn")):
            return "x", "LB30b"
        return "a", "LB31"


def fmt(br, rules=False):
    if not br:
        return "-"
    if rules:
        return ",".join("%d%s:%s" % (o, k, r) for o, k, r in br)
    return ",".join("%d%s" % (o, k) for o, k, _ in br)


def read_cases(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            name, hx = line.split("\t", 1)
            out.append((name, bytes.fromhex(hx)))
    return out


def parse_lbtest(text):
    """[(line_no, bytes, [expected break offsets excluding 0])] from LineBreakTest.txt."""
    out = []
    for no, line in enumerate(text.split("\n"), 1):
        s = line.split("#", 1)[0].strip()
        if not s:
            continue
        data = b""
        exp = []
        for tok in s.split():
            if tok == "÷":
                if data:
                    exp.append(len(data))
            elif tok == "×":
                pass
            else:
                data += chr(int(tok, 16)).encode("utf-8", "surrogatepass")
        out.append((no, data, exp))
    return out


def selftest(ucd_dir):
    import random
    rnd = random.Random(14)
    bad = 0
    for _ in range(20000):
        b = bytes(rnd.choice([rnd.randrange(256), 0x80 | rnd.randrange(64), 0xC2 + rnd.randrange(51)])
                 for _ in range(rnd.randrange(1, 8)))
        mine = "".join(chr(c) for c, _ in decode(b))
        if mine != b.decode("utf-8", "replace"):
            bad += 1
    print("  model decoder vs Python UTF-8 codec (maximal subpart), 20,000 random byte strings: %d mismatches" % bad)
    M = Model(ucd_dir)
    vec = parse_lbtest(ucd.read(ucd_dir, "LineBreakTest.txt").decode("utf-8"))
    fails = 0
    for no, data, exp in vec:
        got = [o for o, k, _ in M.breaks(data)]
        if got != exp:
            fails += 1
            if fails <= 5:
                print("  model FAIL line %d: got %s want %s" % (no, got, exp))
    print("  model vs LineBreakTest-16.0.0.txt: %d/%d" % (len(vec) - fails, len(vec)))
    return 1 if bad or fails else 0


def main(argv):
    ucd_dir, cmd = argv[0], argv[1]
    if cmd == "selftest":
        return selftest(ucd_dir)
    if cmd == "dump":
        M = Model(ucd_dir)
        rules = len(argv) > 3 and argv[3] == "rules"
        w = sys.stdout.write
        for name, data in read_cases(argv[2]):
            w(fmt(M.breaks(data), rules) + "\n")
        return 0
    print("unknown command", cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
