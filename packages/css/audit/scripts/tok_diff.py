"""W3C CSS Syntax Level 3 token-level differential: Pion `tokenize` vs Rust cssparser =0.35.0 vs
Node css-tree@3.1.0 (and Pion `tokenize_bytes` vs `tokenize` on raw byte inputs).

Corpus = hand-written edge cases (url/BadUrl, unicode-range vs ident, escapes, numbers, CDO/CDC,
comments, strings, NUL / invalid UTF-8) + deterministic grammar/byte mutation fuzz (--fuzz N).
Numbers are compared after rounding to f32 (cssparser stores f32); Node's Hash kind is not
distinguished (css-tree has one Hash type), so IDHASH/HASH are folded for the Node comparison.
A case counts as a *Pion-only deviation* when Rust and Node agree with each other and Pion differs.
Usage: tok_diff.py [--fuzz N] [--show K] [--json out.json]
"""
import argparse, collections, json, os, random, struct, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import run, parse_items

SEEDS = [
    # url(...) unquoted / quoted / whitespace / escapes / parens / non-printables / BadUrl / case
    "url(a.png)", "URL(a.png)", "uRl(a.png)", "url( a.png )", "url(  'a.png'  )", 'url("a.png")',
    "url(a b)", "url(a\"b)", "url(a'b)", "url(a(b)", "url(a\\)b)", "url(a\\\nb)", "url(a\x01b)",
    "url(a\x7fb)", "url(a\x0bb)", "url()", "url( )", "url(", "url(a", "url(a ", "url(\\", "url(\\)",
    "url(a\\29 b)", "url(http://a/*b*/)", "url(a b) x", "url(a\"b) c", "u\\rl(a)", "\\75 rl(a)",
    "url (a)", "url(\ta\t)", "url(a)b", "url(\"a\" b)", "url(\"a\"", "url(\u00e9)", "url(a){}",
    # unicode-range vs ident / selector
    "U+0-10FFFF", "U+4??", "u+1f600", "u+foo", "u+a", "U+A-B", "u+??????", "u+1234567", "U+-1",
    "u+a{color:red}", ".u+a", "u+ a", "u +a", "U+0025-00FF", "u+0x", "u+e1", "U+1e3", "u+?a",
    # escapes
    "\\", "a\\", "\\\n", "a\\\nb", "\\41", "\\41 b", "\\41\nb", "\\41\r\nb", "\\41\tb", "\\0",
    "\\0 a", "\\110000", "\\FFFFFF", "\\D800", "\\DFFF", "\\1F600", "\\1F6000", "\\31 23",
    "#\\31 a", ".\\31 a", "\\e9", "\u00e9t\u00e9", "--", "--a", "-a", "-1", "-.5", "-\\31",
    "--\\31", "-", "- -", "-\\\n", "\\-a", "a\\ b", "\\@x", "@\\61", "@-x", "@--x", "@-1", "@",
    # numbers
    "1e+2", "1e-2", "1e+", "1e", "1E3", "+.5", "-.5", ".5", "1.2.3", "1.", "1.e2", "+", "+a",
    "+1px", "-1px", "1px-2px", "1-2", "1--a", "1%", "1.5%", "1e2%", "1e2px", "1x2", "0.1",
    "00.100", "+0", "-0", "-0.0e-0", "1e999", "1e-999", "123456789012345678901234567890",
    "0.30000000000000004", "1.7976931348623157e309", "3.4028236e38", "1e+2e3", "12\\px", "1\\70 x",
    # CDO / CDC / comments / strings
    "<!--", "-->", "<!-", "--!>", "<!---->", "a<!--b-->c", "/*", "/* a", "/**/", "/*/", "a/**/b",
    "a/* */b", "/*a*//*b*/", "*/", '"a', "'a", '"a\nb"', '"a\\\nb"', '"\\', '"\\"', "'\\'",
    '"a\\\r\nb"', '"\\41"', '"\\0"', '"', "''", '""x', "'\\\n'", '"a\fb"',
    # punctuation / attribute matchers / misc
    "a~=b", "a|=b", "a^=b", "a$=b", "a*=b", "a||b", "(]", "[)", "{)", "}", ")", "]", "#", "#-",
    "#-1", "#1", "#--", "#a", "#\\", "@media", "@MEDIA", "!important", "! important", "!/*c*/important",
    "a:b;c,d", "\t\n\f\r ", "\r\n", "\r", "\f", "\x00", "a\x00b", "\ufeffa", "\u00a0", "\u2028",
    # realistic snippets
    ".a{color:red}", "@media (min-width:768px){.a{margin:0 auto}}", "a[href^='http']:not(.x)::before{}",
    ":nth-child(2n+1 of #id.foo)", "calc(100% - 10px)", "--x:  12px ;", "rgb(255 0 0 / 50%)",
    "@font-face{src:url(a.woff2)format('woff2'),url(b.woff)}", "@import url(x.css) layer(base) supports(display:grid);",
    "grid-template-areas:'a b' 'c d'", "content:'\\201C'", "font:12px/1.5 'Helvetica Neue',sans-serif",
]

FRAGS = ["url(", "URL(", ")", "(", "\\", "\\\n", "\\41 ", "u+", "U+", "?", "-", "--", "+", ".", "e", "E",
         "1", "0", "9", "a", "f", "#", "@", "'", '"', "/*", "*/", "<!--", "-->", " ", "\n", "\t", "%",
         "px", "{", "}", "[", "]", ";", ":", ",", "!", "\x00", "\x01", "\x7f", "\u00e9", "\U0001F600",
         "\r\n", "\f", "\\0", "\\110000", "\\D800", "1e", "1.5", "-.", "+.", "important", "\\\\"]


def gen(rng):
    k = rng.random()
    if k < 0.45:
        return "".join(rng.choice(FRAGS) for _ in range(rng.randint(1, 12)))
    s = list(rng.choice(SEEDS))
    for _ in range(rng.randint(1, 4)):
        op = rng.random()
        pos = rng.randint(0, len(s))
        if op < 0.5:
            s[pos:pos] = list(rng.choice(FRAGS))
        elif op < 0.8 and s:
            del s[min(pos, len(s) - 1)]
        elif s:
            s[min(pos, len(s) - 1)] = rng.choice(FRAGS)
    return "".join(s)


def f32(x):
    try:
        return struct.unpack("f", struct.pack("f", float(x)))[0]
    except OverflowError:
        return float("inf") if float(x) > 0 else float("-inf")


def norm(items, fold_hash=False, pct_is_unit=False):
    """pct_is_unit: the dump carries cssparser's f32 `unit_value` (0.15 for 15%) instead of 15."""
    if items is None:
        return None
    out = []
    for k, v in items:
        if k in ("NUM", "PCT", "DIM"):
            parts = v.decode("utf-8", "replace").split(" ", 2)
            num = f32(parts[1])
            if k == "PCT" and not pct_is_unit:
                num = f32(float(parts[1]) / 100.0)
            v = (parts[0], repr(num)) + tuple(parts[2:])
        elif fold_hash and k == "IDHASH":
            k = "HASH"
        out.append((k, v))
    return out


def category(src, a, b):
    """Coarse cause bucket from the first differing token."""
    i = 0
    a = a or []
    b = b or []
    while i < len(a) and i < len(b) and a[i] == b[i]:
        i += 1
    ka = a[i][0] if i < len(a) else "EOF"
    kb = b[i][0] if i < len(b) else "EOF"
    if "URANGE" in (ka, kb):
        return "unicode-range token (removed from CSS Syntax 3; cssparser/css-tree emit ident/+/...)"
    if {ka, kb} == {"HASH", "IDHASH"}:
        return "hash type flag (id vs unrestricted)"
    if {ka, kb} & {"NUM", "PCT", "DIM"} and ka == kb:
        return "numeric value / flags"
    return f"{ka} vs {kb}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fuzz", type=int, default=20000)
    ap.add_argument("--show", type=int, default=3)
    ap.add_argument("--json")
    a = ap.parse_args()
    rng = random.Random(20261123)
    cases = list(dict.fromkeys(SEEDS + [gen(rng) for _ in range(a.fuzz)]))
    P = run("pion", "tok", cases, raw=True)
    R = run("rust", "tok", cases, raw=True)
    N = run("node", "tok", cases, raw=True)
    stats = collections.Counter()
    cats = collections.defaultdict(list)
    for src, p, r, n in zip(cases, P, R, N):
        pi, ri, ni = parse_items(p), parse_items(r), parse_items(n)
        pr = norm(pi) == norm(ri, pct_is_unit=True)
        pn = norm(pi, True) == norm(ni, True)
        rn = norm(ri, True, True) == norm(ni, True)
        stats["cases"] += 1
        stats["pion==rust"] += pr
        stats["pion==node"] += pn
        stats["rust==node"] += rn
        if not pr and rn:
            stats["pion_only_deviation"] += 1
            cats[category(src, norm(pi), norm(ri, pct_is_unit=True))].append((src, p[:200], r[:200]))
        elif not pr and pn:
            stats["pion==css-tree, cssparser deviates"] += 1
            cats["(Pion==css-tree; cssparser differs) " + category(src, norm(pi), norm(ri, pct_is_unit=True))].append((src, p[:200], r[:200]))
        elif not pr:
            stats["three_way_or_oracles_disagree"] += 1
            cats["(all three differ) " + category(src, norm(pi), norm(ri, pct_is_unit=True))].append((src, p[:200], r[:200]))
    # raw-byte path: tokenize_bytes(Bytes) vs tokenize(String) on invalid UTF-8 / NUL inputs
    raw = [b"a\xffb", b"\xc3", b"\xe2\x82", b"\xf0\x9f\x98", b"\xed\xa0\x80", b"\xc0\xaf", b"a\x00b", b"\"\xff\"",
           b"url(\xff)", b"#\xfe", b"@\x80x", b"\xef\xbf\xbe", b"\xf4\x90\x80\x80", b"\x80\x80"]
    raw += [bytes(rng.randrange(256) for _ in range(rng.randint(1, 16))) for _ in range(2000)]
    PB = run("pion", "tokb", raw, raw=True)
    PS = run("pion", "tok", raw, raw=True)
    RB = run("rust", "tok", raw, raw=True)  # Rust oracle decodes records with from_utf8_lossy (U+FFFD per maximal subpart)
    bstats = collections.Counter()
    bex = []
    for src, pb, ps, rb in zip(raw, PB, PS, RB):
        bstats["cases"] += 1
        same_rb = norm(parse_items(pb)) == norm(parse_items(rb), pct_is_unit=True)
        bstats["tokenize_bytes==cssparser(lossy)"] += same_rb
        try:
            ps.decode("utf-8")
        except UnicodeDecodeError:
            bstats["tokenize(String) emits invalid UTF-8 in token values"] += 1
            if len(bex) < 3:
                bex.append((src, ps[:120]))
        if not same_rb and len(bex) < 6:
            bex.append((src, pb[:120], rb[:120]))
    print(f"token differential: {stats['cases']} cases ({len(SEEDS)} hand-written + fuzz)")
    for k in ("pion==rust", "pion==node", "rust==node", "pion_only_deviation", "pion==css-tree, cssparser deviates",
              "three_way_or_oracles_disagree"):
        print(f"  {k:32s} {stats[k]:6d}  ({100.0 * stats[k] / stats['cases']:.2f}%)")
    print("  deviation buckets (count, examples):")
    for c, lst in sorted(cats.items(), key=lambda x: -len(x[1])):
        print(f"    {len(lst):6d}  {c}")
        for src, p, r in lst[:a.show]:
            print(f"            src={src!r}\n              pion={p!r}\n              rust={r!r}")
    print(f"raw-byte path: {bstats['cases']} byte inputs")
    for k, v in bstats.items():
        if k != "cases":
            print(f"  {k:55s} {v}")
    for e in bex:
        print("    ", e)
    if a.json:
        json.dump({"stats": stats, "buckets": {k: [list(map(repr, x)) for x in v[:20]] for k, v in cats.items()},
                   "bytes": bstats}, open(a.json, "w"), indent=1, default=str)


if __name__ == "__main__":
    main()
