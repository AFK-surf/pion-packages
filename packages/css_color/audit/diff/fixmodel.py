#!/usr/bin/env python3
"""Fix model: cumulative candidate fixes for the value findings of REPORT.md, applied to copies of packages/css_color.
  python3 -I fixmodel.py <package dir> <out dir>      -> <out dir>/stage<k>/css_color (k = 1..N), prints `k id`
Stage k contains the fixes of stages 1..k. compare.py attributes a value divergence from an oracle to the finding of the
first stage whose output agrees with the oracle, so every attribution is backed by a working fix, not by a pattern.
The fixes are minimal sketches for the reviewer of the fix branch, not drop-in patches."""
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spec_ref as R  # noqa: E402


def sub(text, old, new, count=1):
    assert text.count(old) == count, (old[:80], text.count(old))
    return text.replace(old, new)


def p1_1(f):  # HSL/HWB from (near-)white/black: CSS Color 4 ED rgbToHsl / rgbToHwb epsilon guards
    s = f["space.pion"]
    s = sub(s, "    if denom == 0.0 {", "    if f64_abs(l) <= 0.00001 || f64_abs(1.0 - l) < 0.00001 {")
    s = sub(s, "  if white + black >= 100.0 - 1.0e-7 {", "  if white + black >= 100.0 - 0.001 {")
    f["space.pion"] = s


def p2_8(f):  # powerless-hue epsilons of the ED tables: hsl S <= 0.001 (0.00001 of 1), lch C <= 0.0015, oklch C <= 4e-6
    s = f["space.pion"]
    s = sub(s, "  if f64_abs(s) < 1.0e-7 {\n    hue_missing = true\n  }",
            "  if s <= 0.00001 {\n    hue_missing = true\n    s = 0.0\n  }")
    s = sub(s, "  if c < eps {", "  if c <= eps {")
    s = s.replace("rect_to_polar(l, a, b, 1.0e-4)", "rect_to_polar(l, a, b, 0.0015)")
    s = s.replace("rect_to_polar(self.c0, self.c1, self.c2, 1.0e-4)", "rect_to_polar(self.c0, self.c1, self.c2, 0.0015)")
    s = s.replace("rect_to_polar(l, a, b, 1.0e-6)", "rect_to_polar(l, a, b, 0.000004)")
    s = s.replace("rect_to_polar(self.c0, self.c1, self.c2, 1.0e-6)", "rect_to_polar(self.c0, self.c1, self.c2, 0.000004)")
    # a powerless hue of the source color becomes missing before conversion (ED §4.4), chroma / B normalised
    s = sub(s, "pub fn Color::convert(self : Color, target : ColorSpace) -> Color {", """fn powerless_normalize(c : Color) -> Color {
  match c.space {
    ColorSpace::Hsl =>
      if !c.m0 && !c.m1 && c.c1 <= 0.001 {
        Color::new_with_missing(c.space, 0.0, f64_min(c.c1, 0.0), c.c2, c.alpha, true, c.m1, c.m2, c.ma)
      } else {
        c
      }
    ColorSpace::Hwb =>
      if !c.m0 && !c.m1 && !c.m2 && c.c1 + c.c2 >= 99.999 {
        Color::new_with_missing(c.space, 0.0, c.c1, if c.c1 + c.c2 < 100.0 { 100.0 - c.c1 } else { c.c2 }, c.alpha, true, false, false, c.ma)
      } else {
        c
      }
    ColorSpace::Lch =>
      if !c.m2 && !c.m1 && c.c1 <= 0.0015 {
        Color::new_with_missing(c.space, c.c0, f64_min(c.c1, 0.0), 0.0, c.alpha, c.m0, c.m1, true, c.ma)
      } else {
        c
      }
    ColorSpace::Oklch =>
      if !c.m2 && !c.m1 && c.c1 <= 0.000004 {
        Color::new_with_missing(c.space, c.c0, f64_min(c.c1, 0.0), 0.0, c.alpha, c.m0, c.m1, true, c.ma)
      } else {
        c
      }
    _ => c
  }
}

pub fn Color::convert(self : Color, target : ColorSpace) -> Color {
  if self.space.eq(target) {
    return self
  }
  powerless_normalize(self).convert_impl(target)
}

fn Color::convert_impl(self : Color, target : ColorSpace) -> Color {""")
    f["space.pion"] = s


def p1_2(f):  # relative color syntax: a channel keyword of a missing (or powerless) origin component resolves to none
    s = f["parser.pion"]
    s = sub(s, "  va : Double\n}", "  va : Double\n  m0 : Bool\n  m1 : Bool\n  m2 : Bool\n  ma : Bool\n}")
    s = sub(s, 'va: 1.0 }', 'va: 1.0, m0: false, m1: false, m2: false, ma: false }')
    s = sub(s, "v2: v2, va: va }", "v2: v2, va: va, m0: false, m1: false, m2: false, ma: false }")
    s = sub(s, "fn CalcEnv::lookup(self : CalcEnv, name : String) -> Option[Double] {", """fn CalcEnv::with_missing(self : CalcEnv, m0 : Bool, m1 : Bool, m2 : Bool, ma : Bool) -> CalcEnv {
  CalcEnv::{ active: self.active, k0: self.k0, v0: self.v0, k1: self.k1, v1: self.v1, k2: self.k2, v2: self.v2, va: self.va, m0: m0, m1: m1, m2: m2, ma: ma }
}

fn CalcEnv::lookup_missing(self : CalcEnv, name : String) -> Bool {
  if !self.active {
    false
  } else if name == self.k0 {
    self.m0
  } else if name == self.k1 {
    self.m1
  } else if name == self.k2 {
    self.m2
  } else if name == "alpha" {
    self.ma
  } else {
    false
  }
}

fn CalcEnv::lookup(self : CalcEnv, name : String) -> Option[Double] {""")
    s = re.sub(r"(CalcEnv::make\([^\n]*?, (\w+)\.alpha\))", r"\1.with_missing(\2.m0, \2.m1, \2.m2, \2.ma)", s)
    s = sub(s, "      Some(v) => return Ok((v, false, false))", "      Some(v) => return Ok((v, env.lookup_missing(ident), false))")
    f["parser.pion"] = s


def p2_7(f):  # analogous components: x,y,z are Reds/Greens/Blues; plus analogous sets (CSS Color 4 §12.2)
    s = f["space.pion"]
    s = sub(s, "    ColorSpace::XyzD50 | ColorSpace::XyzD65 => 0\n",
            "    ColorSpace::XyzD50 | ColorSpace::XyzD65 => {\n      if idx == 0 { 1 } else if idx == 1 { 2 } else { 3 }\n    }\n")
    s = sub(s, "  (m0, m1, m2)\n}", """  // analogous sets: when every source component without an analog is missing, so are the target's
  let sm = [src.m0, src.m1, src.m2]
  let mut rest = 0
  let mut rest_missing = 0
  let mut i = 0
  while i < 3 {
    let sc = channel_category(src.space, i)
    if !(sc != 0 && (sc == t0 || sc == t1 || sc == t2)) {
      rest = rest + 1
      if sm[i] {
        rest_missing = rest_missing + 1
      }
    }
    i = i + 1
  }
  if rest > 0 && rest == rest_missing {
    let s0 = channel_category(src.space, 0)
    let s1 = channel_category(src.space, 1)
    let s2 = channel_category(src.space, 2)
    if !(t0 != 0 && (t0 == s0 || t0 == s1 || t0 == s2)) { m0 = true }
    if !(t1 != 0 && (t1 == s0 || t1 == s1 || t1 == s2)) { m1 = true }
    if !(t2 != 0 && (t2 == s0 || t2 == s1 || t2 == s2)) { m2 = true }
  }
  (m0, m1, m2)
}""")
    f["space.pion"] = s


def p2_11(f):  # color-mix(): a missing hue is filled in before the hue fix-up; 0 interpolated alpha -> 0 components
    s = f["mix.pion"]
    s = sub(s, "  if m1 {\n    return (v2, false)\n  }",
            "  if is_hue && (m1 || m2) {\n    let hv = if m1 { v2 } else { v1 }\n    return (interpolate_hue(hv, hv, w2, hue_mode), false)\n  }\n"
            "  if m1 {\n    return (v2, false)\n  }")
    s = sub(s, "    (w1 * v1 + w2 * v2, false)", "    (0.0, false)")
    f["mix.pion"] = s


def p2_12(f):  # exact hue normalisation for |h| >= 2^52 * 360 (f64_rem_euclid returned 0)
    s = f["math.pion"]
    s = sub(s, "fn f64_rem_euclid(x : Double, m : Double) -> Double {", """fn f64_fmod_exact(a0 : Double, b : Double) -> Double {
  let mut a = a0
  if a < b {
    return a
  }
  let mut t = b
  while t * 2.0 <= a {
    t = t * 2.0
  }
  while t >= b {
    if a >= t {
      a = a - t
    }
    t = t * 0.5
  }
  a
}

fn f64_rem_euclid(x : Double, m : Double) -> Double {""")
    s = sub(s, "  let r = x - f64_floor(x / m) * m\n",
            "  let fm = f64_fmod_exact(f64_abs(x), m)\n  let r = if x >= 0.0 || fm == 0.0 { fm } else { m - fm }\n")
    f["math.pion"] = s


def p2_9(f):  # hsl(): only a negative saturation is clamped at parsed-value time (ED §7); S > 100% stays
    # (L is still clamped to [0, 100]: Chrome 159 does so, and no WPT vector says otherwise)
    s = f["parser.pion"]
    s = sub(s, "        f64_clamp(s, 0.0, 100.0),\n        f64_clamp(l, 0.0, 100.0),", "        f64_max(0.0, s),\n        f64_clamp(l, 0.0, 100.0),", count=2)
    f["parser.pion"] = s


def _mat(name, m):
    args = ",\n".join("    %r" % float(v) for row in m for v in row)
    return name, args


def p2_2(f):  # CSS Color 4 ED (2025): rec2020 uses the BT.1886 gamma 2.4 transfer (WPT follows, Chrome 159 does not yet)
    s = f["space.pion"]
    s = re.sub(r"fn rec2020_to_linear_ch\(v : Double\) -> Double \{.*?\n\}\n",
               "fn rec2020_to_linear_ch(v : Double) -> Double {\n  let sign = if v < 0.0 { -1.0 } else { 1.0 }\n  sign * f64_pow(f64_abs(v), 2.4)\n}\n", s, flags=re.S)
    s = re.sub(r"fn rec2020_from_linear_ch\(v : Double\) -> Double \{.*?\n\}\n",
               "fn rec2020_from_linear_ch(v : Double) -> Double {\n  let sign = if v < 0.0 { -1.0 } else { 1.0 }\n  sign * f64_pow(f64_abs(v), 1.0 / 2.4)\n}\n", s, flags=re.S)
    # current ED Bradford and ProPhoto matrices (derived from the chromaticities in spec_ref.py)
    for fn, m in [("xyz_d65_to_d50", R.D65_TO_D50), ("xyz_d50_to_d65", R.D50_TO_D65),
                  ("lin_prophoto_to_xyz_d50", R.TO_XYZ["prophoto-rgb"]), ("xyz_d50_to_lin_prophoto", R.FROM_XYZ["prophoto-rgb"])]:
        pat = re.compile(r"(fn %s\([^)]*\) -> \(Double, Double, Double\) \{\n  mat3_mul\(\n)(.*?)(,\n    [a-z]+,\n    [a-z]+,\n    [a-z]+,\n  \)\n\})" % fn, re.S)
        assert pat.search(s), fn
        s = pat.sub(lambda mo: mo.group(1) + ",\n".join("    %r" % float(v) for row in m for v in row) + mo.group(3), s)
    f["space.pion"] = s


STAGES = [("P1-1", p1_1), ("P2-8", p2_8), ("P1-2", p1_2), ("P2-7", p2_7), ("P2-11", p2_11), ("P2-12", p2_12),
          ("P2-9", p2_9), ("P2-2", p2_2)]


def main():
    pkg, out = sys.argv[1], sys.argv[2]
    names = ["math.pion", "mix.pion", "parser.pion", "space.pion"]
    f = {n: open(os.path.join(pkg, "src", n), encoding="utf-8").read() for n in names}
    for k, (fid, fn) in enumerate(STAGES, 1):
        fn(f)
        d = os.path.join(out, "stage%d" % k, "css_color")
        if os.path.exists(os.path.dirname(d)):
            shutil.rmtree(os.path.dirname(d))
        shutil.copytree(pkg, d, ignore=shutil.ignore_patterns("bench", "wasm_smoke", "*_test.pion"))
        for n in names:
            with open(os.path.join(d, "src", n), "w", encoding="utf-8") as fh:
                fh.write(f[n])
        print(k, fid)


if __name__ == "__main__":
    main()
