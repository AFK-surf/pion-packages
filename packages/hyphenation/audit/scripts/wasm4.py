"""Native debug / Native release / Wasm32 debug / Wasm32 release byte-for-byte parity.

EXECUTES the .wasm builds of audit/probe under node (~/.pion/share/pion/pion_wasm_rt.mjs). Corpora: a
sample of every diff.py class, multilang words for 8 scripts, hyphenate_text texts, the adversarial
pattern sets of dos.py (load), plus the Int32 value-pointer overflow (crash parity: all four must fail
the same way). Usage: wasm4.py [--json out.json]
"""
import glob, hashlib, json, os, random, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, BIN, CRATE_PAT, CRATE_HYP, write_records
import diff, dos

RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
VARIANTS = {
    "native_debug": [os.path.join(BIN, "pion_probe_debug")],
    "native_release": [os.path.join(BIN, "pion_probe")],
    "wasm32_debug": ["node", RT, os.path.join(BIN, "pion_probe_debug.wasm")],
    "wasm32_release": ["node", RT, os.path.join(BIN, "pion_probe_release.wasm")],
}
BIG = dos.BIG


def main():
    sys.stdout.reconfigure(line_buffering=True)
    rng = random.Random(11)
    C = diff.build_corpus()
    sample = [w for recs in C.values() for w in (recs if len(recs) < 8000 else rng.sample(recs, 8000))]
    pdir = os.path.dirname(CRATE_PAT)
    jobs = [("opp", ("@en_us", "-", "2", "3"), sample, ()),
            ("all", ("@en_us", "-", "2", "3"), sample, ()),
            ("opp", (CRATE_PAT, CRATE_HYP, "2", "3"), sample, ())]
    for code, mn in (("de-1996", (2, 2)), ("ru", (2, 2)), ("el-monoton", (1, 1)), ("hu", (2, 2)),
                     ("th", (2, 3)), ("hi", (1, 1)), ("ka", (1, 2)), ("fr", (2, 3))):
        pat = os.path.join(pdir, f"hyph-{code}.pat.txt")
        cores = [c for c in ("".join(ch for ch in t if not ch.isdigit() and ch != ".") for t in open(pat, encoding="utf-8").read().split()) if c]
        words = ["".join(rng.choice(cores) for _ in range(rng.randint(1, 4))) for _ in range(3000)]
        words += [w.upper() for w in words[:1000]]
        jobs.append(("all", (pat, "-", str(mn[0]), str(mn[1])), words, ()))
    texts = [" ".join(rng.choice(C["dict_lower"]) + rng.choice(["", ",", "—", " ", "'s", "”"]) for _ in range(rng.randint(1, 30))) for _ in range(3000)]
    for sep in ("-", "­", ""):
        jobs.append(("text", ("@en_us", "-", "2", "3"), texts, (sep,)))
    report, ok_all = {}, True
    for idx, (mode, spec, recs, extra) in enumerate(jobs):
        inp = os.path.join(TMP, f"w4_{idx}.in")
        write_records(inp, recs)
        hashes = {}
        for v, cmd in VARIANTS.items():
            out = inp + f".{v}.out"
            t0 = time.time()
            r = subprocess.run(cmd + [mode, *spec, inp, out, *extra], capture_output=True, timeout=1800)
            if r.returncode != 0 or not os.path.exists(out):
                hashes[v] = f"FAILED rc={r.returncode} {r.stdout[-120:]!r} {r.stderr[-200:]!r}"
                continue
            hashes[v] = hashlib.sha256(open(out, "rb").read()).hexdigest()
            hashes[v + "_secs"] = round(time.time() - t0, 2)
            os.unlink(out)
        same = len({hashes[v] for v in VARIANTS}) == 1 and not hashes["native_release"].startswith("FAILED")
        ok_all &= same
        key = f"{mode}:{os.path.basename(spec[0])}:{len(recs)}#{idx}"
        report[key] = dict(hashes, identical=same)
        print(f"  {key:44s} identical={same}  sha256={hashes['native_release'][:16]}  " +
              " ".join(f"{v}={hashes.get(v + '_secs', '-')}s" for v in VARIANTS))
        if not same:
            for v in VARIANTS:
                print(f"      {v}: {hashes[v][:200]}")
    # load parity on adversarial pattern sets
    for kind in ("random_saturated_alphabet", "fanout_all_pairs", "sparse_byte_extremes", "duplicates_multi_digit", "long_disjoint_64"):
        pf = os.path.join(TMP, f"w4_{kind}.pat")
        open(pf, "w", encoding="utf-8").write("\n".join(dos.gen_patterns(kind, 20000, random.Random(2))) + "\n")
        outs = {}
        for v, cmd in VARIANTS.items():
            r = subprocess.run(cmd + ["load", pf, "-", "1", "1", "1"] + BIG, capture_output=True, timeout=1800)
            outs[v] = (r.returncode, r.stdout.decode(errors="replace").strip())
        same = len(set(outs.values())) == 1 and outs["native_release"][0] == 0
        ok_all &= same
        report[f"load:{kind}"] = {k: list(v) for k, v in outs.items()}
        print(f"  load:{kind:39s} identical={same}  {outs['native_release']}")
    # crash parity: Int32 value-pointer overflow must fail identically (panic / trap) in all 4 modes
    pf = os.path.join(TMP, "dos_meta_overflow.pat.txt")
    pat = "1" + "1".join("abcdefghijklmno") + "1"
    open(pf, "w").write((pat + "\n") * 524289)
    inp = os.path.join(TMP, "w4_ovf.in")
    write_records(inp, ["abcdefghijklmno"])
    crash = {}
    for v, cmd in VARIANTS.items():
        r = subprocess.run(cmd + ["opp", pf, "-", "1", "1", inp, inp + ".out"] + BIG, capture_output=True, timeout=1800)
        tail = (r.stdout + r.stderr).decode(errors="replace").strip().splitlines()
        crash[v] = f"rc={r.returncode} {tail[0][:90] if tail else ''}"
        print(f"  crash:meta_offset_int32_overflow {v:15s} {crash[v]}")
    report["crash:meta_offset_int32_overflow"] = crash
    print("4-mode parity:", "ALL IDENTICAL" if ok_all else "MISMATCH / FAILURE")
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
