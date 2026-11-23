"""Native debug / Native release / Wasm32 debug / Wasm32 release byte-for-byte parity.

Actually EXECUTES the .wasm builds of audit/probe under node (pion_wasm_rt.mjs), not just compiles.
Corpora: every html5lib tree-construction #data (doc + frag tree dumps, to_html), the XSS vectors
+ grammar fuzz (sanitize, keep-comments sanitize), the CSS selector differential set, and stress
inputs (5k nesting, adoption amplification, 100 KB entity runs, invalid UTF-8-free binary-ish text).
Usage: wasm4.py <html5lib tree-construction dir> [--json out.json]
"""
import glob, hashlib, json, os, random, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from common import TMP, BIN, write_records, read_records
from html5lib_suite import parse_dat
from xss import VECTORS, gen
from css_diff import SELS, DOC

RT = os.path.expanduser("~/.pion/share/pion/pion_wasm_rt.mjs")
VARIANTS = {
    "native_debug": [os.path.join(BIN, "pion_probe_debug")],
    "native_release": [os.path.join(BIN, "pion_probe")],
    "wasm32_debug": ["node", RT, os.path.join(BIN, "pion_probe_debug.wasm")],
    "wasm32_release": ["node", RT, os.path.join(BIN, "pion_probe_release.wasm")],
}


def main():
    data = []
    for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.dat"))):
        data += [t["data"] for t in parse_dat(f)]
    rng = random.Random(7)
    xss = VECTORS + [gen(rng) for _ in range(3000)]
    sel = []
    for s in SELS:
        sel += [s, DOC]
    stress = ["<div>" * 5000 + "x", "<i>" * 200 + "<b>" * 200 + "</i>" * 200, "&amp;" * 20000, "&" * 50000,
              "<a " + "".join(f"a{i}=1 " for i in range(3000)) + ">", "<table><tr><td>" * 3000,
              "".join(chr(c) for c in range(1, 0x2000) if not 0xD800 <= c <= 0xDFFF)]
    jobs = [("tree", data, ["doc"]), ("tree", data, ["frag"]), ("html", data, ["doc"]), ("san", xss, []),
            ("sanc", xss, []), ("sel", sel, []), ("tree", stress, ["frag"]), ("san", stress, [])]
    report = {}
    ok_all = True
    for mode, recs, extra in jobs:
        inp = os.path.join(TMP, f"w4_{mode}_{'_'.join(extra)}.in")
        write_records(inp, recs)
        hashes = {}
        for v, cmd in VARIANTS.items():
            out = inp + f".{v}.out"
            t0 = time.time()
            r = subprocess.run(cmd + [mode, inp, out] + extra, capture_output=True, timeout=900)
            dt = time.time() - t0
            if r.returncode != 0 or not os.path.exists(out):
                hashes[v] = f"FAILED rc={r.returncode} {r.stderr[-300:]!r}"
                ok_all = False
                continue
            hashes[v] = hashlib.sha256(open(out, "rb").read()).hexdigest()
            hashes[v + "_secs"] = round(dt, 2)
            if v != "native_release":
                os.unlink(out)
        same = len({hashes[v] for v in VARIANTS}) == 1
        ok_all &= same
        key = f"{mode}{'/' + extra[0] if extra else ''}[{len(recs)} recs]"
        report[key] = {"identical": same, **hashes}
        print(f"{key:28s} identical={same} sha256={hashes['native_release'][:16]} "
              + " ".join(f"{v}={hashes.get(v + '_secs')}s" for v in VARIANTS))
        os.unlink(inp)
        if os.path.exists(inp + ".native_release.out"):
            os.unlink(inp + ".native_release.out")
    print("ALL 4 MODES BYTE-IDENTICAL, NO TRAP:", ok_all)
    # Wasm-only trap: match_complex_at() is recursive (README claims "zero recursion ... selector
    # traversal"); a child-combinator chain of n compounds recurses n deep. Native survives, wasm32
    # (node's default JS/wasm stack) traps with RangeError between n=6000 and n=12000.
    traps = {}
    for n in (6000, 12000):
        path = os.path.join(TMP, f"w4_deep_{n}.html")
        open(path, "w").write("<div>" * n)
        css = "sel:" + " > ".join(["div"] * n)
        row = {}
        for v, cmd in VARIANTS.items():
            r = subprocess.run(cmd + ["one", path, css], capture_output=True, timeout=300)
            first = (r.stdout + r.stderr).decode(errors="replace").strip().splitlines()
            row[v] = first[0][:80] if first else f"rc={r.returncode}"
        os.unlink(path)
        traps[f"child_chain_{n}"] = row
        print(f"deep child-combinator selector n={n} ({len(css) - 4} B):", json.dumps(row))
    report["deep_selector_recursion"] = traps
    if "--json" in sys.argv:
        json.dump(report, open(sys.argv[sys.argv.index("--json") + 1], "w"), indent=1)


if __name__ == "__main__":
    main()
