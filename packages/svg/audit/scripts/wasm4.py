"""4-mode byte parity: native_rel / native_dbg / wasm_rel / wasm_dbg (the .wasm builds EXECUTED under node with
~/.pion/share/pion/pion_wasm_rt.mjs) on every audit corpus, including soft-float trig (rot), arc conversion,
flatten, number formatting and the optimizer."""
import hashlib, os, random, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import IMPLS, TMP, Ledger, write_records, bits, SEP
import path_diff, geom_check, dom_opt_check, fmt_check, attr_diff

MODES = ["pion", "pion_dbg", "wasm_rel", "wasm_dbg"]


def icons(n):
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "bench"))
    import importlib.util
    spec = importlib.util.spec_from_file_location("gen_data", os.path.join(os.path.dirname(__file__), "..", "..", "bench", "gen_data.py"))
    gd = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gd)
    out = os.path.join(TMP, "icons_w4.txt")
    gd.gen_icons(out, n)
    return open(out).read().split("\n---SVG---\n")


def main():
    rng = random.Random(99)
    pd = path_diff.HAND + [path_diff.gen(rng) for _ in range(3000)]
    gm = [f"0.25{SEP}{d}" for _, d in geom_check.HAND] + [f"0.1{SEP}{geom_check.fuzz_path(rng)}" for _ in range(400)]
    fm = [f"{p}{SEP}{d}" for p in (0, 3, 8) for d in fmt_check.EDGE + [geom_check.fuzz_path(rng) for _ in range(200)]]
    degs = [0, 30, 45, 90, 360000, -720, 1e6, 1e9, 1e15, 1e300] + [rng.uniform(-1e5, 1e5) for _ in range(2000)]
    rot = ["b%d" % bits(d) for d in degs]
    docs = [d for _, d, _ in dom_opt_check.XML] + [d for _, d in dom_opt_check.OPT]
    ic = icons(300)
    cols = list(attr_diff.NAMED) + [f"hsl({rng.uniform(-720, 720)!r},{rng.uniform(0, 100)!r}%,{rng.uniform(0, 100)!r}%)" for _ in range(500)]
    jobs = [("path", pd), ("geom", gm), ("fmt", fm), ("rot", rot), ("color", cols), ("xml", docs), ("extract", docs + ic),
            ("opt", docs + ic), ("optc", docs + ic)]
    L = Ledger("wasm4")
    allsame = True
    for mode, recs in jobs:
        inp = os.path.join(TMP, f"w4_{mode}.in")
        write_records(inp, recs)
        hs, secs = {}, {}
        for m in MODES:
            out = inp + "." + m
            t0 = time.time()
            r = subprocess.run(IMPLS[m] + [mode, inp, out], capture_output=True, timeout=900)
            secs[m] = time.time() - t0
            if r.returncode != 0 or not os.path.exists(out):
                hs[m] = f"FAILED rc={r.returncode} {r.stderr[-200:]!r}"
            else:
                hs[m] = hashlib.sha256(open(out, "rb").read()).hexdigest()
                os.unlink(out)
        os.unlink(inp)
        same = len(set(hs.values())) == 1 and not hs["pion"].startswith("FAILED")
        allsame &= same
        print(f"  {mode:8s} [{len(recs):5d} recs] identical={same} sha256={hs['pion'][:16]} " +
              " ".join(f"{m}={secs[m]:.2f}s" for m in MODES))
        if not same:
            for m in MODES:
                print(f"      {m}: {hs[m][:120]}")
        L.check(f"4-mode byte parity: {mode}", same, "P1")
    sys.exit(L.save())


if __name__ == "__main__":
    main()
