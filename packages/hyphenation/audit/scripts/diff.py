"""Large-scale differential: Pion `opportunities` vs Rust `hyphenation =0.8.4` `hyphenate(w).breaks`.

Corpus: every word of /usr/share/dict/words (Webster 2nd, 235,976 entries) and the tokens of
/usr/share/dict/web2a, the 1,441 hyph-utf8 + 14 TeXbook exceptions, and generated adversarial classes
(case variants, 0-5 char words, long compounds, apostrophes / hyphens / digits / punctuation,
non-ASCII and multi-byte UTF-8). Two comparisons:
  engine : Pion from_tex(crate hyph-en-us.pat.txt + hyph-en-us.hyp.txt, 2, 3) vs Rust from_embedded(EnglishUS)
           -> identical tables, so any diff is an engine / API-semantics difference
  en_us  : Pion Dictionary::en_us() (built-in tables) vs Rust from_embedded(EnglishUS)
Plus structural invariants on Pion split_word / hyphenate (round-trip, char boundaries, minima).
Usage: diff.py [--show N] [--json out.json]
"""
import collections, json, os, random, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, PION, RUST, CRATE_PAT, CRATE_HYP, run_batch

SHOW = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 3
TEXBOOK14 = ("as-so-ciate as-so-ciates dec-li-na-tion oblig-a-tory phil-an-thropic present presents "
             "project projects reci-procity re-cog-ni-zance ref-or-ma-tion ret-ri-bu-tion ta-ble").split()


def build_corpus():
    rng = random.Random(20261123)
    words = [w.strip() for w in open("/usr/share/dict/words", encoding="utf-8") if w.strip()]
    web2a = sorted({t for line in open("/usr/share/dict/web2a", encoding="utf-8") for t in re.split(r"[\s-]+", line) if t})
    hyp = open(CRATE_HYP, encoding="utf-8").read().split()
    excw = sorted({e.replace("-", "") for e in hyp + TEXBOOK14})
    lower = sorted({w.lower() for w in words + web2a})
    C = collections.OrderedDict()
    C["dict_lower"] = lower
    C["dict_as_is"] = sorted(set(words) - set(lower))  # proper nouns etc. with capitals
    C["dict_capitalized"] = [w.capitalize() for w in lower if len(w) > 1][::3]
    C["dict_upper"] = [w.upper() for w in lower][1::3]
    C["dict_mixed"] = ["".join(c.upper() if rng.random() < 0.5 else c for c in w) for w in lower[2::5]]
    C["exceptions"] = excw + [w.capitalize() for w in excw] + [w.upper() for w in excw]
    alpha = "abcdefghijklmnopqrstuvwxyz"
    short = [""] + list(alpha) + ["".join(rng.choice(alpha) for _ in range(n)) for n in (2, 3, 4, 5) for _ in range(3000)]
    C["short_0_5"] = short + [w for w in lower if len(w) <= 5][:5000]
    C["long_compound"] = ["".join(rng.choice(lower) for _ in range(rng.randint(2, 8))) for _ in range(20000)] + \
        ["".join(rng.choice(lower) for _ in range(40)) for _ in range(300)]
    C["apostrophe"] = [w + rng.choice(["'s", "'t", "'ll", "s'"]) for w in lower[::40]] + ["o'" + w for w in lower[7::200]]
    C["hyphen_compound"] = [rng.choice(lower) + "-" + rng.choice(lower) for _ in range(8000)] + \
        ["-" + w for w in lower[::300]] + [w + "-" for w in lower[1::300]] + [w + "--" + w for w in lower[2::300]]
    C["digits"] = [w + str(rng.randint(0, 999)) for w in lower[::60]] + [str(rng.randint(0, 99)) + w for w in lower[5::60]] + \
        [w[:len(w) // 2] + "2" + w[len(w) // 2:] for w in lower[9::60]]
    C["punct_wrapped"] = [rng.choice("([\"'") + w + rng.choice([".", ",", "!", "?", ")", "]", "\"", "';", "...", ":"]) for w in lower[::50]] + \
        [w + "." for w in lower[3::50]] + [w.replace(w[len(w) // 2:len(w) // 2 + 1], ".", 1) for w in lower[4::80] if len(w) > 3]
    C["whitespace_ctl"] = [w + rng.choice(["\t", " ", "\r", "\f", "\v", "\x00", "\x1f"]) + rng.choice(lower) for w in lower[::200]]
    acc = ["é", "ü", "ö", "ä", "ß", "ñ", "ç", "ø", "æ", "œ", "ł", "ı", "İ", "Ä", "Ü", "É", "Σ"]
    nonascii = []
    for w in lower[::40]:
        k = rng.randint(0, len(w))
        nonascii.append(w[:k] + rng.choice(acc) + w[k:])
    nonascii += [w.capitalize().replace(w[0].upper(), rng.choice(["Ä", "Ö", "Ü", "É", "İ", "Ł"]), 1) for w in lower[11::200]]
    nonascii += ["café", "naïve", "résumé", "Résumé", "RÉSUMÉ", "façade", "über", "straße", "İstanbul", "İnternationalization",
                 "internatİonalization", "hyphenİzation", "computerİ", "SİMPLİFİCATİON", "ǅungla", "ﬁnancial", "ﬂoweriness"]
    C["non_ascii"] = nonascii
    marks = ["­", " ", "—", "’", "​", "́", "\U0001F600", "中文", "‐", "‑"]
    C["unicode_marks"] = [w[:len(w) // 2] + rng.choice(marks) + w[len(w) // 2:] for w in lower[::120]] + \
        [w + rng.choice(marks) for w in lower[13::300]] + [rng.choice(marks) + w for w in lower[17::300]] + \
        ["hy­phen­ation", "­hyphenation", "hyphenation­", "résumé"]
    return C


def compare(C, pion_spec, label, rust_spec=("@en_us", "-", 2, 3)):
    res = collections.OrderedDict()
    for cls, recs in C.items():
        p = run_batch(PION, "opp", pion_spec, recs, f"diff_{label}_{cls}")
        r = run_batch(RUST, "opp", rust_spec, recs, f"diff_{label}_{cls}")
        bad = [(w, pp, rr) for w, pp, rr in zip(recs, p, r) if pp != rr]
        res[cls] = {"total": len(recs), "diff": len(bad), "examples": [list(b) for b in bad[:SHOW]]}
        pct = 100.0 * (len(recs) - len(bad)) / max(1, len(recs))
        print(f"  [{label}] {cls:16s} total={len(recs):7d} diff={len(bad):6d} identical={pct:7.3f}%")
        for w, pp, rr in bad[:SHOW]:
            print(f"      {w!r:40.40s} pion=[{pp}] rust=[{rr}]")
    return res


def invariants(C):
    """split_word / hyphenate round-trips and offset sanity on the Pion side (en_us)."""
    viol = collections.Counter()
    ex = {}
    n = 0
    for cls, recs in C.items():
        out = run_batch(PION, "all", ("@en_us", "-", 2, 3), recs, f"inv_{cls}")
        for w, o in zip(recs, out):
            if "\x1e" in w or "\x1f" in w:  # the probe's own field separators: not checkable
                continue
            n += 1
            opp_s, split_s, hyph = o.split("\x1e")
            opps = [int(x) for x in opp_s.split(",")] if opp_s else []
            parts = split_s.split("\x1f") if w else []
            b = w.encode()
            checks = {
                "split_roundtrip": "".join(parts) == w,
                "split_count": (len(parts) == len(opps) + 1) if w else parts == [],
                "hyphenate_join": hyph == "=".join(parts) if w else hyph == "",
                "ascending": all(x < y for x, y in zip(opps, opps[1:])),
                "in_range": all(0 < x < len(b) for x in opps),
                "char_boundary": all((b[x] & 0xC0) != 0x80 for x in opps if 0 < x < len(b)),
            }
            for k, ok in checks.items():
                if not ok:
                    viol[k] += 1
                    ex.setdefault(k, (cls, w, o))
    print(f"  invariants over {n} records: " + ("ALL HOLD" if not viol else str(dict(viol))))
    for k, v in ex.items():
        print(f"      {k}: {v!r}"[:300])
    return {"records": n, "violations": dict(viol), "examples": {k: list(v) for k, v in ex.items()}}


def main():
    sys.stdout.reconfigure(line_buffering=True)
    C = build_corpus()
    print(f"  corpus: {sum(len(v) for v in C.values())} records in {len(C)} classes")
    # TeX \\hyphenation is case-insensitive (\\lccode); hyphenation 0.8.4 stores exception keys verbatim and
    # lowercases only the query, so its 175 capitalised exceptions (Ar-kan-sas, ATP-ase...) never match.
    # engine_tex feeds Rust the same files with the exceptions lowercased = TeX semantics.
    lc_hyp = os.path.join(TMP, "hyph-en-us.hyp.lower.txt")
    open(lc_hyp, "w", encoding="utf-8").write(open(CRATE_HYP, encoding="utf-8").read().lower())
    report = {"engine": compare(C, (CRATE_PAT, CRATE_HYP, 2, 3), "engine"),
              "engine_tex": compare(C, (CRATE_PAT, CRATE_HYP, 2, 3), "engine_tex", (CRATE_PAT, lc_hyp, 2, 3)),
              "en_us": compare(C, ("@en_us", "-", 2, 3), "en_us"),
              "invariants": invariants(C)}
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
