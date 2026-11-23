"""Minifier / serializer semantic-preservation audit.

Oracle: lightningcss 1.0.0-alpha.72. For every input X we compare
    lnorm(X)  vs  lnorm(pion_minify(X))
where lnorm = lightningcss parse (error recovery on) + lightningcss minified print, i.e. lightningcss's
canonical semantic form. Equal forms => Pion's minification preserved meaning (as far as a real
minifier can tell). We also flag outputs that lightningcss *strict* parsing rejects although the
input was accepted ("minify generated invalid CSS"), and the same check for `to_css` (pretty printer).
Usage: minify_diff.py [--fuzz N] [--show K] [--json out.json]
"""
import argparse, collections, json, os, random, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import run

HAND = [
    # math functions: spaces around +/- and unit-less zero
    "a{width:calc(10px + 20px)}", "a{width:calc(100% - 0px)}", "a{width:calc( 100% - 10px )}",
    "a{width:min(0px + 10px, 5%)}", "a{width:round(0px + 10px, 1px)}", "a{width:round(up, 0px - 1px, 1px)}",
    "a{width:abs(0px - 5px)}", "a{width:mod(0px + 7px, 5px)}", "a{width:rem(0px + 7px, 5px)}",
    "a{width:hypot(0px, 3px)}", "a{width:sign(0px - 1px)}", "a{transform:rotate(atan2(0px, 1px))}",
    "a{width:calc(var(--a, 0px) + 1px)}", "a{width:clamp(0px, 1vw + 0px, 10px)}", "a{width:calc(1px - -0px)}",
    "a{height:calc-size(auto, size + 0px)}", "a{margin:max(0px - 1px, 0px)}",
    "a{width:-webkit-calc(100% - 0px)}", "a{width:-moz-calc(0px + 10px)}", "a{width:CALC(0px + 10px)}",
    # zero units in non-length grammar positions
    "a{flex:0 0 0px}", "a{flex:1 1 0px}", "a{flex-basis:0px}", "a{--gap:0px}", "a{transition:opacity 0s}",
    "a{transform:rotate(0deg)}", "@keyframes k{0%{opacity:0}100%{opacity:1}}", "a{line-height:0px}",
    "a{grid-template-columns:repeat(2, 0px)}",
    # number shortening / sign gluing
    "a{opacity:0.5}", "a{margin:10px -0.5px}", "a{z-index:1+2}", "a{grid-row:1/ +2}", "a{x:1 +.5}",
    "a{x:a+1px}", "a{x:1px+0.5px}", "a{x:+0.5}", "a{x:1e+2}", "a{x:1e-2px}", "a{x:00.5}", "a{x:-0.0}",
    "a{line-height:+1.5}", "a{margin:1px+2px}",
    # comments
    "a{margin:1px/**/2px}", "a{font:12px/**/Arial}", "a{border:1px/*w*/solid/*s*/red}", "a/**/b{x:y}",
    "a{color:red/*c*/}", "a{color:red /* c */;}", "a{x:y/**/!important}", "a{x:1/**/%}",
    "a{content:\"/* not comment */\"}", "a{background:url(http://a/*b*/)}", "a{background:url( \"x/*y*/\" )}",
    # escapes in units / idents / hashes
    "a{width:1\\70 x}", "a{width:1p\\78}", "a{width:0\\70 x}", "a{color:#\\66 \\66 \\66}", "a{x:\\31 23}",
    "a{font-family:\\66 oo}", "a{width:1\\.5px}",
    # hashes / colors
    "a{color:#FFFFFF}", "a{color:#aabbccdd}", "a{color:#ffffffff}", "a{color:#FFFF}", "a{grid-area:#abcdef}",
    "a{color:#ABCDEF}",
    # selectors
    ":is(div :hover){x:y}", ":not(a :focus){x:y}", ":where(.a :first-child){x:y}", ":has(a :hover){x:y}",
    "a :hover{x:y}", "a > b{x:y}", "a + b{x:y}", "a ~ b{x:y}", "[class ~= x]{x:y}", "[a = \"b\" i]{x:y}",
    "a:nth-child(2n + 1){x:y}", "a:nth-child(2n - 1){x:y}", "a:nth-child( -n + 3 ){x:y}",
    ":is(.a , .b){x:y}", "a , b{x:y}", "*  .a{x:y}", "u+a{x:y}", "a .u+b{x:y}", "svg|a{x:y}",
    "a::before{content:'x'}", "html|* :not(:link){x:y}", ".a\\:b{x:y}",
    # at-rule preludes
    "@media screen and (min-width : 0px){a{x:y}}", "@media (width >= 768px) and (width <= 1024px){a{x:y}}",
    "@media not (color){a{x:y}}", "@media screen and (min-width: 1px), print{a{x:y}}",
    "@supports (display : grid) and (not (display : inline-grid)){a{x:y}}", "@supports selector(a :hover){a{x:y}}",
    "@import url(a.css) screen and (orientation : landscape);", "@layer a , b;", "@container card (min-width : 400px){a{x:y}}",
    "@font-face{font-family:x;src:url(a.woff2) format('woff2')}", "@page :first{margin:0px}",
    # declarations / ordering / nesting
    ".a{ @media screen { color: red } color: blue }", ".a{ &.b { color: red } color: blue }",
    ".a{ :is(&) { color: red } color: blue }", ".a{color:red; .b{color:blue} color:green}",
    ".a{--x:{a;b}; color:red}", ".a{--x: {a:b} ; y:z}", ".a{--x:  12px ;}", ".a{--x:a  b !important}",
    ".a{color:RED}", ".a{COLOR:red}", "a{x:y!IMPORTANT}", "a{x:y ! important}", "a{x:url(a b)}",
    "a{color:red;;}", "a{}", "a{;}", "a,b{x:y}a,b{x:z}", "@media screen{}",
    # strings
    "a{content:'a\\'b'}", "a{content:\"a\\\nb\"}", "a{content:'\\201C'}", "a{font-family:'Helvetica Neue'}",
    "a{quotes:'\"' '\"'}",
]

PROPS = [
    ("margin", ["0px", "0", "10px -5px", "1px 2px 3px 4px", "auto", "0.5em", "-0.5rem", "calc(1px + 0px)"]),
    ("width", ["calc(100% - 0px)", "calc(10px + 20px)", "min(0px, 10px)", "max(0px + 1px, 5%)", "clamp(0px, 10vw, 5px)",
               "round(0px + 10px, 1px)", "abs(0px - 5px)", "100%", "0px", "var(--w, 0px)"]),
    ("color", ["#FFFFFF", "#aabbcc", "#AABBCCDD", "red", "rgb(255 0 0 / 50%)", "rgba(0, 0, 0, 0.5)", "hsl(120 100% 50%)"]),
    ("font", ["12px/1.5 Arial", "italic bold 12px/30px Georgia, serif", "0.875rem/1.25 'Inter', sans-serif"]),
    ("flex", ["0 0 0px", "1 1 0%", "1", "none", "0 1 auto"]),
    ("transition", ["opacity 0s", "all 0.3s ease-in-out", "transform 0.2s cubic-bezier(0.4, 0, 0.2, 1)"]),
    ("transform", ["translate(0px, -0.5px)", "rotate(0deg)", "scale(1.5) translateX(0px)", "matrix(1, 0, 0, 1, 0, 0)"]),
    ("grid-template-columns", ["repeat(2, 0px)", "repeat(auto-fill, minmax(0px, 1fr))", "1fr 0px 2fr"]),
    ("box-shadow", ["0px 0px 0px 0px rgba(0, 0, 0, 0.5)", "inset 0 1px 0 #fff", "0 0 0 1px red, 0 2px 4px #000"]),
    ("background", ["url(a.png) no-repeat 0px 0px", "linear-gradient(to right, #fff 0%, #000 100%)", "url('a b.png')"]),
    ("--custom", ["0px", "  12px ", "{a:b}", "calc(1px+2px)", "  "]),
    ("content", ['"/* x */"', "'\\201C'", "counter(a) '. '", '""']),
]
SELECTORS = [".a", "#b", "a > b", "a + .c", ".a :hover", ":is(.a :hover)", ":not(.a, #b)", "a:nth-child(2n + 1)",
             "[data-x = \"y\" i]", "u+a", ".a, .b", "svg|a", "a::before"]


def gen(rng):
    rules = []
    for _ in range(rng.randint(1, 4)):
        decls = []
        for _ in range(rng.randint(1, 5)):
            p, vals = rng.choice(PROPS)
            v = rng.choice(vals)
            imp = " !important" if rng.random() < 0.1 else ""
            decls.append(f"{p}: {v}{imp}")
        body = "; ".join(decls)
        sel = rng.choice(SELECTORS)
        r = f"{sel} {{ {body} }}"
        if rng.random() < 0.2:
            r = f"@media (min-width: {rng.choice(['0px', '768px', '48em'])}) {{ {r} }}"
        rules.append(r)
    return "\n".join(rules)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fuzz", type=int, default=2000)
    ap.add_argument("--show", type=int, default=60)
    ap.add_argument("--json")
    a = ap.parse_args()
    rng = random.Random(4242)
    cases = list(dict.fromkeys(HAND + [gen(rng) for _ in range(a.fuzz)]))
    PM = run("pion", "min", cases)
    PC = run("pion", "css", cases)
    L0 = run("rust", "lnorm", cases)
    L1 = run("rust", "lnorm", PM)
    L2 = run("rust", "lnorm", PC)
    S0 = run("rust", "lstrict", cases)
    S1 = run("rust", "lstrict", PM)
    PM2 = run("pion", "min", PM)
    st = collections.Counter()
    bad = []
    for i, c in enumerate(cases):
        st["cases"] += 1
        if PM[i].startswith("ERR"):
            st["pion minify ERR"] += 1
            continue
        changed = L0[i] != L1[i]
        st["minify changes lightningcss semantic form"] += changed
        st["to_css changes lightningcss semantic form"] += L0[i] != L2[i]
        invalid = S0[i] == "OK" and S1[i] != "OK"
        st["minify output rejected by strict parser (input accepted)"] += invalid
        st["minify not idempotent (min(min(x)) != min(x))"] += PM2[i] != PM[i]
        if changed or invalid:
            bad.append((i < len(HAND), c, PM[i], L0[i], L1[i], S1[i] if invalid else ""))
    print(f"minify semantic audit: {st['cases']} inputs ({len(HAND)} hand-written + {st['cases'] - len(HAND)} generated)")
    for k, v in st.items():
        if k != "cases":
            print(f"  {k:58s} {v:5d}  ({100.0 * v / st['cases']:.1f}%)")
    hand_bad = [b for b in bad if b[0]]
    print(f"  hand-written semantic breaks: {len(hand_bad)}")
    for _, c, pm, l0, l1, s1 in hand_bad[:a.show]:
        print(f"    in   ={c!r}\n      pion ={pm!r}\n      ln(in)={l0!r}\n      ln(pm)={l1!r}" + (f"\n      strict(pm)={s1!r}" if s1 else ""))
    gen_bad = [b for b in bad if not b[0]]
    # Attribute each generated break to the trigger(s) present; `var(--w, 0px)` -> `var(--w,0)` is the
    # only change lightningcss flags that we judge harmless (lightningcss keeps fallback units verbatim).
    trig = [(":is(.a :hover)", "descendant combinator before ':' dropped inside :is()"),
            ("round(", "0px -> 0 inside round() (non-whitelisted math fn)"),
            ("abs(", "0px -> 0 inside abs() (non-whitelisted math fn)"),
            ("{a:b}", "custom property with {}-block value parsed as nested rule (value + !important lost)")]
    buckets = collections.Counter()
    for _, c, pm, l0, l1, s1 in gen_bad:
        hits = [d for t, d in trig if t in c]
        if not hits:
            hits = ["only var(--w, 0px) fallback unit dropped (judged harmless; lightningcss conservative)"] \
                if "var(--w, 0px)" in c else ["UNCLASSIFIED"]
        for h in hits:
            buckets[h] += 1
    print(f"  generated-corpus semantic breaks: {len(gen_bad)} (a break may have several triggers)")
    for k, v in buckets.most_common():
        print(f"    {v:5d}  {k}")
    for _, c, pm, l0, l1, s1 in [b for b in gen_bad if not any(t in b[1] for t, _ in trig) and "var(--w, 0px)" not in b[1]][:3]:
        print(f"    UNCLASSIFIED in={c!r}\n      pion ={pm!r}\n      ln(in)={l0!r}\n      ln(pm)={l1!r}")
    if a.json:
        json.dump({"stats": st, "bad": bad[:400]}, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
