"""Adversarial / un-curated head-to-head timings (complements packages/html/bench).

Strictly interleaved rounds (pion, rust, go, pion, ...), median of ROUNDS wall-clock process
times, each process doing REPS internal repetitions of `one <file> <op>`. Each row also reports
whether the implementations' outputs agree ("ok <count>" lines) - for parse/sanitize corpora
outside the curated bench inputs they usually do NOT, which is itself a finding.
Usage: adv_bench.py <html5lib tree-construction dir> <markup5ever entities.rs> [--json out.json]
"""
import glob, json, os, re, statistics, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, PION, RUST, GO
from html5lib_suite import parse_dat

ROUNDS = int(os.environ.get("ROUNDS", "5"))


def timeit(cmd):
    t0 = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, timeout=600)
    return time.perf_counter() - t0, r.stdout.decode().strip()


def main():
    h5 = []
    for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.dat"))):
        h5 += [t["data"] for t in parse_dat(f)]
    # drop inputs that switch the tokenizer into a state that can swallow the rest of a
    # concatenated corpus (plaintext / unclosed raw text / unclosed comments)
    raw = ("plaintext", "<script", "<style", "<xmp", "<iframe", "<noembed", "<noframes", "<noscript",
           "<textarea", "<title", "<!--", "<![CDATA", "<svg", "<math", "<template", "<frameset", "<select")
    h5 = [d for d in h5 if not any(r in d.lower() for r in raw) and d.count('"') % 2 == 0 and d.count("'") % 2 == 0]
    ents = re.findall(r'\("(&[A-Za-z0-9]+;)"', open(sys.argv[2], encoding="utf-8").read())
    wide = "<ul>" + "".join(f'<li class="i{k % 7}" data-k="{k}">x</li>' for k in range(20000)) + "</ul>"
    deep_blog = ("<div class=a><div class=b><section><article><div><p><span><em>x</em></span></p></div></article></section></div></div>") * 3000
    cases = [
        ("parse: filtered html5lib corpus x40 (messy markup)", "\n".join(h5) * 40, "parse", 3, ["rust", "go"]),
        ("parse: all 2125 WHATWG ;-entities x40", " ".join(ents) * 40, "parse", 3, ["rust", "go"]),
        ("sanitize: filtered html5lib corpus x40", "\n".join(h5) * 40, "san", 3, ["rust"]),
        ("select: li:nth-child(2n+1) on 20k siblings", wide, "sel:li:nth-child(2n+1)", 1, ["rust"]),
        ("select: li:last-child on 20k siblings", wide, "sel:li:last-child", 1, ["rust"]),
        ("select: li:first-of-type on 20k siblings", wide, "sel:li:first-of-type", 1, ["rust"]),
        ("select: [data-k$='7'] on 20k siblings", wide, "sel:[data-k$='7']", 1, ["rust"]),
        ("select: div.a div.b em (30k nodes, descendant)", deep_blog, "sel:div.a div.b em", 1, ["rust"]),
        ("select: section > article p > span em", deep_blog, "sel:section > article p > span em", 1, ["rust"]),
    ]
    bins = {"pion": PION, "rust": RUST, "go": GO}
    rows = []
    for name, data, op, reps, others in cases:
        path = os.path.join(TMP, "adv_bench.html")
        open(path, "w").write(data)
        impls = ["pion"] + others
        times = {k: [] for k in impls}
        outs = {}
        for _ in range(ROUNDS):
            for k in impls:
                dt, out = timeit([bins[k], "one", path, op, str(reps)])
                times[k].append(dt)
                outs[k] = out
        med = {k: statistics.median(v) for k, v in times.items()}
        row = {"case": name, "bytes": len(data.encode()), "reps": reps,
               "median_ms": {k: round(v * 1000, 1) for k, v in med.items()},
               "pion_speedup_vs_rust": round(med["rust"] / med["pion"], 2),
               "outputs": outs, "outputs_agree_with_rust": outs["pion"] == outs["rust"]}
        rows.append(row)
        print(f"{name:48s} {row['bytes']:>9d}B  " + "  ".join(f"{k}={row['median_ms'][k]:>9.1f}ms" for k in impls)
              + f"  pion/rust speedup={row['pion_speedup_vs_rust']:.2f}x  same_output={row['outputs_agree_with_rust']}"
              + ("" if row["outputs_agree_with_rust"] else f"  ({outs['pion']} vs {outs['rust']})"))
        sys.stdout.flush()
        os.unlink(path)
    if "--json" in sys.argv:
        json.dump(rows, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
