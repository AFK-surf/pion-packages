"""Native debug / Native release / Wasm32 debug / Wasm32 release byte-for-byte parity of the full
`info` dump. EXECUTES the .wasm builds under node (~/.pion/share/pion/pion_wasm_rt.mjs).
Corpora: targeted + random differential corpus, raw invalid-UTF-8 byte soup, adversarial stress
(depth/bracket bombs, 20k isolates, 2k paragraphs), plus `cls` / `tab` table dumps.
Usage: wasm4.py [--json out.json]"""
import hashlib, json, os, random, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, VARIANTS, write_records
import diff_fuzz

R, A = "א", "a"


def main():
    rng = random.Random(9)
    texts = diff_fuzz.targeted() + [diff_fuzz.rand_text(rng) for _ in range(5000)]
    recs = [rng.choice("-01") + t for t in texts]
    raw = [bytes([b"-01"[rng.randrange(3)]]) +
           bytes(rng.choice([rng.randrange(256), 0xE2, 0x80, 0xAB, 0xA9, 0xD7, 0x90, 0x28, 0x29, 0x0A])
                 for _ in range(rng.randint(1, 40))) for _ in range(3000)]
    stress = ["-" + R + "(" * 20000 + A + ")" * 20000, "1" + "⁧" * 20000 + A + "⁩" * 20000,
              "-" + ("‫‪" * 70 + A + R + "1") * 200, "-" + (R + " " + A + "\n") * 2000,
              "0" + (A + "⁦" + R + "⁩") * 5000, "-" + "⁨" * 5000 + R + "⁩" * 5000]
    jobs = [("info", recs), ("info", raw), ("info", stress), ("cls", ["x"]), ("tab", ["x"])]
    report, ok_all = {}, True
    for idx, (mode, rs) in enumerate(jobs):
        inp = os.path.join(TMP, f"w4_{idx}_{mode}.in")
        write_records(inp, rs)
        hashes = {}
        for v, cmd in VARIANTS.items():
            out = inp + f".{v}.out"
            t0 = time.time()
            r = subprocess.run(cmd + [mode, inp, out], capture_output=True, timeout=1800)
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
        key = f"{mode}[{len(rs)} recs]#{idx}"
        report[key] = dict(hashes, identical=same)
        secs = " ".join(f"{v}={hashes.get(v + '_secs', '-')}s" for v in VARIANTS)
        print(f"  {key:24s} identical={same}  sha256={hashes['native_release'][:16]}  {secs}")
        if not same:
            for v in VARIANTS:
                print(f"      {v}: {hashes[v][:200]}")
    print("  4-mode parity:", "ALL IDENTICAL" if ok_all else "MISMATCH / FAILURE")
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
