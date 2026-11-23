"""Geometry differential: Pion `to_cubic_beziers` / `path_bbox` / `path_length` / `flatten_path` versus an
independent Python reference (W3C SVG 1.1 F.6.5 / F.6.6 arc centre parameterisation with libm, smooth
reflection rules, exact cubic extrema, dense Gauss-Legendre arc length) and Rust svgtypes+kurbo 0.11.3.
Usage: geom_check.py [fuzz]"""
import math, os, random, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import run, f64, Ledger, SEP

HAND = [
    ("all20", "M10 20m1 2L30 40l3 4H50h5V60v6C1 2 3 4 5 6c1 2 3 4 5 6S7 8 9 10s1 2 3 4Q11 12 13 14q1 2 3 4T15 16t1 2A25 25-30 0 1 50-25a10 20 45 1 0 5 5Zz"),
    ("S-after-S", "M0 0C10 20 30 20 40 0S70-20 80 0s30 20 40 0"),
    ("S-after-Q", "M0 0Q20 30 40 0S60 30 80 0"),
    ("S-first", "M5 5S20 30 40 0"),
    ("T-chain", "M0 0Q10 20 20 0T40 0T60 0t20 0t20 0"),
    ("T-after-C", "M0 0C10 20 30 20 40 0T80 0"),
    ("T-after-L", "M0 0L10 10T30 0"),
    ("T-after-A", "M0 0A10 10 0 0 1 20 0T40 0"),
    ("Q-after-T-reset", "M0 0Q10 10 20 0T40 0L50 0T70 0"),
    ("Z-then-rel-l", "M10 10l10 0 0 10zl5 5"),
    ("Z-then-rel-c", "M10 10h10v10zc1 2 3 4 5 6"),
    ("Z-then-rel-a", "M10 10h10v10za5 5 0 0 1 10 0"),
    ("Z-then-rel-m", "m10 10h10v10zm5 5h1"),
    ("Z-then-S", "M0 0C10 10 20 10 30 0ZS10 10 20 0"),
    ("multi-Z", "M0 0h10v10zM20 20h5v5zz"),
    ("arc-rx0", "M0 0A0 10 0 0 1 10 10"),
    ("arc-ry0", "M0 0A10 0 0 0 1 10 10"),
    ("arc-neg-radii", "M0 0A-10-20 30 1 0 15 5"),
    ("arc-same-point", "M5 5A10 10 0 0 1 5 5L6 6"),
    ("arc-too-small", "M0 0A1 1 0 0 1 100 0"),
    ("arc-too-small-rot", "M0 0A1 3 37 1 1 100 40"),
    ("arc-rot-360000", "M0 0A30 10 360000 0 1 40 20"),
    ("arc-rot-neg720", "M0 0A30 10 -720 1 0 40 20"),
    ("arc-rot-1e7", "M0 0A30 10 10000045 0 1 40 20"),
    ("arc-aspect-1e6", "M0 0A1000000 1 0 0 1 10 1"),
    ("arc-aspect-1e-6", "M0 0A0.000001 50 0 1 1 0 60"),
    ("arc-large-sweep", "M0 0A50 50 0 1 1 0.001 0"),
    ("arc-large-nosweep", "M0 0A50 50 0 1 0 0.001 0"),
    ("arc-big-radius-small-span", "M0 0A100000 100000 0 0 1 1 0"),
    ("arc-big-radius-tiny-span", "M1000 1000A1000000 1000000 0 0 1 1000.001 1000"),
    ("arc-half", "M0 0A10 10 0 0 1 20 0"),
    ("arc-half-rot", "M0 0A10 20 45 1 0 20 0"),
    ("arc-compact", "M0 0a25 25 0 0150 25"),
    ("circle-2arcs", "M-5 0A5 5 0 1 0 5 0A5 5 0 1 0-5 0Z"),
    ("cusp", "M0 0C100 100 -100 100 0 0"),
    ("self-intersect", "M0 0C100 100 0 100 100 0"),
    ("inflection", "M0 0C30 60 70 -60 100 0"),
    ("degenerate-line-cubic", "M0 0C10 10 20 20 30 30"),
    ("degenerate-point-cubic", "M5 5C5 5 5 5 5 5"),
    ("collinear-overshoot", "M0 0C100 0 -50 0 50 0"),
    ("quad-overshoot", "M0 0Q100 100 0 0"),
    ("tiny-scale-cubic", "M0 0C0 1e-13 1e-13 1e-13 1e-13 0"),
    ("tiny-scale-cubic2", "M0 0C0 3e-9 1e-9 3e-9 1e-9 0"),
    ("huge-coords", "M1e12 1e12C2e12 3e12 -1e12 2e12 1.5e12 1e12"),
    ("only-M", "M10 10"),
    ("M-M", "M10 10M20 20"),
    ("trailing-M", "M0 0L10 10M100 100"),
    ("empty", ""),
    ("H-V-chain", "M1 1H5V5H1V1h3v3h-3z"),
]

GL = [(-0.9739065285171717, 0.0666713443086881), (-0.8650633666889845, 0.1494513491505806),
      (-0.6794095682990244, 0.2190863625159820), (-0.4333953941292472, 0.2692667193099963),
      (-0.1488743389816312, 0.2955242247147529), (0.1488743389816312, 0.2955242247147529),
      (0.4333953941292472, 0.2692667193099963), (0.6794095682990244, 0.2190863625159820),
      (0.8650633666889845, 0.1494513491505806), (0.9739065285171717, 0.0666713443086881)]


def tokens(d):
    """Tiny reference tokenizer (only for well-formed corpora; the grammar is audited in path_diff.py).
    Arc flags are single characters (W3C grammar), so `a25 25 0 0150 25` tokenizes correctly."""
    out, i, n, cmd, argi = [], 0, len(d), "", 0
    while i < n:
        c = d[i]
        if c in "MmLlHhVvCcSsQqTtAaZz":
            out.append(c); i += 1; cmd = c.upper(); argi = 0
        elif c in " \t\n\r\f,":
            i += 1
        elif cmd == "A" and argi % 7 in (3, 4):
            out.append(float(c)); i += 1; argi += 1
        else:
            j = i
            if d[j] in "+-": j += 1
            while j < n and d[j].isdigit(): j += 1
            if j < n and d[j] == ".":
                j += 1
                while j < n and d[j].isdigit(): j += 1
            if j < n and d[j] in "eE" and j + 1 < n and (d[j + 1].isdigit() or (d[j + 1] in "+-" and j + 2 < n and d[j + 2].isdigit())):
                j += 2
                while j < n and d[j].isdigit(): j += 1
            out.append(float(d[i:j])); i = j; argi += 1
    return out


def reference(d):
    """Absolute normalised segments: ('M',x,y) ('L',x,y) ('C',x1,y1,x2,y2,x,y) ('A',arcdict) ('Z',)."""
    t = tokens(d)
    segs, i, cmd = [], 0, None
    cx = cy = sx = sy = 0.0
    lcx = lcy = 0.0
    last = None
    ar = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}
    while i < len(t):
        if isinstance(t[i], str):
            cmd = t[i]; i += 1
            if cmd in "Zz":
                segs.append(("Z",)); cx, cy = sx, sy; last = None; cmd = None
                continue
        U = cmd.upper(); rel = cmd.islower()
        a = t[i:i + ar[U]]; i += ar[U]
        ox, oy = (cx, cy) if rel else (0.0, 0.0)
        if U == "M":
            cx, cy = a[0] + ox, a[1] + oy; sx, sy = cx, cy; segs.append(("M", cx, cy)); last = None
            cmd = "l" if rel else "L"
        elif U == "L":
            cx, cy = a[0] + ox, a[1] + oy; segs.append(("L", cx, cy)); last = None
        elif U == "H":
            cx = a[0] + ox; segs.append(("L", cx, cy)); last = None
        elif U == "V":
            cy = a[0] + oy; segs.append(("L", cx, cy)); last = None
        elif U in "CS":
            if U == "C":
                x1, y1, x2, y2, x, y = a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy, a[4] + ox, a[5] + oy
            else:
                x1, y1 = (2 * cx - lcx, 2 * cy - lcy) if last == "C" else (cx, cy)
                x2, y2, x, y = a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy
            segs.append(("C", x1, y1, x2, y2, x, y)); lcx, lcy = x2, y2; last = "C"; cx, cy = x, y
        elif U in "QT":
            if U == "Q":
                qx, qy, x, y = a[0] + ox, a[1] + oy, a[2] + ox, a[3] + oy
            else:
                qx, qy = (2 * cx - lcx, 2 * cy - lcy) if last == "Q" else (cx, cy)
                x, y = a[0] + ox, a[1] + oy
            segs.append(("C", cx + 2 / 3 * (qx - cx), cy + 2 / 3 * (qy - cy), x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y), x, y))
            lcx, lcy = qx, qy; last = "Q"; cx, cy = x, y
        elif U == "A":
            x, y = a[5] + ox, a[6] + oy
            segs.append(("A", arc_param(cx, cy, a[0], a[1], a[2], a[3] != 0, a[4] != 0, x, y)))
            cx, cy = x, y; last = None
    return segs


def arc_param(x1, y1, rx, ry, rot, fa, fs, x2, y2):
    """W3C SVG 1.1 F.6.5 + F.6.6 (radii correction), straight from the spec text, libm trig."""
    if x1 == x2 and y1 == y2:
        return dict(kind="skip", x2=x2, y2=y2)
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0:
        return dict(kind="line", x2=x2, y2=y2)
    phi = math.radians(rot % 360.0)
    c, s = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = c * dx + s * dy, -s * dx + c * dy
    lam = (x1p / rx) ** 2 + (y1p / ry) ** 2
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    k = math.sqrt(max(0.0, num / den)) if den else 0.0
    if fa == fs:
        k = -k
    cxp, cyp = k * rx * y1p / ry, -k * ry * x1p / rx
    cx = c * cxp - s * cyp + (x1 + x2) / 2
    cy = s * cxp + c * cyp + (y1 + y2) / 2
    th1 = math.atan2((y1p - cyp) / ry, (x1p - cxp) / rx)
    th2 = math.atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx)
    dth = th2 - th1
    if not fs and dth > 0:
        dth -= 2 * math.pi
    elif fs and dth < 0:
        dth += 2 * math.pi
    return dict(kind="arc", cx=cx, cy=cy, rx=rx, ry=ry, c=c, s=s, th1=th1, dth=dth, x2=x2, y2=y2)


def cubic_pt(p, t):
    m = 1 - t
    return (m * m * m * p[0] + 3 * m * m * t * p[2] + 3 * m * t * t * p[4] + t * t * t * p[6],
            m * m * m * p[1] + 3 * m * m * t * p[3] + 3 * m * t * t * p[5] + t * t * t * p[7])


def cubic_extrema(p):
    """Exact 1-D extrema of each coordinate (derivative roots, cancellation-free quadratic formula)."""
    pts = [(p[0], p[1]), (p[6], p[7])]
    for k in (0, 1):
        p0, p1, p2, p3 = p[k], p[k + 2], p[k + 4], p[k + 6]
        a = -p0 + 3 * p1 - 3 * p2 + p3
        b = 2 * (p0 - 2 * p1 + p2)
        cc = p1 - p0
        roots = []
        if a == 0:
            if b != 0:
                roots.append(-cc / b)
        else:
            disc = b * b - 4 * a * cc
            if disc >= 0:
                q = -0.5 * (b + math.copysign(math.sqrt(disc), b))
                if q != 0:
                    roots += [q / a, cc / q]
                else:
                    roots.append(-b / (2 * a))
        for t in roots:
            if 0 < t < 1:
                pts.append(cubic_pt(p, t))
    return pts


def cubic_len(p, depth=0):
    def speed(t):
        m = 1 - t
        dx = 3 * m * m * (p[2] - p[0]) + 6 * m * t * (p[4] - p[2]) + 3 * t * t * (p[6] - p[4])
        dy = 3 * m * m * (p[3] - p[1]) + 6 * m * t * (p[5] - p[3]) + 3 * t * t * (p[7] - p[5])
        return math.hypot(dx, dy)
    tot, N = 0.0, 64
    for k in range(N):
        a, b = k / N, (k + 1) / N
        tot += sum(w * speed((a + b) / 2 + (b - a) / 2 * x) for x, w in GL) * (b - a) / 2
    return tot


def pion_geom(out):
    lines = out.split("\n")
    if lines[0] != "OK":
        return None
    i, cub = 2, []
    while lines[i] != "BBOX" and not lines[i].startswith("BBOX"):
        f = lines[i].split()
        cub.append((f[0], [f64(x) for x in f[1:]]))
        i += 1
    bb = lines[i].split()[1:]
    bbox = None if bb == ["NONE"] else [f64(x) for x in bb]
    length = f64(lines[i + 1].split()[1])
    polys, flat_err = [], lines[i + 2].strip() == "FLAT ERR"
    for l in lines[i + 3:]:
        f = l.split()
        pts = [f64(x) for x in f[2:]]
        polys.append((f[1] == "1", list(zip(pts[0::2], pts[1::2]))))
    return dict(cubics=cub, bbox=bbox, length=length, polys=polys, flat_err=flat_err)


def seg_dist(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    L = vx * vx + vy * vy
    t = 0.0 if L == 0 else max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / L))
    return math.hypot(px - (ax + t * vx), py - (ay + t * vy))


def check_one(name, d, tol, g, rk, stats):
    """Returns list of (category, message) problems."""
    probs = []
    ref = reference(d)
    cub = g["cubics"]
    # --- 1. normalisation: walk reference segments against Pion cubics
    ci, cx, cy, sx, sy = 0, 0.0, 0.0, 0.0, 0.0
    allpts = []
    scale = 1.0
    for r in ref:
        for v in r[1:] if r[0] != "A" else (r[1]["x2"], r[1]["y2"]):
            scale = max(scale, abs(v))
    eps = 1e-12 * scale
    for r in ref:
        if r[0] in "MLC":
            if ci >= len(cub) or cub[ci][0] != r[0]:
                probs.append(("normalize", f"expected {r[0]} at cubic #{ci}, got {cub[ci][0] if ci < len(cub) else 'END'}"))
                return probs
            vals = cub[ci][1]
            if any(abs(a - b) > eps for a, b in zip(vals, r[1:])):
                probs.append(("normalize", f"{r[0]} #{ci}: pion={vals} ref={list(r[1:])}"))
            ci += 1
            if r[0] == "C":
                allpts += [("C", (cx, cy) + tuple(vals))]
            elif r[0] == "L":
                allpts += [("L", (cx, cy) + tuple(vals))]
            cx, cy = r[-2], r[-1]
            if r[0] == "M":
                sx, sy = cx, cy
                allpts.append(("P", (cx, cy)))
        elif r[0] == "Z":
            if ci >= len(cub) or cub[ci][0] != "Z":
                probs.append(("normalize", f"expected Z at #{ci}"))
                return probs
            ci += 1
            if (cx, cy) != (sx, sy):
                allpts.append(("L", (cx, cy, sx, sy)))
            cx, cy = sx, sy
        else:
            a = r[1]
            if a["kind"] == "skip":
                continue
            if a["kind"] == "line":
                if ci >= len(cub) or cub[ci][0] != "L" or abs(cub[ci][1][0] - a["x2"]) > eps or abs(cub[ci][1][1] - a["y2"]) > eps:
                    probs.append(("arc-degenerate", f"rx/ry=0 arc must become a straight line (F.6.2), got {cub[ci] if ci < len(cub) else 'END'}"))
                    return probs
                allpts.append(("L", (cx, cy, a["x2"], a["y2"])))
                ci += 1; cx, cy = a["x2"], a["y2"]
                continue
            k0 = ci
            while ci < len(cub) and cub[ci][0] == "C" and (ci == k0 or (cub[ci - 1][1][4], cub[ci - 1][1][5]) != (a["x2"], a["y2"])):
                ci += 1
            pieces = cub[k0:ci]
            if not pieces or (pieces[-1][1][4], pieces[-1][1][5]) != (a["x2"], a["y2"]):
                probs.append(("arc", f"arc cubics do not end exactly at the endpoint {a['x2'], a['y2']}"))
                return probs
            rmax = max(a["rx"], a["ry"])
            worst_r, worst_ang, prev_ang = 0.0, 0.0, None
            px, py = cx, cy
            u_all = []
            for _, v in pieces:
                p = (px, py) + tuple(v)
                allpts.append(("C", p))
                for k in range(17):
                    X, Y = cubic_pt(p, k / 16)
                    dx, dy = X - a["cx"], Y - a["cy"]
                    ux = (a["c"] * dx + a["s"] * dy) / a["rx"]
                    uy = (-a["s"] * dx + a["c"] * dy) / a["ry"]
                    rr = math.hypot(ux, uy)
                    worst_r = max(worst_r, abs(rr - 1) * min(a["rx"], a["ry"]) / rmax)
                    u_all.append(math.atan2(uy, ux))
                px, py = v[4], v[5]
            # unwrap angles and compare with th1 .. th1+dth
            un = [u_all[0]]
            for ang in u_all[1:]:
                dlt = (ang - un[-1] + math.pi) % (2 * math.pi) - math.pi
                un.append(un[-1] + dlt)
            off = round((un[0] - a["th1"]) / (2 * math.pi)) * 2 * math.pi
            start_err = abs(un[0] - off - a["th1"])
            end_err = abs(un[-1] - off - (a["th1"] + a["dth"]))
            stats["arc_rel_err"] = max(stats.get("arc_rel_err", 0), worst_r)
            stats["arc_ang_err"] = max(stats.get("arc_ang_err", 0), start_err, end_err)
            if worst_r > 1e-3 or start_err > 1e-6 or end_err > 1e-6:
                probs.append(("arc", f"arc deviates from W3C F.6.5 ellipse: radial {worst_r:.3g}*r, start angle err {start_err:.3g}, end angle err {end_err:.3g} rad"))
            cx, cy = a["x2"], a["y2"]
    if ci != len(cub):
        probs.append(("normalize", f"{len(cub) - ci} extra cubic segments"))
    # --- 2. bbox: exact extrema of Pion's own cubics (+ M points, as documented by Pion)
    pts = []
    for kind, p in allpts:
        if kind == "P":
            pts.append(p)
        elif kind == "L":
            pts += [(p[0], p[1]), (p[2], p[3])]
        else:
            pts += cubic_extrema(p)
    if pts:
        ex = [min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts)]
        span = max(ex[2] - ex[0], ex[3] - ex[1], 1e-300)
        mag = max(abs(v) for v in ex) or 1.0
        if g["bbox"] is None:
            probs.append(("bbox", "bbox None for a non-empty path"))
        else:
            err = max(abs(a - b) for a, b in zip(g["bbox"], ex))
            stats["bbox_rel_err"] = max(stats.get("bbox_rel_err", 0), err / span)
            if err > 1e-9 * span + 4e-16 * mag:
                probs.append(("bbox", f"bbox {g['bbox']} vs exact {ex} (err {err:.3g} = {err / span:.3g} of extent)"))
    # --- 3. path_length vs dense GL integration of the same cubics
    tot = 0.0
    for kind, p in allpts:
        if kind == "L":
            tot += math.hypot(p[2] - p[0], p[3] - p[1])
        elif kind == "C":
            tot += cubic_len(p)
    if tot > 0:
        rel = abs(g["length"] - tot) / tot
        stats["len_rel_err"] = max(stats.get("len_rel_err", 0), rel)
        if rel > 1e-6:
            probs.append(("length", f"path_length {g['length']!r} vs {tot!r} (rel {rel:.3g})"))
    # --- 4. flatten: every point of every cubic must be within `tol` of the polyline piece
    if not g["flat_err"]:
        worst = 0.0
        flat_pts = [pt for _c, ps in g["polys"] for pt in ps]
        idx = 0
        for kind, p in allpts:
            if kind != "C":
                continue
            start, end = (p[0], p[1]), (p[6], p[7])
            try:
                a0 = flat_pts.index(start, max(0, idx - 1))
                a1 = flat_pts.index(end, a0 + 1)
            except ValueError:
                continue
            piece = flat_pts[a0:a1 + 1]
            idx = a1
            for k in range(1, 256):
                X, Y = cubic_pt(p, k / 256)
                dmin = min(seg_dist(X, Y, *piece[j], *piece[j + 1]) for j in range(len(piece) - 1)) if len(piece) > 1 else math.hypot(X - piece[0][0], Y - piece[0][1])
                worst = max(worst, dmin)
        stats["flat_ratio"] = max(stats.get("flat_ratio", 0), worst / tol)
        if worst > tol * (1 + 1e-9):
            probs.append(("flatten", f"flatten_path(tol={tol}) max deviation {worst:.4g} = {worst / tol:.2f} x tolerance"))
    # --- 5. Rust svgtypes+kurbo cross-check (bbox/perimeter; kurbo's arc approximation uses tol 0.1)
    if rk.startswith("OK") and g["bbox"] is not None and not any(r[0] == "A" for r in ref) and not any(r[0] == "M" for r in ref[1:]):
        kv = [f64(x) for x in rk.split()[1:]]
        span = max(kv[2] - kv[0], kv[3] - kv[1], 1e-300)
        if max(abs(a - b) for a, b in zip(g["bbox"], kv[:4])) > 1e-9 * span + 1e-15 * max(map(abs, kv[:4])):
            probs.append(("kurbo-bbox", f"pion bbox {g['bbox']} vs kurbo {kv[:4]}"))
        if kv[4] > 1e-3 and abs(g["length"] - kv[4]) / kv[4] > 1e-6:  # kurbo accuracy is absolute (1e-9)
            probs.append(("kurbo-len", f"pion length {g['length']!r} vs kurbo perimeter {kv[4]!r}"))
    return probs


def fuzz_path(rng):
    def n():
        return f"{rng.uniform(-200, 200):.{rng.randrange(0, 4)}f}"
    def r():
        return f"{rng.uniform(0.5, 150):.2f}"
    out = [f"M{n()} {n()}"]
    for _ in range(rng.randrange(1, 9)):
        c = rng.choice("LlHhVvCcSsQqTtAaZzM")
        if c in "Zz":
            out.append(c)
        elif c in "Aa":
            out.append(f"{c}{r()} {r()} {rng.uniform(-400, 400):.1f} {rng.randrange(2)} {rng.randrange(2)} {n()} {n()}")
        else:
            k = {"L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "M": 2}[c.upper()]
            out.append(c + " ".join(n() for _ in range(k)))
    return "".join(out)


def main():
    fuzz = int(sys.argv[1]) if len(sys.argv) > 1 else 1500
    rng = random.Random(7)
    cases = list(HAND) + [(f"fuzz{i}", fuzz_path(rng)) for i in range(fuzz)]
    tols = {}
    recs = []
    for name, d in cases:
        tol = 0.25 if not name.startswith("huge") else 1e3
        if name.startswith("tiny"):
            tol = 1e-16
        tols[name] = tol
        recs.append(f"{tol!r}{SEP}{d}")
    P = run("pion", "geom", recs)
    R = run("rust", "geom", [d for _, d in cases])
    L = Ledger("geom")
    by_cat, stats = {}, {}
    for (name, d), p, r in zip(cases, P, R):
        g = pion_geom(p)
        if g is None:
            by_cat.setdefault("parse", []).append((name, d, "pion rejected a well-formed path"))
            continue
        for cat, msg in check_one(name, d, tols[name], g, r, stats):
            by_cat.setdefault(cat, []).append((name, d, msg))
    print("  max errors: " + ", ".join(f"{k}={v:.3g}" for k, v in sorted(stats.items())))
    for cat, items in sorted(by_cat.items()):
        print(f"  [{cat}] {len(items)} cases")
        for name, d, msg in items[:6]:
            print(f"    {name}: {d[:90]!r}\n      {msg[:300]}")
    def has(cat, pred=lambda n: True):
        return [x for x in by_cat.get(cat, []) if pred(x[0])]
    hand = lambda n: not n.startswith("fuzz")
    L.check("normalize: implicit L/l, H/V, Q->C elevation, S/s & T/t reflection chains, Z + relative base = reference",
            not has("normalize"), "P1", (has("normalize") or [("", "", "")])[0][2][:200])
    L.check("arcs: F.6.2 rx=0/ry=0 -> straight line, F.6.6 radii scaling, |r| for negative radii, sweep/large-arc direction",
            not has("arc-degenerate") and not has("arc", hand), "P1", (has("arc-degenerate") + has("arc", hand) or [("", "", "")])[0][2][:200])
    L.check("arcs (fuzz 1500): every arc approximation within 1e-3*r and endpoints/angles within 1e-6 rad",
            not has("arc"), "P1", f"{len(has('arc'))} fuzz arcs" if has("arc") else "")
    L.check("path_bbox: exact extrema of the cubics (relative error <= 1e-9 of extent) incl. scale-invariance (1e-13 curves)",
            not has("bbox"), "P2", (has("bbox") or [("", "", "")])[0][0] + " " + (has("bbox") or [("", "", "")])[0][2][:200])
    L.check("path_length: relative error <= 1e-6 (the documented GL5 tolerance)", not has("length"), "P2",
            (has("length") or [("", "", "")])[0][2][:200])
    L.check("flatten_path(tol): every curve point within `tol` of the polyline (documented contract)",
            not has("flatten"), "P1", f"{len(has('flatten'))} paths; worst ratio {stats.get('flat_ratio', 0):.2f}x tolerance")
    L.check("kurbo 0.11.3 cross-check: bbox & perimeter agree on non-arc paths", not has("kurbo-bbox") and not has("kurbo-len"),
            "P2", ((has("kurbo-bbox") + has("kurbo-len")) or [("", "", "")])[0][2][:200])
    L.check("well-formed corpus accepted", not has("parse"), "P1")
    sys.exit(L.save())


if __name__ == "__main__":
    main()
