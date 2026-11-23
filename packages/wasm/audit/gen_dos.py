#!/usr/bin/env python3
"""DoS / complexity-cliff probes.  usage: gen_dos.py <out_dir>

Every probe is a *valid* (or cheaply-invalid) module whose cost should be linear in its
size.  run_audit.sh times Pion (`harness time`) against wasmparser (`oracle time`) and
records peak RSS with /usr/bin/time.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wasmgen import *  # noqa: E402,F401,F403


def probes():
    out = []
    # 1. Export-name uniqueness check is O(n^2) in Pion (linear scan over all previous names).
    for n in (10_000, 25_000, 50_000, 100_000):
        out.append((f"exports_{n}", single_func(b"\x0b", exports=[export("e%06d" % i, 0, 0) for i in range(n)])))
    # 2. Locals amplification: every local of every function is materialised one-by-one
    #    (validate_func_body pushes `count` ints per group; print_wat prints them all).
    for nf in (200, 1000, 2000):
        body = code_entry(b"\x0b", [(50_000, I32)])
        out.append((f"locals_50k_x{nf}funcs", module(types=[([], [])], funcs=[0] * nf, codes=[body] * nf)))
    # 3. br_table: 100,000 targets to a label with 8 results -> targets x arity pop/push.
    res = [I64] * 8
    body = b"\x02\x01" + b"".join(i64c(0) for _ in res) + i32c(0) + b"\x0e" + vec(u32(0) for _ in range(100_000)) + \
        u32(0) + b"\x0b" + b"\x1a" * 8 + b"\x0b"
    out.append(("br_table_100k_arity8", module(types=[([], []), ([], res)], funcs=[0], codes=[code_entry(body)])))
    # 4. Large straight-line function (memory per decoded instruction).
    body = (i32c(1) + b"\x1a") * 450_000 + b"\x0b"
    out.append(("straight_line_900k_instrs", single_func(body)))
    # 5. Many tiny functions.
    out.append(("funcs_200k_tiny", module(types=[([], [])], funcs=[0] * 200_000, codes=[code_entry(b"\x0b")] * 200_000)))
    # 6. Deep nesting at Pion's control-depth limit (4,095 levels) x 200 functions.
    deep = code_entry(b"\x02\x40" * 4095 + b"\x0b" * 4095 + b"\x0b")
    out.append(("nesting_4095_x200funcs", module(types=[([], [])], funcs=[0] * 200, codes=[deep] * 200)))
    return out


def main():
    d = sys.argv[1]
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "manifest.tsv"), "w") as m:
        for i, (n, b) in enumerate(probes()):
            with open(os.path.join(d, f"{n}.wasm"), "wb") as f:
                f.write(b)
            m.write(f"{i}\t{n}\t{len(b)}\n")
    print(f"wrote {len(probes())} DoS probes to {d}")


if __name__ == "__main__":
    main()
