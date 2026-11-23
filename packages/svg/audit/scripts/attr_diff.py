"""Transform / viewBox / preserveAspectRatio / color / length differential:
Pion vs Rust svgtypes 0.15.3 + libm, plus CSS Color 4 / SVG 2 spec expectations computed in Python."""
import colorsys, math, os, random, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import run, f64, bits, ulps, Ledger, SEP

NAMED = {  # CSS Color 4 §6.1 named colors (148 incl. rebeccapurple), independent copy for the audit
 "aliceblue":"f0f8ff","antiquewhite":"faebd7","aqua":"00ffff","aquamarine":"7fffd4","azure":"f0ffff","beige":"f5f5dc",
 "bisque":"ffe4c4","black":"000000","blanchedalmond":"ffebcd","blue":"0000ff","blueviolet":"8a2be2","brown":"a52a2a",
 "burlywood":"deb887","cadetblue":"5f9ea0","chartreuse":"7fff00","chocolate":"d2691e","coral":"ff7f50",
 "cornflowerblue":"6495ed","cornsilk":"fff8dc","crimson":"dc143c","cyan":"00ffff","darkblue":"00008b","darkcyan":"008b8b",
 "darkgoldenrod":"b8860b","darkgray":"a9a9a9","darkgreen":"006400","darkgrey":"a9a9a9","darkkhaki":"bdb76b",
 "darkmagenta":"8b008b","darkolivegreen":"556b2f","darkorange":"ff8c00","darkorchid":"9932cc","darkred":"8b0000",
 "darksalmon":"e9967a","darkseagreen":"8fbc8f","darkslateblue":"483d8b","darkslategray":"2f4f4f","darkslategrey":"2f4f4f",
 "darkturquoise":"00ced1","darkviolet":"9400d3","deeppink":"ff1493","deepskyblue":"00bfff","dimgray":"696969",
 "dimgrey":"696969","dodgerblue":"1e90ff","firebrick":"b22222","floralwhite":"fffaf0","forestgreen":"228b22",
 "fuchsia":"ff00ff","gainsboro":"dcdcdc","ghostwhite":"f8f8ff","gold":"ffd700","goldenrod":"daa520","gray":"808080",
 "green":"008000","greenyellow":"adff2f","grey":"808080","honeydew":"f0fff0","hotpink":"ff69b4","indianred":"cd5c5c",
 "indigo":"4b0082","ivory":"fffff0","khaki":"f0e68c","lavender":"e6e6fa","lavenderblush":"fff0f5","lawngreen":"7cfc00",
 "lemonchiffon":"fffacd","lightblue":"add8e6","lightcoral":"f08080","lightcyan":"e0ffff","lightgoldenrodyellow":"fafad2",
 "lightgray":"d3d3d3","lightgreen":"90ee90","lightgrey":"d3d3d3","lightpink":"ffb6c1","lightsalmon":"ffa07a",
 "lightseagreen":"20b2aa","lightskyblue":"87cefa","lightslategray":"778899","lightslategrey":"778899",
 "lightsteelblue":"b0c4de","lightyellow":"ffffe0","lime":"00ff00","limegreen":"32cd32","linen":"faf0e6",
 "magenta":"ff00ff","maroon":"800000","mediumaquamarine":"66cdaa","mediumblue":"0000cd","mediumorchid":"ba55d3",
 "mediumpurple":"9370db","mediumseagreen":"3cb371","mediumslateblue":"7b68ee","mediumspringgreen":"00fa9a",
 "mediumturquoise":"48d1cc","mediumvioletred":"c71585","midnightblue":"191970","mintcream":"f5fffa","mistyrose":"ffe4e1",
 "moccasin":"ffe4b5","navajowhite":"ffdead","navy":"000080","oldlace":"fdf5e6","olive":"808000","olivedrab":"6b8e23",
 "orange":"ffa500","orangered":"ff4500","orchid":"da70d6","palegoldenrod":"eee8aa","palegreen":"98fb98",
 "paleturquoise":"afeeee","palevioletred":"db7093","papayawhip":"ffefd5","peachpuff":"ffdab9","peru":"cd853f",
 "pink":"ffc0cb","plum":"dda0dd","powderblue":"b0e0e6","purple":"800080","rebeccapurple":"663399","red":"ff0000",
 "rosybrown":"bc8f8f","royalblue":"4169e1","saddlebrown":"8b4513","salmon":"fa8072","sandybrown":"f4a460",
 "seagreen":"2e8b57","seashell":"fff5ee","sienna":"a0522d","silver":"c0c0c0","skyblue":"87ceeb","slateblue":"6a5acd",
 "slategray":"708090","slategrey":"708090","snow":"fffafa","springgreen":"00ff7f","steelblue":"4682b4","tan":"d2b48c",
 "teal":"008080","thistle":"d8bfd8","tomato":"ff6347","turquoise":"40e0d0","violet":"ee82ee","wheat":"f5deb3",
 "white":"ffffff","whitesmoke":"f5f5f5","yellow":"ffff00","yellowgreen":"9acd32"}


def clamp255(v):
    v = math.floor(v + 0.5)
    return 0 if v < 0 else 255 if v > 255 else int(v)


def css_hsl(h, s, l):
    """CSS Color 4 §7.1 hslToRgb (double precision), hue in degrees, s/l in [0,1]."""
    h = h % 360.0
    def f(n):
        k = (n + h / 30.0) % 12
        a = s * min(l, 1 - l)
        return l - a * max(-1, min(k - 3, 9 - k, 1))
    return [clamp255(f(0) * 255), clamp255(f(8) * 255), clamp255(f(4) * 255)]


def main():
    L = Ledger("attr")
    # ---------------- trig / rotate / skew vs libm
    rng = random.Random(3)
    degs = [0, 30, 45, 60, 90, 120, 135, 180, 270, 360, -45, -90, -720, 720, 360000, -360000, 1e6, 1e7, 1e9, 1e12,
            1e15, 1e18, 1e300, 89.9999999, 90.0000001, 0.001, 1e-10]
    degs += [rng.uniform(-720, 720) for _ in range(3000)] + [rng.uniform(-1e9, 1e9) for _ in range(500)]
    recs = ["b%d" % bits(d) for d in degs]
    P = run("pion", "rot", recs)
    R = run("rust", "rot", recs)
    worst = {"cos": (0, 0), "sin": (0, 0)}
    worst_small = {"cos": (0, 0), "sin": (0, 0)}
    worst_720 = 0.0
    big_bad = []
    for d, p, r in zip(degs, P, R):
        pv = [f64(x) for x in p.split()[1:]]
        rv = [f64(x) for x in r.split()[1:]]
        for k, (a, b) in zip(("cos", "sin"), zip(pv[:2], rv[:2])):
            # error relative to 1 (absolute) is what matters for a rotation matrix entry
            e = abs(a - b)
            if abs(d) <= 720:
                worst_720 = max(worst_720, e)
            if abs(d) <= 1e6:
                if e > worst_small[k][0]:
                    worst_small[k] = (e, d)
            elif e > 1e-6:
                big_bad.append((d, k, a, b))
            if e > worst[k][0]:
                worst[k] = (e, d)
    print(f"  rotate() vs libm |deg|<=1e6: worst abs err cos={worst_small['cos'][0]:.3g} @ {worst_small['cos'][1]!r}, "
          f"sin={worst_small['sin'][0]:.3g} @ {worst_small['sin'][1]!r}")
    for d, k, a, b in big_bad[:6]:
        print(f"    huge angle {d!r}: {k} pion={a!r} libm={b!r}")
    print(f"  rotate() vs libm |deg|<=720: worst abs err {worst_720:.3g}")
    L.check("rotate(): sin/cos within 1.2e-15 absolute (~5 ulp of 1) of libm for |deg| <= 720", worst_720 <= 1.2e-15, "ctl")
    L.check("rotate(): sin/cos within 1e-14 absolute of libm up to |deg| <= 1e6 (e.g. rotate(360000))",
            max(worst_small["cos"][0], worst_small["sin"][0]) <= 1e-14, "P2",
            f"worst {max(worst_small['cos'][0], worst_small['sin'][0]):.3g} absolute at {max(worst_small.values())[1]!r} deg "
            "(2-term Cody-Waite reduction error grows linearly with the quadrant count)")
    L.check("rotate(): huge angles (|deg| > 1e6 .. 1e300) still match libm sin/cos (no silent cos=1, sin=0)", not big_bad, "P2",
            f"{len(big_bad)} angles, e.g. rotate({big_bad[0][0]!r}) {big_bad[0][1]} = {big_bad[0][2]!r} vs libm {big_bad[0][3]!r}" if big_bad else "")
    sk = []
    for d, p, r in zip(degs, P, R):
        a, b = f64(p.split()[3]), f64(r.split()[3])
        if abs(d) < 1e6 and abs(b) < 1e10 and abs(a - b) > 1e-12 * max(1, abs(b)):
            sk.append((d, a, b))
    L.check("skewX(): tan within 1e-12 relative of libm (|deg| < 1e6, finite tan)", not sk, "ctl",
            f"{len(sk)} angles, e.g. skewX({sk[0][0]!r}) = {sk[0][1]!r} vs {sk[0][2]!r}" if sk else "")
    # ---------------- parse_transform
    TF = ["translate(10)", "translate(10,20)", "translate(10 20)", "translate(10, 20)", "translate( 10 , 20 )",
          "scale(2)", "scale(2,3)", "rotate(45)", "rotate(45 10 20)", "rotate(45,10,20)", "skewX(30)", "skewY(-30)",
          "matrix(1 2 3 4 5 6)", "matrix(1,2,3,4,5,6)", "translate(1e2,-1e-2)", "translate(10,,20)", "translate(,10)",
          "translate(10,)", "translate()", "translate(1 2 3)", "rotate(1 2)", "rotate(1 2 3 4)", "matrix(1 2 3 4 5)",
          "scale()", "skewX()", "skewX(1 2)", "translate(10)scale(2)", "translate(10),scale(2)", "translate(10) , scale(2)",
          "translate(10),,scale(2)", "translate (10)", "TRANSLATE(10)", "translate(10", "translate(10))", "foo(1)",
          "translate(10) rotate(30 5 5) scale(2 3) skewX(10) matrix(1 0.5 -0.5 1 3 4)", "", "   ", "rotate(360000)",
          "rotate(-720)", "translate(1.2.3)", "scale(.5.5)", "translate(1e)", "rotate(10deg)", "translate(10px)",
          "translate(10%)", "matrix(1 0 0 1 0 0)translate(3 4)"]
    P = run("pion", "tf", TF)
    R = run("rust", "tf", TF)
    bad_acc, bad_val = [], []
    for s, p, r in zip(TF, P, R):
        pe, re_ = p.startswith("ERR"), r.startswith("ERR")
        if pe != re_:
            bad_acc.append((s, p[:3], r[:3]))
            continue
        if not pe:
            pv = [f64(x) for x in p.split()[1:]]
            rv = [f64(x) for x in r.split()[1:]]
            if max(abs(a - b) for a, b in zip(pv, rv)) > 1e-12 * max(1, max(map(abs, rv))):
                bad_val.append((s, pv, rv))
    for x in bad_acc:
        print(f"    TF accept? {x}")
    for x in bad_val:
        print(f"    TF value {x}")
    # svgtypes ignores an empty / whitespace transform list (identity) — both conventions are fine.
    bad_acc = [x for x in bad_acc if x[0].strip()]
    L.check("parse_transform: accept/reject agrees with svgtypes (6 functions, arg counts, separators)", not bad_acc, "ctl",
            str(bad_acc[:3]))
    L.check("parse_transform: matrix composition order equals svgtypes (pre-multiplication, rotate(a cx cy))", not bad_val, "ctl",
            str(bad_val[:2]))
    # invert of an invertible (tiny-scale) matrix
    # (checked in redteam_test.pion: p2_invert_rejects_invertible_small_scale_matrix)
    # ---------------- viewBox / preserveAspectRatio
    VB = ["0 0 24 24", "0,0,24,24", "-10 -10 20 20", "0 0 0 10", "0 0 10 0", "0 0 -1 10", "0 0 1e3 1e-3", "0 0 24",
          "0 0 24 24 24", "0 0 24 24,", " 0 0 24 24 ", "a b c d", "0 0 24px 24"]
    P = run("pion", "vb", VB)
    R = run("rust", "vb", VB)
    vb_bad = [(s, p[:3], r[:3]) for s, p, r in zip(VB, P, R) if (p.startswith("ERR") != r.startswith("ERR")) or (not p.startswith("ERR") and p != r)]
    for x in vb_bad:
        print(f"    VB {x}")
    L.check("parse_viewbox: rejects zero width/height like svgtypes (SVG: 0 disables rendering, not identity)",
            not [x for x in vb_bad if x[0] in ("0 0 0 10", "0 0 10 0")], "P2", str(vb_bad[:3]))
    # svgtypes accepts trailing garbage after 4 numbers; SVG 2 §8.6 grammar is exactly 4 numbers -> Pion correct.
    exempt = ("0 0 0 10", "0 0 10 0", "0 0 24 24 24", "0 0 24 24,")
    L.check("parse_viewbox: other accept/reject decisions agree with svgtypes (5th number / trailing comma: Pion stricter = spec)",
            not [x for x in vb_bad if x[0] not in exempt], "ctl", str([x for x in vb_bad if x[0] not in exempt][:3]))
    aligns = ["none"] + [f"x{a}Y{b}" for b in ("Min", "Mid", "Max") for a in ("Min", "Mid", "Max")]
    PAR = [a + m for a in aligns for m in ("", " meet", " slice")] + ["defer xMidYMid", "defer", "xMidYMid  slice ", "slice",
           "xmidymid", "xMidYMid meet slice", "", "none slice"]
    P = run("pion", "par", PAR)
    R = run("rust", "par", PAR)
    # svgtypes ignores trailing tokens ('xMidYMid meet slice'); the grammar has one meetOrSlice -> Pion stricter = spec.
    par_bad = [(s, p, r) for s, p, r in zip(PAR, P, R) if p != r and not (p.startswith("ERR") and r.startswith("ERR"))
               and s != "xMidYMid meet slice"]
    for x in par_bad:
        print(f"    PAR {x}")
    L.check("parse_preserve_aspect_ratio: all 10 aligns x meet/slice (+defer) agree with svgtypes", not par_bad, "ctl", str(par_bad[:3]))
    # viewbox_transform vs SVG 2 §8.2 algorithm (Python)
    vbt_bad = []
    recs, exp = [], []
    for vb in [(0, 0, 24, 24), (-5, 3, 10, 40), (10, 20, 300, 100)]:
        for (w, h) in [(96, 48), (48, 96), (100, 100)]:
            for a in aligns:
                for m in ("meet", "slice"):
                    recs.append(f"{vb[0]} {vb[1]} {vb[2]} {vb[3]}{SEP}{w}{SEP}{h}{SEP}{a} {m}")
                    sx, sy = w / vb[2], h / vb[3]
                    if a != "none":
                        sx = sy = min(sx, sy) if m == "meet" else max(sx, sy)
                    tx, ty = -vb[0] * sx, -vb[1] * sy
                    if "xMid" in a: tx += (w - vb[2] * sx) / 2
                    if "xMax" in a: tx += (w - vb[2] * sx)
                    if "YMid" in a: ty += (h - vb[3] * sy) / 2
                    if "YMax" in a: ty += (h - vb[3] * sy)
                    exp.append((sx, 0, 0, sy, tx, ty))
    P = run("pion", "vbt", recs)
    for rec, p, e in zip(recs, P, exp):
        pv = [f64(x) for x in p.split()[1:]]
        if max(abs(a - b) for a, b in zip(pv, e)) > 1e-9:
            vbt_bad.append((rec.replace(SEP, "|"), pv, e))
    L.check("viewbox_transform: 3 viewBoxes x 3 viewports x 10 aligns x meet/slice = SVG 2 §8.2 equations", not vbt_bad, "ctl",
            str(vbt_bad[:2]))
    # ---------------- colors
    C = []
    for n, hx in NAMED.items():
        C += [n, n.upper(), n.capitalize(), " " + n + " "]
    C += ["#f00", "#F00", "#ff0000", "#ff000080", "#f008", "#ff00", "#ff00000", "#gg0000", "#", "#12345", "rgb(255,0,0)",
          "rgb(255 0 0)", "rgb(100%,0%,0%)", "rgb(50%,50%,50%)", "rgb(300,-20,128.4)", "rgb(128.5,0,0)", "rgba(0,0,0,0.5)",
          "rgba(0,0,0,50%)", "rgb(255 0 0 / 50%)", "rgb(255,0,0,)", "rgb(255,0)", "rgb(255,0,0", "rgb()", "RGB(1,2,3)",
          "rgb( 1 , 2 , 3 )", "rgba(1,2,3,2)", "rgba(1,2,3,-1)", "hsl(120,100%,50%)", "hsl(0,100%,50%)", "hsl(-120,100%,50%)",
          "hsl(480,100%,50%)", "hsl(360,100%,50%)", "hsl(720.5,50%,50%)", "hsl(30,50%,50%)", "hsla(240,100%,50%,0.5)",
          "hsl(120deg 100% 50%)", "hsl(0.5turn,100%,50%)", "hsl(200,150%,50%)", "hsl(200,-10%,50%)", "hsl(200,50%,120%)",
          "transparent", "currentColor", "none", "url(#a)", "inherit", "red blue", "redd", "#fff icc-color(a,1)", ""]
    rng = random.Random(11)
    hs = [(rng.uniform(-720, 720), rng.uniform(0, 100), rng.uniform(0, 100)) for _ in range(3000)]
    C += [f"hsl({h!r},{s!r}%,{l!r}%)" for h, s, l in hs]
    P = run("pion", "color", C)
    R = run("rust", "color", C)
    named_bad = []
    for s, p in zip(C, P):
        k = s.strip().lower()
        if k in NAMED:
            hx = NAMED[k]
            expv = f"OK {int(hx[0:2], 16)} {int(hx[2:4], 16)} {int(hx[4:6], 16)} 255"
            if p != expv:
                named_bad.append((s, p, expv))
    L.check(f"parse_color: all {len(NAMED)} CSS4 named colors, case-insensitive, padded", not named_bad and len(NAMED) == 148, "ctl",
            str(named_bad[:3]))
    hsl_bad = []
    for (h, s_, l), p in zip(hs, P[-len(hs):]):
        e = css_hsl(h, s_ / 100, l / 100)
        pv = [int(x) for x in p.split()[1:4]] if p.startswith("OK") else None
        if pv != e:
            hsl_bad.append((h, s_, l, pv, e))
    print(f"  hsl() vs CSS Color 4 hslToRgb (double): {len(hsl_bad)} / {len(hs)} differ" +
          (f", e.g. {hsl_bad[0]}" if hsl_bad else ""))
    L.check("parse_color hsl(): equals CSS Color 4 hslToRgb rounded (3000 random)", not hsl_bad, "ctl", str(hsl_bad[:2]))
    diffs = []
    for s, p, r in zip(C, P, R):
        if s.strip().lower() in NAMED or s.startswith("hsl(") and s in [f"hsl({h!r},{s_!r}%,{l!r}%)" for h, s_, l in hs[:0]]:
            continue
        if p != r:
            diffs.append((s, p, r))
    for x in diffs[:40]:
        print(f"    COLOR {x[0]!r}: pion={x[1]!r} svgtypes={x[2]!r}")
    # Spec-grounded expectations where svgtypes and CSS Color 4 agree:
    must = {
        "rgb(255,0,0,)": "ERR",        # trailing comma is invalid in every CSS color grammar
        "rgb(255,0)": "ERR", "rgb(255,0,0": "ERR", "rgb()": "ERR", "#12345": "ERR", "#gg0000": "ERR", "redd": "ERR",
        "rgb(300,-20,128.4)": "OK 255 0 128 255", "rgba(1,2,3,2)": "OK 1 2 3 255", "rgba(1,2,3,-1)": "OK 1 2 3 0",
        "hsl(-120,100%,50%)": "OK 0 0 255 255", "hsl(480,100%,50%)": "OK 0 255 0 255", "transparent": "OK 0 0 0 0",
        "rgba(0,0,0,0.5)": "OK 0 0 0 128", "#ff000080": "OK 255 0 0 128", "#f008": "OK 255 0 0 136",
    }
    must_bad = [(s, dict(zip(C, P))[s], e) for s, e in must.items() if dict(zip(C, P))[s] != e]
    L.check("parse_color: spec edge cases (trailing comma, clamping, negative/>360 hue, alpha, hex4/8)", not must_bad, "P2",
            str(must_bad[:4]))
    # ---------------- lengths
    LN = ["10", "10px", "10pt", "10pc", "1in", "2.54cm", "25.4mm", "50%", "1em", "1ex", "10PX", " 10 px ", "10 px", "px",
          "1e2px", "1e", "10q", "-5mm", "+.5in"]
    P = run("pion", "len", LN)
    R = run("rust", "len", LN)
    for s, p, r in zip(LN, P, R):
        print(f"    LEN {s!r}: pion={p[:3]}{' ' + str(f64(p.split()[1])) if p.startswith('OK') else ''} svgtypes={r[:3]} {r[3:] if r.startswith('OK') else ''}")
    sys.exit(L.save())


if __name__ == "__main__":
    main()
