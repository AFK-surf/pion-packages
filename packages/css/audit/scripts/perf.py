"""Adversarial / un-curated head-to-head timings and a Pion phase breakdown.

Corpora (generated deterministically into $AUDIT_TMP):
  design_system : packages/css/bench/gen_data.py (the README corpus, 6000 blocks ~2.09 MB)
  color_heavy   : every declaration a color function / hex / named color
  selector_heavy: long complex selector lists (:is/:not/:has/:nth-child(of S)/attributes)
  nesting_heavy : CSS Nesting 4 levels deep with & and nested @media
  custom_props  : design-token sheet, 40 custom properties per rule
Implementations (each run REPS times in one process, ROUNDS processes, median wall time reported):
  pion  count (zero-alloc count_tokens) / tokn (tokenize -> Array[Token]) / parse / min / css (to_css)
  rust  tokcount (cssparser token walk) / sheet (cssparser generic owned AST, same shape as Pion's) /
        lparse (lightningcss full typed AST) / lmin (lightningcss parse + real minify + print)
  node  tokcount / parse (css-tree full AST) / gen (css-tree parse + generate)
Usage: perf.py [--rounds R] [--json out.json]
"""
import json, os, re, statistics, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, PION, RUST, NODE_ORACLE, NODE_MODULES

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(HERE, "..", "..", "bench", "gen_data.py")


def corpus_color(n):
    out = []
    for i in range(n):
        out.append(f".c{i}{{color:rgb({i % 256} {(i * 7) % 256} {(i * 13) % 256} / {(i % 10) / 10});"
                   f"background:hsl({i % 360}deg {i % 100}% 50%);border-color:#{i % 4096:03x};"
                   f"outline-color:rgba({i % 256},0,0,.5);fill:rebeccapurple;stroke:#{i % 16777216:06x}80}}\n")
    return "".join(out)


def corpus_selector(n):
    return "".join(
        f":is(.a{i}, #b{i}) > ul li:not(.x{i}, [data-k='{i}']):nth-child(2n+1 of .item{i}),"
        f" .card{i}:has(> img:hover) ~ p::before, svg|g{i} [aria-x~=\"v{i}\" i] {{color:red}}\n" for i in range(n))


def corpus_nesting(n):
    return "".join(
        f".n{i}{{color:red;& .a{{margin:0 auto;&:hover{{color:blue;& > .b{{padding:1px;@media (min-width:768px){{padding:2px}}}}}}}}}}\n"
        for i in range(n))


def corpus_custom(n):
    return "".join(":root.t%d{%s}\n" % (i, "".join(f"--tok-{i}-{k}: {k}px ;" for k in range(40))) for i in range(n))


def build_corpora():
    paths = {}
    p = os.path.join(TMP, "perf_design_system.css")
    subprocess.run([sys.executable, GEN, p, "6000"], check=True, capture_output=True)
    paths["design_system"] = p
    for name, fn, n in (("color_heavy", corpus_color, 12000), ("selector_heavy", corpus_selector, 8000),
                        ("nesting_heavy", corpus_nesting, 15000), ("custom_props", corpus_custom, 2500)):
        p = os.path.join(TMP, f"perf_{name}.css")
        with open(p, "w") as f:
            f.write(fn(n))
        paths[name] = p
    return paths


IMPLS = [("pion", "count"), ("pion", "tokn"), ("pion", "parse"), ("pion", "min"), ("pion", "css"),
         ("rust", "tokcount"), ("rust", "sheet"), ("rust", "lparse"), ("rust", "lmin"),
         ("node", "tokcount"), ("node", "parse"), ("node", "gen")]


def cmd(impl, mode, path, reps):
    if impl == "pion":
        return [PION, "one", path, mode, str(reps)]
    if impl == "rust":
        return [RUST, "one", path, mode, str(reps)]
    return ["node", NODE_ORACLE, "one", path, mode, str(reps)]


def run_once(c):
    t0 = time.perf_counter()
    r = subprocess.run(["/usr/bin/time", "-l"] + c, capture_output=True, env=dict(os.environ, NODE_PATH=NODE_MODULES))
    dt = time.perf_counter() - t0
    m = re.search(rb"(\d+)\s+maximum resident set size", r.stderr)
    return dt, (int(m.group(1)) / 1048576 if m else 0), r.stdout.decode().strip()[:60]


def main():
    rounds = int(sys.argv[sys.argv.index("--rounds") + 1]) if "--rounds" in sys.argv else 5
    reps = 3
    paths = build_corpora()
    res = {}
    for cname, path in paths.items():
        size = os.path.getsize(path)
        print(f"\n### {cname}: {size / 1e6:.2f} MB x {reps} reps/process, {rounds} interleaved rounds (median)")
        print(f"| impl/mode | median ms | MB/s | peak RSS MB | vs rust/sheet | output |")
        print(f"|---|---:|---:|---:|---:|---|")
        samples = {k: [] for k in IMPLS}
        rss = {}
        outs = {}
        for rd in range(rounds + 1):  # round 0 = warmup
            order = IMPLS[rd % len(IMPLS):] + IMPLS[:rd % len(IMPLS)]
            for k in order:
                dt, r, o = run_once(cmd(k[0], k[1], path, reps))
                if rd > 0:
                    samples[k].append(dt)
                rss[k] = max(rss.get(k, 0), r)
                outs[k] = o
        base = statistics.median(samples[("rust", "sheet")])
        for k in IMPLS:
            med = statistics.median(samples[k])
            mbps = size * reps / med / 1e6
            ok = outs[k] if outs[k].startswith("ok") else "**" + outs[k][:40] + "**"
            print(f"| {k[0]}/{k[1]} | {med * 1000:.1f} | {mbps:.1f} | {rss[k]:.1f} | {base / med:.2f}x | {ok} |")
            res[f"{cname}/{k[0]}/{k[1]}"] = {"median_ms": med * 1000, "mbps": mbps, "rss_mb": rss[k], "out": outs[k]}
    if "--json" in sys.argv:
        json.dump(res, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
