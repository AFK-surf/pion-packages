#!/usr/bin/env python3
"""F1 evidence: float fidelity of Pion's printers vs Rust toml 1.2.

Writes N doubles (deterministic seed) to a TOML file, then checks
  (a) to_toml_test_json value text  == the parsed double      (pion_cli decode)
  (b) stringify -> re-parse by Rust toml 1.2 == original double (pion_cli roundtrip)
and the same (b) for Rust's own toml::to_string.  Python's float() is the arbiter (correctly rounded).
usage: float_fuzz.py <workdir> [n]
"""
import json, math, os, random, struct, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from difflib_toml import BIN

work = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
os.makedirs(work, exist_ok=True)
r = random.Random(7)
sets = {
    "random_bits_shortest": [],      # uniformly random finite doubles, shortest repr
    "python_random_0_1": [],         # random.random(): what any Python/JS program emits
    "config_like_6_decimals": [],    # round(x, <=6)
}
for _ in range(n):
    while True:
        x = struct.unpack("<d", struct.pack("<Q", r.getrandbits(64)))[0]
        if math.isfinite(x):
            break
    sets["random_bits_shortest"].append(repr(x))
    sets["python_random_0_1"].append(repr(r.random()))
    sets["config_like_6_decimals"].append(repr(round(r.uniform(0, 10 ** r.randint(0, 6)), r.randint(1, 6))))


def lit(t):
    return t if ("e" in t or "." in t or "inf" in t or "nan" in t) else t + ".0"


def decode(cmd, path):
    return json.loads(subprocess.run(cmd + [path], capture_output=True, check=True).stdout)


print(f"{'set':26s} {'n':>6s} {'pion json':>10s} {'pion stringify':>15s} {'rust stringify':>15s}")
total_bad = 0
for name, vals in sets.items():
    src = os.path.join(work, f"floats_{name}.toml")
    with open(src, "w") as f:
        f.write("".join(f"f{i} = {lit(t)}\n" for i, t in enumerate(vals)))
    pj = decode([f"{BIN}/pion_cli", "decode"], src)
    bad_json = [vals[i] for i in range(len(vals)) if float(pj[f"f{i}"]["value"]) != float(vals[i])]
    res = {}
    for impl, cmd in (("pion", [f"{BIN}/pion_cli", "roundtrip"]), ("rust", [f"{BIN}/rust_ref", "roundtrip"])):
        out = os.path.join(work, f"floats_{name}.{impl}.toml")
        with open(out, "wb") as f:
            f.write(subprocess.run(cmd + [src], capture_output=True, check=True).stdout)
        rj = decode([f"{BIN}/rust_ref", "decode"], out)
        res[impl] = [vals[i] for i in range(len(vals)) if float(rj[f"f{i}"]["value"]) != float(vals[i])]
    total_bad += len(res["pion"])
    print(f"{name:26s} {len(vals):6d} {len(bad_json):10d} {len(res['pion']):15d} {len(res['rust']):15d}")
    if res["pion"]:
        i = vals.index(res["pion"][0])
        print(f"    e.g. {vals[i]}  ->  pion json {pj[f'f{i}']['value']}")
print("RESULT:", "FAIL" if total_bad else "PASS", f"({total_bad} doubles corrupted by pion stringify)")
