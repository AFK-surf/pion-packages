"""Independent reference model of packages/idna's public API, written from the specifications only:

  * RFC 3492 Punycode (own encoder / decoder; cross-checked against CPython's `punycode` codec, `selftest`)
  * UAX #15 NFC / NFD from UnicodeData.txt 16.0.0 (cross-checked against `unicodedata` on characters that
    CPython's older Unicode database already has, `selftest`)
  * UTS #46 16.0.0 §4 Processing, §4.1 Validity Criteria V1-V9, §4.2 ToASCII, §4.3 ToUnicode
  * RFC 5892 Appendix A ContextJ / ContextO, RFC 5893 §2 Bidi rules 1-6
  * UTS #39 16.0.0 §4 skeleton = bidiSkeleton(LTR, X): UAX #9 reordering (uba.py, incl. L3 / L4), then
    internalSkeleton (NFD, Default_Ignorable_Code_Point removal, prototypes, NFD); the pre-15 README formula
    NFD(map(NFD(X))) is kept to classify old behaviour
  * packages/idna README's display_domain policy (script sets, whole-script ASCII-skeleton test, invisible,
    mixed numbering systems), and its default IdnaLimits

Usage:
  model.py dump <corpus>   -> same line format as `idna_audit dump` (see compare.py for what is compared)
  model.py selftest        -> cross-check punycode / NFC against the Python standard library
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uba  # noqa: E402
from ucd import data  # noqa: E402

D = data()

LIMIT_BYTES, LIMIT_LABELS, LIMIT_LABEL_CPS, LIMIT_PUNY = 4096, 128, 1000, 2000

# ------------------------------------------------------------------------------------------------ NFC / NFD
SB, LB, VB, TB, LC, VC, TC = 0xAC00, 0x1100, 0x1161, 0x11A7, 19, 21, 28
NC, SC = VC * TC, LC * VC * TC


def _decomp(cp, out):
    if SB <= cp < SB + SC:
        s = cp - SB
        out.append(LB + s // NC)
        out.append(VB + (s % NC) // TC)
        if s % TC:
            out.append(TB + s % TC)
        return
    d = D.decomp.get(cp)
    if d is None:
        out.append(cp)
    else:
        for x in d:
            _decomp(x, out)


def nfd(cps):
    out = []
    for cp in cps:
        _decomp(cp, out)
    # canonical ordering (stable sort of each run of non-starters)
    i = 0
    n = len(out)
    while i < n:
        if D.ccc.get(out[i], 0) == 0:
            i += 1
            continue
        j = i
        while j < n and D.ccc.get(out[j], 0) != 0:
            j += 1
        out[i:j] = sorted(out[i:j], key=lambda c: D.ccc.get(c, 0))
        i = j
    return out


def nfc(cps):
    d = nfd(cps)
    out = []
    starter = -1
    last_ccc = -1
    for cp in d:
        c = D.ccc.get(cp, 0)
        if starter >= 0 and (last_ccc < c or (last_ccc == 0 and starter == len(out) - 1)):
            st = out[starter]
            comp = None
            if LB <= st < LB + LC and VB <= cp < VB + VC:
                comp = SB + ((st - LB) * VC + (cp - VB)) * TC
            elif SB <= st < SB + SC and (st - SB) % TC == 0 and TB < cp < TB + TC:
                comp = st + (cp - TB)
            else:
                comp = D.compose.get((st, cp))
            if comp is not None:
                out[starter] = comp
                continue
        if c == 0:
            starter = len(out)
            last_ccc = 0
        else:
            last_ccc = c
        out.append(cp)
    return out


# ------------------------------------------------------------------------------------------------ RFC 3492
BASE, TMIN, TMAX, SKEW, DAMP, IBIAS, IN = 36, 1, 26, 38, 700, 72, 128


def _adapt(delta, numpoints, first):
    delta = delta // DAMP if first else delta // 2
    delta += delta // numpoints
    k = 0
    while delta > ((BASE - TMIN) * TMAX) // 2:
        delta //= BASE - TMIN
        k += BASE
    return k + (BASE - TMIN + 1) * delta // (delta + SKEW)


def _digit(d):
    return chr(97 + d) if d < 26 else chr(22 + d)


def puny_encode(cps):
    out = [chr(c) for c in cps if c < 0x80]
    b = h = len(out)
    if b:
        out.append("-")
    n, delta, bias = IN, 0, IBIAS
    while h < len(cps):
        m = min(c for c in cps if c >= n)
        delta += (m - n) * (h + 1)
        n = m
        for c in cps:
            if c < n:
                delta += 1
            elif c == n:
                q = delta
                k = BASE
                while True:
                    t = TMIN if k <= bias else (TMAX if k >= bias + TMAX else k - bias)
                    if q < t:
                        break
                    out.append(_digit(t + (q - t) % (BASE - t)))
                    q = (q - t) // (BASE - t)
                    k += BASE
                out.append(_digit(q))
                bias = _adapt(delta, h + 1, h == b)
                delta = 0
                h += 1
        delta += 1
        n += 1
    return "".join(out)


def puny_decode(s):
    """Returns the list of code points, or None if `s` is not valid Punycode."""
    if any(ord(c) >= 0x80 for c in s):
        return None
    p = s.rfind("-")
    out = [ord(c) for c in s[:p]] if p >= 0 else []
    i, n, bias = 0, IN, IBIAS
    pos = p + 1 if p >= 0 else 0
    while pos < len(s):
        old, w, k = i, 1, BASE
        while True:
            if pos >= len(s):
                return None
            c = ord(s[pos])
            pos += 1
            if 97 <= c <= 122:
                dg = c - 97
            elif 65 <= c <= 90:
                dg = c - 65
            elif 48 <= c <= 57:
                dg = c - 22
            else:
                return None
            i += dg * w
            t = TMIN if k <= bias else (TMAX if k >= bias + TMAX else k - bias)
            if dg < t:
                break
            w *= BASE - t
            k += BASE
            if i > 0xFFFFFFFF:
                return None
        bias = _adapt(i - old, len(out) + 1, old == 0)
        n += i // (len(out) + 1)
        i %= len(out) + 1
        if n > 0x10FFFF or 0xD800 <= n <= 0xDFFF:
            return None
        out.insert(i, n)
        i += 1
    return out


# ------------------------------------------------------------------------------------------------ UTS #46
def _bidi_rules(lab):
    """RFC 5893 §2 rules 1-6 for one non-empty label; returns True if they hold."""
    bc = [D.bidi_class(c) for c in lab]
    if bc[0] in ("R", "AL"):
        allowed = {"R", "AL", "AN", "EN", "ES", "CS", "ET", "ON", "BN", "NSM"}
        if any(x not in allowed for x in bc):
            return False
        j = len(bc) - 1
        while j >= 0 and bc[j] == "NSM":
            j -= 1
        if j < 0 or bc[j] not in ("R", "AL", "EN", "AN"):
            return False
        if "EN" in bc and "AN" in bc:
            return False
        return True
    if bc[0] == "L":
        allowed = {"L", "EN", "ES", "CS", "ET", "ON", "BN", "NSM"}
        if any(x not in allowed for x in bc):
            return False
        j = len(bc) - 1
        while j >= 0 and bc[j] == "NSM":
            j -= 1
        return j >= 0 and bc[j] in ("L", "EN")
    return False


def _contextj(lab):
    for i, c in enumerate(lab):
        if c == 0x200D:
            if i == 0 or D.ccc.get(lab[i - 1], 0) != 9:
                return False
        elif c == 0x200C:
            if i > 0 and D.ccc.get(lab[i - 1], 0) == 9:
                continue
            j = i - 1
            while j >= 0 and D.jt.get(lab[j], "U") == "T":
                j -= 1
            if j < 0 or D.jt.get(lab[j], "U") not in ("L", "D"):
                return False
            k = i + 1
            while k < len(lab) and D.jt.get(lab[k], "U") == "T":
                k += 1
            if k >= len(lab) or D.jt.get(lab[k], "U") not in ("R", "D"):
                return False
    return True


HAN, HIRA, KATA, GREEK, HEBREW = 5, 6, 7, 3, 10


def _contexto(lab):
    sc = [D.script.get(c, 0) for c in lab]
    for i, c in enumerate(lab):
        if c == 0x00B7:
            if not (0 < i < len(lab) - 1 and lab[i - 1] == 0x6C and lab[i + 1] == 0x6C):
                return False
        elif c == 0x0375:
            if i + 1 >= len(lab) or sc[i + 1] != GREEK:
                return False
        elif c in (0x05F3, 0x05F4):
            if i == 0 or sc[i - 1] != HEBREW:
                return False
        elif c == 0x30FB:
            if not any(s in (HAN, HIRA, KATA) for s in sc):
                return False
    if any(0x660 <= c <= 0x669 for c in lab) and any(0x6F0 <= c <= 0x6F9 for c in lab):
        return False
    return True


def _valid_label(lab, o, transitional, decoded):
    """UTS #46 §4.1 V1-V8 (+ RFC 5892 ContextO when enabled). Returns a list of failed criteria."""
    errs = []
    if nfc(lab) != lab:
        errs.append("V1")
    if o["hyphens"]:
        if len(lab) >= 4 and lab[2] == 0x2D and lab[3] == 0x2D:
            errs.append("V2")
        if lab and (lab[0] == 0x2D or lab[-1] == 0x2D):
            errs.append("V3")
    elif lab[:4] == [0x78, 0x6E, 0x2D, 0x2D]:
        errs.append("V4")
    if 0x2E in lab:
        errs.append("V5")
    if lab and D.is_mark(lab[0]):
        errs.append("V6")
    for c in lab:
        st = D.idna.get(c, ("disallowed", []))[0]
        if c < 0x80:
            if o["std3"] and not (0x61 <= c <= 0x7A or 0x30 <= c <= 0x39 or c == 0x2D):
                errs.append("U1")
                break
        elif not (st == "valid" or (st == "deviation" and not transitional)):
            errs.append("V7")
            break
    if o["joiners"] and not _contextj(lab):
        errs.append("C")
    if o["contexto"] and not _contexto(lab):
        errs.append("CO")
    return errs


def process(cps, o, transitional):
    """UTS #46 §4 Processing. Returns (labels, errors, limit_hit)."""
    out = []
    for c in cps:
        st, m = D.idna.get(c, ("disallowed", []))
        if st == "valid":
            out.append(c)
        elif st == "ignored":
            pass
        elif st == "mapped":
            if transitional:
                # IdnaTestV2 (toAsciiT of FAẞ.de = fass.de): a mapping that yields a deviation character is
                # itself subject to the transitional deviation mapping (ẞ -> ß -> ss)
                for x in m:
                    sx, mx = D.idna.get(x, ("disallowed", []))
                    out.extend(mx if sx == "deviation" else [x])
            else:
                out.extend(m)
        elif st == "deviation":
            out.extend(m if transitional else [c])
        else:
            out.append(c)
    norm = nfc(out)
    labels = []
    cur = []
    for c in norm:
        if c == 0x2E:
            labels.append(cur)
            cur = []
        else:
            cur.append(c)
    labels.append(cur)
    errs = []
    limit = len(labels) > LIMIT_LABELS
    res = []
    for lab in labels:
        if lab[:4] == [0x78, 0x6E, 0x2D, 0x2D]:
            if any(c >= 0x80 for c in lab):
                errs.append("P4-nonascii")
                res.append(lab)
                continue
            payload = "".join(chr(c) for c in lab[4:])
            if len(payload) > LIMIT_PUNY:
                limit = True
            dec = puny_decode(payload)
            if dec is not None and len(dec) > LIMIT_LABEL_CPS:
                limit = True
            if dec is None:
                if not o["ignore"]:
                    errs.append("P4")
                    res.append(lab)
                    continue
                dec = lab
            if not dec or all(c < 0x80 for c in dec):
                errs.append("P4-ascii")
            errs.extend(_valid_label(dec, o, False, True))
            res.append(dec)
        else:
            if len(lab) > LIMIT_LABEL_CPS:
                limit = True
            errs.extend(_valid_label(lab, o, transitional, False))
            res.append(lab)
    if o["bidi"]:
        if any(D.bidi_class(c) in ("R", "AL", "AN") for lab in res for c in lab):
            for lab in res:
                if lab and not _bidi_rules(lab):
                    errs.append("B")
                    break
    return res, errs, limit


def _dns_ok(ascii_s):
    s = ascii_s[:-1] if ascii_s.endswith(".") else ascii_s
    if len(s) < 1 or len(s) > 253:
        return False
    return all(1 <= len(lab) <= 63 for lab in s.split("."))


def to_ascii(cps, o):
    """Returns ('OK', str) / ('ERR', reason) / ('LIMIT', '')."""
    labels, errs, limit = process(cps, o, o["transitional"])
    if limit:
        return ("LIMIT", "")
    if errs:
        return ("ERR", errs[0])
    parts = []
    for lab in labels:
        if any(c >= 0x80 for c in lab):
            parts.append("xn--" + puny_encode(lab))
        else:
            parts.append("".join(chr(c) for c in lab))
    a = ".".join(parts)
    if o["dns"] and not _dns_ok(a):
        return ("ERR", "A4")
    return ("OK", a)


def to_unicode(cps, o):
    labels, errs, limit = process(cps, o, False)
    if limit:
        return ("LIMIT", "", "")
    return ("1" if not errs else "0", "".join("".join(chr(c) for c in lab) + "." for lab in labels)[:-1],
            errs[0] if errs else "-")


def profile(name):
    base = dict(std3=False, hyphens=False, bidi=True, joiners=True, contexto=False, dns=False,
                transitional=False, ignore=False)
    if name == "S":
        base.update(std3=True, hyphens=True, contexto=True, dns=True)
    elif name in ("N", "L"):
        base.update(std3=True, hyphens=True, dns=True)
    elif name == "T":
        base.update(std3=True, hyphens=True, dns=True, transitional=True)
    elif name == "R":
        base.update(bidi=False, joiners=False)
    elif name == "I":
        base.update(ignore=True)
    return base


# ------------------------------------------------------------------------------------------------ UTS #39
def skeleton_readme(cps):
    """NFD(prototype_map(NFD(X))) as packages/idna README.md documents it."""
    out = []
    for c in nfd(cps):
        out.extend(D.proto.get(c, [c]))
    return nfd(out)


def skeleton_spec(cps):
    """UTS #39 16.0 internalSkeleton(X) (= skeleton(X) for text without strong RTL characters)."""
    out = []
    for c in nfd(cps):
        if c in D.di:
            continue
        out.extend(D.proto.get(c, [c]))
    return nfd(out)


def skeleton_bidi(cps, full=True):
    """UTS #39 16.0 skeleton(X) = bidiSkeleton(LTR, X) = internalSkeleton(L4(L3(UBA L1-L2 order of X))).
    full=False: the reduced reordering (see uba.py). None when X is outside the UBA model's scope."""
    v = uba.visual(cps, full)
    return None if v is None else skeleton_spec(v)


# Small-capital Latin letters README.md (fix branch) counts as ASCII look-alikes in whole-script skeletons.
SMALL_CAPS = {0x0299, 0x029C, 0x1D00, 0x1D04, 0x1D07, 0x1D0A, 0x1D0B, 0x1D0D, 0x1D0F, 0x1D18, 0x1D1B, 0x1D1C,
              0x1D20, 0x1D21, 0x1D22}
# Chrome kDangerousPattern CJK slash / dash look-alikes
CJK_SLASH = {0x30CE, 0x30BD, 0x30BE, 0x30F3, 0x30FC, 0x4E36, 0x4E40, 0x4E41, 0x4E3F, 0x4E00}


def _cjk_context(c):
    s = 2 if (0x41 <= c <= 0x5A or 0x61 <= c <= 0x7A) else D.script.get(c, 0)
    return s in (5, 6, 7, 8, 30) or c in (0x30FC, 0x30FB, 0x3005, 0x3006, 0x3007)


def has_rtl(cps):
    return any(D.bidi_class(c) in ("R", "AL", "AN") for c in cps)


def scripts(cps):
    ids = []
    for c in cps:
        s = 2 if (0x41 <= c <= 0x5A or 0x61 <= c <= 0x7A) else D.script.get(c, 0)
        if s not in (0, 1) and s not in ids:
            ids.append(s)
    return ids


def _script_set_ok(ids):
    if len(ids) <= 1:
        return True
    s = set(ids)
    return s <= {2, 5, 6, 7} or s <= {2, 5, 8} or s <= {2, 5, 30}


def display(cps):
    """packages/idna README display_domain policy (browser_default). Returns (fallback, reasons, display, ascii)."""
    st, a = to_ascii(cps, profile("S"))
    if st != "OK":
        return ("1", {"InvalidIdna"}, None, "")
    u = to_unicode([ord(c) for c in a], profile("S"))
    if u[0] != "1":
        return ("1", {"InvalidIdna"}, a, a)
    if u[1] == a:
        return ("0", set(), a, a)
    reasons = set()
    for lab in u[1].split("."):
        lc = [ord(c) for c in lab]
        if not lc:
            continue
        if any(c in D.di or 0x335 <= c <= 0x338 for c in lc):
            reasons.add("InvisibleCodePoint")
        systems = {D.digit_zero[c] for c in lc if c in D.digit_zero}
        if len(systems) > 1:
            reasons.add("MixedNumberingSystems")
        ids = scripts(lc)
        if not _script_set_ok(ids):
            reasons.add("MixedScript")
        for k, c in enumerate(lc):
            if c in CJK_SLASH and ((k > 0 and not _cjk_context(lc[k - 1])) or
                                   (k + 1 < len(lc) and not _cjk_context(lc[k + 1]))):
                reasons.add("MixedScript")
        sk = skeleton_bidi(lc) or skeleton_bidi(lc, False)
        if any(c >= 0x80 for c in lc) and 2 not in ids and len(ids) == 1:
            base = [c for c in sk if not D.is_mark(c)]
            if base and all(c < 0x80 or c in SMALL_CAPS for c in base):
                reasons.add("WholeScriptConfusable")
        if any(c >= 0x80 for c in lc) and 2 in ids and len(ids) == 1:
            if sk and all(c < 0x80 for c in sk):
                reasons.add("WholeScriptConfusable")
    if reasons:
        return ("1", reasons, a, a)
    return ("0", set(), u[1], a)


# ------------------------------------------------------------------------------------------------ dump
def h(s):
    b = s.encode("utf-8", "surrogatepass") if isinstance(s, str) else s
    return b.hex() if b else "-"


def utf8(b):
    try:
        return [ord(c) for c in b.decode("utf-8")]
    except UnicodeDecodeError:
        return None


def dump_case(raw):
    out = []
    cps = utf8(raw)
    too_big = len(raw) > LIMIT_BYTES
    for p in ("S", "U", "N", "T", "R", "I", "L"):
        o = profile(p)
        if p == "L" and cps is not None and any(c in (0x2E, 0x3002, 0xFF0E, 0xFF61) for c in cps):
            out.append("A L ERR sep")
            out.append("U L 0 sep " + h(raw))
            continue
        if cps is None:
            out.append("A %s ERR utf8" % p)
            out.append("U %s 0 utf8 %s" % (p, h(raw)))
            continue
        if too_big:
            out.append("A %s LIMIT" % p)
            out.append("U %s LIMIT" % p)
            continue
        st, v = to_ascii(cps, o)
        out.append("A %s %s %s" % (p, st, h(v) if st == "OK" else v))
        u = to_unicode(cps, o)
        out.append("U %s LIMIT" % p if u[0] == "LIMIT" else "U %s %s %s %s" % (p, u[0], u[2], h(u[1])))
    if cps is None:
        out.append("K ?")
        out.append("C ?")
        out.append("D 1 InvalidIdna RAW -")
        out.append("P ERR utf8")
    else:
        sr = skeleton_readme(cps)
        ss = skeleton_bidi(cps)
        sb = skeleton_bidi(cps, False)
        out.append("K %s %s %s %s" % (h("".join(map(chr, sr))), "?" if ss is None else h("".join(map(chr, ss))),
                                      h("".join(map(chr, sb))), "rtl" if has_rtl(cps) else "ltr"))
        out.append("C " + (",".join(str(x) for x in scripts(cps)) or "-"))
        if too_big:
            out.append("D 1 InvalidIdna RAW -")
        else:
            f, rs, disp, a = display(cps)
            out.append("D %s %s %s %s" % (f, ",".join(sorted(rs)) or "-", "RAW" if disp is None else h(disp), h(a)))
        if too_big or len(cps) > LIMIT_LABEL_CPS or any(0xD800 <= c <= 0xDFFF for c in cps):
            out.append("P ERR limit")
        else:
            out.append("P OK " + h(puny_encode(cps)))
    try:
        s = raw.decode("ascii")
        if len(raw) > LIMIT_PUNY or len(raw) > LIMIT_BYTES:
            raise ValueError
        dec = puny_decode(s)
        if dec is None or len(dec) > LIMIT_LABEL_CPS:
            raise ValueError
        out.append("Q OK " + h("".join(map(chr, dec))))
    except (UnicodeDecodeError, ValueError):
        out.append("Q ERR -")
    return "\n".join(out) + "\n"


def run_dump(path):
    w = sys.stdout.write
    with open(path, "rb") as f:
        for line in f:
            line = line.rstrip(b"\n")
            if b"\t" not in line:
                continue
            name, hx = line.split(b"\t", 1)
            w("=" + name.decode() + "\n")
            w(dump_case(bytes.fromhex(hx.decode())))


def selftest():
    import random
    import unicodedata
    import codecs
    rnd = random.Random(46)
    pool = [c for c in range(0x20, 0x30000) if c in D.gc and not (0xD800 <= c <= 0xDFFF)
            and unicodedata.category(chr(c)) != "Cn" and D.gc[c] == unicodedata.category(chr(c))]
    marks = [c for c in pool if D.ccc.get(c, 0)]
    bad = 0
    n = 0
    for _ in range(20000):
        s = [rnd.choice(pool if rnd.random() < 0.6 else marks) for _ in range(rnd.randint(1, 8))]
        t = "".join(map(chr, s))
        n += 1
        if "".join(map(chr, nfc(s))) != unicodedata.normalize("NFC", t) or \
                "".join(map(chr, nfd(s))) != unicodedata.normalize("NFD", t):
            bad += 1
            if bad < 5:
                print("NFC/NFD mismatch", [hex(c) for c in s])
    print("selftest NFC/NFD vs unicodedata %s: %d/%d agree" % (unicodedata.unidata_version, n - bad, n))
    pbad = 0
    for _ in range(20000):
        s = [rnd.choice(pool) for _ in range(rnd.randint(1, 12))]
        t = "".join(map(chr, s))
        e = codecs.encode(t, "punycode").decode()
        if puny_encode(s) != e or puny_decode(e) != s:
            pbad += 1
    print("selftest RFC 3492 vs codecs punycode: %d/%d agree" % (20000 - pbad, 20000))
    return 1 if bad or pbad else 0


def nfcqc():
    """NFC_Quick_Check != Yes code points that UTS #46 lets through (valid / deviation / mapping targets):
    every one of them must make packages/idna normalise. Prints the count and checks compare.NFC_GAP."""
    import gzip
    from ucd import UCD
    qc = set()
    with gzip.open(os.path.join(UCD, "DerivedNormalizationProps.txt.gz"), "rt", encoding="utf-8") as f:
        for line in f:
            body = line.split("#", 1)[0].strip()
            p = [x.strip() for x in body.split(";")] if body else []
            if len(p) >= 3 and p[1] == "NFC_QC":
                a, _, b = p[0].partition("..")
                qc.update(range(int(a, 16), int(b or a, 16) + 1))
    reach = set()
    for c, (st, m) in D.idna.items():
        if st in ("valid", "deviation"):
            reach.add(c)
        reach.update(m)
    need = sorted(c for c in qc & reach)
    from compare import NFC_GAP
    print("  NFC_Quick_Check=Maybe/No code points reachable after UTS #46 mapping: %d; P1-1 gap list (%d) %s" %
          (len(need), len(NFC_GAP), "is a subset" if NFC_GAP <= set(need) else "is NOT a subset"))
    return 0 if NFC_GAP <= set(need) else 1


if __name__ == "__main__":
    if sys.argv[1] == "nfcqc":
        sys.exit(nfcqc())
    if sys.argv[1] == "dump":
        run_dump(sys.argv[2])
    elif sys.argv[1] == "selftest":
        sys.exit(selftest())
