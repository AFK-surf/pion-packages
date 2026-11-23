"""Ad-hoc repro: one.py [--dict en_us|crate|PATS:HYP:LMIN:RMIN] [--text SEP] word ...
Prints, per word, Pion `opportunities` (or `hyphenate_text`) next to Rust `hyphenate(w).breaks`.
--dict en_us : Pion Dictionary::en_us() vs Rust from_embedded(EnglishUS)   (default)
--dict crate : Pion from_tex(crate hyph-en-us.pat.txt/.hyp.txt, 2, 3) vs Rust from_embedded(EnglishUS)
--dict P:H:L:R : both sides load pattern file P / exception file H ('-' = none) with minima L, R
"""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import PION, RUST, CRATE_PAT, CRATE_HYP, run_batch

args = sys.argv[1:]
spec = "en_us"
text = None
if args[:1] == ["--dict"]:
    spec, args = args[1], args[2:]
if args[:1] == ["--text"]:
    text, args = args[1], args[2:]
words = [w.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8") for w in args]
if spec == "en_us":
    ps, rs = ("@en_us", "-", 2, 3), ("@en_us", "-", 2, 3)
elif spec == "crate":
    ps, rs = (CRATE_PAT, CRATE_HYP, 2, 3), ("@en_us", "-", 2, 3)
else:
    p, h, l, r = spec.split(":")
    ps = rs = (p, h, l, r)
if text is not None:
    for w, o in zip(words, run_batch(PION, "text", ps, words, "one", extra=(text,))):
        print(f"{w!r} -> {o!r}")
    sys.exit(0)
po = run_batch(PION, "opp", ps, words, "one")
ro = run_batch(RUST, "opp", rs, words, "one")
for w, p, r in zip(words, po, ro):
    print(f"{w!r:32s} pion=[{p}] rust=[{r}] {'' if p == r else 'DIFF'}")
