#!/usr/bin/env python3
"""Find the smallest nesting depth that crashes each `driver deep <depth> <kind>` probe in each of the
4 build modes (native debug / native release / wasm32 debug / wasm32 release).

usage: depth_bisect.py <bin dir> <pion_wasm_rt.mjs> [kinds...]

<bin dir> must hold pion_driver, pion_driver_dbg, pion_driver.wasm, pion_driver_dbg.wasm.
A probe "survives" when it exits 0 and prints `ok <kind> <depth>`; anything else (SIGSEGV 139,
`RangeError: Maximum call stack size exceeded`, wasm trap) is a crash. Searches 1..2,000,000.
"""
import os
import subprocess
import sys

KINDS = ["build", "parse", "parse_obj", "json", "eq", "clone", "diff", "copy", "patchgrow"]


def survives(cmd, depth, kind):
    try:
        r = subprocess.run(cmd + ["deep", str(depth), kind], capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return None
    return r.returncode == 0 and f"ok {kind} {depth}" in r.stdout, r


def bisect(cmd, kind, hi_cap=2_000_000):
    lo, hi = 1, 1000
    while True:
        s = survives(cmd, hi, kind)
        if s is None:
            return f">= {hi} (timeout)"
        if not s[0]:
            break
        lo = hi
        if hi >= hi_cap:
            return f"> {hi_cap} (no crash)"
        hi = min(hi * 4, hi_cap)
    last = s[1]
    while hi - lo > max(1, lo // 100):  # 1% precision
        mid = (lo + hi) // 2
        s = survives(cmd, mid, kind)
        if s is None or not s[0]:
            hi = mid
            if s is not None:
                last = s[1]
        else:
            lo = mid
    why = f"exit {last.returncode}"
    if "Maximum call stack" in last.stderr:
        why = "RangeError: Maximum call stack size exceeded"
    elif "memory access out of bounds" in last.stderr:
        why = "wasm trap: memory access out of bounds (shadow stack ran into the heap)"
    elif last.returncode in (139, -11):
        why = "SIGSEGV"
    elif last.returncode in (138, -10):
        why = "SIGBUS"
    return f"~{hi} ({why})"


def main():
    bdir, rt = sys.argv[1], sys.argv[2]
    kinds = sys.argv[3:] or KINDS
    modes = [("native-debug", [os.path.join(bdir, "pion_driver_dbg")]),
             ("native-release", [os.path.join(bdir, "pion_driver")]),
             ("wasm32-debug", ["node", rt, os.path.join(bdir, "pion_driver_dbg.wasm")]),
             ("wasm32-release", ["node", rt, os.path.join(bdir, "pion_driver.wasm")])]
    print("| probe | " + " | ".join(m for m, _ in modes) + " |")
    print("|---|" + "---|" * len(modes))
    for k in kinds:
        cells = [bisect(cmd, k) for _, cmd in modes]
        print(f"| `{k}` | " + " | ".join(cells) + " |", flush=True)


if __name__ == "__main__":
    main()
