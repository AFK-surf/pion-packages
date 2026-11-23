"""Structure-level differentials.

  sheet : Pion `parse_stylesheet` AST vs a CSS Syntax 3 + CSS Nesting AST built on Rust cssparser
          =0.35.0 StyleSheetParser/RuleBodyParser (rust/src/main.rs, `sheet`), hand cases + fuzz
  decls : Pion `parse_declarations` vs cssparser declaration-list parsing
  spec  : Pion `selector_list_specificity` vs lightningcss 1.0.0-alpha.72 (parcel_selectors, Servo
          `selectors` fork) — validity and (a,b,c)
  color : Pion `parse_color` vs cssparser-color =0.3.0 (r g b exact, alpha within 1/255)
  mq    : Pion `parse_media_query_list` validity vs lightningcss
Usage: struct_diff.py [--fuzz N] [--show K] [--json out.json]
"""
import argparse, collections, json, os, random, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import run

SHEETS = [
    # nesting
    ".a{& .b{color:red}}", ".a { & > .b { color: red } }", ".a{color:red; .b{color:blue} }",
    ".a{ @media screen { color: red } color: blue }", ".a{ @media (min-width:1px){ color:red; .b{x:y} } }",
    ".a{a:hover{color:red}}", ".a{color:red;a:hover{color:blue}}", ".a{.b{}.c{}}", "a{b{c{d{}}}}",
    ".a{color:red .b{x:y}}", ".a{--x:{a;b}; color:red}", ".a{--x: {a:b} ; y:z}", ".a{--x:[a;b];y:z}",
    ".a{color:{red};x:y}", ".a{color: red {x}; y:z}", ".a{foo:bar{x:y}}", ".a{&:hover;color:red}",
    # top-level recovery
    "a; b{color:red}", "color:red; b{x:y}", "a{} ; b{}", "a{}}b{x:y}", "}a{x:y}", "a{x:y}}}}b{x:y}",
    "@media screen { color: red; b{x:y} }", "@media screen{a; b{x:y}}", "@supports (display:grid){a{x:y}}",
    "@layer a, b;", "@layer a{b{x:y}}", "@container card (min-width: 400px){a{x:y}}",
    "@keyframes k{0%{opacity:0}to{opacity:1}}", "@keyframes k{from{a:b} 50%{c:d}}",
    "@import url(a.css) screen;", "@import 'a.css' layer(x) supports(display:grid) print;",
    "@font-face{font-family:x;src:url(a.woff2)}", "@page :first{margin:1in}",
    "@property --x{syntax:'<length>';inherits:false;initial-value:0px}", "@unknown foo{a:b;c{d:e}}",
    "@unknown foo;a{b:c}", "@media screen", "@media screen{", "a{b:c", "a{b:c;", "a{b:(c;d:e}",
    "a{b:[c;d:e}", "a{b:c) ;d:e}", "a{b:c] ;d:e}", "a{b:c;d:[e)]}", "a{b:url(x;y);c:d}", "a{b:'x;y';c:d}",
    "a{b:\"x\ny\";c:d}", "a{b:url(x y);c:d}", "<!-- a{b:c} -->", ".a{<!-- color:red}", ".a{color:red; -->}",
    # declarations / !important / custom properties
    "a{color:red!important}", "a{color:red ! important}", "a{color:red !IMPORTANT}", "a{color:red!/*c*/important}",
    "a{color:red !important x}", "a{color:!important}", "a{color: ;}", "a{color:}", "a{--x:;}", "a{--x: ;}",
    "a{--x:  12px ;}", "a{--x:a !important}", "a{--X:Y}", "a{COLOR:RED}", "a{color:red /* c */;}",
    "a{color:/* c */red}", "a{color:red/**/;x:y}", "a{1color:red;x:y}", "a{color red;x:y}", "a{:red;x:y}",
    "a{color::red}", "a{-webkit-x:y}", "a{\\63 olor:red}", "a{color:red;;;x:y}", "a{@media x{y:z} c:d}",
    "/* c */ a /* d */ { /* e */ b /* f */ : /* g */ c /* h */ ; }",
]

SHEET_FRAGS = ["a", ".b", "#c", "{", "}", ";", ":", "color", "red", "--x", "!important", "@media", "@supports",
               " screen", "(", ")", "[", "]", "&", " ", "\n", "/*c*/", "'s'", '"t', "url(x)", "url(x y)", "<!--",
               "-->", ",", ">", "+", "@layer", "@import", "@font-face", "0px", "calc(1px + 2px)", "\\", "--"]


def gen_sheet(rng):
    if rng.random() < 0.5:
        s = list(rng.choice(SHEETS))
        for _ in range(rng.randint(1, 3)):
            pos = rng.randint(0, len(s))
            s[pos:pos] = list(rng.choice(SHEET_FRAGS))
        return "".join(s)
    return "".join(rng.choice(SHEET_FRAGS) for _ in range(rng.randint(2, 18)))


DECLS = ["color:red", "color:red;", "a:b;c:d", "a:b!important", "a:b {x:y} c:d", "a:b}c:d", "{x}a:b",
         "a:b;{c:d};e:f", "--x:{a;b};c:d", "a:url(x;y);b:c", "a;b:c", "@x y;a:b", "@x{y};a:b", "a:b;;c:d"]

SELS = [
    "*", "a", ".a", "#a", "a.b#c", "a b", "a > b", "a + b", "a ~ b", "a || b", "[a]", "[a=b]", "[a='b' i]",
    "[a=\"]\"]", "[ns|a]", "[*|a]", "svg|a", "*|a", "|a", "ns|*", ":hover", "::before", ":before", ":after",
    ":first-line", ":first-letter", "::first-line", ":is(.a, #b)", ":where(#id)", ":not(.a, #b)", ":has(> #x)",
    ":nth-child(2n+1)", ":nth-child(2n+1 of #id.foo)", ":nth-last-child(odd of .a, #b)", ":nth-of-type(2)",
    ":host", ":host(.a)", ":host-context(#a)", "::slotted(.a)", "::part(x)", "::highlight(x)", ":lang(en)",
    ":dir(rtl)", ":is()", ":where()", ":not()", ":is(::before)", "a::before.b", "a:hover::before",
    "u+a", ".u+a", "u + a", "U+A", "u+b > i", "a..b", "a#", "##a", "a,", ",a", "a,,b", ">>a", "a >", "{", "$",
    "a)", "(a)", "[a", "a]", ":::a", ": hover", "a:", "::", ".1a", "#1a", ".\\31 a", "#\\31 a", "a\\:b",
    ":NOT(.a)", ":IS(#a)", "::BEFORE", ":-webkit-any(.a,#b)", ":matches(.a)", "&", "& .a", ".a &",
    ".a" * 2000, ":is(" * 50 + "a" + ")" * 50, "a b c d e f g h i j", ":nth-child(-n+3)",
    ":nth-child(2n of)", "*:not(*)", "a:not(:not(#b))", "html|*:not(:link):not(:visited)",
]

COLORS = [
    "red", "RED", "Red", "currentColor", "CURRENTCOLOR", "transparent", "rebeccapurple", "grey", "notacolor",
    "#fff", "#FFFF", "#ff0000", "#ff000080", "#ff00", "#f", "#ff", "#fffff", "#fffffff", "#ggg", "#123456789",
    "rgb(255 0 0)", "rgb(255, 0, 0)", "rgba(255,0,0,0.5)", "rgb(255 0 0 / 50%)", "rgb(100% 50% 0% / 0.5)",
    "rgb(255, 0, 0, 50%)", "rgb(255, 0%, 0)", "rgb(255 0% 0)", "rgb(255 0 0 / )", "rgb(255,0,0 / 0.5)",
    "rgb(300 -5 0)", "rgb(255.5 0 0)", "rgb(127.5 0 0)", "rgb(1e2 0 0)", "rgb(none 0 0)", "rgb(255 0 0 / none)",
    "rgb(1 2 3", "rgb(1 2)", "rgb(1 2 3 4)", "rgb(calc(255) 0 0)", "rgb(var(--x))", "rgb()", "rgb(,,)",
    "rgba(255 0 0)", "RGB(1 2 3)", "rgb( 1 2 3 )", "rgb(1 2 3)x", "rgb(1,2,3,)", "rgb(1 2 3 / 2)",
    "hsl(120 100% 50%)", "hsl(120, 100%, 50%)", "hsl(120deg 100% 25%)", "hsl(1turn 100% 50%)",
    "hsl(0.5rad 100% 50%)", "hsl(200grad 100% 50%)", "hsl(-120 100% 50%)", "hsl(480 100% 50%)",
    "hsl(0, 100, 50)", "hsl(0 100 50)", "hsl(0 100% 50% / 0.25)", "hsla(0, 100%, 50%, .5)", "hsl(none 100% 50%)",
    "hsl(120 100% 50% / 50%)", "hsl(0.5turn, 50%, 50%)", "hsl(1e1 100% 50%)", "hsl(30 60% 40%)",
    "hwb(120 0% 0%)", "lab(50% 40 59.5)", "lch(52.2% 72.2 50)", "oklab(0.4 0.1 0.1)", "oklch(0.6 0.1 200)",
    "color(srgb 1 0 0)", "color-mix(in srgb, red, blue)", "light-dark(red, blue)", "rgb(255 0 0 / -1)",
    "rgb(255 0 0 / 1.5)", "rgb(0 0 0 / 0.333)", "#0000", "rgba(0,0,0,0)",
]

MQS = [
    "screen", "all", "print and (color)", "only screen and (min-width: 768px)", "not screen and (color)",
    "(width >= 768px)", "(400px <= width <= 1200px)", "(width > 100px > 50px)", "(100px < width > 50px)",
    "not (color)", "(color) and (hover)", "(color) or (hover)", "(color) and (hover) or (x)", "not (a) and (b)",
    "not (a) or (b)", "screen and (a) or (b)", "screen and not (a)", "(not (color))", "((color))",
    "(min-width: 0)", "(min-width:)", "(: 1px)", "(width = )", "(1px)", "(width: 1px 2px)", "and", "or", "not",
    "only", "not only screen", "screen, print", "screen, (bogus", "screen,", ",screen", "", "screen print",
    "(color) (hover)", "@x", "screen and", "screen and (", "(width >= 768px) and (orientation: landscape)",
    "(-webkit-min-device-pixel-ratio: 2)", "(min-resolution: 2dppx)", "(aspect-ratio: 16/9)", "(prefers-color-scheme: dark)",
    "not (not (color))", "(color) and ((hover) or (pointer: fine))", "(400px >= width >= 100px)", "(400px <= width >= 100px)",
]


def compare(mode, cases, eq, show, label):
    P = run("pion", mode, cases)
    R = run("rust", mode, cases)
    same = 0
    diffs = []
    for c, p, r in zip(cases, P, R):
        if eq(p, r):
            same += 1
        else:
            diffs.append((c, p, r))
    print(f"[{label}] {len(cases)} cases: agree {same} ({100.0 * same / len(cases):.1f}%), differ {len(diffs)}")
    for c, p, r in diffs[:show]:
        cc = c if len(c) < 90 else c[:87] + "..."
        print(f"    src={cc!r}\n        pion={p[:160]!r}\n        orac={r[:160]!r}")
    return {"cases": len(cases), "agree": same, "diffs": [(c[:200], p[:300], r[:300]) for c, p, r in diffs]}


def color_eq(p, r):
    if r == "OTHER":
        r = "ERR"  # Color 4 spaces Pion does not support -> counted as a difference only via the gap stat
        return p == "ERR"
    if p == "ERR" or r == "ERR" or p == "currentcolor" or r == "currentcolor":
        return p == r
    a, b = p.split(), r.split()
    return a[:3] == b[:3] and abs(float(a[3]) - float(b[3])) <= 1 / 255


def spec_eq(p, r):
    return p == r


def mq_eq(p, r):
    if p == "ERR" or r == "ERR":
        return p == r
    n, bad = r.split()
    return int(bad) == 0 and p == n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fuzz", type=int, default=3000)
    ap.add_argument("--show", type=int, default=40)
    ap.add_argument("--json")
    a = ap.parse_args()
    rng = random.Random(77)
    out = {}
    sheets = list(dict.fromkeys(SHEETS + [gen_sheet(rng) for _ in range(a.fuzz)]))
    print(f"== stylesheet AST vs cssparser StyleSheetParser/RuleBodyParser (hand {len(SHEETS)} + fuzz)")
    out["sheet_hand"] = compare("sheet", SHEETS, lambda p, r: p == r, a.show, "sheet/hand")
    out["sheet_all"] = compare("sheet", sheets, lambda p, r: p == r, 0, "sheet/hand+fuzz")
    out["decls"] = compare("decls", DECLS, lambda p, r: p == r, a.show, "decls")
    print("== Selectors Level 4 specificity vs lightningcss (parcel_selectors)")
    out["spec"] = compare("spec", SELS, spec_eq, a.show, "spec")
    P = run("pion", "spec", SELS)
    R = run("rust", "spec", SELS)
    acc_invalid = [s for s, p, r in zip(SELS, P, R) if r == "ERR" and p != "ERR"]
    print(f"    invalid selectors (lightningcss rejects) that Pion accepts with a specificity: {len(acc_invalid)}")
    print("    " + ", ".join(repr(x if len(x) < 30 else x[:27] + '...') for x in acc_invalid))
    print("== CSS Color 4 vs cssparser-color 0.3.0")
    out["color"] = compare("color", COLORS, color_eq, a.show, "color")
    R = run("rust", "color", COLORS)
    gap = [c for c, r in zip(COLORS, R) if r == "OTHER"]
    print(f"    Color 4 color spaces parsed by cssparser-color but unsupported by Pion: {gap}")
    print("== Media Queries 4 validity vs lightningcss")
    out["mq"] = compare("mq", MQS, mq_eq, a.show, "mq")
    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
