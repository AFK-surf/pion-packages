#!/usr/bin/env python3
"""Run every hand-written probe (probes.py) through Pion, Rust toml 1.2 / 0.8, Go BurntSushi; print a verdict table.

Reference for TOML 1.0.0 = the majority of {rust_toml_0.8, go_burntsushi} (both TOML 1.0 parsers);
rust_toml_1.2 is shown for information (it implements TOML 1.1).
"""
import json, sys
sys.path.insert(0, __import__("os").path.dirname(__file__))
from probes import P
from difflib_toml import run, compare, IMPLS

def main():
    out = []
    ndiff = 0
    for name, data in P.items():
        res = {i: run(i, data) for i in IMPLS}
        ref08, refgo = res["rust_toml_0.8"], res["go_burntsushi"]
        c_pion_08 = compare(res["pion"], ref08)
        c_pion_go = compare(res["pion"], refgo)
        c_08_go = compare(ref08, refgo)
        flag = "OK"
        if c_pion_08 != "agree" and c_pion_go != "agree":
            flag = "PION-DIFFERS-FROM-BOTH"
        elif c_pion_08 != "agree" or c_pion_go != "agree":
            flag = "REFS-SPLIT"
        if flag != "OK" or "-v" in sys.argv:
            ndiff += flag != "OK"
            print(f"== {name}: {flag}")
            for i in IMPLS:
                s, v = res[i]
                print(f"   {i:14s} {s:7s} {json.dumps(v)[:160] if s == 'ok' else v[:160]}")
            print(f"   pion~0.8: {c_pion_08} | pion~go: {c_pion_go} | 0.8~go: {c_08_go}")
        out.append({"name": name, "flag": flag, "results": {i: res[i][0] for i in IMPLS}})
    print(f"\n{len(P)} probes, {ndiff} with disagreement")
    json.dump(out, open(sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != "-v" else "/dev/null", "w"), indent=1)

main()
