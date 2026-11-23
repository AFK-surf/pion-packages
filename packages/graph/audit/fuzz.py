#!/usr/bin/env python3
"""Differential fuzz: Pion `packages/graph` vs Rust petgraph =0.8.3 (+ exact / brute-force references).

    python3 fuzz.py --oracle BIN --runner BIN [--runner-wasm "node rt.mjs x.wasm"] --seeds 1,2,3 --cases 1000 --out DIR

Both binaries generate identical graphs from (seed, case) and print `c<case> <section> <payload>`.
For every Pion line, the oracle line with the same key is ground truth (aliases below). Oracle lines
ending in `_pg` are petgraph's own answer where it disagrees with ground truth (upstream defects).
"""
import argparse, collections, json, os, shlex, subprocess, sys

ALIAS = {"mst_prim": "mst"}
COMPAT = {"ops_lay", "ops_ord", "uops_lay"}  # petgraph-layout compatibility (not correctness)


def run(cmd, seed, cases):
    p = subprocess.run(cmd + ["fuzz", str(seed), str(cases)], capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"{cmd} failed rc={p.returncode}: {p.stderr[-2000:]}")
    out = {}
    for ln in p.stdout.splitlines():
        c, sec, *rest = ln.split(" ", 2)
        out[(c, sec)] = " ".join(rest) if rest else ""
    return out, p.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--oracle", required=True)
    ap.add_argument("--runner", required=True)
    ap.add_argument("--seeds", default="1")
    ap.add_argument("--cases", type=int, default=500)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    stats = collections.defaultdict(lambda: [0, 0])  # section -> [checked, mismatched]
    upstream = collections.Counter()
    examples = collections.defaultdict(list)
    for seed in [int(s) for s in a.seeds.split(",")]:
        orc, _ = run(shlex.split(a.oracle), seed, a.cases)
        pio, raw = run(shlex.split(a.runner), seed, a.cases)
        with open(os.path.join(a.out, f"pion_seed{seed}.txt"), "w") as f:
            f.write(raw)
        for (c, sec), v in orc.items():
            if sec.endswith("_pg"):
                upstream[sec] += 1
                if len(examples["UPSTREAM " + sec]) < 3:
                    examples["UPSTREAM " + sec].append(
                        {"seed": seed, "case": c, "petgraph": v[:300], "truth": orc.get((c, sec[:-3]), orc.get((c, "mst"), ""))[:300]})
        for (c, sec), v in pio.items():
            key = ALIAS.get(sec, sec)
            want = orc.get((c, key))
            stats[sec][0] += 1
            if want is None or want != v:
                stats[sec][1] += 1
                if len(examples[sec]) < 5:
                    examples[sec].append({"seed": seed, "case": c, "pion": v[:400], "truth": (want or "<absent>")[:400]})
        for (c, sec) in orc:
            if not sec.endswith("_pg") and (c, sec) not in pio:
                stats[sec + "(missing)"][1] += 1
    summary = {
        "sections": {k: {"checked": v[0], "mismatched": v[1], "kind": "compat" if k in COMPAT else "correctness"}
                     for k, v in sorted(stats.items())},
        "upstream_petgraph_disagreements": dict(upstream),
        "examples": examples,
    }
    with open(os.path.join(a.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print(f"{'section':16s} {'checked':>8s} {'mismatch':>9s}  kind")
    for k, v in sorted(stats.items()):
        print(f"{k:16s} {v[0]:8d} {v[1]:9d}  {'compat' if k in COMPAT else 'correctness'}")
    print("petgraph disagreeing with ground truth:", dict(upstream))
    bad = [k for k, v in stats.items() if v[1] and k not in COMPAT]
    print("CORRECTNESS MISMATCHES:", ", ".join(sorted(bad)) if bad else "none")


if __name__ == "__main__":
    main()
