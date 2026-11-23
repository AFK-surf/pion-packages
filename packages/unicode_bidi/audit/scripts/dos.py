"""DoS / complexity / crash probes. Each case runs at size x1 and x2 (growth ~2 = linear, ~4 = quadratic)
in Pion native release (+ peak RSS), Rust `unicode-bidi =0.3.18` --release, and once (x1) in Pion
native debug / Wasm32 debug / Wasm32 release to prove no stack overflow / OOM / trap in any mode.
Usage: dos.py [--quick] [--only case,case] [--json out.json]     (env DOS_TIMEOUT, default 60 s per run)
"""
import json, os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, PION, RUST, VARIANTS

TO = int(os.environ.get("DOS_TIMEOUT", "60"))
R, A = "א", "a"
LRE, RLE, LRO, RLO, PDF, LRI, RLI, FSI, PDI = "‪‫‭‮‬⁦⁧⁨⁩"
N = 50000

CASES = [
    # (name, sub, builder(n) -> str, rust_supported)
    ("open_brackets_50k", "lines", lambda n: R + "(" * n + A, True),
    ("alternating_pairs_50k", "lines", lambda n: R + "()" * n + A, True),
    ("pairs_with_strong_50k", "lines", lambda n: R + ("(" + A + ")") * n + R, True),
    ("nested62_blocks", "lines", lambda n: R + ("(" * 62 + A + ")" * 62) * (n // 124), True),
    ("nested62_neutral_body", "lines", lambda n: R + "(" * 62 + "!" * n + ")" * 62 + A, True),
    ("lri_x50k_pdi_x50k", "lines", lambda n: R + LRI * n + A + PDI * n, True),
    ("fsi_x50k_pdi_x50k", "lines", lambda n: FSI * n + R + PDI * n, True),
    ("rle_x50k_pdf_x50k", "lines", lambda n: RLE * n + A + PDF * n, True),
    ("lri_a_pdi_x50k", "lines", lambda n: (A + LRI + R + PDI) * n, True),
    ("ws_x50k_rtl", "lines", lambda n: R + " " * n, True),
    ("bn_x50k_rtl", "lines", lambda n: R + "­" * n + "1", True),
    ("nsm_x50k_after_pdi", "lines", lambda n: R + LRI + A + PDI + "̀" * n, True),
    ("cs_bn_mix_50k", "lines", lambda n: R + ("1" + "­" * 3 + "," + "­" * 3) * (n // 8) + "1", True),
    ("et_bn_run_50k", "lines", lambda n: R + ("$" + "­") * n + "1", True),
    ("max_levels_alternating", "lines", lambda n: (RLE + LRE) * 62 + (A + R + "1" + "٠") * (n // 4), True),
    # Per-line APIs clone the WHOLE text's levels (O(lines x text)); sized /10 so Pion finishes.
    ("paragraphs_rtl_x5k", "lines", lambda n: (R + "\n") * (n // 10), True),
    ("paragraphs_rtl_x5k_l1only", "l1", lambda n: (R + "\n") * (n // 10), True),
    ("paragraphs_ltr_x5k_l1only", "l1", lambda n: (A + "\n") * (n // 10), True),
    ("crlf_ws_lines_3k", "lines", lambda n: (R + " \t" + LRI + "\r\n") * (n // 16), True),
    ("farview_single_line_rtl", "farview", lambda n: (R + " ab (1) ") * (n // 8), False),
    ("vis_levels_0_125_50k", "vis", lambda n: ",".join(str(i % 126) for i in range(n)), False),
    ("vis_huge_int_level", "vis", lambda n: "0," + str(n * 20), False),
    # Memory amplification at the documented default limit (16 MiB): size fixed, see the rss column.
    ("max_input_16mib_mixed", "lines", lambda n: big16(), True),
]


def big16():
    unit = "Hello \u05E9\u05DC\u05D5\u05DD \u0645\u0631\u062D\u0628\u0627 (123) [abc] 4.5 "
    s = unit * (16 * 1024 * 1024 // len(unit.encode()) - 1)
    return s


def run_one(cmd, path, sub):
    t0 = time.time()
    try:
        r = subprocess.run(["/usr/bin/time", "-l"] + cmd + ["one", path, sub], capture_output=True, timeout=TO)
    except subprocess.TimeoutExpired:
        return dict(secs=None, timeout=True)
    dt = time.time() - t0
    m = re.search(rb"(\d+)\s+maximum resident set size", r.stderr)
    return dict(secs=round(dt, 3), rc=r.returncode, rss_mb=round(int(m.group(1)) / 2**20, 1) if m else None,
                out=r.stdout.decode(errors="replace").strip()[:80],
                err=r.stderr.decode(errors="replace").split("\n")[0][:160] if r.returncode else "")


def main():
    quick = "--quick" in sys.argv
    rep = {}
    print(f"  {'case':28s} {'pion x1':>8s} {'pion x2':>8s} {'grow':>5s} {'rss':>7s} | {'rust x1':>8s} {'rust x2':>8s} {'grow':>5s} | 4-mode")
    only = sys.argv[sys.argv.index("--only") + 1].split(",") if "--only" in sys.argv else None
    for name, sub, build, rust_ok in CASES:
        if only and name not in only:
            continue
        res = {}
        for mul in (1, 2):
            if name.startswith("max_input") and mul == 2:
                continue
            n = N * mul // (5 if quick else 1)
            path = os.path.join(TMP, f"dos_{name}_{mul}.txt")
            with open(path, "w", encoding="utf-8") as f:
                f.write(build(n))
            res[f"pion_x{mul}"] = run_one([PION], path, sub)
            if rust_ok:
                res[f"rust_x{mul}"] = run_one([RUST], path, sub)
            if mul == 1:
                for v, cmd in VARIANTS.items():
                    if v != "native_release":
                        res[v] = run_one(cmd, path, sub)
            os.unlink(path)

        def g(k):
            a, b = res.get(f"{k}_x1", {}).get("secs"), res.get(f"{k}_x2", {}).get("secs")
            return (b / a) if a and b and a > 0.02 else None
        gs = lambda k: f"{g(k):.1f}" if g(k) else "-"
        fmt = lambda x: "TIMEOUT" if x is None else f"{x:.3f}"
        four = all(res[v].get("rc") == 0 for v in VARIANTS if v != "native_release") and res["pion_x1"].get("rc") == 0
        p1, p2 = res["pion_x1"], res.get("pion_x2", res["pion_x1"])
        line = f"  {name:28s} {fmt(p1.get('secs')):>8s} {fmt(p2.get('secs')):>8s} {gs('pion'):>5s} {str(p2.get('rss_mb')):>7s} |"
        if name.startswith("max_input"):
            line += f" rust_rss={r1.get('rss_mb') if rust_ok and (r1 := res.get('rust_x1')) else '-'}MB"
        if rust_ok:
            r1, r2 = res["rust_x1"], res.get("rust_x2", res["rust_x1"])
            line += f" {fmt(r1.get('secs')):>8s} {fmt(r2.get('secs')):>8s} {gs('rust'):>5s} |"
        else:
            line += f" {'n/a':>8s} {'n/a':>8s} {'-':>5s} |"
        bad = [f"{v}:{'TIMEOUT' if res[v].get('timeout') else res[v].get('rc')}" for v in VARIANTS
               if v != "native_release" and res[v].get("rc") != 0]
        line += " ok" if four else " FAIL " + " ".join(bad)
        print(line, flush=True)
        rep[name] = res
    if "--json" in sys.argv:
        json.dump(rep, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
