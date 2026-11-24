#!/usr/bin/env python3
"""Color::to_gamut against the CSS Color 4 ED §13.2 binary-search gamut mapping (spec_ref.gamut_map).
  python3 -I gamut.py <gamut.cases> <pion run output> <pion gamut output>
`run` gives the parsed origin (native coordinates), `gamut` gives css_color's mapped color in the destination.
Checks per case: the result is in gamut (bounded destinations), an in-gamut origin is returned unchanged, L <= 0 maps
to black and L >= 1 to white, chroma never increases, and ΔE_OK(css_color, spec) is reported. Divergences larger than
0.0005 ΔE_OK are attributed with a Python port of css_color's loop (space.pion Color::to_gamut): the port must
reproduce css_color, and the port with the three P2-10 deviations removed (early exit returns the in-gamut `lo` color
instead of `clipped`; no step-11 "clip(origin) within JND" shortcut; epsilon 1e-5 instead of 1e-4) must reproduce the
spec. Exit 0 / 3 (known finding only) / 1 (P0: out of gamut, changed in-gamut color, unexplained)."""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare as C  # noqa: E402
import spec_ref as R  # noqa: E402


def pion_port(src, c, rgb, fixed=False):
    """css_color Color::to_gamut (space.pion) in Python; fixed=True applies the spec's step 11, epsilon and return."""
    direct = R.convert(src, c, rgb)
    if R.in_gamut(rgb, direct):
        return direct
    ok = R.convert(src, c, "oklch")
    if ok[0] >= 1.0:
        return [1.0, 1.0, 1.0]
    if ok[0] <= 0.0:
        return [0.0, 0.0, 0.0]
    jnd, eps = 0.02, (0.0001 if fixed else 0.00001)
    lo, hi, h, mig, it = 0.0, ok[1], ok[2], True, 0
    clipped = [min(1.0, max(0.0, v)) for v in direct]
    if fixed and R.delta_eok(rgb, clipped, src, c) < jnd:
        return clipped
    while hi - lo > eps and it < 64:
        mid = (lo + hi) / 2
        cand = [ok[0], mid, h]
        dst = R.convert("oklch", cand, rgb)
        if mig and R.in_gamut(rgb, dst):
            lo = mid
        else:
            clipped = [min(1.0, max(0.0, v)) for v in dst]
            e = R.delta_eok(rgb, clipped, "oklch", cand)
            if e < jnd:
                if jnd - e < eps:
                    if fixed:
                        return clipped
                    break
                mig = False
                lo = mid
            else:
                hi = mid
        it += 1
    if mig and not fixed:
        return [min(1.0, max(0.0, v)) for v in R.convert("oklch", [ok[0], lo, h], rgb)]
    return clipped


def main():
    cases = C.read_cases(sys.argv[1])
    runs = C.lines(sys.argv[2])
    maps = C.lines(sys.argv[3])
    assert len(cases) == len(runs) == len(maps)
    n = bad = shortcut = big = 0
    worst = (0.0, "")
    worst_h = (0.0, "")
    p0 = []
    iters = []
    for (dest, s), r, m in zip(cases, runs, maps):
        if not r.startswith("OK "):
            continue
        rec = C.pion_rec(r)
        if any(abs(v) > 1e6 for v in rec["c"]):
            continue  # absurd magnitudes: covered by the DoS / API sweeps
        n += 1
        w = m.split(" ")
        got = [C.fl(w[2]), C.fl(w[3]), C.fl(w[4])]
        gm = [ch == "1" for ch in w[6]]
        in_g = w[8] == "1"
        src = [0.0 if rec["m"][i] else rec["c"][i] for i in range(3)]
        ref, it = R.gamut_map(rec["space"], src, dest)
        iters.append(it)
        rgb = "srgb" if dest in ("hsl", "hwb") else dest
        got_rgb = R.convert(dest, [0.0 if (gm[i] or v != v) else v for i, v in enumerate(got)], rgb) if dest != rgb else got
        if rgb in R.RGB_SPACES and not all(-1e-9 <= v <= 1 + 1e-9 for v in got_rgb):
            p0.append("out of gamut: %s -> %s %s" % (s, dest, got))
            continue
        o = R.convert(rec["space"], src, "oklch")
        direct = R.convert(rec["space"], src, rgb)
        if R.in_gamut(rgb, direct) and 0 < o[0] < 1 and rec["tspace"] == dest and R.in_gamut(rgb, rec["t"] if dest == rgb else direct):
            d = max(abs(a - b) for a, b in zip(rec["t"], got))
            if d > 1e-12:
                p0.append("in-gamut origin changed: %s -> %s %s (%g)" % (s, dest, got, d))
            continue
        gok = R.convert(rgb, got_rgb, "oklch")
        if gok[1] > o[1] + 1e-6 and o[0] < 1 and o[0] > 0:
            p0.append("chroma increased: %s %g -> %g" % (s, o[1], gok[1]))
        e = R.delta_eok(rgb, got_rgb, rgb, R.convert(dest, ref, rgb) if dest != rgb else ref)
        if gok[1] > 0.02 and o[1] > 0.02 and 0.1 < o[0] < 0.95:
            dh = C.hue_diff(gok[2], o[2])
            if dh > worst_h[0]:
                worst_h = (dh, s + " -> " + dest)
        if e > 0.0005:
            port = pion_port(rec["space"], src, rgb)
            fixed = pion_port(rec["space"], src, rgb, fixed=True)
            spec_rgb = R.convert(dest, ref, rgb) if dest != rgb else ref
            if R.delta_eok(rgb, port, rgb, got_rgb) < 1e-6 and R.delta_eok(rgb, fixed, rgb, spec_rgb) < 1e-6:
                shortcut += 1
                if shortcut <= 3:
                    print("    P2-10 ΔE_OK %.4f %s -> %s css_color %s spec %s" % (e, s, dest, [round(v, 6) for v in got], [round(v, 6) for v in ref]))
            else:
                bad += 1
                if bad <= 10:
                    print("    UNEXPLAINED ΔE_OK %.4f %s -> %s pion %s spec %s" % (e, s, dest, got, ref))
        if e > 0.0005:
            big += 1
        if e > worst[0]:
            worst = (e, "%s -> %s" % (s, dest))
    print("  %d origins mapped: worst ΔE_OK(css_color, spec) %.4f (%s); %d > 0.0005" % (n, worst[0], worst[1], big))
    print("  spec binary-search iterations: max %d, mean %.1f; max hue drift of a chromatic result %.3f deg (%s)" % (
        max(iters), sum(iters) / max(1, len(iters)), worst_h[0], worst_h[1]))
    print("  divergences > 0.0005 reproduced by the port and removed by the P2-10 fix: %d" % shortcut)
    for x in p0[:10]:
        print("    P0 " + x)
    if p0 or bad:
        return 1
    if shortcut:
        print("FINDINGS P2-10")
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
