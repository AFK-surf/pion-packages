"""Native debug / Native release / Wasm32 debug / Wasm32 release byte-for-byte parity.

EXECUTES the .wasm builds of audit/probe under node (~/.pion/share/pion/pion_wasm_rt.mjs). Corpora:
grammar fuzz + byte mutations (parse/tok/min/print/valid), raw random bytes (parseb/tokb), the hand spec corpus,
and stress inputs at the default limits. Then the deep-AST crash (P1-4) is replayed on every variant.
Usage: wasm4.py [--n N] [--json out.json]
"""
import argparse, hashlib, json, os, random, subprocess, time
from common import TMP, BIN, write_records
import gen, spec_diff

RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
VARIANTS = {
    "native_debug": [os.path.join(BIN, "pion_probe_debug")],
    "native_release": [os.path.join(BIN, "pion_probe")],
    "wasm32_debug": ["node", RT, os.path.join(BIN, "pion_probe_debug.wasm")],
    "wasm32_release": ["node", RT, os.path.join(BIN, "pion_probe_release.wasm")],
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=6000)
    ap.add_argument("--json")
    a = ap.parse_args()
    r = random.Random(99)
    docs = [c[2] for c in spec_diff.CASES]
    for i in range(a.n):
        d = gen.gdoc(r)
        docs.append(gen.mutate(r, d) if i % 2 else d)
    raw = [bytes(r.randrange(256) for _ in range(r.randint(1, 24))) for _ in range(2000)]
    raw += [d.encode()[: r.randint(1, max(1, len(d.encode())))] for d in docs[:2000]]
    stress = ["{a" * 50000 + "}" * 50000, "{ f(x: " + "[" * 50000 + "1" + "]" * 50000 + ") }",
              "{ f(x: " + "{a:" * 50000 + "1" + "}" * 50000 + ") }", "type T { f: " + "[" * 50000 + "Int" + "]" * 50000 + " }",
              "{ " + "a " * 499990 + "}", '{ f(x: """' + "\n   line" * 100000 + '""") }', "#" + "x" * 2_000_000,
              '{ f(x: "' + "\\u0041" * 200000 + '") }', "{" + "a" * 1_000_000 + "}"]
    jobs = [("parse", docs), ("tok", docs), ("min", docs), ("print", docs), ("valid", docs), ("parseb", raw), ("tokb", raw),
            ("parse", stress), ("min", stress)]
    report = dict(jobs=[], crash=[])
    ok_all = True
    for idx, (mode, recs) in enumerate(jobs):
        inp = os.path.join(TMP, f"w4_{idx}_{mode}.in")
        write_records(inp, recs)
        hashes, secs = {}, {}
        for v, cmd in VARIANTS.items():
            out = inp + f".{v}.out"
            t0 = time.time()
            p = subprocess.run(cmd + [mode, inp, out], capture_output=True, timeout=1800)
            secs[v] = round(time.time() - t0, 2)
            if p.returncode != 0 or not os.path.exists(out):
                hashes[v] = f"FAILED rc={p.returncode} {p.stderr[-200:]!r}"
                ok_all = False
                continue
            hashes[v] = hashlib.sha256(open(out, "rb").read()).hexdigest()
            os.unlink(out)
        os.unlink(inp)
        same = len(set(hashes.values())) == 1
        ok_all &= same
        print(f"  {mode:6s} {len(recs):6d} records  {'IDENTICAL' if same else 'MISMATCH'}  sha256={list(hashes.values())[0][:16]}  "
              + " ".join(f"{k}={s}s" for k, s in secs.items()))
        if not same:
            for k, h in hashes.items():
                print(f"      {k}: {h}")
        report["jobs"].append(dict(mode=mode, n=len(recs), same=same, hashes=hashes, secs=secs))
    # deep-AST teardown crash, raised max_depth (probe `one parse` uses ParseOptions(1e8,...))
    path = os.path.join(TMP, "w4_deep.graphql")
    deep = [("selection", 600, lambda n: "{a" * n + "}" * n), ("selection", 800, lambda n: "{a" * n + "}" * n),
            ("selection", 30000, lambda n: "{a" * n + "}" * n),
            ("list value", 2000, lambda n: "{ f(x: " + "[" * n + "1" + "]" * n + ") }"),
            ("list value", 5000, lambda n: "{ f(x: " + "[" * n + "1" + "]" * n + ") }"),
            ("list value", 60000, lambda n: "{ f(x: " + "[" * n + "1" + "]" * n + ") }")]
    for what, n, g in deep:
        open(path, "w").write(g(n))
        row = dict(what=what, n=n)
        for v, cmd in VARIANTS.items():
            p = subprocess.run(cmd + ["one", path, "parse"], capture_output=True, text=True, timeout=600)
            msg = p.stdout.strip() or (p.stderr.strip().splitlines() or [""])[0]
            row[v] = f"rc={p.returncode} {msg[:45]}"
        print(f"  deep {what} n={n} (max_depth raised): " + " | ".join(f"{k}: {row[k]}" for k in VARIANTS))
        report["crash"].append(row)
    print(f"wasm4: {'ALL IDENTICAL' if ok_all else 'MISMATCHES FOUND'}")
    if a.json:
        json.dump(report, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
