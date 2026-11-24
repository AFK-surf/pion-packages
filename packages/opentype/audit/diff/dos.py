#!/usr/bin/env python3
"""DoS gate for packages/opentype (stdlib only, run with `python3 -I`).

  dos.py <bombs.tsv> <native_rel_bin> <wasm_runner + wasm_rel> -- <oracle_bin>

Every bomb (< 8 KiB, written by gen.py) is run through `stress` (the whole public API: full Unicode
cmap sweep, every glyph outlined, names, kern matrix, UVS, fvar/avar) in native --release and wasm32
--release, and through ttf-parser 0.25.1 for comparison (counting pen, constant memory).

Exit 1 (P0): a crash, a wasm trap, a non-zero exit, a hang beyond HARD_S, or native/wasm digests that
differ. Exit 3: no P0, but a bomb exceeds its per-bomb budget (an OPEN P2 amplification finding).
"""
import resource
import subprocess
import sys
import time

HARD_S = 60
ORACLE_S = 10


def run(cmd, limit):
    t0 = time.monotonic()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=limit)
        dt = time.monotonic() - t0
        return p.returncode, p.stdout.strip().splitlines()[-1:] or [""], p.stderr.strip()[-200:], dt
    except subprocess.TimeoutExpired:
        return "timeout", [""], "", limit


def main():
    a = sys.argv[1:]
    sep = a.index("--")
    rows = [ln.rstrip("\n").split("\t") for ln in open(a[0]) if ln.strip()]
    native = a[1]
    wasm = a[2:sep]
    oracle = a[sep + 1]
    p0 = over = 0
    print("  %-26s %6s %9s %9s %8s  %-12s %s" % ("bomb", "bytes", "native", "wasm32", "budget", "ttf-parser", "note"))
    for name, path, budget, note in rows:
        size = len(open(path, "rb").read())
        rn = run([native, "stress", path, "0"], HARD_S)
        rw = run(wasm + ["stress", path, "0"], HARD_S)
        ro = run([oracle, "stress", path], ORACLE_S)
        bad = []
        for tag, r in (("native", rn), ("wasm32", rw)):
            if r[0] != 0:
                bad.append("%s rc=%s %s" % (tag, r[0], r[2]))
        if not bad and rn[1] != rw[1] and rn[1][0].split(" ")[-1] != rw[1][0].split(" ")[-1]:
            bad.append("native/wasm digest differ: %s vs %s" % (rn[1], rw[1]))
        nms = int(rn[1][0].split()[0][3:]) if rn[0] == 0 and rn[1][0].startswith("ms=") else -1
        wms = int(rw[1][0].split()[0][3:]) if rw[0] == 0 and rw[1][0].startswith("ms=") else -1
        ost = ("%.0f ms" % (ro[3] * 1000)) if ro[0] == 0 else ("TIMEOUT >%ds" % ORACLE_S if ro[0] == "timeout" else "rc=%s" % ro[0])
        flag = ""
        if bad:
            p0 += 1
            flag = "  P0: " + "; ".join(bad)
        elif max(nms, wms) > int(budget):
            over += 1
            flag = "  OVER BUDGET"
        print("  %-26s %6d %7d ms %7d ms %5s ms  %-12s %s%s" % (name, size, nms, wms, budget, ost, note[:60], flag))
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    print("  peak child RSS: %.1f MiB" % (rss / (1024 * 1024) if sys.platform == "darwin" else rss / 1024))
    if p0:
        sys.exit(1)
    sys.exit(3 if over else 0)


if __name__ == "__main__":
    main()
