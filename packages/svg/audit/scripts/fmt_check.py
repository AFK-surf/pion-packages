"""`format_path` serializer audit: every output must be valid SVG path data (svgtypes 0.15.3 accepts it), keep the
segment list, and keep each number within half a unit of the requested precision (absolute coordinates, so the
relative-command rounding drift is visible). Edge numbers: -0, 1e-7, 2e9 boundary, 1e21, 1e306+, exponents."""
import os, random, sys
sys.path.insert(0, os.path.dirname(__file__))
from common import run, f64, Ledger, SEP
from geom_check import fuzz_path

EDGE = ["M0 0L-0 -0", "M0 0L-0.0004 0.0004", "M0 0L1e-7 -1e-7", "M0 0L0.5 -0.5", "M0 0L1.5 2.5", "M0 0L0.0005 0.0015",
        "M0 0L1999999.9995 -1999999.9995", "M0 0L2000000 2000001.5", "M0 0L123456789.123 -98765432.987",
        "M0 0L1e21 -1e21", "M0 0L1.5e300 0", "M0 0L1e306 1e307", "M0 0L1.7976931348623157e308 0", "M0 0L4294967296.5 0",
        "M.5.5L.5.5.5.5", "M1.5.5l.5.5", "M0 0a10 10 0 0110 10", "M0 0a.5.5 0 01.5.5", "M0 0h1e-9v-1e-9",
        "M0 0C.1.2.3.4.5.6", "M-1-2-3-4", "M0 0L999.9995 0.0005", "M0 0L9.99999999 -9.99999999",
        "M0 0" + "l.0004 0" * 1000, "M0 0" + "h.0006" * 500]


def main():
    rng = random.Random(17)
    paths = EDGE + [fuzz_path(rng) for _ in range(1500)]
    L = Ledger("fmt")
    bad_parse, bad_struct, bad_num, bad_abs = [], [], [], []
    for prec in (0, 3, 8):
        recs = [f"{prec}{SEP}{d}" for d in paths]
        F = run("pion", "fmt", recs)
        outs = [f[3:] if f.startswith("OK ") else None for f in F]
        R0 = run("rust", "path", paths)
        R1 = run("rust", "path", [o or "" for o in outs])
        tol = 0.5 * 10 ** -prec
        for d, o, r0, r1 in zip(paths, outs, R0, R1):
            if o is None or not r0.startswith("OK"):
                continue
            if not r1.startswith("OK"):
                bad_parse.append((prec, d, o))
                continue
            s0 = [l.split() for l in r0.split("\n")[1:]]
            s1 = [l.split() for l in r1.split("\n")[1:]]
            if [x[0] for x in s0] != [x[0] for x in s1]:
                bad_struct.append((prec, d, o))
                continue
            worst = 0.0
            for a, b in zip(s0, s1):
                for k, (x, y) in enumerate(zip(a[1:], b[1:])):
                    if a[0] in "Aa" and k in (3, 4):
                        if x != y:
                            worst = float("inf")
                        continue
                    xv, yv = f64(x), f64(y)
                    err = abs(xv - yv)
                    if err > tol * (1 + 1e-9) + 1e-14 * abs(xv):  # parse ulps are audited in path_diff.py
                        worst = max(worst, err)
            if worst:
                bad_num.append((prec, worst, d, o))
            # absolute positions (relative-command drift)
            def absolute(segs):
                cx = cy = sx = sy = 0.0
                pts = []
                for s in segs:
                    c, v = s[0], [f64(x) for x in s[1:]]
                    rel = c.islower()
                    U = c.upper()
                    if U == "Z":
                        cx, cy = sx, sy
                    elif U == "H":
                        cx = v[0] + (cx if rel else 0)
                    elif U == "V":
                        cy = v[0] + (cy if rel else 0)
                    else:
                        nx, ny = v[-2] + (cx if rel else 0), v[-1] + (cy if rel else 0)
                        cx, cy = nx, ny
                        if U == "M":
                            sx, sy = cx, cy
                    pts.append((cx, cy))
                return pts
            a0, a1 = absolute(s0), absolute(s1)
            dr = max((max(abs(p[0] - q[0]), abs(p[1] - q[1])) / max(1.0, abs(p[0]), abs(p[1])) for p, q in zip(a0, a1)), default=0)
            if dr > 4 * tol + 1e-12:
                bad_abs.append((prec, dr, d))
    for x in bad_parse[:6]:
        print(f"    INVALID prec={x[0]} d={x[1][:60]!r} -> {x[2][:80]!r}")
    for x in bad_struct[:4]:
        print(f"    STRUCT prec={x[0]} d={x[1][:60]!r} -> {x[2][:80]!r}")
    bad_num.sort(key=lambda x: -x[1])
    for x in bad_num[:8]:
        print(f"    NUM prec={x[0]} err={x[1]:.3g} d={x[2][:60]!r} -> {x[3][:80]!r}")
    for x in sorted(bad_abs, key=lambda x: -x[1])[:4]:
        print(f"    DRIFT prec={x[0]} rel-abs-err={x[1]:.3g} d={x[2][:80]!r}")
    L.check("format_path output always parses as SVG path data (no 'inf', 'nan', '1e+21' ambiguity)", not bad_parse, "P1",
            f"{len(bad_parse)} outputs, e.g. {bad_parse[0][2][:60]!r}" if bad_parse else "")
    L.check("format_path keeps the segment/command list (implicit-command elision is lossless)", not bad_struct, "P1",
            f"{len(bad_struct)} outputs" if bad_struct else "")
    L.check("format_path rounds every number to within 0.5*10^-precision (incl. values >= 2e9/10^p and |v| >= 1e21)",
            not bad_num, "P2", f"{len(bad_num)} outputs; worst err {bad_num[0][1]:.3g} prec={bad_num[0][0]} on {bad_num[0][2][:50]!r}" if bad_num else "")
    L.check("format_path relative commands: absolute positions stay within 4 rounding units (no cumulative drift)",
            not bad_abs, "P2", f"{len(bad_abs)} paths; worst {max(x[1] for x in bad_abs):.3g}" if bad_abs else "")
    sys.exit(L.save())


if __name__ == "__main__":
    main()
