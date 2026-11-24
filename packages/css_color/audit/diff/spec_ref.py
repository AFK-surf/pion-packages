#!/usr/bin/env python3
"""Independent float64 reference for the css_color audit: a port of the CSS Color 4 Editor's Draft sample code
(https://drafts.csswg.org/css-color-4/, conversions.js, retrieved 2026-11-24) using Python's libm.

Every RGB<->XYZ matrix and the Bradford adaptation are derived here from the primaries and white-point chromaticities
with exact rational arithmetic (the ED's rational matrices are the same numbers), so they are independent of the
constants under audit. Two ED changes that browsers have not shipped are switchable:
  REC2020_TF = "bt2020"  piecewise BT.2020 OETF (Chrome 159, color 0.3.3 and css_color) | "gamma24" (ED: BT.1886)
Powerless-hue epsilons follow the ED tables (hsl S <= 0.001, hwb W+B >= 99.999, lch C <= 0.0015, oklch C <= 4e-6).
Stdlib only; import as a module (compare.py, gamut.py) or run `spec_ref.py selftest`."""
import math
from fractions import Fraction as F

REC2020_TF = "bt2020"

SPACES = ["srgb", "srgb-linear", "display-p3", "a98-rgb", "prophoto-rgb", "rec2020", "xyz-d50", "xyz-d65",
          "hsl", "hwb", "lab", "lch", "oklab", "oklch"]
RGB_SPACES = SPACES[:6]
POLAR = {"hsl": 0, "hwb": 0, "lch": 2, "oklch": 2}  # hue index


def _inv(m):
    a, b, c = m[0]
    d, e, f = m[1]
    g, h, i = m[2]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
            [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
            [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]


def _mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]


def _xyz(x, y):
    return [x / y, F(1), (1 - x - y) / y]


def _rgb2xyz(prims, white):
    p = [_xyz(*q) for q in prims]
    m = [[p[j][i] for j in range(3)] for i in range(3)]
    w = _xyz(*white)
    mi = _inv(m)
    s = [sum(mi[i][k] * w[k] for k in range(3)) for i in range(3)]
    return [[m[i][j] * s[j] for j in range(3)] for i in range(3)]


def _f(m):
    return [[float(x) for x in r] for r in m]


D65 = (F("0.3127"), F("0.3290"))
D50 = (F("0.3457"), F("0.3585"))
_BRAD = [[F("0.8951"), F("0.2664"), F("-0.1614")], [F("-0.7502"), F("1.7135"), F("0.0367")],
         [F("0.0389"), F("-0.0685"), F("1.0296")]]


def _bradford(src, dst):
    ws, wd = _xyz(*src), _xyz(*dst)
    ls = [sum(_BRAD[i][k] * ws[k] for k in range(3)) for i in range(3)]
    ld = [sum(_BRAD[i][k] * wd[k] for k in range(3)) for i in range(3)]
    d = [[ld[i] / ls[i] if i == j else F(0) for j in range(3)] for i in range(3)]
    return _mul(_inv(_BRAD), _mul(d, _BRAD))


_PRIMS = {
    "srgb": ([("0.64", "0.33"), ("0.30", "0.60"), ("0.15", "0.06")], D65),
    "display-p3": ([("0.680", "0.320"), ("0.265", "0.690"), ("0.150", "0.060")], D65),
    "a98-rgb": ([("0.64", "0.33"), ("0.21", "0.71"), ("0.15", "0.06")], D65),
    "prophoto-rgb": ([("0.734699", "0.265301"), ("0.159597", "0.840403"), ("0.036598", "0.000105")], D50),
    "rec2020": ([("0.708", "0.292"), ("0.170", "0.797"), ("0.131", "0.046")], D65),
}
TO_XYZ = {}
FROM_XYZ = {}
for _k, (_p, _w) in _PRIMS.items():
    _m = _rgb2xyz([(F(a), F(b)) for a, b in _p], _w)
    TO_XYZ[_k] = _f(_m)
    FROM_XYZ[_k] = _f(_inv(_m))
D65_TO_D50 = _f(_bradford(D65, D50))
D50_TO_D65 = _f(_bradford(D50, D65))
D50_WHITE = [float(v) for v in _xyz(*D50)]

XYZ_TO_LMS = [[0.8190224379967030, 0.3619062600528904, -0.1288737815209879],
              [0.0329836539323885, 0.9292868615863434, 0.0361446663506424],
              [0.0481771893596242, 0.2642395317527308, 0.6335478284694309]]
LMS_TO_OKLAB = [[0.2104542683093140, 0.7936177747023054, -0.0040720430116193],
                [1.9779985324311684, -2.4285922420485799, 0.4505937096174110],
                [0.0259040424655478, 0.7827717124575296, -0.8086757549230774]]
LMS_TO_XYZ = [[1.2268798758459243, -0.5578149944602171, 0.2813910456659647],
              [-0.0405757452148008, 1.1122868032803170, -0.0717110580655164],
              [-0.0763729366746601, -0.4214933324022432, 1.5869240198367816]]
OKLAB_TO_LMS = [[1.0000000000000000, 0.3963377773761749, 0.2158037573099136],
                [1.0000000000000000, -0.1055613458156586, -0.0638541728258133],
                [1.0000000000000000, -0.0894841775298119, -1.2914855480194092]]


def mv(m, v):
    return [m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
            m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
            m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2]]


def cbrt(v):
    """Correctly rounded-ish cube root (math.cbrt needs Python 3.11): pow guess + one Newton step."""
    if v == 0 or v != v or math.isinf(v):
        return v
    a = abs(v)
    g = a ** (1 / 3)
    g = g - (g * g * g - a) / (3 * g * g)
    return math.copysign(g, v)


def _sgnpow(v, p):
    return math.copysign(abs(v) ** p, v) if v != 0 else 0.0


def lin(space, v):
    a = abs(v)
    if space in ("srgb", "display-p3"):
        return v / 12.92 if a <= 0.04045 else math.copysign(((a + 0.055) / 1.055) ** 2.4, v)
    if space == "a98-rgb":
        return _sgnpow(v, 563 / 256)
    if space == "prophoto-rgb":
        return v / 16 if a <= 16 / 512 else math.copysign(a ** 1.8, v)
    if space == "rec2020":
        if REC2020_TF == "gamma24":
            return _sgnpow(v, 2.4)
        al, be = 1.09929682680944, 0.018053968510807
        return v / 4.5 if a < be * 4.5 else math.copysign(((a + al - 1) / al) ** (1 / 0.45), v)
    return v


def gam(space, v):
    a = abs(v)
    if space in ("srgb", "display-p3"):
        return math.copysign(1.055 * a ** (1 / 2.4) - 0.055, v) if a > 0.0031308 else 12.92 * v
    if space == "a98-rgb":
        return _sgnpow(v, 256 / 563)
    if space == "prophoto-rgb":
        return math.copysign(a ** (1 / 1.8), v) if a >= 1 / 512 else 16 * v
    if space == "rec2020":
        if REC2020_TF == "gamma24":
            return _sgnpow(v, 1 / 2.4)
        al, be = 1.09929682680944, 0.018053968510807
        return math.copysign(al * a ** 0.45 - (al - 1), v) if a > be else 4.5 * v
    return v


def hsl_to_rgb(h, s, l):
    h = h % 360.0
    s, l = s / 100.0, l / 100.0

    def f(n):
        k = (n + h / 30.0) % 12.0
        a = s * min(l, 1 - l)
        return l - a * max(-1.0, min(k - 3, 9 - k, 1.0))
    return [f(0), f(8), f(4)]


def rgb_to_hsl(r, g, b):
    mx, mn = max(r, g, b), min(r, g, b)
    hue, sat, light = float("nan"), 0.0, (mn + mx) / 2
    d = mx - mn
    eps = 1 / 100000
    if d != 0:
        sat = 0.0 if (abs(light) <= eps or abs(1 - light) < eps) else (mx - light) / min(light, 1 - light)
        if mx == r:
            hue = (g - b) / d + (6 if g < b else 0)
        elif mx == g:
            hue = (b - r) / d + 2
        else:
            hue = (r - g) / d + 4
        hue *= 60
    if sat < 0:
        hue += 180
        sat = abs(sat)
    if hue >= 360:
        hue -= 360
    if sat <= eps:
        hue, sat = float("nan"), 0.0
    return [hue, sat * 100, light * 100]


def hwb_to_rgb(h, w, b):
    w, b = w / 100, b / 100
    if w + b >= 1:
        g = w / (w + b)
        return [g, g, g]
    rgb = hsl_to_rgb(h, 100, 50)
    return [c * (1 - w - b) + w for c in rgb]


def rgb_to_hwb(r, g, b):
    mx, mn = max(r, g, b), min(r, g, b)
    d = mx - mn
    hue = float("nan")
    if d != 0:
        if mx == r:
            hue = (g - b) / d + (6 if g < b else 0)
        elif mx == g:
            hue = (b - r) / d + 2
        else:
            hue = (r - g) / d + 4
        hue = (hue * 60) % 360
    white, black = mn, 1 - mx
    if white + black >= 1 - 1 / 100000:
        hue = float("nan")
    return [hue, white * 100, black * 100]


K = 24389 / 27
E = 216 / 24389


def xyz50_to_lab(x):
    xyz = [x[i] / D50_WHITE[i] for i in range(3)]
    f = [cbrt(v) if v > E else (K * v + 16) / 116 for v in xyz]
    return [116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2])]


def lab_to_xyz50(lab):
    f1 = (lab[0] + 16) / 116
    f0 = lab[1] / 500 + f1
    f2 = f1 - lab[2] / 200
    xyz = [f0 ** 3 if f0 ** 3 > E else (116 * f0 - 16) / K,
           ((lab[0] + 16) / 116) ** 3 if lab[0] > K * E else lab[0] / K,
           f2 ** 3 if f2 ** 3 > E else (116 * f2 - 16) / K]
    return [xyz[i] * D50_WHITE[i] for i in range(3)]


def xyz65_to_oklab(x):
    lms = mv(XYZ_TO_LMS, x)
    return mv(LMS_TO_OKLAB, [cbrt(v) for v in lms])


def oklab_to_xyz65(o):
    lms = mv(OKLAB_TO_LMS, o)
    return mv(LMS_TO_XYZ, [v ** 3 for v in lms])


def to_polar(lab, eps):
    c = math.sqrt(lab[1] ** 2 + lab[2] ** 2)
    h = math.degrees(math.atan2(lab[2], lab[1]))
    if h < 0:
        h += 360
    if c <= eps:  # ED §4.4: a powerless hue becomes missing and its chroma is set to 0
        h, c = float("nan"), 0.0
    return [lab[0], c, h]


def from_polar(p):
    h = 0.0 if math.isnan(p[2]) else p[2]
    return [p[0], p[1] * math.cos(math.radians(h)), p[1] * math.sin(math.radians(h))]


def to_xyz65(space, c):
    """c: 3 coordinates (missing already replaced by 0, NaN hue = 0)."""
    c = [0.0 if (v != v) else v for v in c]
    if space in RGB_SPACES:
        l = list(c) if space == "srgb-linear" else [lin(space, v) for v in c]
        x = mv(TO_XYZ["srgb" if space == "srgb-linear" else space], l)
        return mv(D50_TO_D65, x) if space == "prophoto-rgb" else x
    if space == "xyz-d65":
        return list(c)
    if space == "xyz-d50":
        return mv(D50_TO_D65, c)
    if space == "hsl":
        return to_xyz65("srgb", hsl_to_rgb(*c))
    if space == "hwb":
        return to_xyz65("srgb", hwb_to_rgb(*c))
    if space == "lab":
        return mv(D50_TO_D65, lab_to_xyz50(c))
    if space == "lch":
        return mv(D50_TO_D65, lab_to_xyz50(from_polar(c)))
    if space == "oklab":
        return oklab_to_xyz65(c)
    if space == "oklch":
        return oklab_to_xyz65(from_polar(c))
    raise ValueError(space)


def from_xyz65(space, x):
    """Returns 3 coordinates; a powerless hue is NaN."""
    if space in RGB_SPACES:
        base = "srgb" if space == "srgb-linear" else space
        xx = mv(D65_TO_D50, x) if space == "prophoto-rgb" else x
        l = mv(FROM_XYZ[base], xx)
        return l if space == "srgb-linear" else [gam(space, v) for v in l]
    if space == "xyz-d65":
        return list(x)
    if space == "xyz-d50":
        return mv(D65_TO_D50, x)
    if space == "hsl":
        return rgb_to_hsl(*from_xyz65("srgb", x))
    if space == "hwb":
        return rgb_to_hwb(*from_xyz65("srgb", x))
    if space == "lab":
        return xyz50_to_lab(mv(D65_TO_D50, x))
    if space == "lch":
        return to_polar(xyz50_to_lab(mv(D65_TO_D50, x)), 0.0015)
    if space == "oklab":
        return xyz65_to_oklab(x)
    if space == "oklch":
        return to_polar(xyz65_to_oklab(x), 0.000004)
    raise ValueError(space)


D50_SPACES = ("xyz-d50", "lab", "lch", "prophoto-rgb")
PACKAGE_ROUTING = False  # True: route D50 <-> D50 through XYZ-D65 like css_color (except lab <-> xyz-d50 / lch)


def _to_xyz50(space, c):
    c = [0.0 if (v != v) else v for v in c]
    if space == "xyz-d50":
        return list(c)
    if space == "lab":
        return lab_to_xyz50(c)
    if space == "lch":
        return lab_to_xyz50(from_polar(c))
    return mv(TO_XYZ["prophoto-rgb"], [lin("prophoto-rgb", v) for v in c])


def _from_xyz50(space, x):
    if space == "xyz-d50":
        return list(x)
    if space == "lab":
        return xyz50_to_lab(x)
    if space == "lch":
        return to_polar(xyz50_to_lab(x), 0.0015)
    return [gam("prophoto-rgb", v) for v in mv(FROM_XYZ["prophoto-rgb"], x)]


def convert(src, c, dst):
    if src == dst:
        return list(c)
    direct = not PACKAGE_ROUTING or {src, dst} in ({"lab", "xyz-d50"}, {"lab", "lch"})
    if src in D50_SPACES and dst in D50_SPACES and direct:  # no chromatic adaptation between two D50 spaces
        return _from_xyz50(dst, _to_xyz50(src, c))
    return from_xyz65(dst, to_xyz65(src, c))


def use_package_constants():
    """Swap in the constants css_color ships (pre-2023 ED values for Bradford and ProPhoto, copied verbatim from
    packages/css_color/src/space.pion) so that a comparison isolates the software math from the constant drift."""
    global D65_TO_D50, D50_TO_D65, PACKAGE_ROUTING
    PACKAGE_ROUTING = True
    D65_TO_D50 = [[1.0479298208405488, 0.022946793341019088, -0.05019222954313557],
                  [0.029627815688159344, 0.990434484573249, -0.01707382502938514],
                  [-0.009243058152591178, 0.015055144896577895, 0.7518742899580008]]
    D50_TO_D65 = [[0.9554734527042182, -0.023098536874261423, 0.0632593086610217],
                  [-0.028369706963208136, 1.0099954580058226, 0.021041398966943008],
                  [0.012314001688319899, -0.020507696433477912, 1.3303659366080753]]
    TO_XYZ["prophoto-rgb"] = [[0.7977604896723027, 0.13518583717574031, 0.0313493495815248],
                              [0.2880711282292934, 0.7118432178101014, 0.00008565396060525902], [0.0, 0.0, 0.8251046025104601]]
    FROM_XYZ["prophoto-rgb"] = [[1.3457989731028281, -0.25558010007997534, -0.05110628506753401],
                                [-0.5446224939028347, 1.5082327413132781, 0.02053603239147973], [0.0, 0.0, 1.2119675456389454]]


# --- gamut mapping, CSS Color 4 ED "binary search gamut mapping with local MINDE" ---

def in_gamut(space, c):
    return all(0.0 <= v <= 1.0 for v in c)


def delta_eok(s1, c1, s2, c2):
    a, b = convert(s1, c1, "oklab"), convert(s2, c2, "oklab")
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def gamut_map(src, c, dest):
    """Map color (src, c) into the gamut of the RGB space `dest` (hsl/hwb map via srgb). Returns (dest coords, iters)."""
    rgb = "srgb" if dest in ("hsl", "hwb") else dest
    if rgb not in RGB_SPACES:
        return convert(src, c, dest), 0
    origin = convert(src, c, "oklch")
    if origin[0] >= 1.0:
        return convert(rgb, [1.0, 1.0, 1.0], dest), 0
    if origin[0] <= 0.0:
        return convert(rgb, [0.0, 0.0, 0.0], dest), 0
    direct = convert(src, c, rgb)
    if in_gamut(rgb, direct):
        return convert(src, c, dest), 0
    jnd, eps = 0.02, 0.0001

    def clip(oklch):
        return [min(1.0, max(0.0, v)) for v in convert("oklch", oklch, rgb)]
    cur = list(origin)
    clipped = clip(cur)
    if delta_eok(rgb, clipped, "oklch", cur) < jnd:
        return convert(rgb, clipped, dest), 0
    lo, hi, lo_in, it = 0.0, origin[1], True, 0
    while hi - lo > eps:
        it += 1
        ch = (lo + hi) / 2
        cur = [origin[0], ch, origin[2]]
        if lo_in and in_gamut(rgb, convert("oklch", cur, rgb)):
            lo = ch
            continue
        clipped = clip(cur)
        e = delta_eok(rgb, clipped, "oklch", cur)
        if e < jnd:
            if jnd - e < eps:
                return convert(rgb, clipped, dest), it
            lo_in = False
            lo = ch
        else:
            hi = ch
    return convert(rgb, clipped, dest), it


# --- WCAG 2.1 ---

def wcag_luminance_srgb(rgb):
    def lin_w(v):
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = [lin_w(min(1.0, max(0.0, v))) for v in rgb]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def selftest():
    # white in every space round-trips, D50 white maps to D65 white through Bradford, matrices invert
    for s in SPACES:
        w = convert("srgb", [1.0, 1.0, 1.0], s)
        back = convert(s, w, "srgb")
        assert all(abs(v - 1) < 1e-12 for v in back), (s, back)
    x = mv(D50_TO_D65, D50_WHITE)
    w65 = [float(v) for v in _xyz(*D65)]
    assert all(abs(x[i] - w65[i]) < 1e-15 for i in range(3)), x
    print("spec_ref selftest ok")


if __name__ == "__main__":
    selftest()
