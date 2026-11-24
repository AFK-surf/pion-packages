#!/usr/bin/env python3
"""Comparators for the css_color red-team audit (stdlib only, run with python3 -I).

  compare.py same <a> <b>                                    byte-identical outputs (4-mode determinism)
  compare.py chrome <cases> <pion> <chrome> [examples]       acceptance + values vs headless Chrome golden
  compare.py wpt <vectors.tsv> <pion> [examples]             WPT css-color parsing vectors (pinned commit)
  compare.py spec <cases> <pion>                             pion convert() vs float64 spec_ref.py, per target space
  compare.py rust <cases> <pion> <rust>                      numeric agreement with Rust color =0.3.3 (f32)
  compare.py mixrust <pion> <rust mix output>                color-mix() values vs color 0.3.3 interpolate()
  compare.py roundtrip <cases> <pion>                        parse(to_css(c)) == c

Every divergence is attributed to a finding id of REPORT.md by the classifiers below; out-of-scope features are
counted separately. Exit status: 0 = clean, 3 = only divergences of known (open) findings, 1 = an unexplained
divergence (P0 for run_audit.sh). The last stdout line `FINDINGS <ids>` lists the open finding ids that reproduced."""
import math
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spec_ref as R  # noqa: E402

SCALE = {"srgb": [1, 1, 1], "srgb-linear": [1, 1, 1], "display-p3": [1, 1, 1], "a98-rgb": [1, 1, 1],
         "prophoto-rgb": [1, 1, 1], "rec2020": [1, 1, 1], "xyz-d50": [1, 1, 1], "xyz-d65": [1, 1, 1],
         "hsl": [360, 100, 100], "hwb": [360, 100, 100], "lab": [100, 125, 125], "lch": [100, 150, 360],
         "oklab": [1, 0.4, 0.4], "oklch": [1, 0.4, 360]}
FOUND = set()
STAGES = []  # [(finding id, [lines])] from fixmodel.py builds, see load_stages()
BASE = []  # the unmodified package's output the stages were built from (FIX_BASE); attribution needs equality


def load_stages(spec):
    """spec: `P1-1=<file>,P2-8=<file>,...` (cumulative fix-model outputs for the same case file)."""
    STAGES.clear()
    for item in [x for x in (spec or "").split(",") if x]:
        fid, path = item.split("=", 1)
        STAGES.append((fid, lines(path)))


def attribute(i, exp, tol, line):
    """First fix-model stage whose output for line i agrees with `exp`. Only lines on which the audited build agrees
    with the fix model's base build can be attributed (an injected bug must stay unexplained)."""
    if BASE and (i >= len(BASE) or BASE[i] != line):
        return None
    for fid, out in STAGES:
        r = pion_rec(out[i]) if i < len(out) else None
        if r is not None and value_error(r, exp, tol)[0] <= 1.0:
            return fid
    return None


def unhex(s):
    if s.startswith("hex:"):
        return bytes.fromhex(s[4:]).decode("utf-8", "replace")
    return s


def read_cases(path):
    out = []
    for line in open(path, encoding="utf-8").read().split("\n"):
        if line == "":
            continue
        t, s = line.split("\t", 1) if "\t" in line else ("-", line)
        out.append((t, unhex(s)))
    return out


def lines(path):
    return open(path, encoding="utf-8", errors="replace").read().rstrip("\n").split("\n")


def fl(x):
    """Pion side prints `b<IEEE-754 bits>` (exact and mode-independent); the Rust oracle prints decimals."""
    if x.startswith("b"):
        return struct.unpack("<d", struct.pack("<q", int(x[1:])))[0]
    return float(x)


def pion_rec(line):
    """OK <space> c0 c1 c2 a mask T <space> ... R .. C .. L .. P .. S css"""
    if not line.startswith("OK "):
        return None
    w = line.split(" ")
    rec = {"space": w[1], "c": [fl(w[2]), fl(w[3]), fl(w[4])], "a": fl(w[5]), "m": [ch == "1" for ch in w[6]],
           "tspace": w[8], "t": [fl(w[9]), fl(w[10]), fl(w[11])], "ta": fl(w[12]), "tm": [ch == "1" for ch in w[13]],
           "rgba8": [int(v) for v in w[15].split(",")], "clamped": [int(v) for v in w[17].split(",")],
           "lum": fl(w[19])}
    i = line.index(" P ") + 3
    j = line.index(" S ", i)
    p = line[i:j].split(" ")
    rec["rp"] = None if p[0] == "ERR" else {"space": p[0], "c": [fl(p[1]), fl(p[2]), fl(p[3])], "a": fl(p[4]),
                                            "m": [ch == "1" for ch in p[5]]}
    rec["css"] = line[j + 3:]
    return rec


SER = re.compile(r"^\s*([a-z-]+)\((.*)\)\s*$", re.S)


def parse_ser(s):
    """Parse a browser / WPT serialization: rgb()/rgba() legacy, color(), lab/lch/oklab/oklch/hsl/hwb modern."""
    try:
        return _parse_ser(s)
    except (ValueError, IndexError):
        return None


def _parse_ser(s):
    m = SER.match(s.strip())
    if not m:
        return None
    fn, body = m.group(1).lower(), m.group(2)
    legacy = "," in body
    if fn == "color":
        parts = body.split()
        sp = {"xyz": "xyz-d65"}.get(parts[0], parts[0])
        body = " ".join(parts[1:])
    else:
        sp = {"rgb": "srgb", "rgba": "srgb"}.get(fn, fn)
    alpha, ma = 1.0, False
    if legacy:
        vals = [v.strip() for v in body.split(",")]
        if len(vals) == 4:
            alpha = float(vals[3].rstrip("%")) / (100 if vals[3].endswith("%") else 1)
        vals = vals[:3]
    else:
        if "/" in body:
            body, a = body.split("/")
            a = a.strip()
            if a == "none":
                ma, alpha = True, 0.0
            else:
                alpha = float(a.rstrip("%")) / (100 if a.endswith("%") else 1)
        vals = body.split()
    if sp not in SCALE or len(vals) != 3:
        return None
    c, mm = [], []
    for i, v in enumerate(vals):
        if v == "none":
            c.append(0.0)
            mm.append(True)
            continue
        mm.append(False)
        x = float(v.rstrip("%").rstrip("deg"))
        if v.endswith("%") and sp in ("srgb",) and fn in ("rgb", "rgba"):
            x = x * 2.55
        c.append(x)
    if fn in ("rgb", "rgba"):
        c = [v / 255.0 for v in c]
    return {"space": sp, "c": c, "a": alpha, "m": mm + [ma], "legacy": fn in ("rgb", "rgba")}


def hue_diff(a, b):
    d = abs(a - b) % 360.0
    return min(d, 360.0 - d)


def to_space(rec, sp):
    c = [0.0 if rec["m"][i] else rec["c"][i] for i in range(3)]
    if rec["space"] == sp:
        return list(c)
    return R.convert(rec["space"], c, sp)


def value_error(rec, exp, abs_tol):
    """Largest channel error of pion `rec` against parsed expectation `exp` in exp's space, in units of `abs_tol`
    (<= 1 passes). Missing channels must match when the spaces are equal."""
    sp = exp["space"]
    got = to_space(rec, sp)
    worst, why = 0.0, ""
    hue_i = R.POLAR.get(sp)
    for i in range(3):
        if exp["m"][i]:
            if rec["space"] == sp and not rec["m"][i]:
                return 99.0, "expected none in channel %d" % i
            continue
        if rec["space"] == sp and rec["m"][i] and abs(exp["c"][i]) > abs_tol[i]:
            return 99.0, "unexpected none in channel %d" % i
        g = got[i]
        if exp["legacy"]:  # legacy rgb() serializations are clamped to 0..255
            g = min(1.0, max(0.0, g))
        if i == hue_i:
            chroma = exp["c"][1]
            if (sp in ("hsl",) and (chroma < 1e-3 or exp["c"][2] in (0.0, 100.0))) or (sp == "hwb" and exp["c"][1] + exp["c"][2] >= 99.99) \
                    or (sp in ("lch", "oklch") and chroma < 1e-3 * SCALE[sp][1]):
                continue
            if g != g:
                g = 0.0
            e = hue_diff(g, exp["c"][i]) / abs_tol[i]
        else:
            e = abs(g - exp["c"][i]) / abs_tol[i] if g == g else 99.0
        if e > worst:
            worst, why = e, "ch%d got %.6g want %.6g" % (i, g, exp["c"][i])
    ea = abs((0.0 if rec["m"][3] else rec["a"]) - exp["a"]) / 0.0051
    if exp["m"][3] and not rec["m"][3]:
        return 99.0, "expected alpha none"
    if ea > worst:
        worst, why = ea, "alpha got %.6g want %.6g" % (rec["a"], exp["a"])
    return worst, why


def tol_for(exp, eps):
    """Chrome serializes 6 significant digits and computes some paths in float32: 2e-3 of the reference range
    (0..1 spaces), 0.02 % of it for 0..100 / 0..360 ranges, relative for |values| > 1; legacy rgb() is integer."""
    if exp["legacy"]:
        return [0.5 / 255 + 1e-6] * 3
    if eps is not None:
        return [eps] * 3
    out = []
    for i, s in enumerate(SCALE[exp["space"]]):
        t = (2e-3 * s if s <= 1 else 0.02 * s / 100) * max(1.0, abs(exp["c"][i]) / s)
        if abs(exp["c"][i]) > s or exp["c"][i] < 0:  # out of the reference range: float32 error is amplified
            t = max(t, 3e-3 * abs(exp["c"][i]))
        out.append(t)
    return out


# --- classification of divergences (finding ids as in REPORT.md) ---

OUT_OF_SCOPE = [
    ("currentcolor", r"currentcolor"),
    ("system-color", r"\b(canvas|canvastext|linktext|visitedtext|activetext|buttonface|buttontext|buttonborder|field|"
                     r"fieldtext|highlight|highlighttext|selecteditem|selecteditemtext|mark|marktext|graytext|accentcolor|"
                     r"accentcolortext)\b"),
    ("css-wide-keyword", r"^\s*(inherit|initial|unset|revert|revert-layer)\s*$"),
    ("var()/env()", r"\b(var|env|attr)\("),
    ("light-dark()/contrast-color()/alpha()", r"\b(light-dark|contrast-color|alpha)\("),
    ("math function other than calc()", r"\b(sign|abs|min|max|clamp|round|mod|rem|sin|cos|tan|asin|acos|atan|atan2|pow|"
                                        r"sqrt|hypot|log|exp|progress|calc-size)\("),
    ("length unit in calc()", r"\d(em|px|cqw|cqh|vw|vh|rem|ex|ch)\b"),
    ("CSS comment / escape", r"/\*|\\"),
]


def out_of_scope(s):
    l = s.lower()
    for name, pat in OUT_OF_SCOPE:
        if re.search(pat, l):
            return name
    if l.count("(") > l.count(")"):
        return "unclosed ( at end of input (CSS auto-closes at EOF)"
    return None


def classify_accept(s, pion_ok, pion_line=""):
    """Finding id for an acceptance divergence, None if unexplained."""
    l = s.lower()
    if not pion_ok and pion_line == "ERR NonFiniteValue":
        return "P2-5"
    if pion_ok:  # pion accepts, the reference rejects
        if re.search(r"#[0-9a-f]+[g-z_]", l):
            return "P2-3"
        if "calc(" in l:
            return "P2-4"
        return None
    if "display-p3-linear" in l:
        return "P2-6"
    if re.search(r"color-mix\(\s*(?!in\b)", l) or _mix_arity(l):
        return "P2-6"
    if re.search(r"\b(infinity|nan)\b", l) or re.search(r"calc\([^)]*/\s*\(?\s*(0|g - g)\b", l) or "/ 0)" in l:
        return "P2-5"
    if "calc(" in l:
        return "P2-5"
    if re.search(r"\b\d+(\.\d+)?e\+?(309|[4-9]\d\d|\d{4,})", l) or re.search(r"\d{309,}", l) or re.search(r"e\d{4,}", l) \
            or re.search(r"1e308\d", l):
        return "P2-5"
    if re.search(r"\b0(\.0+)?%\s*,[^,]*\b0(\.0+)?%\s*\)", l) or re.search(r"\b0%\s*,\s*blue\s+0%", l) or "1e-400%" in l:
        return "P2-6"
    if re.search(r"from#", l):
        return "P2-3"
    return None


def _mix_arity(l):
    """True when some color-mix() has a number of colors other than 2 (single-colour / N-ary, CSS Color 5 ED)."""
    for m in re.finditer(r"color-mix\(", l):
        depth, commas = 0, 0
        for ch in l[m.end():]:
            if ch == "(":
                depth += 1
            elif ch == ")":
                if depth == 0:
                    break
                depth -= 1
            elif ch == "," and depth == 0:
                commas += 1
        if commas != 2:
            return True
    return False


def classify_value(s, rec, exp, oracle="chrome"):
    """Oracle-side explanations that no css_color fix can remove (checked by hand, see REPORT.md)."""
    l = s.lower()
    if oracle != "chrome":
        return None
    if "a98-rgb" in l or exp["space"] == "a98-rgb":
        return "ORACLE-chrome-a98"
    if re.search(r"hsla?\(\s*[^,\s)]+[\s,]+0*(1\d\d|[2-9]\d\d|\d{4,})(\.\d*)?%", l):
        # Chrome 159 keeps S > 100% in hsl() serializations but clamps it when resolving to sRGB (P2-9)
        return "ORACLE-chrome-hsl-s-over-100"
    if "rec2020" in l or exp["space"] == "rec2020":
        # Chrome 159 keeps the BT.2020 piecewise transfer; the CSS Color 4 ED (and WPT) moved to gamma 2.4 (P2-2).
        # Only reachable once a build follows the ED: the baseline agrees with Chrome on every rec2020 conversion.
        return "ORACLE-chrome-rec2020-pre-ED"
    if re.search(r"(\d[eE]\+?\d{2,}|\d{15,}(\.\d*)?)\s*(rad|grad|turn)\b", l) or re.search(r"\d{17,}|\d[eE]\+?\d{3,}", l):
        return "ORACLE-ill-conditioned"
    polar = re.search(r"\b(in (hsl|hwb|lch|oklch)\b|(hsl|hwb|lch|oklch)\(from)", l)
    achromatic = re.search(r"\b(gray|grey|white|black|transparent|#808080)\b|\(\s*[\d.]+%?\s+(none|0|0\.00\d*|0\.0000\d*)\s", l) or \
        re.search(r"lch\([\d.]+%? (0|0\.00\d+)[ )]|oklch\([\d.]+%? (0|0\.0000\d+)[ )]|none", l)
    if polar and achromatic:
        return "ORACLE-chrome-powerless"
    return None


def cmd_chrome(cases_path, pion_path, chrome_path, nex=6):
    cases, pion, chrome = read_cases(cases_path), lines(pion_path), lines(chrome_path)
    assert len(cases) == len(pion) == len(chrome), (len(cases), len(pion), len(chrome))
    stats = {"both_ok": 0, "both_err": 0, "oos": 0, "value_ok": 0, "unparsed_expect": 0}
    by, unexplained = {}, []
    for idx, ((t, s), p, c) in enumerate(zip(cases, pion, chrome)):
        pok, cok = p.startswith("OK "), c != "I"
        if pok != cok:
            oos = out_of_scope(s)
            if oos:
                stats["oos"] += 1
                by.setdefault("out-of-scope: " + oos, []).append(s)
                continue
            fid = classify_accept(s, pok, p)
            if fid is None:
                unexplained.append(("pion %s, chrome %s" % ("accepts" if pok else "rejects (" + p + ")",
                                                            "accepts" if cok else "rejects"), s))
            else:
                FOUND.add(fid)
                by.setdefault(fid + (" over-accept" if pok else " under-accept"), []).append(s)
            continue
        if not pok:
            stats["both_err"] += 1
            continue
        stats["both_ok"] += 1
        exp = parse_ser(c.split("\t", 1)[1])
        if exp is None and re.search(r"infinity|nan", c.lower()):
            stats["oos"] += 1
            by.setdefault("out-of-scope: non-finite calc() result (chrome serializes calc(infinity))", []).append(s)
            continue
        if exp is None:
            stats["unparsed_expect"] += 1
            unexplained.append(("cannot parse chrome serialization " + c, s))
            continue
        rec = pion_rec(p)
        if any(abs(v) > 1e12 for v in rec["c"]) or any(abs(v) > 1e12 for v in exp["c"]):
            stats["value_ok"] += 1
            continue
        tol = tol_for(exp, None)
        err, why = value_error(rec, exp, tol)
        if err <= 1.0:
            stats["value_ok"] += 1
            continue
        fid = attribute(idx, exp, tol, p) or classify_value(s, rec, exp)
        if fid is None:
            unexplained.append(("value " + why + " (chrome " + c.split("\t", 1)[1] + ")", s))
        else:
            FOUND.add(fid)
            by.setdefault(fid + " value", []).append("%s  [%s; chrome %s]" % (s, why, c.split("\t", 1)[1]))
    print("  %d cases: both accept %d (values within tolerance %d), both reject %d, out-of-scope %d" % (
        len(cases), stats["both_ok"], stats["value_ok"], stats["both_err"], stats["oos"]))
    for k in sorted(by):
        print("    %-58s %5d  e.g. %s" % (k, len(by[k]), " | ".join(x[:90] for x in by[k][:nex])))
    for why, s in unexplained[:20]:
        print("    UNEXPLAINED %s :: %s" % (why, s[:160]))
    return 1 if unexplained else (3 if any(not k.startswith("out-of-scope") for k in by) else 0)


def unesc(s):
    return s.replace("\\t", "\t").replace("\\n", "\n").replace("\\\\", "\\")


def cmd_wpt(vec_path, pion_path, nex=6):
    vec = [l.split("\t") for l in lines(vec_path)]
    pion = lines(pion_path)
    assert len(vec) == len(pion)
    passed, oos, by, unexplained = 0, 0, {}, []
    for idx, ((kind, file, spec, expd, eps), p) in enumerate(zip(vec, pion)):
        s = unesc(spec)
        pok = p.startswith("OK ")
        want_ok = kind != "invalid"
        if pok != want_ok:
            o = out_of_scope(s)
            if o:
                oos += 1
                by.setdefault("out-of-scope: " + o, []).append(s)
                continue
            fid = classify_accept(s, pok, p)
            if fid is None:
                unexplained.append(("%s: pion %s, WPT %s" % (file, "accepts" if pok else "rejects", kind), s))
            else:
                FOUND.add(fid)
                by.setdefault(fid + (" over-accept" if pok else " under-accept"), []).append(s)
            continue
        if not pok or expd == "-":
            passed += 1
            continue
        alts = [parse_ser(unesc(e)) for e in expd.split(" || ")]
        alts = [a for a in alts if a is not None]
        if not alts:  # specified-value serializations such as color-mix(...) stay symbolic
            passed += 1
            continue
        rec = pion_rec(p)
        if any(abs(v) > 1e12 for v in rec["c"]):
            passed += 1
            continue
        e_tol = 0.01 if eps == "-" or eps.startswith("prop") else float(eps)
        tols = [tol_for(a, None) if a["legacy"] else [e_tol] * 3 for a in alts]
        best = min((value_error(rec, a, tl) + (a, tl) for a, tl in zip(alts, tols)), key=lambda x: x[0])
        if best[0] <= 1.0:
            passed += 1
            continue
        fid = attribute(idx, best[2], best[3], p) or classify_value(s, rec, best[2], "wpt")
        if fid is None:
            unexplained.append(("%s: value %s (want %s)" % (file, best[1], expd), s))
        else:
            FOUND.add(fid)
            by.setdefault(fid + " value", []).append("%s  [%s; want %s]" % (s, best[1], expd))
    print("  %d WPT vectors: %d pass, %d out-of-scope, %d divergent (known findings), %d unexplained" % (
        len(vec), passed, oos, sum(len(v) for k, v in by.items() if not k.startswith("out-of-scope")), len(unexplained)))
    for k in sorted(by):
        print("    %-58s %5d  e.g. %s" % (k, len(by[k]), " | ".join(x[:90] for x in by[k][:nex])))
    for why, s in unexplained[:30]:
        print("    UNEXPLAINED %s :: %s" % (why, s[:160]))
    return 1 if unexplained else (3 if any(not k.startswith("out-of-scope") for k in by) else 0)


def cmd_chromewpt(vec_path, chrome_path):
    """Context for the oracle: how often headless Chrome itself disagrees with the pinned WPT vectors, per file."""
    vec = [l.split("\t") for l in lines(vec_path)]
    chrome = lines(chrome_path)
    per = {}
    for (kind, file, spec, expd, eps), c in zip(vec, chrome):
        st = per.setdefault(file, [0, 0])
        cok = c != "I"
        if (kind == "invalid") == cok:
            st[1] += 1
            continue
        if not cok or expd == "-" or not kind.startswith("computed"):
            st[0] += 1
            continue
        got = parse_ser(c.split("\t", 1)[1])
        alts = [a for a in (parse_ser(unesc(e)) for e in expd.split(" || ")) if a]
        if got is None or not alts:
            st[0] += 1
            continue
        e_tol = 0.01 if eps == "-" or eps.startswith("prop") else float(eps)
        ok = any(value_error(got, a, tol_for(a, None) if a["legacy"] else [e_tol] * 3)[0] <= 1.0 for a in alts)
        st[0 if ok else 1] += 1
    tot = [sum(v[0] for v in per.values()), sum(v[1] for v in per.values())]
    print("  headless Chrome on the same %d WPT vectors: %d agree, %d disagree" % (tot[0] + tot[1], tot[0], tot[1]))
    for f in sorted(per, key=lambda k: -per[k][1])[:8]:
        if per[f][1]:
            print("    %-48s Chrome disagrees with %4d / %4d" % (f, per[f][1], sum(per[f])))
    return 0


def cmd_spec(cases_path, pion_path, constants="ed"):
    """pion T (= c.convert(target)) against spec_ref.convert(native coords) per target space. With
    constants=package, spec_ref uses css_color's own constants, so the residual is the software math error alone
    (gate: <= 1e-9 of the reference range); with constants=ed it also shows the constant drift (P2-2).
    HSL/HWB targets inside the ED near-white/black guard are counted for P1-1 and skipped."""
    if constants == "package":
        R.use_package_constants()
    cases, pion = read_cases(cases_path), lines(pion_path)
    worst, guard = {}, 0
    for (t, s), p in zip(cases, pion):
        rec = pion_rec(p)
        if rec is None or rec["tspace"] not in SCALE:
            continue
        if any(abs(v) > 1e6 for v in rec["c"]):
            continue
        ref = to_space(rec, rec["tspace"])
        if rec["tspace"] in ("hsl", "hwb"):
            rgb = to_space(rec, "srgb")
            li = (max(rgb) + min(rgb)) / 2
            if abs(li) <= 1e-5 or abs(1 - li) < 1e-5 or ref[0] != ref[0]:
                if any(abs(rec["t"][i] - ref[i]) > 1e-6 for i in (1, 2)):
                    guard += 1
                continue
        hi = R.POLAR.get(rec["tspace"])
        for i in range(3):
            if rec["tm"][i] or ref[i] != ref[i]:
                continue
            if i == hi and ref[1] < 0.01 * SCALE[rec["tspace"]][1]:
                continue  # hue of a near-achromatic color is ill-conditioned
            if hi is not None and i == 1 and rec["tspace"] in ("lch", "oklch") and \
                    min(abs(rec["t"][1]), abs(ref[1])) <= (0.0015 if rec["tspace"] == "lch" else 0.000004):
                FOUND.add("P2-8")
                continue  # chroma inside the powerless epsilon (zeroed with a different threshold: P2-8)
            if rec["tspace"] == "a98-rgb" and abs(ref[i]) < 1e-6:
                continue  # pure-gamma transfer has an infinite slope at 0: 1e-17 residuals become 1e-8
            d = hue_diff(rec["t"][i], ref[i]) if i == hi else abs(rec["t"][i] - ref[i])
            rel = d / (SCALE[rec["tspace"]][i] * max(1.0, abs(ref[i]) / SCALE[rec["tspace"]][i]))
            if rel > worst.get(rec["tspace"], (0, "", ""))[0]:
                worst[rec["tspace"]] = (rel, rec["space"], s)
    bad = []
    for dst in R.SPACES:
        e, src, s = worst.get(dst, (0.0, "-", "-"))
        flag = ""
        if e > 1e-9:
            flag = "  > 1e-9"
            bad.append(dst)
        print("    -> %-13s max |pion - spec_ref| / range = %.2e  (from %s: %s)%s" % (dst, e, src, s[:60], flag))
    if guard:
        print("    %d HSL/HWB results inside the ED near-white/black guard differ (P1-1)" % guard)
        FOUND.add("P1-1")
    if constants == "package":
        print("  software math (constants equalised): %s" % ("FAIL > 1e-9: " + " ".join(bad) if bad else "all targets <= 1e-9"))
        return 1 if bad else (3 if guard else 0)
    if bad:
        FOUND.add("P2-2")
    return 3 if bad or guard else 0


def cmd_rust(cases_path, pion_path, rust_path):
    cases, pion, rust = read_cases(cases_path), lines(pion_path), lines(rust_path)
    n = acc = 0
    worst = (0.0, "")
    top = 0.0
    for (t, s), p, r in zip(cases, pion, rust):
        if not (p.startswith("OK ") and r.startswith("OK ")):
            continue
        rp, w = pion_rec(p), r.split(" ")
        rt = [fl(w[9]), fl(w[10]), fl(w[11])]
        rs = w[8]
        if rs != rec_space(rp) or any(abs(v) > 1e6 for v in rp["c"]):
            continue
        n += 1
        hi = R.POLAR.get(rs)
        e = 0.0
        for i in range(3):
            if rp["tm"][i]:
                continue
            if i == hi:
                if rp["t"][1] < 1e-3 * SCALE[rs][1] or (rs == "hsl" and rp["t"][1] < 0.1):
                    continue
                d = hue_diff(rp["t"][i], rt[i]) / 360
            else:
                d = abs(rp["t"][i] - rt[i]) / (SCALE[rs][i] * max(1.0, abs(rt[i]) / SCALE[rs][i]))
            e = max(e, d)
        top = max(top, e)
        if e < 2e-4:
            acc += 1
        elif e > worst[0]:
            worst = (e, "%s -> %s pion %s rust %s" % (s, rs, rp["t"], rt))
    print("  %d cases accepted by both: %d within 2e-4 of range (f32 oracle); max error %.2e of range %s" % (
        n, acc, top, worst[1][:150]))
    return 0 if n == acc else 3


def rec_space(rp):
    return rp["tspace"]


def cmd_mixrust(pion_path, rust_path):
    pion, rust = lines(pion_path), lines(rust_path)
    n = acc = 0
    worst = (0.0, "")
    by = {}
    for i, (p, r) in enumerate(zip(pion, rust)):
        if not (p.startswith("OK ") and r.startswith("OK ")):
            continue
        rp, w = pion_rec(p), r.split(" ")
        ps = R.convert(rp["space"], [0.0 if rp["m"][k] else rp["c"][k] for k in range(3)], "srgb")
        rs = [fl(w[9]), fl(w[10]), fl(w[11]), fl(w[12])]
        n += 1
        e = max(max(abs(ps[k] - rs[k]) for k in range(3)), abs(rp["a"] - rs[3]))
        if e < 2e-3:
            acc += 1
        else:
            by.setdefault("line", []).append((e, i + 1, ps, rs))
            if e > worst[0]:
                worst = (e, "line %d pion %s rust %s" % (i + 1, [round(v, 5) for v in ps + [rp["a"]]], rs))
    print("  color-mix: %d cases parsed by the Rust harness: %d within 2e-3 (sRGB); worst %.3g %s" % (n, acc, worst[0], worst[1]))
    return 0 if n == acc else 3


def cmd_roundtrip(cases_path, pion_path, nex=4):
    cases, pion = read_cases(cases_path), lines(pion_path)
    n = ok = 0
    by = {}
    for (t, s), p in zip(cases, pion):
        rec = pion_rec(p)
        if rec is None:
            continue
        n += 1
        rp = rec["rp"]
        good = rp is not None and rp["m"] == rec["m"]
        if good:
            a = to_space(rp, rec["space"]) if rp["space"] != rec["space"] else rp["c"]
            for i in range(3):
                if rec["m"][i]:
                    continue
                d = abs(a[i] - rec["c"][i])
                if R.POLAR.get(rec["space"]) == i:
                    d = hue_diff(a[i], rec["c"][i])
                if d > 1e-5 * max(1.0, abs(rec["c"][i])):
                    good = False
            if abs(rp["a"] - rec["a"]) > 1e-5:
                good = False
        if good:
            ok += 1
            continue
        if any(abs(v) >= 9.2e12 for v in rec["c"]):
            k = "P2-1 (|component| >= 2^63 / 1e6 is serialized as 9223372036854.775807)"
        elif rec["space"] == "hsl" and not (0 <= rec["c"][1] <= 100 and 0 <= rec["c"][2] <= 100):
            k = "P2-9 (hsl S > 100% / L outside 0..100 serialized, clamped again on re-parse)"
        elif (rec["space"] in ("lab", "lch") and not 0 <= rec["c"][0] <= 100) or \
                (rec["space"] in ("oklab", "oklch") and not 0 <= rec["c"][0] <= 1):
            k = "P2-1 (lab/oklab L outside the parse-time clamp range serialized as lab()/oklab())"
        else:
            k = "UNEXPLAINED"
        by.setdefault(k, []).append("%s -> %s" % (s, rec["css"]))
    lum_n = lum_bad = 0
    for (t, s), p in zip(cases, pion):
        rec = pion_rec(p)
        if rec is None or rec["space"] != "srgb" or any(rec["m"][:3]) or not all(0 <= v <= 1 for v in rec["c"]):
            continue
        lum_n += 1
        if abs(rec["lum"] - R.wcag_luminance_srgb(rec["c"])) > 1e-12:
            lum_bad += 1
    print("  %d parsed colors: parse(to_css(c)) == c for %d; WCAG relative_luminance of %d in-gamut sRGB colors: %d off by > 1e-12" % (
        n, ok, lum_n, lum_bad))
    if lum_bad:
        by.setdefault("UNEXPLAINED relative_luminance", []).append("%d colors" % lum_bad)
    for k in sorted(by):
        print("    %-70s %5d  e.g. %s" % (k, len(by[k]), " | ".join(x[:100] for x in by[k][:nex])))
        if k.startswith("P"):
            FOUND.add(k.split(" ")[0])
    return 1 if any(k.startswith("UNEXPLAINED") for k in by) else (3 if by else 0)


def main():
    cmd = sys.argv[1]
    if cmd == "same":
        a, b = open(sys.argv[2], "rb").read(), open(sys.argv[3], "rb").read()
        if a == b:
            return 0
        la, lb = a.split(b"\n"), b.split(b"\n")
        for i, (x, y) in enumerate(zip(la, lb)):
            if x != y:
                print("    first difference at line %d:\n      %s\n      %s" % (i + 1, x[:200], y[:200]))
                break
        return 1
    load_stages(os.environ.get("FIX_STAGES", ""))
    if os.environ.get("FIX_BASE"):
        BASE[:] = lines(os.environ["FIX_BASE"])
    rc = {"chrome": lambda: cmd_chrome(*sys.argv[2:5]), "wpt": lambda: cmd_wpt(*sys.argv[2:4]),
          "spec": lambda: cmd_spec(*sys.argv[2:5]), "chromewpt": lambda: cmd_chromewpt(*sys.argv[2:4]), "rust": lambda: cmd_rust(*sys.argv[2:5]),
          "mixrust": lambda: cmd_mixrust(*sys.argv[2:4]), "roundtrip": lambda: cmd_roundtrip(*sys.argv[2:4])}[cmd]()
    print("FINDINGS " + " ".join(sorted(FOUND)))
    return rc


if __name__ == "__main__":
    sys.exit(main())
