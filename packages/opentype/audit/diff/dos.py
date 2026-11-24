#!/usr/bin/env python3
"""DoS gate for packages/opentype (stdlib only, run with `python3 -I`).

  dos.py <bombs.tsv> <native_rel_bin> <wasm_runner + wasm_rel> -- <oracle_bin>

Every bomb (written by gen.py; < 8 KiB, or < 1 MiB for size-amplification bombs) runs in native --release
and wasm32 --release in one of three modes:
  stress  the whole public API (full Unicode cmap sweep, every glyph outlined, names, kern matrix, UVS,
          fvar/avar); also through ttf-parser 0.25.1 for comparison (counting pen, constant memory)
  cost    Face::parse, then 20,000 glyph_index + 20,000 glyph_variation_index lookups (budget: lookups)
  parse   the same run, budget applied to Face::parse alone

Exit 1 (P0): a crash, a wasm trap, a non-zero exit, a hang beyond HARD_S, or native/wasm results that
differ. Exit 3: no P0, but a bomb exceeds its budget; each such bomb prints `OPEN-FINDING <id> <text>`.
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
    print("  %-26s %7s %9s %9s %8s  %-12s %-6s %s" % ("bomb", "bytes", "native", "wasm32", "budget", "ttf-parser", "mode", "note"))
    opened = []
    for row in rows:
        name, path, budget, note = row[:4]
        mode = row[4] if len(row) > 4 else "stress"
        fid = row[5] if len(row) > 5 else "-"
        size = len(open(path, "rb").read())
        cmd = ["stress", path, "0"] if mode == "stress" else ["cost", path, "20000"]
        rn = run([native] + cmd, HARD_S)
        rw = run(wasm + cmd, HARD_S)
        ro = run([oracle, "stress", path], ORACLE_S) if mode == "stress" else ("n/a", [""], "", 0)
        bad = []
        for tag, r in (("native", rn), ("wasm32", rw)):
            if r[0] != 0:
                bad.append("%s rc=%s %s" % (tag, r[0], r[2]))
        if mode == "stress" and not bad and rn[1] != rw[1] and rn[1][0].split(" ")[-1] != rw[1][0].split(" ")[-1]:
            bad.append("native/wasm digest differ: %s vs %s" % (rn[1], rw[1]))
        def ms(r):
            if r[0] != 0:
                return -1
            kv = dict(x.split("=", 1) for x in r[1][0].split() if "=" in x)
            key = {"stress": "ms", "cost": "lookup_ms", "parse": "parse_ms"}[mode]
            return int(kv.get(key, -1))
        nms, wms = ms(rn), ms(rw)
        if mode != "stress" and not bad:
            hn = [x for x in rn[1][0].split() if x.startswith("hits=")]
            hw = [x for x in rw[1][0].split() if x.startswith("hits=")]
            if hn != hw:
                bad.append("native/wasm results differ: %s vs %s" % (rn[1], rw[1]))
        if ro[0] == "n/a":
            ost = "-"
        else:
            ost = ("%.0f ms" % (ro[3] * 1000)) if ro[0] == 0 else ("TIMEOUT >%ds" % ORACLE_S if ro[0] == "timeout" else "rc=%s" % ro[0])
        flag = ""
        if bad:
            p0 += 1
            flag = "  P0: " + "; ".join(bad)
        elif max(nms, wms) > int(budget):
            over += 1
            flag = "  OVER BUDGET (%s)" % fid
            opened.append((fid, name, max(nms, wms), budget, mode))
        print("  %-26s %7d %7d ms %7d ms %5s ms  %-12s %-6s %s%s" % (name, size, nms, wms, budget, ost, mode, note[:70], flag))
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    print("  peak child RSS: %.1f MiB" % (rss / (1024 * 1024) if sys.platform == "darwin" else rss / 1024))
    for fid, name, got, budget, mode in opened:
        what = {"stress": "full API sweep", "cost": "40,000 cmap/UVS lookups", "parse": "Face::parse"}[mode]
        print("OPEN-FINDING %s %s: %s takes %d ms (budget %s ms)" % (fid, name, what, got, budget))
    if p0:
        sys.exit(1)
    sys.exit(3 if over else 0)


if __name__ == "__main__":
    main()
