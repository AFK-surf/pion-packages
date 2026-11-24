#!/usr/bin/env python3
"""Deterministic red-team corpus for packages/css_color.
  python3 -I gen.py <out dir> [fuzz count]
Writes <group>.cases (`<target space>\t<input>` lines; inputs with bytes outside printable ASCII are `hex:` encoded),
mix.rust (the color-mix group as `<space>|<hue>|<c1>|<p1>|<c2>|<p2>` for the Rust oracle, same line order) and
gamut.cases (`<destination>\t<input>`). Prints `<group> <count>` lines."""
import os
import random
import sys

SPACES = ["srgb", "srgb-linear", "display-p3", "a98-rgb", "prophoto-rgb", "rec2020", "xyz-d50", "xyz-d65",
          "hsl", "hwb", "lab", "lch", "oklab", "oklch"]
PREDEF = ["srgb", "srgb-linear", "display-p3", "a98-rgb", "prophoto-rgb", "rec2020", "xyz", "xyz-d50", "xyz-d65"]
HUES = ["shorter", "longer", "increasing", "decreasing"]
NAMED = """aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown burlywood
cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod darkgray
darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen
darkslateblue darkslategray darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue
firebrick floralwhite forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray green greenyellow grey honeydew
hotpink indianred indigo ivory khaki lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan
lightgoldenrodyellow lightgray lightgreen lightgrey lightpink lightsalmon lightseagreen lightskyblue lightslategray
lightslategrey lightsteelblue lightyellow lime limegreen linen magenta maroon mediumaquamarine mediumblue mediumorchid
mediumpurple mediumseagreen mediumslateblue mediumspringgreen mediumturquoise mediumvioletred midnightblue mintcream
mistyrose moccasin navajowhite navy oldlace olive olivedrab orange orangered orchid palegoldenrod palegreen
paleturquoise palevioletred papayawhip peachpuff peru pink plum powderblue purple rebeccapurple red rosybrown royalblue
saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray slategrey snow springgreen
steelblue tan teal thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen""".split()
assert len(NAMED) == 148, len(NAMED)


def enc(s):
    b = s.encode("utf-8", "surrogateescape")
    if all(0x20 <= x < 0x7F for x in b) and not s.startswith("hex:"):
        return s
    return "hex:" + b.hex()


def num(rng, lo, hi, nd=4):
    return ("%." + str(nd) + "f") % rng.uniform(lo, hi)


def gen_named(rng):
    out = []
    for n in NAMED + ["transparent"]:
        out += [n, n.upper(), "".join(c.upper() if i % 2 else c for i, c in enumerate(n)), " %s\t" % n, "\n\r\f%s " % n]
    for ws in [" ", "\v", "　", "﻿", " ", "\u0085", "\x00"]:
        out += [ws + "red", "red" + ws, "re" + ws + "d"]
    out += ["currentcolor", "currentColor", "canvas", "CanvasText", "ButtonFace", "red red", "redd", "rde", "", " ",
            "\t\n", "re-d", "red;", "red)", "(red)", "#red", "-red", "r\\65 d", "\\72 ed", "red/**/", "/**/red",
            "transparent ", "TRANSPARENT", "transparant", "inherit", "initial", "none", "unset", "rgb", "rgba()"]
    return out


def gen_hex(rng):
    out = []
    for n in range(0, 10):
        for _ in range(6):
            out.append("#" + "".join(rng.choice("0123456789abcdefABCDEF") for _ in range(n)))
    out += ["#fffg", "#ffffffg", "#ff ff ff", "# fff", "#éff", "#ff00zz", "#0x123", "#-12", "##fff", "#fff ",
            " #FFF", "#FfFfFf", "#12345", "#1234567", "#123456789", "#ffffffff0", "fff", "#ff\x00f", "#fff#fff"]
    return out


def gen_syntax(rng):
    out = []
    # rgb()/rgba() legacy vs modern, numbers vs percentages, separators, arity, garbage
    for fn in ["rgb", "rgba", "RGB", "Rgba"]:
        out += ["%s(255, 0, 0)" % fn, "%s(255,0,0)" % fn, "%s( 255 , 0 , 0 )" % fn, "%s(255 0 0)" % fn,
                "%s(255, 0 0)" % fn, "%s(255 0, 0)" % fn, "%s(255, 0, 0 / 0.5)" % fn, "%s(255 0 0, 0.5)" % fn,
                "%s(255 0 0 / 0.5)" % fn, "%s(255, 0, 0, 0.5)" % fn, "%s(255, 0, 0, 50%%)" % fn,
                "%s(255, 50%%, 0)" % fn, "%s(255 50%% 0)" % fn, "%s(100%%, 50%%, 0%%)" % fn,
                "%s(100%% 50%% 0%% / 50%%)" % fn, "%s(255, 0)" % fn, "%s(255 0)" % fn, "%s(255, 0, 0, 0.5, 1)" % fn,
                "%s(255 0 0 0)" % fn, "%s(255 0 0 / 0.5 / 1)" % fn, "%s(255px 0 0)" % fn, "%s(255 0 0deg)" % fn,
                "%s(255 0 0) x" % fn, "%s(255 0 0" % fn, "%s 255 0 0)" % fn, "%s (255 0 0)" % fn,
                "%s(none 0 0)" % fn, "%s(none, 0, 0)" % fn, "%s(255, none, 0)" % fn, "%s(255 0 0 / none)" % fn,
                "%s(255, 0, 0, none)" % fn, "%s(-10 300 1e2)" % fn, "%s(1e1 2E1 +3)" % fn, "%s(.5 +.5 -.5)" % fn,
                "%s(5. 0 0)" % fn, "%s(10-20 30)" % fn, "%s(1.2.3 4)" % fn, "%s(255,,0,0)" % fn, "%s(,255,0,0)" % fn,
                "%s(255, 0, 0,)" % fn, "%s(255 / 0 0)" % fn, "%s(/ 0.5)" % fn, "%s()" % fn, "%s(255 0 0 /)" % fn,
                "%s(255 0 0 / 150%%)" % fn, "%s(255 0 0 / -1)" % fn, "%s(2.5, 3.4, 4.6)" % fn,
                "%s(255, 0, 0, 1e-400)" % fn, "%s(1e308 0 0)" % fn, "%s(1e309 0 0)" % fn, "%s(9e9999 0 0)" % fn,
                "%s(calc(255) 0 0)" % fn, "%s(calc(50%%), 0, 0)" % fn, "%s(calc(1+2) 0 0)" % fn,
                "%s(calc(1 + 2) 0 0)" % fn, "%s(calc(1 -2) 0 0)" % fn, "%s(calc(- 5) 0 0)" % fn,
                "%s(255 0 0)" % fn, "%s(255\v0 0)" % fn]
    for fn in ["hsl", "hsla"]:
        out += ["%s(120, 100%%, 50%%)" % fn, "%s(120deg, 100%%, 50%%, 0.5)" % fn, "%s(120 100%% 50%%)" % fn,
                "%s(120 100 50)" % fn, "%s(120, 100, 50)" % fn, "%s(120, 100%%, 50)" % fn, "%s(120 100%% 50)" % fn,
                "%s(120, 100%% 50%%)" % fn, "%s(120 100%% 50%%, 0.5)" % fn, "%s(none 100%% 50%%)" % fn,
                "%s(none, 100%%, 50%%)" % fn, "%s(120 none 50%%)" % fn, "%s(120 100%% none / none)" % fn,
                "%s(50%% 100%% 50%%)" % fn, "%s(120px 100%% 50%%)" % fn, "%s(120 -10%% 50%%)" % fn,
                "%s(120 110%% 120%%)" % fn, "%s(120, calc(50%%), 50%%)" % fn, "%s(calc(50%%) 100%% 50%%)" % fn,
                "%s(calc(120deg + 0.5turn) 100%% 50%%)" % fn, "%s(120 100%% 50%% / 0.5 0.5)" % fn]
    out += ["hwb(120 10% 20%)", "hwb(120, 10%, 20%)", "hwb(120 10 20)", "hwb(120deg 60% 60%)", "hwb(none 10% 20%)",
            "hwb(120 none none)", "hwb(120 -10% 20%)", "hwb(120 10% 20% / 50%)", "hwb(1turn 0% 0%)",
            "hwb(120 10% 20% 30%)", "hwba(120 10% 20%)"]
    for fn, lmax, cmax in [("lab", 100, 125), ("lch", 100, 150), ("oklab", 1, 0.4), ("oklch", 1, 0.4)]:
        out += ["%s(50%% 20%% -20%%)" % fn, "%s(50 20 30)" % fn, "%s(0.5 0.1 0.1)" % fn, "%s(-10 20 30)" % fn,
                "%s(150 20 30)" % fn, "%s(110%% 0 0)" % fn, "%s(none none none / none)" % fn, "%s(50, 20, 30)" % fn,
                "%s(50 20 30 / 0.5)" % fn, "%s(50 20)" % fn, "%s(50 20 30 40)" % fn, "%s(50 20deg 30)" % fn,
                "%s(50 20 30deg)" % fn, "%s(50 20 1.5turn)" % fn, "%s(50 -20 -400deg)" % fn,
                "%s(50 20 1e6)" % fn, "%s(50%% none 30)" % fn, "%s(50 20 30%%)" % fn]
    for sp in PREDEF + ["SRGB", "Display-P3", "xyz-d60", "srgb-lin", "rec2100", "--custom", "p3"]:
        out += ["color(%s 0.5 0.25 0.125)" % sp, "color(%s 50%% 25%% 12.5%%)" % sp, "color(%s 1 0 0 / 0.5)" % sp,
                "color(%s none 0.5 none / none)" % sp, "color(%s 1.5 -0.5 2)" % sp, "color(%s 0.5 0.5)" % sp,
                "color(%s 0.5 0.5 0.5 0.5)" % sp, "color(%s 0.5, 0.5, 0.5)" % sp, "color(%s 0.5deg 0 0)" % sp,
                "color( %s 0 0 0 )" % sp, "color(%s)" % sp, "color(%s 1e13 0 0)" % sp, "color(%s 9e12 0 0)" % sp,
                "color(%s 1e300 1e-300 -1e300)" % sp]
    out += ["color(0.5 0.5 0.5)", "color()", "color(srgb, 0.5, 0.5, 0.5)", "color(srgb 0.5 0.5 0.5 /)"]
    # angles: every unit, negative, huge, fractional
    for u in ["", "deg", "rad", "grad", "turn", "DEG", "Turn", "px", "%", "e1", "e", "degs"]:
        for v in ["0", "-30", "30.5", "400", "-720.25", "1e3", "1e8", "0.25", "3.14159", "-0.5", "1e300"]:
            for fn in ["hsl(%s 50%% 50%%)", "hwb(%s 20%% 30%%)", "lch(50 40 %s)", "oklch(0.6 0.1 %s)"]:
                out.append(fn % (v + u))
    return out


def gen_none(rng):
    out = []
    cols = ["hsl(none 50% 50%)", "hsl(120 none 50%)", "hsl(120 50% none)", "hwb(none 20% 30%)", "hwb(120 none 30%)",
            "lab(none 20 30)", "lab(50 none 30)", "lch(50 40 none)", "lch(50 none 120)", "lch(none 40 120)",
            "oklab(none 0.1 0.1)", "oklch(0.6 0.1 none)", "oklch(0.6 none 30)", "oklch(none 0.1 30)",
            "rgb(none 128 0)", "rgb(255 none 0)", "rgb(255 128 none)", "color(srgb none 0.5 0)",
            "color(xyz-d65 none 0.5 0.2)", "color(xyz-d50 0.3 none 0.2)", "color(display-p3 0.2 0.3 none)",
            "rgb(255 0 0 / none)", "oklch(0.6 0.1 30 / none)", "white", "black", "gray", "#808080",
            "rgb(128 128 128 / 0)", "hsl(120 0% 50%)", "hsl(120 50% 0%)", "hsl(120 50% 100%)", "hwb(120 60% 40%)",
            "hwb(120 70% 50%)", "lch(50 0 120)", "oklch(0.5 0 200)", "oklch(0 0.1 30)", "oklch(1 0.1 30)",
            "lab(0 0 0)", "lab(100 0 0)", "lch(50 0.001 120)", "lch(50 0.002 120)", "oklch(0.5 0.000003 30)",
            "oklch(0.5 0.000005 30)", "color(srgb 0.5 0.5 0.500001)", "color(srgb 0.5 0.5 0.50001)"]
    for c in cols:
        for t in SPACES:
            out.append((t, c))
    for sp in SPACES:
        for c1 in cols[::3]:
            for c2 in ["blue", "rgb(255 128 0 / 0.5)", "oklch(0.7 0.2 300)"]:
                out.append(("srgb", "color-mix(in %s, %s, %s)" % (sp, c1, c2)))
                out.append((sp, "color-mix(in %s, %s 30%%, %s)" % (sp, c2, c1)))
    return out


def gen_mix(rng):
    pion, rust = [], []
    cols = ["red", "blue", "#00ff0080", "rgb(240 40 30 / 0.7)", "hsl(30 90% 50%)", "hsl(330 90% 50%)",
            "oklch(0.65 0.18 35 / 0.85)", "oklch(0.72 0.14 250)", "lch(60 50 10)", "lch(60 50 190)",
            "color(display-p3 0.9 0.2 0.1 / 0.75)", "color(rec2020 0.1 0.8 0.3)", "white", "black", "gray",
            "transparent", "rgb(0 0 0 / 0)", "hwb(200 10% 20%)", "lab(50 -40 30)", "color(xyz-d50 0.2 0.3 0.4)",
            "oklch(0.5 0.1 359)", "oklch(0.5 0.1 1)", "oklch(0.5 0.1 90)", "oklch(0.5 0.1 270)"]
    pcts = [None, 0, 10, 25, 50, 75, 100, 12.5, 33.3]
    for sp in SPACES:
        hs = HUES if sp in ("hsl", "hwb", "lch", "oklch") else ["shorter"]
        for hm in hs:
            for _ in range(24 if len(hs) == 1 else 12):
                c1, c2 = rng.choice(cols), rng.choice(cols)
                p1, p2 = rng.choice(pcts), rng.choice(pcts)
                if p1 == 0 and p2 == 0:
                    p2 = 10
                if (p1 is not None and p2 is None and p1 > 100) or (p1 is not None and p2 is not None and p1 + p2 == 0):
                    continue
                meth = sp if hm == "shorter" and rng.random() < 0.5 else "%s %s hue" % (sp, hm)
                if sp not in ("hsl", "hwb", "lch", "oklch"):
                    meth = sp
                a = c1 + ("" if p1 is None else " %s%%" % p1)
                b = ("" if p2 is None else "%s%% " % p2) + c2
                pion.append(("srgb", "color-mix(in %s, %s, %s)" % (meth, a, b)))
                rust.append("%s|%s|%s|%s|%s|%s" % (sp, hm, c1, "" if p1 is None else p1, c2, "" if p2 is None else p2))
    # hue edge cases: crossing 0/360, exactly 180 apart, one or both hues none, alpha 0 / none
    pairs = [(10, 350), (350, 10), (0, 180), (180, 0), (90, 270), (270, 90), (0, 0), (359.9, 0.1), (45, 225.0001),
             (720, -90), (-180, 180)]
    for sp in ["hsl", "hwb", "lch", "oklch"]:
        for hm in HUES:
            for h1, h2 in pairs:
                f = {"hsl": "hsl(%s 80%% 50%%)", "hwb": "hwb(%s 10%% 10%%)", "lch": "lch(60 50 %s)",
                     "oklch": "oklch(0.6 0.15 %s)"}[sp]
                c1, c2 = f % h1, f % h2
                pion.append((sp, "color-mix(in %s %s hue, %s, %s)" % (sp, hm, c1, c2)))
                rust.append("%s|%s|%s||%s|" % (sp, hm, c1, c2))
            for c1, c2 in [("oklch(0.6 0.15 none)", "oklch(0.6 0.15 120)"), ("oklch(0.6 0.15 none)", "oklch(0.4 0.1 none)"),
                           ("oklch(0.6 0.15 30 / 0)", "oklch(0.6 0.15 120)"), ("oklch(0.6 0.15 30 / none)", "oklch(0.6 0.15 120 / 0.5)"),
                           ("oklch(0.6 0.15 30 / none)", "oklch(0.6 0.15 120 / none)"), ("white", "blue"), ("gray", "red"),
                           ("transparent", "red"), ("rgb(255 0 0 / 0)", "rgb(0 0 255 / 0)")]:
                pion.append((sp, "color-mix(in %s %s hue, %s, %s)" % (sp, hm, c1, c2)))
                rust.append("%s|%s|%s||%s|" % (sp, hm, c1, c2))
    # percentage normalisation and invalid percentages
    for p in ["red 30%, blue 30%", "red 70%, blue 70%", "red 0%, blue 0%", "red -10%, blue", "red 150%, blue",
              "red, blue 150%", "red 100%, blue 100%", "red 50%, blue 50%", "30% red, 20% blue", "red 0.001%, blue 0%",
              "red 100%, blue 0%", "red, blue", "red 25%, blue", "red, 25% blue", "red 30% 40%, blue", "red, blue,",
              "red", "red, blue, green", "red 50, blue", "red 50px, blue", "red calc(50%), blue", "red none, blue",
              "red 1e2%, blue", "red 1e-400%, blue 0%"]:
        for sp in ["srgb", "oklch"]:
            pion.append(("srgb", "color-mix(in %s, %s)" % (sp, p)))
            rust.append("")
    for s in ["color-mix(in srgb red, blue)", "color-mix(srgb, red, blue)", "color-mix(red, blue)",
              "color-mix(in, red, blue)", "color-mix(in srgb shorter hue, red, blue)", "color-mix(in oklch hue, red, blue)",
              "color-mix(in oklch shorter, red, blue)", "color-mix(in oklch longer hue hue, red, blue)",
              "color-mix(in OKLCH LONGER HUE, red, blue)", "color-mix(in xyz, red, blue)", "color-mix(in foo, red, blue)",
              "color-mix( in srgb , red , blue )", "color-mix(in srgb,red,blue)", "color-mix(in srgb, red, blue",
              "color-mix(in hsl, color(display-p3 0 1 0) 100%, rgb(0, 0, 0) 0%)", "color-mix(in srgb, currentcolor, red)"]:
        pion.append(("srgb", s))
        rust.append("")
    return pion, rust


CH = {"rgb": "r g b", "hsl": "h s l", "hwb": "h w b", "lab": "l a b", "lch": "l c h", "oklab": "l a b", "oklch": "l c h"}


def gen_relative(rng):
    out = []
    origins = ["rebeccapurple", "#3b82f6", "rgb(20% 40% 60% / 80%)", "hsl(120 none 50%)", "lch(50 0 0)",
               "color(display-p3 1 0 0)", "oklch(0.7 0.2 none / none)", "color-mix(in oklch, red, blue)",
               "transparent", "color(xyz 0.2 0.3 0.4)"]
    for fn, ch in CH.items():
        a, b, c = ch.split()
        for o in origins:
            out += ["%s(from %s %s)" % (fn, o, ch), "%s(from %s %s / alpha)" % (fn, o, ch),
                    "%s(from %s %s %s %s)" % (fn, o, c, a, b), "%s(from %s %s)" % (fn, o, ch.upper()),
                    "%s(from %s none %s %s)" % (fn, o, b, c), "%s(from %s %s %s %s / none)" % (fn, o, a, b, c),
                    "%s(from %s calc(%s * 0.5) %s calc(%s + 10))" % (fn, o, a, b, c),
                    "%s(from %s %s %s %s / calc(alpha / 2))" % (fn, o, a, b, c), "%s(from %s alpha alpha alpha)" % (fn, o)]
        out += ["%s(from red %s)" % (fn, "x y z"), "%s(from red %s %s)" % (fn, a, b), "%s(from red %s %s %s %s)" % (fn, a, b, c, a),
                "%s(from red, %s, %s, %s)" % (fn, a, b, c), "%s(from %s %s)" % (fn, "", ch), "%s(from from red %s)" % (fn, ch),
                "%s(fromred %s)" % (fn, ch), "%s(from#f00 %s)" % (fn, ch), "%s(from #fffr %s %s)" % (fn, b, c),
                "%s(from red %s)" % (fn, {"rgb": "l c h", "hsl": "r g b", "hwb": "l a b", "lab": "r g b", "lch": "h s l",
                                          "oklab": "x y z", "oklch": "r g b"}[fn]),
                "%s(from red calc(%s) %s %s)" % (fn, a, b, c), "%s(from red calc(%s + 10%%) %s %s)" % (fn, a, b, c),
                "%s(from red %s %s %s / 50%%)" % (fn, a, b, c), "%s(from red e pi %s)" % (fn, c)]
    for sp in PREDEF:
        k = "x y z" if sp.startswith("xyz") else "r g b"
        out += ["color(from red %s %s)" % (sp, k), "color(from red %s %s / alpha)" % (sp, k),
                "color(from lab(50 20 30) %s calc(%s * 2) %s)" % (sp, k.split()[0], " ".join(k.split()[1:])),
                "color(from red %s %s)" % (sp, "x y z" if k == "r g b" else "r g b")]
    # calc(): precedence, unary, percentages, units, division by zero, parentheses, nesting, constants
    exprs = ["r", "r + 10", "r - 10", "r * 2", "r / 2", "r + g * 2", "(r + g) * 2", "r - -10", "-r + 300", "+r",
             "-(r)", "- r", "r+10", "r -10", "r- 10", "r * -1", "r / 0", "r / (g - g)", "0 / 0", "r * 1e308 * 10",
             "((((((r))))))", "(r", "r)", "()", "", "r r", "r +", "* r", "calc(r)", "calc(calc(r) + 1)", "pi * 10",
             "e * 10", "10%", "r + 10%", "50% * 2", "100% - 20%", "r * 1%", "10deg", "1px", "r * (2 + 3) - 4 / 2",
             "2 * 3 + 4", "2 + 3 * 4", "20 - 4 - 3", "64 / 4 / 2", "1e2", "1e-2 * 100", "-.5e1 * -10", "R", "Calc(r)",
             "min(r, 10)", "abs(-10)", "sign(1)", "infinity", "NaN", "none", "r * none"]
    for e in exprs:
        out.append("rgb(from red calc(%s) g b)" % e)
        out.append("rgb(calc(%s) 0 0)" % e)
    for e in ["h + 30", "h + 30deg", "h + 0.5turn", "h + 1rad", "h + 100grad", "h * 2", "h + 10%", "30deg * 2", "h - 720"]:
        out.append("hsl(from red calc(%s) s l)" % e)
        out.append("oklch(from red l c calc(%s))" % e)
    out += ["oklch(from oklch(from red l c h) calc(l + 0.1) c h)",
            "oklch(from color-mix(in oklch, coral, dodgerblue) calc(l + 0.05) c calc(h + 15))",
            "color-mix(in oklch, rgb(from red r g b), hsl(from blue h s l))",
            "rgb(from color-mix(in srgb, rgb(from red r 0 b), color-mix(in lab, blue, white)) r g b)",
            "color-mix(in srgb, oklch(from color-mix(in oklch, red, blue) l c calc(h + 180)) 30%, white)"]
    return out


def gen_numeric(rng, n):
    out = []
    for i in range(n):
        t = SPACES[i % len(SPACES)]
        k = rng.randrange(14)
        a = "" if rng.random() < 0.6 else " / %s" % num(rng, 0, 1, 3)
        if k < 6:
            sp = PREDEF[[0, 1, 2, 3, 4, 5][k]]
            lo, hi = (-0.2, 1.2) if rng.random() < 0.3 else (0, 1)
            s = "color(%s %s %s %s%s)" % (sp, num(rng, lo, hi), num(rng, lo, hi), num(rng, lo, hi), a)
        elif k == 6:
            s = "color(%s %s %s %s%s)" % (rng.choice(["xyz", "xyz-d50"]), num(rng, 0, 1), num(rng, 0, 1), num(rng, 0, 1.1), a)
        elif k == 7:
            s = "rgb(%s %s %s%s)" % (num(rng, 0, 255, 2), num(rng, 0, 255, 2), num(rng, 0, 255, 2), a)
        elif k == 8:
            s = "hsl(%s %s%% %s%%%s)" % (num(rng, -720, 720, 3), num(rng, 0, 100, 3), num(rng, 0, 100, 3), a)
        elif k == 9:
            s = "hwb(%s %s%% %s%%%s)" % (num(rng, 0, 360, 3), num(rng, 0, 60, 3), num(rng, 0, 60, 3), a)
        elif k == 10:
            s = "lab(%s %s %s%s)" % (num(rng, 0, 100, 3), num(rng, -125, 125, 3), num(rng, -125, 125, 3), a)
        elif k == 11:
            s = "lch(%s %s %s%s)" % (num(rng, 0, 100, 3), num(rng, 0, 150, 3), num(rng, 0, 360, 3), a)
        elif k == 12:
            s = "oklab(%s %s %s%s)" % (num(rng, 0, 1), num(rng, -0.4, 0.4), num(rng, -0.4, 0.4), a)
        else:
            s = "oklch(%s %s %s%s)" % (num(rng, 0, 1), num(rng, 0, 0.4), num(rng, 0, 360, 3), a)
        out.append((t, s))
    return out


def gen_gamut(rng):
    out = []
    dests = ["srgb", "display-p3", "rec2020", "a98-rgb", "prophoto-rgb", "srgb-linear", "hsl", "hwb"]
    fixed = ["oklch(0.7 0.4 150)", "color(rec2020 1 0 0)", "color(display-p3 0 1 0)", "color(display-p3 1 1 0)",
             "oklch(0 0.3 30)", "oklch(1 0.3 30)", "oklch(0.0000001 0.3 30)", "oklch(0.9999999 0.3 30)",
             "oklch(0.5 0 0)", "oklch(0.5 0.4 none)", "lab(100 104.3 -50.9)", "lab(0 104.3 -50.9)", "color(srgb 1.01 0.5 0.5)",
             "color(srgb 1.2 0.5 0.5)", "color(srgb -0.01 0.5 0.5)", "color(xyz 0.9 0.1 0.1)", "oklch(0.5 1 30)",
             "oklch(0.5 10 30)", "oklch(0.5 1000 30)", "lab(50 1000 0)", "oklch(0.6 0.2 30 / 0.5)", "red", "white", "black",
             "color(srgb 1 1 1.0000001)", "color(srgb 0.5 0.5 0.5)", "oklab(0.5 0.4 0.4)", "color(prophoto-rgb 0 1 0)"]
    for d in dests:
        for s in fixed:
            out.append((d, s))
    for i in range(1200):
        l = rng.choice([rng.uniform(0.02, 0.98), rng.uniform(0.9, 1.0), rng.uniform(0, 0.1)])
        c = rng.uniform(0.0, 0.45)
        h = rng.uniform(0, 360)
        out.append((dests[i % len(dests)], "oklch(%.5f %.5f %.3f)" % (l, c, h)))
    return out


SEEDS = None


def mutate(rng, s):
    ops = rng.randrange(1, 5)
    b = list(s)
    for _ in range(ops):
        k = rng.randrange(9)
        p = rng.randrange(len(b) + 1)
        if k == 0 and b:
            del b[min(p, len(b) - 1)]
        elif k == 1:
            b.insert(p, rng.choice(" ,/()%+-.e0123456789abcdefghlnorsx#\t"))
        elif k == 2 and b:
            b[min(p, len(b) - 1)] = rng.choice("(),/ %0-9.+-eE")
        elif k == 3:
            b.insert(p, rng.choice(["\x00", " ", "\udcff", "\udc80", "　", "\v", "�", "é", "\U0001f600"]))
        elif k == 4:
            q = rng.randrange(len(b) + 1)
            b = b[:min(p, q)] + b[max(p, q):] + b[min(p, q):max(p, q)]
        elif k == 5:
            b.insert(p, rng.choice(["calc(", "none", "from ", "color-mix(in oklch, ", "1e308", "1e-400", "999999999999999",
                                    "deg", "turn", "%", " / ", ", ", "))", "(("]))
        elif k == 6 and b:
            b = b[:p]
        elif k == 7:
            b.insert(p, rng.choice(SEEDS))
        else:
            b = b[:p] + b[p:][::-1]
    return "".join(b)


def gen_fuzz(rng, n, seeds):
    global SEEDS
    SEEDS = seeds
    out = []
    while len(out) < n:
        s = rng.choice(seeds)
        out.append(mutate(rng, s) if rng.random() < 0.9 else s)
    return out


def main():
    d = sys.argv[1]
    nfuzz = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
    os.makedirs(d, exist_ok=True)
    rng = random.Random(0xC55C0102)
    groups = {}
    groups["named"] = [("srgb", s) for s in gen_named(rng)]
    groups["hex"] = [("srgb", s) for s in gen_hex(rng)]
    groups["syntax"] = [("srgb", s) for s in gen_syntax(rng)]
    groups["none"] = gen_none(rng)
    mix, rust = gen_mix(rng)
    groups["mix"] = mix
    groups["relative"] = [("srgb", s) for s in gen_relative(rng)]
    groups["numeric"] = gen_numeric(rng, 6000)
    seeds = [s for g in ("syntax", "mix", "relative", "none") for _, s in groups[g]]
    groups["fuzz"] = [(SPACES[i % 14], s) for i, s in enumerate(gen_fuzz(rng, nfuzz, seeds))]
    for g, lines in groups.items():
        with open(os.path.join(d, g + ".cases"), "w", encoding="utf-8") as f:
            for t, s in lines:
                f.write("%s\t%s\n" % (t, enc(s)))
        print(g, len(lines))
    with open(os.path.join(d, "mix.rust"), "w", encoding="utf-8") as f:
        f.write("\n".join(rust) + "\n")
    gam = gen_gamut(rng)
    with open(os.path.join(d, "gamut.cases"), "w", encoding="utf-8") as f:
        for t, s in gam:
            f.write("%s\t%s\n" % (t, enc(s)))
    print("gamut", len(gam))


if __name__ == "__main__":
    main()
