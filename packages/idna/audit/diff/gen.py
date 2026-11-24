"""Deterministic corpora for the idna red-team audit.

  gen.py <outdir> [fuzz_n]  writes
    <outdir>/idnatest.cases  every source string of the official Unicode 16.0.0 IdnaTestV2.txt (`t<line>`)
    <outdir>/named.cases     hand-written adversarial inputs (`n_<topic>_<k>`)
    <outdir>/fuzz.cases      `fuzz_n` (default 3000) seeded random domains from an adversarial code point pool
  Each line is `<name>\t<hex of the UTF-8 bytes>`. Prints `<idnatest> <named> <fuzz>`.
"""
import gzip
import os
import random
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
UCD = os.environ.get("IDNA_AUDIT_UCD") or os.path.join(HERE, "..", "ucd")


def unescape(s):
    s = re.sub(r"\\x\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), s)
    return re.sub(r"\\u([0-9A-Fa-f]{4})", lambda m: chr(int(m.group(1), 16)), s)


def idnatest_lines():
    """Yields (line_no, [7 columns]) of IdnaTestV2.txt with escapes resolved."""
    with gzip.open(os.path.join(UCD, "IdnaTestV2.txt.gz"), "rt", encoding="utf-8") as f:
        for no, line in enumerate(f, 1):
            body = line.split("#", 1)[0].rstrip("\n")
            if not body.strip():
                continue
            cols = [c.strip() for c in body.split(";")]
            cols += [""] * (7 - len(cols))
            yield no, [unescape(c) for c in cols[:7]]


def enc(s):
    return s.encode("utf-8", "surrogatepass")


def named():
    P = model.puny_encode
    cases = {}

    def add(topic, items):
        for k, v in enumerate(items):
            cases["n_%s_%d" % (topic, k)] = v if isinstance(v, bytes) else enc(v)

    # --- RFC 3492 / Punycode bombs and edge cases (raw and as xn-- labels)
    puny = ["", "-", "--", "a-", "-a", "abc-", "zzzzzzzzzzzzzzzzzzzzzz", "9" * 40, "99999999999", "a-" + "9" * 12,
            "8", "a-a!", "wwwwwwww", "zz-zz", "A-B", "mnchen-3ya", "MNCHEN-3YA", "Mnchen-3ya", "z" * 2000, "z" * 2001,
            "a" * 1999 + "-", "-" * 50, "0" * 30, "a-" + "z" * 7, "\x00-a", "a.b-xxx", "a/b-6ve", "a@b-kva",
            "\x7f-", "e-" + "a" * 8, "jxa" * 10, "3-" + "9" * 9, "ls8h", "z7", "zz", "xn--", "\u00fc"]
    add("puny_raw", puny)
    add("puny_label", ["xn--" + p + ".com" for p in puny if all(ord(c) < 0x80 for c in p)])
    # code points beyond the RFC (surrogates / > U+10FFFF) through crafted deltas, non-canonical encodings
    add("puny_crafted", ["xn--" + s for s in ["a-9r4a", "ab-4z6m", "zzzzz2j", "abcdefghijk1", "0a", "xn--a",
                                              "a-ecp", "a-ecpa", "a-ecpaa", "ls8h", "ls8ha", "--", "-x", "x-"]])
    # RFC 3492 encodings are unique up to letter case: mixed-case digits / basic code points must normalise
    add("puny_case", ["xn--tdaa", "xn--TDAA", "xn--TdAa", "XN--A-SFAA", "xn--A-sfaa", "xn--0CAA", "Xn--ssaa"])
    # --- the 19 NFC_Quick_Check=Maybe code points the fast check misses (P1-1)
    seqs = [("\U0001148F", "\U000114B9\U000114BA"), ("\U0001148F", "\U000114B9\U000114B0"),
            ("\U0001148F", "\U000114B9\U000114BD"), ("\U0001158E", "\U000115B8\U000115AF"),
            ("\U0001158E", "\U000115B9\U000115AF"), ("\U0001190C", "\U00011935\U00011930"),
            ("\U00016100", "\U0001611E\U0001611E"), ("\U00016100", "\U0001611E\U00016129"),
            ("\U00016100", "\U0001611E\U0001611F"), ("\U00016100", "\U00016129\U0001611F"),
            ("\U00016100", "\U0001611E\U00016120"), ("\U00016100", "\U00016121\U0001611F"),
            ("\U00016100", "\U00016122\U0001611F"), ("\U00016100", "\U00016121\U00016120"),
            ("\U00016D4B", "\U00016D67\U00016D67"), ("\U00016D4B", "\U00016D63\U00016D67"),
            ("\U00016D4B", "\U00016D69\U00016D67")]
    nfcq = []
    for base, vs in seqs:
        nfcq += [base + vs + ".com", base + vs, "xn--" + P([ord(c) for c in base + vs]) + ".com",
                 "a" + base + vs + "\u00df.de"]
    add("nfc_maybe", nfcq)
    add("nfc", ["cafe\u0301.fr", "\u1112\u1161\u11ab.kr", "a\u0302\u0323.com", "a\u0323\u0302.com",
                "\u0915\u093c.in", "\u0958.in", "\u0b15\u0b47\u0b3e.in", "\u212b.com", "\u2126.gr", "\u1e9b\u0323.x",
                "\u0344.x", "a\u0344.x", "\u0f73.x", "\u0f40\u0f73.bt", "\u1100\u1161\u11a8", "\u1100\u1161",
                "\uac00\u11a8", "\uac00\u11c3", "e\u0301\u0301\u0301", "a" + "\u0301\u0316" * 100,
                "xn--cafe-yvc.fr", "\u00c5\u030a", "\u0041\u030a\u0301", "\u1fbf\u0301", "\u0374", "\u037e"])
    # --- hyphens / CheckHyphens / V4
    add("hyphen", ["ab--c.com", "-ab.com", "ab-.com", "a-b.com", "xn--mnchen-3ya.com", "ab--\u00fc.com",
                   "ab--c\u00df.com", "-c\u00df.com", "c\u00df-.com", "xn--xn--mnchen-eeb.com", "xn--ab--c-pqa.com",
                   "xn--.com", "xn---.com", "XN--MNCHEN-3YA.COM", "\uff58\uff4e\uff0d\uff0dmnchen-3ya.de",
                   "xn--\u00fc.com", "xn--m\u00fcnchen.com", "xn--9.com", "-", "--", "a--", "---a"])
    # --- bidi (RFC 5893 rules 1-6)
    add("bidi", ["\u05d0\u05d1.com", "a\u05d0.com", "\u05d0a.com", "1\u05d0.com", "\u05d01\u0661.com",
                 "\u06271\u0661.com", "\u05d0\u05b0.com", "\u05d0-.com", "1.\u05d0", "a\u0300.\u05d0",
                 "\u00df1-\u05d0.com", "\u0661.com", "a.\u0661", "\u05d0.\u0661", "\u05d0\u0300", "\u05d0 \u05d1",
                 "\u05d0\u00a0\u05d1", "\u0627\u0644\u0639\u0631\u0628\u064a\u0629.\u0645\u0635\u0631",
                 "\u05d0" + "\u0300" * 10, "a\u0661.com", "\u05d0\u200f\u05d1", "\u05d0\u202e\u05d1", "\u05d0..",
                 "..\u05d0", "\u05d0.", "\u0627\u06f1", "\u06271", "\u0627\u0661\u06f1", "\U00010800\U00010801.x",
                 "\u07c0.x", "x.\u08a0\u0660"])
    # --- ContextJ / ContextO
    add("ctx", ["\u0915\u094d\u200d\u0937.in", "\u0915\u094d\u200c\u0937.in", "a\u200db.com", "a\u200cb.com",
                "\u0628\u200c\u0628.com", "\u0628\u0650\u200c\u0650\u0628", "\u0627\u200c\u0628", "\u200c\u0628",
                "\u0628\u200c", "\u0640\u200c\u0628", "\u0628\u200c\u0640", "\ua872\u200c\ua872",
                "l\u00b7l.cat", "a\u00b7a.cat", "\u00b7l.cat", "l\u00b7", "\u0375\u03b1.gr", "\u0375a.gr", "\u0375",
                "\u05d0\u05f3.il", "\u05f3\u05d0.il", "\u30a2\u30fb\u30a4.jp", "a\u30fb\u30a4.jp", "a\u30fbb.jp",
                "\u3005\u30fb.jp", "\u3007\u30fb.jp", "\u4eba\u3005\u30fb\u3007.jp", "\u30fb", "\u0628\u0661\u06f1",
                "\u0661\u0662", "\u06f1\u06f2", "\u200d", "\u200c", "\u0dc1\u0dca\u200d\u0dbb\u0dd3.com"])
    # --- DNS length
    L63, L64 = "a" * 63, "a" * 64
    d253 = "a" * 63 + "." + "b" * 63 + "." + "c" * 63 + "." + "d" * 61
    add("dns", [L63 + ".com", L64 + ".com", d253, d253 + ".", d253 + "e", d253 + "..", "a..b", "a.b..", ".", "..",
                "", "a.", ".a", "\u00fc" + "a" * 55 + ".com", "\u00fc" + "a" * 56 + ".com", "\u3002", "a\u3002",
                "a\uff0e\uff0e", "\u00df" + "a" * 56 + ".com", ("a." * 126) + "a", ("a." * 127) + "a",
                ("a." * 128) + "a", ("\u00fc." * 127) + "x", "a" * 1000 + ".com", "a" * 1001 + ".com"])
    # --- transitional / deviations
    add("dev", ["fa\u00df.de", "Fa\u00df.de", "\u03b2\u03cc\u03bb\u03bf\u03c2.com", "\u03a3\u03b1.gr",
                "\u1e9e.de", "xn--fa-hia.de", "a\u200d", "\u00df\u00df", "\u03c2.\u03c2", "xn--zca", "xn--3xa"])
    # --- STD3 / ASCII oddities (NUL, controls, / @ :) incl. through fullwidth and Punycode basic parts
    asc = ["a_b.com", "a b.com", "a\uff3fb.com", "a_\u00fc.com", "A_B.COM", "a\x00b.com", "a\x7fb.com",
           "a/b.com", "a@b.com", "a:b.com", "a%2eb.com", "a\\b.com", "\uff0f", "\uff20", "a\u2215b",
           "a\u2044b.com", "a\u2024b", "a\ufe52b", "a\u2488b", "\U0001f100", "\u00a0", "a\u3000b"]
    asc += ["xn--" + p + ".com" for p in ["a\x00b-", "a_b-kva", "a b-kva", "a/b-kva", "a@b-kva", "A-kva"]]
    add("std3", asc)
    # --- invalid UTF-8
    add("utf8", [bytes.fromhex(x) for x in ["61ff2e636f6d", "61c0af2e636f6d", "eda080", "f4908080", "e282",
                                             "c3", "80", "f0908080", "efbfbe", "eda0bdedb8bd", "f7bfbfbf"]])
    # --- UTS #39 / display_domain (spoof and legit)
    add("spoof", ["p\u0430ypal.com", "g\u03bf\u03bfgle.com", "\u0430\u0440\u0440\u04cf\u0435.com",
                  "\u0430m\u0430z\u043en.com", "xn--pypal-4ve.com", "xn--80ak6aa92e.com", "a\u200db.com",
                  "goo\u0261le.com", "\u0251pple.com", "\u0261ithub.com", "facebo\u1d0fk.com", "p\u0251ypal.com",
                  "google.com\u30ceevil.com", "pay\u4e00pal.com", "ama\u30fczon.com", "paypal.com\u4e3fx.evil.com",
                  "evil\u202emoc.elgoog.com", "paypal.com\u2044login.evil.com", "\u0441\u043e\u04e7\u0440.com",
                  "google.com\u0338evil.com", "paypa\u0335l.com", "\u0581\u0585\u0585gle.com",
                  "\u13aa\u13f4\u13ac.com", "paypal\u06611.com", "\u0915\u0031\u0967.in",
                  "\U000116D1\U000116DB.com", "shop\u0e44\u0e17\u0e22.com", "\u0435\u0445\u0430m\u0440l\u0435.com",
                  "\u0440\u0430\u0443\u0440\u0430\u04cf.com", "\u0455\u0441\u04bb\u04e7\u043d.de",
                  "\u0131stanbul.com", "\u0138.com", "\u01c3.com", "\u0283.com", "\u1d00pple.com",
                  "\u03bf\u03c1\u03bf.com", "\u05e1\u05d5.com", "e\u0300\u0300\u0300.com", "i\u0307.com",
                  "\u0237.com", "\u0458\u0430\u0432\u0430.com"])
    add("legit", ["\u4e2d\u6587.com", "\u65e5\u672c\u8a9e.jp", "\ud55c\uad6d\uc5b4.kr", "m\u00fcnchen.de",
                  "caf\u00e9.fr", "www.\u0e23\u0e49\u0e32\u0e19.\u0e44\u0e17\u0e22", "abc\u4e2d\u6587.com",
                  "\u30ce\u30fc\u30c8.jp", "\u043f\u0440\u0438\u0432\u0435\u0442.\u0440\u0444",
                  "\u0645\u062b\u0627\u0644.\u0625\u062e\u062a\u0628\u0627\u0631",
                  "\u05e9\u05dc\u05d5\u05dd.\u05d9\u05e9\u05e8\u05d0\u05dc", "\u03b5\u03bb\u03bb\u03ac\u03b4\u03b1.gr",
                  "b\u00fccher.de", "example.com", "EXAMPLE.COM", "\uff25\uff38\uff21\uff2d\uff30\uff2c\uff25\u3002\uff23\uff2f\uff2d",
                  "\u0939\u093f\u0928\u094d\u0926\u0940.\u092d\u093e\u0930\u0924", "\u0b87\u0ba8\u0bcd\u0ba4\u0bbf\u0baf\u0bbe",
                  "\u10e1\u10d0\u10e5\u10d0\u10e0\u10d7\u10d5\u10d4\u10da\u10dd.ge", "\u0570\u0561\u0575.am",
                  "\u1797\u17b6\u179f\u17b6.kh", "\u3042\u3044\u3046\u4e00\u4e8c.jp", "\u5317\u4eac\u5927\u5b66.cn",
                  "\u00e6ble.dk", "c\u0153ur.fr", "k\u0131rm\u0131z\u0131.com.tr", "\u30dd\u30b1\u30e2\u30f3123.jp",
                  "\u30b3\u30fc\u30d2\u30fc1.jp", "\u0442\u0435\u0441\u0442.\u0440\u0444", "\u03b1\u03b8\u03ae\u03bd\u03b1.gr",
                  "\u03b1\u03b3\u03bf\u03c1\u03ac.gr", "\u0442\u0435\u0441\u0442.bg", "\u0440\u0430\u0431\u043e\u0442\u0430.ua"])
    # whole-script rule across TLDs: ordinary Greek / Cyrillic words and spoofs on native and foreign TLDs
    words = ("αθήνα ελλάδα κύπρος ήλιος θάλασσα νέα τουρισμός αγορά ορος τέχνη υγεία παιδιά "
             "тест москва сайт весна город новости работа банк такси кино почта школа рот нос сосна тесто хор "
             "соӧр ѕсһӧн аррӏе раураӏ ехо").split()
    add("wsc", [w + tld for w in words for tld in (".gr", ".com", ".eu", ".\u0440\u0444", ".bg", ".ua", ".cy", ".\u03b5\u03bb")])
    # UAX #9 isolates (outside the reference UBA's scope: INFO-10 / INFO-12)
    add("bidi_iso", ["\u20671 2\u2069", "a\u2067b\u2069c", "\u2067lapyap\u2069", "\u05d0\u2066ab\u2069\u05d1",
                     "\u2068\u05d0 1\u2069"])
    return cases


def pool():
    """Adversarial code point pool (weighted by repetition)."""
    p = []
    p += [ord(c) for c in "abcdefghijklmnopqrstuvwxyz0123456789"] * 3
    p += [ord(c) for c in "ABCXYZ-.-.-._ /@:"] * 2
    p += [0x3002, 0xFF0E, 0xFF61, 0xFF21, 0xFF41, 0xFF0D, 0x2024, 0xFE52, 0x2488]
    p += [0x00DF, 0x03C2, 0x200C, 0x200D, 0x00AD, 0x034F, 0x200B, 0x2060, 0xFE0F, 0x180B]
    p += [0x0300, 0x0301, 0x0302, 0x0308, 0x0316, 0x0323, 0x0327, 0x0335, 0x0338, 0x0344, 0x093C, 0x094D, 0x0F73]
    p += [0x00C5, 0x00E9, 0x00FC, 0x00E0, 0x212B, 0x2126, 0x0958, 0x1E9B, 0x0130, 0x0131, 0x017F, 0x01C4, 0x0149]
    p += [0x1100, 0x1161, 0x11A8, 0xAC00, 0xD55C, 0x3131]
    p += [0x05D0, 0x05D1, 0x05B0, 0x05F3, 0x0627, 0x0628, 0x0640, 0x0650, 0x064B, 0x0660, 0x0661, 0x06F1, 0x200F,
          0x202E, 0x0710, 0x07C0, 0x08A0, 0x10800]
    p += [0x0915, 0x0937, 0x0967, 0x0DC1, 0x0DCA, 0x0DBB, 0x0B15, 0x0B47, 0x0B3E, 0xA872]
    p += [0x00B7, 0x0375, 0x03B1, 0x30FB, 0x30A2, 0x3005, 0x4E00, 0x4E2D, 0x3042, 0x30CE]
    p += [0x0430, 0x0435, 0x043E, 0x0440, 0x04CF, 0x04E7, 0x03BF, 0x0261, 0x0251, 0x13AA, 0x0585]
    p += [0x1148F, 0x114B9, 0x114BA, 0x114B0, 0x1158E, 0x115B8, 0x115AF, 0x1611E, 0x1611F, 0x16D67, 0x116D1, 0x116DB]
    p += [0x0378, 0xE000, 0xFFFD, 0x10FFFD, 0x32931, 0xE0001, 0x1F600, 0x2603, 0x00A0, 0x3000, 0x0000, 0x007F]
    p += [0x1D400, 0x1D7CE, 0x2460, 0x3392, 0xFDFA, 0x1F12A, 0x00BD, 0x2122]
    return p


def fuzz(n, seed=3492):
    rnd = random.Random(seed)
    P = pool()
    out = {}
    for k in range(n):
        r = rnd.random()
        if r < 0.55:
            labels = []
            for _ in range(rnd.randint(1, 4)):
                labels.append("".join(chr(rnd.choice(P)) for _ in range(rnd.randint(0, 9))))
            s = ".".join(labels)
        elif r < 0.8:
            # random Unicode label encoded as an A-label (valid Punycode, possibly invalid IDN), maybe mutated
            lab = [rnd.choice(P) for _ in range(rnd.randint(1, 8))]
            lab = [c for c in lab if not (0xD800 <= c <= 0xDFFF)] or [0xFC]
            a = model.puny_encode(lab)
            if rnd.random() < 0.3 and a:
                i = rnd.randrange(len(a))
                a = a[:i] + rnd.choice("abz09-A") + a[i + 1:]
            s = ("XN--" if rnd.random() < 0.1 else "xn--") + a + rnd.choice([".com", "", ".\u00fc", ".xn--a"])
        else:
            # random punctuation / limit-edge lengths
            ln = rnd.choice([62, 63, 64, 252, 253, 254])
            base = "".join(chr(rnd.choice(P[:120])) for _ in range(ln))
            s = base
        out["f%05d" % k] = enc(s)
    return out


def write(path, items):
    with open(path, "w") as f:
        for k, v in items.items():
            f.write("%s\t%s\n" % (k, v.hex()))


def main():
    outdir = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 3000
    os.makedirs(outdir, exist_ok=True)
    it = {"t%05d" % no: enc(cols[0].strip('"') if cols[0] == '""' else cols[0]) for no, cols in idnatest_lines()}
    for k in list(it):
        if it[k] == b'""':
            it[k] = b""
    write(os.path.join(outdir, "idnatest.cases"), it)
    nm = named()
    write(os.path.join(outdir, "named.cases"), nm)
    fz = fuzz(n)
    write(os.path.join(outdir, "fuzz.cases"), fz)
    print(len(it), len(nm), len(fz))


if __name__ == "__main__":
    main()
