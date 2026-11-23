"""4-mode consistency: run one request file through native-release / native-debug / wasm32-release /
wasm32-debug Pion probes; every result line must be identical (aborts are normalised to CRASH and
must happen on the same requests in every mode).

usage: fourmode.py <requests.tsv> <bin_dir> <wasm_rt.mjs>
"""
import hashlib
import sys

from runner import run_impl

req, bindir, rt = sys.argv[1:4]
n = sum(1 for l in open(req) if l.strip())
modes = {
    "native_rel": [bindir + "/probe", "diff"],
    "native_dbg": [bindir + "/probe_dbg", "diff"],
    "wasm_rel": ["node", rt, bindir + "/probe.wasm", "diff"],
    "wasm_dbg": ["node", rt, bindir + "/probe_dbg.wasm", "diff"],
}
outs = {}
for m, cmd in modes.items():
    lines = run_impl(cmd, req, n, crash_restart=True, timeout=1800)
    outs[m] = ["CRASH" if l.startswith("CRASH") else l for l in lines]
    crashes = sum(1 for l in outs[m] if l == "CRASH")
    traps = sum(1 for l in lines if l.startswith("CRASH") and ("RuntimeError" in l or "unreachable" in l))
    h = hashlib.sha256("\n".join(outs[m]).encode()).hexdigest()
    print("  %-10s %d requests, aborts=%d (wasm RuntimeError/unreachable traps=%d) sha256=%s" % (m, n, crashes, traps, h[:16]))
base = outs["native_rel"]
diffs = [i for i in range(n) if any(outs[m][i] != base[i] for m in outs)]
print("  4-mode result: %s (%d differing requests)" % ("IDENTICAL" if not diffs else "DIFFERENT", len(diffs)))
for i in diffs[:10]:
    for m in outs:
        print("    #%d %-10s %s" % (i, m, outs[m][i][:160]))
sys.exit(1 if diffs else 0)
