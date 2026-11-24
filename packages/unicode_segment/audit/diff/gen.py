"""Corpora for the RT-unicode-segment audit (stdlib only, seeded, deterministic).

    python3 -I -B gen.py <out_dir> <fuzz_n>

writes
  ucd.cases / ucd.expect  every line of the official Unicode 16.0.0 GraphemeBreakTest / WordBreakTest /
                          SentenceBreakTest (1,093 + 1,826 + 512), expected boundary offsets in UTF-8 bytes
  named.cases             hand-written adversarial inputs (GB9c chains, ZWJ families, RI parity, Hangul,
                          Hebrew quotes, abbreviations, full-width punctuation, ill-formed UTF-8, CR/LF runs ...)
  fuzz.cases              <fuzz_n> random strings drawn per UAX #29 property class, <fuzz_n>/2 mutations of
                          official test lines, <fuzz_n>/20 long mixtures; ~6 % carry ill-formed UTF-8 bytes
and prints "<ucd> <named> <fuzz>".
"""

import gzip
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ucd  # noqa: E402

TESTS = [("gb", "GraphemeBreakTest.txt", "G"), ("wb", "WordBreakTest.txt", "W"), ("sb", "SentenceBreakTest.txt", "S")]

ILL_FORMED = [
    b"\x80", b"\xbf", b"\xc0\xaf", b"\xc1\xbf", b"\xc3", b"\xe2\x82", b"\xe0\x80\x80", b"\xed\xa0\x80",
    b"\xed\xbf\xbf", b"\xf0\x9f\x98", b"\xf0\x80\x80\x80", b"\xf4\x90\x80\x80", b"\xf5\x80\x80\x80", b"\xff",
    b"\xfe", b"\xe2\x82\xe2\x82\xac", b"\xf0\x9f\x87\xa8\xf0\x9f\x87", b"\xcc", b"\xe0\xa4", b"\xf0\x9f\x91",
]


def parse_test(path):
    """Yield (line_no, code points, boundary flags) for each test line: flags[i] is True for '÷' before cp i."""
    with gzip.open(path, "rt", encoding="utf-8") as f:
        for no, raw in enumerate(f, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            toks = line.split()
            cps, flags = [], []
            for i, t in enumerate(toks):
                if t in ("÷", "×"):
                    flags.append(t == "÷")
                else:
                    cps.append(int(t, 16))
            yield no, cps, flags


def enc(cps):
    return "".join(chr(c) for c in cps).encode("utf-8", "surrogatepass")


def write_case(f, name, b):
    f.write("%s\t%s\n" % (name, b.hex() if b else "-"))


def named_cases():
    """Hand-written adversarial inputs (str or bytes)."""
    S = lambda *cps: "".join(chr(c) for c in cps)
    deva_conj = S(0x0915, 0x094D, 0x0937)                            # क्ष
    deva_long = S(0x0915, 0x094D, 0x0924, 0x094D, 0x0930, 0x093F)    # क्त्रि
    out = {
        # GB9c Indic conjunct break
        "gb9c_deva_ksha": deva_conj,
        "gb9c_deva_chain": deva_long * 3,
        "gb9c_deva_nukta_linker": S(0x0915, 0x093C, 0x094D, 0x0937),
        "gb9c_deva_zwj_linker": S(0x0915, 0x200D, 0x094D, 0x0937),
        "gb9c_deva_linker_zwj": S(0x0915, 0x094D, 0x200D, 0x0937),
        "gb9c_deva_extend_after_linker": S(0x0915, 0x094D, 0x0301, 0x0937),
        "gb9c_deva_two_linkers": S(0x0915, 0x094D, 0x094D, 0x0937),
        "gb9c_deva_no_consonant": S(0x0905, 0x094D, 0x0937),
        "gb9c_deva_linker_then_vowel": S(0x0915, 0x094D, 0x0905),
        "gb9c_beng": S(0x0995, 0x09CD, 0x09B7, 0x09CD, 0x09A3, 0x09BF),
        "gb9c_mlym": S(0x0D15, 0x0D4D, 0x0D37, 0x0D4D, 0x0D2E),
        "gb9c_guj_tel": S(0x0A95, 0x0ACD, 0x0AB7, 0x0C15, 0x0C4D, 0x0C37),
        "gb9c_mixed_scripts": S(0x0915, 0x094D, 0x0995),
        "gb9c_long_chain_200": (S(0x0915, 0x094D) * 200) + S(0x0915),
        "gb9c_extend_200": S(0x0915) + S(0x0301) * 200 + S(0x094D, 0x0915),
        # GB11 emoji
        "gb11_family": S(0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466),
        "gb11_skin_family": S(0x1F469, 0x1F3FD, 0x200D, 0x1F91D, 0x200D, 0x1F468, 0x1F3FF),
        "gb11_fe0f": S(0x2764, 0xFE0F, 0x200D, 0x1F525),
        "gb11_rainbow_flag": S(0x1F3F3, 0xFE0F, 0x200D, 0x1F308),
        "gb11_zwj_no_ep_before": S(0x0061, 0x200D, 0x1F466),
        "gb11_ep_extend_zwj_ep": S(0x1F468, 0x0301, 0x0301, 0x200D, 0x1F469),
        "gb11_double_zwj": S(0x1F468, 0x200D, 0x200D, 0x1F469),
        "gb11_zwj_at_start": S(0x200D, 0x1F469),
        "gb11_keycap": S(0x0031, 0xFE0F, 0x20E3, 0x0023, 0xFE0F, 0x20E3),
        "gb11_tags_flag": S(0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F),
        # GB12/13 regional indicators
        "ri_flags_4": S(0x1F1FA, 0x1F1F8, 0x1F1E8, 0x1F1F3, 0x1F1EF, 0x1F1F5, 0x1F1E9, 0x1F1EA),
        "ri_odd_3": S(0x1F1FA, 0x1F1F8, 0x1F1E8),
        "ri_odd_7": S(*([0x1F1E6] * 7)),
        "ri_after_letter": S(0x61, 0x1F1FA, 0x1F1F8, 0x1F1E8),
        "ri_extend_between": S(0x1F1FA, 0x0301, 0x1F1F8),
        "ri_zwj_between": S(0x1F1FA, 0x200D, 0x1F1F8, 0x1F1E8),
        "ri_101": S(*([0x1F1E6] * 101)),
        "ri_word_in_text": "a" + S(0x1F1FA, 0x1F1F8, 0x1F1E8) + "b",
        # Hangul
        "hangul_jamo_lvt": S(0x1100, 0x1161, 0x11A8, 0x1100, 0x1100, 0x1161, 0x11A8, 0x11A8),
        "hangul_syllables": S(0xAC00, 0x11A8, 0xAC01, 0x11A8, 0x1161),
        "hangul_text": "안녕하세요 세계. 한국어 텍스트입니다!",
        "hangul_lv_v_t": S(0xAC00, 0x1161, 0x11A8, 0x11A8),
        # Prepend / SpacingMark / controls
        "prepend_chain": S(0x0600, 0x0600, 0x0661, 0x0600, 0x000A, 0x0661),
        "prepend_control": S(0x0600, 0x000D, 0x000A),
        "spacingmark": S(0x0915, 0x093F, 0x0903, 0x0E33),
        "controls": "a\x00b\x01\x7f\x1b[31mc" + S(0x0085, 0x2028, 0x2029, 0x200B, 0xFEFF),
        "crlf_runs": "\r\n" * 20 + "\r" * 7 + "\n" * 7 + "\r\r\n\n",
        "lone_cr_lf": "a\rb\nc\r\nd",
        # Words
        "wb_abbrev": "Dr. U.S.A. e.g. 3.14 i.e. a.b.c. 1,000,000.50 1.2.3",
        "wb_apostrophes": "Don't can't 'quoted' o'clock rock'n'roll l'objet",
        "wb_hebrew_quotes": S(0x05D0, 0x0027, 0x20, 0x05D0, 0x0022, 0x05D1, 0x20, 0x05D0, 0x0022, 0x20, 0x05D0, 0x0027, 0x05D1),
        "wb_hebrew_dq_extend": S(0x05D0, 0x0301, 0x0022, 0x0301, 0x05D1),
        "wb_mid_extend": "a" + S(0x0301) + ":" + S(0x0301) + "b" + " 3" + S(0x200D) + "," + S(0xAD) + "4",
        "wb_mid_trailing": "a: b. 3, 4. x'",
        "wb_katakana": S(0x30AB, 0x30BF, 0x30AB, 0x30CA, 0x30FC, 0x30FB, 0x3031, 0x30A1),
        "wb_extendnumlet": "foo_bar __init__ 1_000 _ a_1_b " + S(0x30AB) + "_" + S(0x30AB),
        "wb_wsegspace": "a" + " " * 5 + "b" + S(0x3000, 0x3000) + "c" + S(0x20, 0x0301, 0x20),
        "wb_zwj_ep": "a" + S(0x200D, 0x1F466) + " " + S(0x200D, 0x2764),
        "wb_cjk_fullwidth": "你好世界！カタカナ、テスト。ＡＢＣ１２３，４５６．７",
        "wb_numbers_ext": S(0x0661, 0x0662, 0x066B, 0x0663) + " 12" + S(0x2044) + "34",
        "wb_ri_words": S(0x1F1FA, 0x1F1F8, 0x1F1E8, 0x1F1F3, 0x1F1E6),
        "wb_format_start": S(0xAD, 0x61, 0xAD, 0x62),
        "wb_newline_extend": "a\n" + S(0x0301) + "b",
        "wb_email_url": "mail me: a.b@c.de or https://x.y/z?q=1&r=2#f",
        # Rust unicode-segmentation 1.12 / 1.13 keep these in one word; WB6 / WB12 break before the punctuation
        "wb_mid_zwj_ep_rust_defect": "a:" + S(0x200D, 0x231A) + " 1," + S(0x200D, 0x1F468) + " " + S(0x05D0) + "'" + S(0x200D, 0x2764),
        "wb_alnum_filter": "+-*/ ¼ ½ ² ³ Ⅷ ⅷ ① " + S(0x16EE) + " " + S(0x0BF2) + " ___ ... ' \" ",
        # Sentences
        "sb_abbrev": "Dr. Smith paid $3.14! Next? U.S.A. is big. e.g. this. Mr. Jones.",
        "sb_sb8": "etc. and more. ( he said. \"lower.\" ) next. 'quote.' then",
        "sb_close_sp": "He left.)) \"  She came.  ) x? !)) A",
        "sb_numeric": "Version 3.14 and 2.0. The end. 1. Item",
        "sb_upper_aterm": "U.S. Army. U.S.A. Navy. A.B. c.",
        "sb_scontinue": "a., b.; c.: d.- e.,f",
        "sb_parasep": "One.\nTwo.\r\nThree." + S(0x2029) + "Four." + S(0x85) + "five",
        "sb_fullwidth": "これは文です。次の文！本当？はい。ＯＫ．終わり",
        "sb_extend_format": "a." + S(0x0301) + " " + S(0xAD) + "b. C",
        "sb_sterm_lower": "Hi! there? yes. no",
        "sb_ellipsis": "Wait... what?! No…really. Ok",
        "sb_quotes_close": "“Hello.” ‘World.’ «Fin.» »next« (Done.) [x.]",
        "sb_multi_lang": "Привет. Как дела? Γειά σου. Τι κάνεις; नमस्ते। आप कैसे हैं? مرحبا. كيف حالك؟",
        # Ill-formed UTF-8 (Pion strings are bytes: \xHH escapes and Bytes::to_string can produce these)
        "bad_lone_cont": b"a\x80b\xbf",
        "bad_truncated_4": b"\xf0\x9f\x98a",
        "bad_truncated_3_end": b"ab\xe2\x82",
        "bad_overlong": b"\xc0\xaf\xe0\x80\xaf",
        "bad_surrogate": b"\xed\xa0\x80\xed\xbf\xbf",
        "bad_over_max": b"\xf4\x90\x80\x80\xf5\x80",
        "bad_ff_fe": b"\xff\xfe\xff",
        "bad_mixed_emoji": b"\xf0\x9f\x87\xa8\xf0\x9f\x87\x80\xf0\x9f\x87\xb3",
        "bad_in_conjunct": "क्".encode() + b"\x80" + "ष".encode(),
        "bad_in_zwj": "👨‍".encode() + b"\xff" + "👩".encode(),
        "bad_cont_run": b"\x80\x80\x80\x80\x80a",
        "bad_lead_run": b"\xe2\xe2\xe2\xe2a",
        "bad_before_extend": b"\xff\xcc\x81\xcc\x81",
        "bad_all_ff_33": b"\xff" * 33,
        # misc
        "empty": "",
        "single_a": "a",
        "single_extend": S(0x0301),
        "single_zwj": S(0x200D),
        "single_ri": S(0x1F1E6),
        "nul": "\x00",
        "bmp_max": S(0xFFFD, 0xFFFE, 0xFFFF),
        "smp_edges": S(0x10000, 0x1FFFF, 0x20000, 0xE0000, 0xE0001, 0xE01EF, 0xF0000, 0x10FFFD, 0x10FFFF),
        "mixed_everything": "Dr. U.S.A. e.g. 3.14 א\"ב 👨‍👩 🇺🇸🇨 क्ष 각!? \r\n" * 3,
    }
    return out


def class_pools(p):
    """class name -> list of code points (Unicode 16.0.0) for each UAX #29 property dimension."""
    pools = {}
    for dim, arr in (("gcb", p.gcb), ("wb", p.wb), ("sb", p.sb), ("incb", p.incb)):
        for cp in range(ucd.NCP):
            v = arr[cp]
            if (v in ("Other", "None")) and cp % 97 != 0:  # keep the default class small but present
                continue
            if 0xD800 <= cp <= 0xDFFF:
                continue
            pools.setdefault(dim + ":" + v, []).append(cp)
    pools["ep"] = [cp for cp in range(ucd.NCP) if p.ep[cp]]
    pools["ascii"] = list(range(0x20, 0x7F)) + [0x0A, 0x0D, 0x09]
    pools["hot"] = [0x2E, 0x27, 0x22, 0x2C, 0x3A, 0x3B, 0x3F, 0x21, 0x28, 0x29, 0x20, 0x0A, 0x0D, 0x200D, 0x0301,
                    0xFE0F, 0x094D, 0x0915, 0x1F1E6, 0x1F1E7, 0x1F468, 0x05D0, 0x30AB, 0x5F, 0x31, 0x41, 0x61, 0xAD,
                    0x2029, 0x85, 0x3002, 0xFF0E, 0x1100, 0x1161, 0x11A8, 0xAC00, 0xAC01, 0x0600, 0x0903, 0x3000]
    return pools


def rand_string(rng, pools, keys, lo, hi):
    n = rng.randint(lo, hi)
    cps = []
    for _ in range(n):
        r = rng.random()
        if r < 0.25:
            cps.append(rng.choice(pools["hot"]))
        elif r < 0.35:
            cps.append(rng.choice(pools["ascii"]))
        else:
            cps.append(rng.choice(pools[rng.choice(keys)]))
    return cps


def maybe_ill_formed(rng, b):
    if rng.random() < 0.06:
        bs = bytearray(b)
        for _ in range(rng.randint(1, 3)):
            at = rng.randint(0, len(bs))
            while 0 < at < len(bs) and (bs[at] & 0xC0) == 0x80:  # insert between scalar values
                at -= 1
            bs[at:at] = rng.choice(ILL_FORMED)
        return bytes(bs), True
    return b, False


def main():
    out, fuzz_n = sys.argv[1], int(sys.argv[2])
    os.makedirs(out, exist_ok=True)
    nu = 0
    with open(os.path.join(out, "ucd.cases"), "w") as fc, open(os.path.join(out, "ucd.expect"), "w") as fe:
        official = []
        for pre, fname, tag in TESTS:
            for no, cps, flags in parse_test(os.path.join(ucd.UCD_ROOT, "16.0.0", fname + ".gz")):
                b = enc(cps)
                offs, o = [], 0
                for i, c in enumerate(cps):
                    if flags[i]:
                        offs.append(o)
                    o += len(chr(c).encode("utf-8", "surrogatepass"))
                if flags[len(cps)]:
                    offs.append(o)
                name = "%s%04d" % (pre, no)
                write_case(fc, name, b)
                fe.write("%s\t%s\t%s\n" % (name, tag, " ".join(map(str, offs))))
                official.append(cps)
                nu += 1
    named = named_cases()
    with open(os.path.join(out, "named.cases"), "w") as f:
        for k, v in named.items():
            write_case(f, "n_" + k, v if isinstance(v, bytes) else v.encode("utf-8"))
    p = ucd.props("16.0.0")
    pools = class_pools(p)
    keys = sorted(k for k in pools if k not in ("hot", "ascii"))
    rng = random.Random(0x5E6_29)
    nf = 0
    nbad = 0
    with open(os.path.join(out, "fuzz.cases"), "w") as f:
        for i in range(fuzz_n):
            b, bad = maybe_ill_formed(rng, enc(rand_string(rng, pools, keys, 1, 16)))
            nbad += bad
            write_case(f, "f_rand_%05d" % i, b)
            nf += 1
        for i in range(fuzz_n // 2):
            cps = list(rng.choice(official))
            for _ in range(rng.randint(1, 3)):
                op = rng.random()
                at = rng.randint(0, len(cps))
                c = rng.choice(pools[rng.choice(keys)]) if rng.random() < 0.7 else rng.choice(pools["hot"])
                if op < 0.4 or not cps:
                    cps.insert(at, c)
                elif op < 0.7:
                    cps[min(at, len(cps) - 1)] = c
                else:
                    del cps[min(at, len(cps) - 1)]
            cps = [c for c in cps if not 0xD800 <= c <= 0xDFFF]
            b, bad = maybe_ill_formed(rng, enc(cps))
            nbad += bad
            write_case(f, "f_mut_%05d" % i, b)
            nf += 1
        for i in range(max(1, fuzz_n // 20)):
            b, bad = maybe_ill_formed(rng, enc(rand_string(rng, pools, keys, 40, 160)))
            nbad += bad
            write_case(f, "f_long_%05d" % i, b)
            nf += 1
    print(nu, len(named), nf, nbad)


if __name__ == "__main__":
    main()
