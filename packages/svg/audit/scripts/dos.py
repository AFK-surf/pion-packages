"""DoS / crash probes in all 4 build modes (native debug/release, wasm32 debug/release under node):
0 SIGSEGV / SIGABRT / RangeError / wasm trap / OOM, bounded time and memory, identical stdout across modes,
plus a scaling probe for the quadratic `<g>` emptiness re-scan in optimize_svg."""
import os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import IMPLS, Ledger

MODES = ["pion", "pion_dbg", "wasm_rel", "wasm_dbg"]
QUICK = os.environ.get("QUICK") == "1"
PROBES = [
    ("nest_g", 200, 128), ("nest_g", 1000, 1016), ("nest_g", 20000, 20016), ("nest_g_extract", 20000, 20016),
    ("nest_g_opt", 1000, 1016), ("nest_g_opt", 20000, 20016), ("segs", 99999, 128), ("segs", 100001, 128),
    ("flatten_huge", 1, 128), ("flatten_tiny_tol", 20000, 128), ("extreme_numbers", 1, 128), ("big_attr", 300000, 128),
    ("wide_doc", 20000, 128), ("unclosed", 300000, 128),
]


def measure(cmd, timeout):
    t0 = time.time()
    try:
        r = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, timeout, 0, b"", b"TIMEOUT"
    dt = time.time() - t0
    m = re.search(rb"(\d+)\s+maximum resident set size", r.stderr)
    rss = int(m.group(1)) if m else 0
    return r.returncode, dt, rss, r.stdout, r.stderr


def main():
    L = Ledger("dos")
    crashes, slow, mismatch = [], [], []
    print(f"  {'probe':28s} " + " ".join(f"{m:>22s}" for m in MODES))
    for kind, n, depth in PROBES:
        outs, cells = {}, []
        for m in MODES:
            budget = 20 if m.startswith("pion") else 120
            rc, dt, rss, out, err = measure(IMPLS[m] + ["dos", kind, str(n), str(depth)], budget * 3)
            outs[m] = out
            bad = rc != 0 or b"RangeError" in err or b"RuntimeError" in err or b"unreachable" in err
            if rc is None:
                crashes.append((kind, n, m, "TIMEOUT"))
            elif bad:
                crashes.append((kind, n, m, f"rc={rc} {err[-200:]!r}"))
            if rc is not None and dt > budget:
                slow.append((kind, n, m, dt))
            cells.append(f"{'CRASH' if bad else 'ok'} {dt:6.2f}s {rss / 2**20:6.1f}MiB")
        print(f"  {kind + ' n=' + str(n) + ' d=' + str(depth):28s} " + " ".join(f"{c:>22s}" for c in cells))
        first = outs[MODES[0]].strip()
        print(f"      -> {first.decode(errors='replace')[:110]}")
        if len({o for o in outs.values()}) != 1:
            mismatch.append((kind, n, {k: v[:80] for k, v in outs.items()}))
    L.check("0 crash / signal / RangeError / wasm trap / timeout across 14 probes x 4 modes", not crashes, "P0", str(crashes[:4]))
    L.check("every probe within budget (native 20 s, wasm 120 s)", not slow, "P1", str(slow[:4]))
    L.check("DoS probe stdout byte-identical in native_rel / native_dbg / wasm_rel / wasm_dbg", not mismatch, "P1", str(mismatch[:2]))
    # scaling: optimize_svg on a <g> chain must be ~linear when max_depth is raised
    ts = {}
    for n in (2500, 10000):
        rc, dt, rss, out, err = measure(IMPLS["pion"] + ["dos", "nest_g_opt", str(n), str(n + 16)], 120)
        ts[n] = dt
    ratio = ts[10000] / max(ts[2500], 1e-3)
    print(f"  optimize_svg nested <g> chain: n=2500 {ts[2500]:.3f}s, n=10000 {ts[10000]:.3f}s, ratio {ratio:.1f} (4 = linear, 16 = quadratic)")
    L.check("optimize_svg is ~linear in <g> nesting depth (ratio for 4x depth <= 6)", ratio <= 6 or ts[10000] < 0.05, "P2",
            f"4x deeper -> {ratio:.1f}x slower (is_empty_group re-scans every subtree; n=10000 takes {ts[10000]:.2f}s)")
    sys.exit(L.save())


if __name__ == "__main__":
    main()
