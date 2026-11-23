"""Native debug / Native release / Wasm32 debug / Wasm32 release byte-for-byte parity.

EXECUTES the .wasm builds of audit/probe under node (~/.pion/share/pion/pion_wasm_rt.mjs), not just
compiles them. Corpora: the token-differential corpus (hand + fuzz), raw invalid-UTF-8 bytes, the
stylesheet / minify / selector / color / media-query corpora, and adversarial stress inputs (50k
nesting of every bracket kind, 10 MB unclosed comment/string, deep :is()/not(), huge selector lists).
Usage: wasm4.py [--json out.json]
"""
import hashlib, json, os, random, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, BIN, write_records
import tok_diff, struct_diff, minify_diff

RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
VARIANTS = {
    "native_debug": [os.path.join(BIN, "pion_probe_debug")],
    "native_release": [os.path.join(BIN, "pion_probe")],
    "wasm32_debug": ["node", RT, os.path.join(BIN, "pion_probe_debug.wasm")],
    "wasm32_release": ["node", RT, os.path.join(BIN, "pion_probe_release.wasm")],
}


def main():
    rng = random.Random(9)
    toks = tok_diff.SEEDS + [tok_diff.gen(rng) for _ in range(5000)]
    raw = [bytes(rng.randrange(256) for _ in range(rng.randint(1, 24))) for _ in range(2000)]
    sheets = struct_diff.SHEETS + [struct_diff.gen_sheet(rng) for _ in range(2000)]
    mins = minify_diff.HAND + [minify_diff.gen(rng) for _ in range(1000)]
    stress = [
        "a{" * 50000 + "}" * 50000, ".a{width:" + "(" * 50000 + "1px" + ")" * 50000 + "}",
        ".a{x:" + "[" * 50000 + "]" * 50000 + "}", "@media all{" * 50000 + "}" * 50000,
        ":is(" * 50000 + "a" + ")" * 50000 + "{x:y}", "a{" * 250 + "b:c" + "}" * 250,
        "/*" + "a*" * 1_000_000, ".a{content:'" + "a" * 2_000_000, ".a{x:" + "\\41 " * 100_000 + "}",
        ",".join(f".s{i} > a:hover" for i in range(30000)) + "{x:y}", "u+a " * 50000,
        ".a{" + "".join(f"--v{i}: {i}px ;" for i in range(30000)) + "}", "}" * 100000 + "a{b:c}",
    ]
    sel_stress = [":is(" * 50000 + "a" + ")" * 50000, ":not(" * 250 + "a" + ")" * 250, ".a" * 50000]
    mq_stress = ["not (" * 50000 + "color" + ")" * 50000, "(" * 255 + "color" + ")" * 255,
                 ", ".join("(min-width: %dpx)" % i for i in range(20000))]
    jobs = [("tok", toks), ("tokb", raw), ("tok", stress), ("sheet", sheets), ("sheet", stress), ("decls", struct_diff.DECLS),
            ("min", mins), ("min", stress), ("css", sheets), ("spec", struct_diff.SELS + sel_stress),
            ("color", struct_diff.COLORS), ("mq", struct_diff.MQS + mq_stress)]
    report = {}
    ok_all = True
    for idx, (mode, recs) in enumerate(jobs):
        inp = os.path.join(TMP, f"w4_{idx}_{mode}.in")
        write_records(inp, recs)
        hashes = {}
        for v, cmd in VARIANTS.items():
            out = inp + f".{v}.out"
            t0 = time.time()
            r = subprocess.run(cmd + [mode, inp, out], capture_output=True, timeout=900)
            dt = time.time() - t0
            if r.returncode != 0 or not os.path.exists(out):
                hashes[v] = f"FAILED rc={r.returncode} {r.stderr[-300:]!r}"
                ok_all = False
                continue
            hashes[v] = hashlib.sha256(open(out, "rb").read()).hexdigest()
            hashes[v + "_secs"] = round(dt, 2)
            os.unlink(out)
        os.unlink(inp)
        same = len({hashes[v] for v in VARIANTS}) == 1
        ok_all &= same
        key = f"{mode}[{len(recs)} recs]#{idx}"
        report[key] = dict(hashes, identical=same)
        secs = " ".join(f"{v}={hashes.get(v + '_secs', '-')}s" for v in VARIANTS)
        print(f"  {key:28s} identical={same}  sha256={hashes['native_release'][:16]}  {secs}")
        if not same:
            for v in VARIANTS:
                print(f"      {v}: {hashes[v][:200]}")
    print("4-mode parity:", "ALL IDENTICAL" if ok_all else "MISMATCH / FAILURE")
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
