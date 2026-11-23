#!/usr/bin/env python3
"""Crash depth of every recursive consumer of a parsed `sql` AST, in all 4 build modes.

usage: depth.py <bin dir> <pion_wasm_rt.mjs>

`driver deep <shape> <n> <max_depth> <stage>` parses an n-long chain (with max_tokens / max_nodes
lifted, max_depth as given), runs one stage (`none` = parse + drop only, `sql` = to_sql,
`tables` = extract_tables, `ph` = extract_placeholders, `eq` = stmt_eq) and must exit 0 printing
the stage line. Anything else (SIGSEGV, `RangeError: Maximum call stack size exceeded`, wasm trap)
is a crash. Part 1 bisects the crash length of left-deep chains the Pratt loop builds *without*
consuming max_depth. Part 2 checks that `max_depth = 128` (the default) and the README's
"keep max_depth <= 256 on wasm32" really are safe for the depth-guarded shapes.
"""
import subprocess
import sys

B, RT = sys.argv[1], sys.argv[2]
MODES = {
    "native-release": [f"{B}/drv"],
    "native-debug": [f"{B}/drv_dbg"],
    "wasm32-release": ["node", RT, f"{B}/drv.wasm"],
    "wasm32-debug": ["node", RT, f"{B}/drv_dbg.wasm"],
}
# Chains the iterative Pratt / set-op loops build as left-deep trees: max_depth never sees them.
CHAINS = ["plus", "or", "concat", "cast", "subscript", "isnull", "collate", "union"]
STAGES = ["none", "sql", "tables", "ph", "eq"]
# Depth-guarded shapes: accepted up to max_depth, then rejected.
GUARDED = ["paren", "not", "neg", "subq", "from", "case", "func", "join", "cte"]


def run(cmd, shape, n, md, stage):
    try:
        r = subprocess.run(cmd + ["deep", shape, str(n), str(md), stage], capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return None, "timeout"
    want = "parsed" if stage == "none" else stage + " "
    ok = r.returncode == 0 and (want in r.stdout or "rejected" in r.stdout)
    why = f"exit {r.returncode}"
    if "Maximum call stack" in r.stderr:
        why = "RangeError: Maximum call stack size exceeded"
    elif "out of bounds" in r.stderr:
        why = "wasm trap: memory access out of bounds"
    elif r.returncode in (139, -11):
        why = "SIGSEGV"
    elif r.returncode in (138, -10):
        why = "SIGBUS"
    return ok, why


def bisect(cmd, shape, stage, cap=1_000_000):
    lo, hi = 0, 1000
    while True:
        ok, why = run(cmd, shape, hi, 128, stage)
        if ok is None:
            return f">={hi} (timeout)"
        if not ok:
            break
        lo = hi
        if hi >= cap:
            return f">{cap} ok"
        hi = min(hi * 4, cap)
    while hi - lo > max(1, lo // 50):  # 2 % precision
        mid = (lo + hi) // 2
        ok, w = run(cmd, shape, mid, 128, stage)
        if ok:
            lo = mid
        else:
            hi, why = mid, w
    return f"~{hi} ({why})"


def main():
    print("Part 1 - crash length of left-deep chains (max_depth=128, limits on tokens/nodes lifted)")
    print("| chain | stage | " + " | ".join(MODES) + " |")
    print("|---|---|" + "---|" * len(MODES))
    for shape in CHAINS:
        for stage in STAGES:
            cells = [bisect(cmd, shape, stage) for cmd in MODES.values()]
            print(f"| {shape} | {stage} | " + " | ".join(cells) + " |", flush=True)
    print()
    print("Part 2 - depth-guarded shapes at the deepest nesting each max_depth accepts (all stages)")
    print("| shape | max_depth | deepest accepted n | " + " | ".join(MODES) + " |")
    print("|---|---|---|" + "---|" * len(MODES))
    for md in (128, 256, 1024):
        for shape in GUARDED:
            n = deepest_accepted(shape, md)
            cells = []
            for cmd in MODES.values():
                bad = [f"{st}: {why}" for st in STAGES for ok, why in [run(cmd, shape, n, md, st)] if not ok]
                cells.append("ok" if not bad else "CRASH " + "; ".join(bad))
            print(f"| {shape} | {md} | {n} | " + " | ".join(cells) + " |", flush=True)


def deepest_accepted(shape, md):
    lo, hi = 1, md + 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        r = subprocess.run(MODES["native-release"] + ["deep", shape, str(mid), str(md), "none"], capture_output=True, text=True)
        if "parsed" in r.stdout:
            lo = mid
        else:
            hi = mid
    return lo

main()
