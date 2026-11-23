"""Benchmark fairness review for packages/svg/bench (W1 / W2 / W3a / W3b). Informational: prints measurements,
never fails the audit. Builds the bench drivers exactly as bench/run_bench.sh does (artifacts in $AUDIT_TMP)."""
import os, statistics, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, BIN, IMPLS

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.normpath(os.path.join(HERE, "..", "..", "bench"))
ROUNDS = int(os.environ.get("ROUNDS", "5"))


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def timeit(cmds):
    """Strictly alternating rounds (1 warm-up); returns {name: (median_s, stdout_first_line)}."""
    res = {k: [] for k in cmds}
    outs = {}
    for r in range(ROUNDS + 1):
        for k, c in cmds.items():
            t0 = time.perf_counter()
            p = sh(c)
            dt = time.perf_counter() - t0
            if p.returncode != 0:
                raise RuntimeError(f"{k}: {p.stderr[-300:]}")
            outs[k] = p.stdout.strip().split("\n")
            if r:
                res[k].append(dt)
    return {k: (statistics.median(v), outs[k]) for k, v in res.items()}


def main():
    paths, icons = os.path.join(TMP, "paths_50k.txt"), os.path.join(TMP, "icons_2k.txt")
    sh(["python3", os.path.join(BENCH, "gen_data.py"), paths, icons, "50000", "2000"], check=True)
    b = sh(["pionc", "build", "--release", "-o", os.path.join(BIN, "bench_pion"), os.path.join(BENCH, "pion_bench")])
    if b.returncode:
        print(b.stdout[-500:], b.stderr[-500:]); sys.exit(1)
    env = dict(os.environ, CARGO_TARGET_DIR=os.path.join(TMP, "bench-rust-target"))
    b = sh(["cargo", "build", "--release", "--locked", "-q", "--manifest-path", os.path.join(BENCH, "rust_bench", "Cargo.toml")], env=env)
    if b.returncode:
        print(b.stderr[-800:]); sys.exit(1)
    rust = os.path.join(TMP, "bench-rust-target", "release", "svg_bench_rust")
    pion = os.path.join(BIN, "bench_pion")
    probe, oracle = IMPLS["pion"][0], IMPLS["rust"][0]
    print("  W1 (50,000 paths) - median of", ROUNDS, "alternating rounds")
    r = timeit({
        "pion w1 (bench driver)": [pion, "w1_paths", paths],
        "rust_bench w1 (svgtypes + hand-port of Pion arc/bbox)": [rust, "w1_paths", paths],
        "rust idiomatic: SimplifyingPathParser + kurbo bbox": [oracle, "w1kurbo", paths],
        "pion stage1 parse_path only": [probe, "w1", paths, "1"],
        "pion stage2 + to_cubic_beziers": [probe, "w1", paths, "2"],
        "pion stage3 + cubics_bbox": [probe, "w1", paths, "3"],
        "rust svgtypes PathParser only": [oracle, "w1parse", paths],
    })
    base = r["rust_bench w1 (svgtypes + hand-port of Pion arc/bbox)"][0]
    for k, (t, out) in r.items():
        print(f"    {k:55s} {t * 1000:8.1f} ms  ({base / t:4.2f}x of rust_bench)  {out[-1][:60]}")
    s1, s2, s3 = (r[f"pion stage{i} " + n][0] for i, n in ((1, "parse_path only"), (2, "+ to_cubic_beziers"), (3, "+ cubics_bbox")))
    print(f"    pion phase split: parse {s1 * 1000:.1f} ms, cubic/arc {(s2 - s1) * 1000:.1f} ms, bbox {(s3 - s2) * 1000:.1f} ms")
    print("  W3b fixed cost: node + `import('svgo')` without optimizing anything")
    node_dir = os.path.join(TMP, "node_pkg")
    if not os.path.isdir(os.path.join(node_dir, "node_modules", "svgo")):
        os.makedirs(node_dir, exist_ok=True)
        for f in ("package.json", "package-lock.json"):
            sh(["cp", os.path.join(BENCH, "node_bench", f), node_dir])
        i = sh(["npm", "ci", "--no-audit", "--no-fund", "--silent"], cwd=node_dir)
        if i.returncode:
            print("    (npm ci failed - svgo checks skipped)", i.stderr[-200:])
            return
    imp = timeit({"node import svgo": ["node", "--input-type=module", "-e", f"await import('{node_dir}/node_modules/svgo/lib/svgo-node.js')"]})
    print(f"    node + import('svgo'): {imp['node import svgo'][0] * 1000:.1f} ms per process (counted inside W3b's 523 ms)")
    js = os.path.join(TMP, "svgo_sem.mjs")
    cases = {
        "text spaces": '<svg xmlns="http://www.w3.org/2000/svg"><text>Hello <tspan>World</tspan> again</text></svg>',
        "switch": '<svg xmlns="http://www.w3.org/2000/svg"><switch><g><rect width="5" height="5"/><circle r="3"/></g></switch></svg>',
        "animate": '<svg xmlns="http://www.w3.org/2000/svg"><g><animate attributeName="opacity" to="0"/><rect width="5" height="5"/></g></svg>',
        "charref": '<svg xmlns="http://www.w3.org/2000/svg"><text>caf&#233;</text></svg>',
    }
    with open(js, "w") as f:
        f.write(f"import {{ optimize }} from '{node_dir}/node_modules/svgo/lib/svgo-node.js';\n")
        f.write(f"const cases = {cases!r};\n".replace("'", '"').replace('"<svg', "'<svg").replace('svg>"', "svg>'"))
        f.write("for (const [k, v] of Object.entries(cases)) console.log(k + ' => ' + optimize(v, {floatPrecision: 3}).data);\n")
    o = sh(["node", js])
    print("  svgo@3.3.2 on the optimizer cases Pion breaks (REPORT P1-2..P1-5):")
    for l in (o.stdout or o.stderr).strip().split("\n"):
        print("    " + l[:160])


if __name__ == "__main__":
    main()
