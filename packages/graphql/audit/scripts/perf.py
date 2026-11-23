"""Adversarial / un-curated head-to-head timings (complements bench/, which uses one curated corpus per workload).

Implementations: Pion native --release, Pion wasm32 --release (node + pion_wasm_rt.mjs), graphql-js 16.10.0,
apollo-parser 0.8.4 (parse/tok only: it has no printer or minifier). All run `one <file> <sub> <reps>` so each
process parses the same file `reps` times; rounds are strictly interleaved; median wall time and peak RSS reported.
Process start-up is included for every implementation (node ~40 ms) — the `reps` are chosen so it is <15% of the total.
Pion uses ParseOptions(1e8, 1e8, 1e8) in `one` mode (the default max_tokens rejects corpora C1/C5).
Usage: perf.py [--rounds R] [--json out.json]
"""
import argparse, json, os, random, re, statistics, subprocess, sys, time
from common import TMP, PION, RUST, NODE_ORACLE, NODE_MODULES, BIN

HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
WASM = os.path.join(BIN, "pion_probe_release.wasm")


def corpora():
    sys.path.insert(0, os.path.join(HERE, "..", "..", "bench"))
    out = {}
    bench_dir = os.path.join(TMP, "bench_corpus")
    os.makedirs(bench_dir, exist_ok=True)
    subprocess.run([sys.executable, os.path.join(HERE, "..", "..", "bench", "gen_data.py"), bench_dir, "1400", "200"], check=True,
                   capture_output=True)
    out["C1 bench/ W1 SDL (2.0 MB)"] = (open(os.path.join(bench_dir, "schema.graphql")).read(), 3)
    r = random.Random(4)

    def deep_q(d):
        s = ""
        for i in range(d):
            s += 'n%d: node(id: "%d", first: %d, filter: {k: [%d, %d], s: "x\\n"}) @include(if: $v) { id ... on T { name } ' % (i, i, i, i, i + 1)
        return s + "leaf" + "}" * d
    q = "query Q($v: Boolean) {" + deep_q(100) + "}"
    out["C2 deep realistic query (depth 100) x 400"] = ("\n".join(q.replace("query Q", f"query Q{i}") for i in range(400)), 10)
    pieces = ["\\n", "\\u00e9", "\\u4E2D", '\\"', "abc", "\\t"]  # no \\u{..} or surrogate pairs: apollo-parser 0.8.4 rejects both
    esc = "{ " + " ".join('f%d(a: "%s")' % (i, "".join(r.choice(pieces) for _ in range(40))) for i in range(20000)) + " }"
    out["C3 escape-heavy strings (20k args)"] = (esc, 10)
    blk = "\n".join('"""\n    Line one of type %d\n      indented more\n    \\""" quoted\n"""\ntype T%d {\n  """\n  field doc\n  """\n  a: Int\n}' % (i, i) for i in range(20000))
    out["C4 block-string-heavy SDL (20k types)"] = (blk, 5)
    out["C5 flat wide query (400k fields)"] = ("{ " + " ".join(f"a{i % 1000}" for i in range(400000)) + " }", 5)
    return out


IMPLS = {
    "pion": lambda f, sub, reps: [PION, "one", f, sub, str(reps)],
    "pion_wasm32": lambda f, sub, reps: ["node", RT, WASM, "one", f, sub, str(reps)],
    "graphql_js": lambda f, sub, reps: ["node", NODE_ORACLE, "one", f, sub, str(reps)],
    "apollo_rust": lambda f, sub, reps: [RUST, "one", f, "parsedef" if sub == "parse" else sub, str(reps)],
}
SUBS = {"parse": ["pion", "pion_wasm32", "graphql_js", "apollo_rust"], "print": ["pion", "pion_wasm32", "graphql_js"],
        "min": ["pion", "pion_wasm32", "graphql_js"]}


def timed(cmd):
    env = dict(os.environ, NODE_PATH=NODE_MODULES)
    t0 = time.perf_counter()
    p = subprocess.run(["/usr/bin/time", "-l"] + cmd, capture_output=True, text=True, env=env, timeout=1200)
    dt = time.perf_counter() - t0
    m = re.search(r"(\d+)\s+maximum resident set size", p.stderr)
    return dt, (int(m.group(1)) / 1048576 if m else 0), p.stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--json")
    a = ap.parse_args()
    rows = []
    for cname, (text, reps) in corpora().items():
        path = os.path.join(TMP, "perf_in.graphql")
        open(path, "w").write(text)
        mb = os.path.getsize(path) / 1e6
        print(f"\n## {cname}: {mb:.2f} MB x {reps} reps")
        for sub, impls in SUBS.items():
            if cname.startswith("C1") and sub == "min":
                continue
            times = {i: [] for i in impls}
            rss, outs = {}, {}
            for _ in range(1):  # warmup
                for i in impls:
                    timed(IMPLS[i](path, sub, reps))
            for rnd in range(a.rounds):
                order = impls[rnd % len(impls):] + impls[:rnd % len(impls)]
                for i in order:
                    dt, r, o = timed(IMPLS[i](path, sub, reps))
                    times[i].append(dt)
                    rss[i] = max(rss.get(i, 0), r)
                    outs[i] = o
            base = statistics.median(times["pion"])
            for i in impls:
                med = statistics.median(times[i])
                ok = not outs[i].startswith("ERR")
                print(f"  {sub:5s} {i:12s} median {med * 1000:8.1f} ms  min {min(times[i]) * 1000:8.1f}  "
                      f"{mb * reps / med:7.1f} MB/s  rss {rss[i]:7.1f} MiB  pion/x = {med / base:5.2f}  {'' if ok else outs[i][:60]}")
                rows.append(dict(corpus=cname, sub=sub, impl=i, median_ms=med * 1000, min_ms=min(times[i]) * 1000,
                                 mbps=mb * reps / med, rss_mib=rss[i], out=outs[i][:80]))
    if a.json:
        json.dump(rows, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
