#!/usr/bin/env python3
"""4-mode (native_dbg / native_rel / wasm_dbg / wasm_rel) byte-for-byte consistency + DoS probes.

Every probe must exit 0 in every mode (no SIGSEGV, no Wasm32 RangeError / trap) and the 4 stdout
SHA-256 digests must be identical.
usage: four_mode.py <harness_dir> <tmp_dir> <ptbatch_input> <batch_input>
"""
import hashlib, os, subprocess, sys, time

HD, T, PTIN, BIN = sys.argv[1:5]
NATIVE = {"native_dbg": os.path.join(T, "h_dbg"), "native_rel": os.path.join(T, "h_rel")}
for name, out in NATIVE.items():
    cmd = ["pionc", "build", "-o", out, HD]
    if name == "native_rel":
        cmd.insert(2, "--release")
    subprocess.run(cmd, check=True, capture_output=True)
# warm the wasm builds once (pionc run caches them)
for rel in ([], ["--release"]):
    subprocess.run(["pionc", "run", "--target", "wasm32", *rel, HD, "--", "gen", "bq", "1"],
                   check=True, capture_output=True)


def run(mode, args):
    if mode in NATIVE:
        cmd = [NATIVE[mode], *args]
    else:
        rel = ["--release"] if mode == "wasm_rel" else []
        cmd = ["pionc", "run", "--target", "wasm32", *rel, HD, "--", *args]
    t0 = time.time()
    p = subprocess.run(cmd, capture_output=True, timeout=900)
    return p.returncode, hashlib.sha256(p.stdout).hexdigest(), time.time() - t0, p.stderr[-300:]


PROBES = [
    ["gen", "bq", "50000"], ["gen", "ul", "32000"], ["gen", "ol", "32000"], ["gen", "bq_list", "10000"],
    ["gen", "emph", "20000"], ["gen", "strong", "20000"], ["gen", "brackets", "20000"],
    ["gen", "links", "20000"], ["gen", "escapes", "8000"], ["gen", "html_lt", "100000"],
    ["gen", "html_lt_open", "100000"], ["gen", "html_comment", "100000"], ["gen", "html_quote", "50000"],
    ["gen", "inline_html", "50000"], ["gen", "table_cols", "5000"], ["gen", "table_rows", "20000"],
    ["gen", "cjk", "20000"], ["ptbatch", PTIN], ["batch", BIN],
]
MODES = ["native_dbg", "native_rel", "wasm_dbg", "wasm_rel"]
bad = 0
for pr in PROBES:
    res = {m: run(m, pr) for m in MODES}
    rcs = {m: r[0] for m, r in res.items()}
    shas = {r[1] for r in res.values()}
    ok = all(rc == 0 for rc in rcs.values()) and len(shas) == 1
    bad += not ok
    label = " ".join(pr[:3]) if pr[0] == "gen" else pr[0] + " <corpus>"
    times = " ".join(f"{m}={res[m][2]:.2f}s" for m in MODES)
    print(f"  {'OK ' if ok else 'BAD'} {label:28s} rc={list(rcs.values())} sha={next(iter(shas))[:16] if len(shas) == 1 else 'MISMATCH'} {times}")
    if not ok:
        for m in MODES:
            print(f"      {m}: rc={res[m][0]} sha={res[m][1][:16]} err={res[m][3]!r}")
print(f"4-mode probes: {len(PROBES)} total, {bad} inconsistent/crashing")
sys.exit(1 if bad else 0)
