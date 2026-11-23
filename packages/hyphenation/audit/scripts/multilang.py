"""Multi-script UTF-8 differential: every hyph-utf8 table bundled with hyphenation 0.8.4 (80 languages,
Latin / Cyrillic / Greek / Indic / Ethiopic / Georgian / Armenian / Coptic...) loaded on BOTH sides from
the same text (Pion from_tex vs Rust Parse::pair + Builder, minima from the crate's language.rs).

Words: alphabetic cores of the language's own patterns glued together (1-4 per word, so every pattern
path is exercised), the language's exception words, and Unicode upper / title-case variants of all of them.
Exceptions are lowercased for Rust so both sides use TeX (case-insensitive) exception semantics.
Usage: multilang.py [--show N] [--per N] [--json out.json]
"""
import collections, glob, json, os, random, re, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, PION, RUST, CRATE_PAT, run_batch

SHOW = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 2
PER = int(sys.argv[sys.argv.index("--per") + 1]) if "--per" in sys.argv else 3000
PDIR = os.path.dirname(CRATE_PAT)
LANGRS = glob.glob(os.path.expanduser("~/.cargo/registry/src/*/hyphenation_commons-0.8.4/src/language.rs"))[0]
MINIMA = {code: (int(a), int(b)) for a, b, code in
          re.findall(r"\((\d+),\s*(\d+)\),\s*\"([^\"]+)\"", open(LANGRS, encoding="utf-8").read())}


def main():
    sys.stdout.reconfigure(line_buffering=True)
    rng = random.Random(7)
    totals = collections.Counter()
    report = {}
    for pat in sorted(glob.glob(os.path.join(PDIR, "hyph-*.pat.txt"))):
        code = os.path.basename(pat)[5:-8]
        if code not in MINIMA:
            continue
        lmin, rmin = MINIMA[code]
        hyp = pat.replace(".pat.txt", ".hyp.txt")
        ptoks = open(pat, encoding="utf-8").read().split()
        cores = [c for c in (re.sub(r"[0-9.]", "", t) for t in ptoks) if c]
        excs = open(hyp, encoding="utf-8").read().split() if os.path.exists(hyp) else []
        words = ["".join(rng.choice(cores) for _ in range(rng.randint(1, 4))) for _ in range(PER)]
        words += [e.replace("-", "") for e in excs]
        words += [w.upper() for w in words[: PER // 2]] + [w.title() for w in words[PER // 2: PER]]
        words += [e.replace("-", "").upper() for e in excs] + [e.replace("-", "").title() for e in excs]
        rhyp = "-"
        if excs:
            rhyp = os.path.join(TMP, f"ml_{code}.hyp.lower.txt")
            open(rhyp, "w", encoding="utf-8").write("\n".join(e.lower() for e in excs) + "\n")
        p = run_batch(PION, "opp", (pat, hyp if excs else "-", lmin, rmin), words, f"ml_{code}")
        r = run_batch(RUST, "opp", (pat, rhyp, lmin, rmin), words, f"ml_{code}")
        bad = [(w, a, b) for w, a, b in zip(words, p, r) if a != b]
        kinds = collections.Counter()
        for w, a, b in bad:
            kinds["cased" if w != w.lower() else "lowercase"] += 1
        totals["words"] += len(words)
        totals["diff"] += len(bad)
        report[code] = {"words": len(words), "diff": len(bad), "kinds": dict(kinds), "examples": [list(x) for x in bad[:SHOW]]}
        if bad:
            print(f"  {code:14s} ({lmin},{rmin}) words={len(words):6d} diff={len(bad):5d} {dict(kinds)}")
            for w, a, b in bad[:SHOW]:
                print(f"      {w!r:36.36s} pion=[{a}] rust=[{b}]")
    print(f"  {len(report)} languages, {totals['words']} words, {totals['diff']} diffs; "
          f"identical languages: {sum(1 for v in report.values() if v['diff'] == 0)}")
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
