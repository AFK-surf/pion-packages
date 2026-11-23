#!/bin/sh
# Red-team audit driver for packages/wasm.
#
#   sh packages/wasm/audit/run_audit.sh [fuzz_count]      (default 20000)
#
# 1. builds the Pion harness (native debug/release + wasm32 debug/release) and the Rust oracle
#    (wasmparser / wasmprinter / wat 0.221.x, --locked) into /tmp/rt-wasm-*
# 2. runs the red-team unit tests (p0/p1/p2 FAIL = defects, control PASS)
# 3. three-way differential on the hand-written vectors and on a deterministic fuzz corpus:
#    Pion validate_bytes vs wasmparser(WASM2) vs V8 WebAssembly.validate, plus
#    Pion decode->encode and print_wat checked with wasmprinter / wat::parse_str
# 4. Native vs Wasm32 4-mode byte-identity of every verdict / re-encoding / WAT hash
# 5. DoS / complexity probes (time + peak RSS vs wasmparser)
# Nothing is written inside the repository.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
AUDIT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FUZZ_COUNT=${1:-20000}
BIN=/tmp/rt-wasm-bin
export PION_CACHE_DIR=/tmp/rt-wasm-pion-cache
RT_MJS="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
mkdir -p "$BIN"

echo "==> toolchain: $(pionc --version) | $(cargo --version) | node $(node --version)"

echo "==> building Pion harness (4 modes)"
pionc build --release -o "$BIN/harness" "$AUDIT/harness"
pionc build -o "$BIN/harness_debug" "$AUDIT/harness"
pionc build --release --target wasm32 -o "$BIN/harness_release.wasm" "$AUDIT/harness"
pionc build --target wasm32 -o "$BIN/harness_debug.wasm" "$AUDIT/harness"

echo "==> building Rust oracle (wasmparser/wasmprinter 0.221.3, wat 1.221.3, --locked)"
rm -rf /tmp/rt-wasm-oracle-build
cp -R "$AUDIT/oracle" /tmp/rt-wasm-oracle-build
CARGO_TARGET_DIR=/tmp/rt-wasm-oracle-target cargo build --release --locked --quiet \
  --manifest-path /tmp/rt-wasm-oracle-build/Cargo.toml
cp /tmp/rt-wasm-oracle-target/release/rt_wasm_oracle "$BIN/oracle"

echo ""
echo "==> red-team unit tests (expect: every p0_/p1_/p2_ FAILS, every control_ PASSES)"
pionc test --json --only-pkg "$AUDIT" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
bad = [t["name"] for t in d["tests"] if t["ok"] != t["name"].startswith("control")]
fails = [t["name"] for t in d["tests"] if not t["ok"]]
ctrl = [t for t in d["tests"] if t["name"].startswith("control")]
print("total=%d defect_tests_failing=%d control_passing=%d/%d unexpected=%s" % (
    d["total"], len(fails), sum(t["ok"] for t in ctrl), len(ctrl), bad or "none"))
for p in ("p0", "p1", "p2"):
    print("  %s FAIL: %d" % (p, sum(1 for n in fails if n.startswith(p + "_"))))
'

echo ""
echo "==> three-way differential: hand-written vectors"
rm -rf /tmp/rt-wasm-targeted
python3 "$AUDIT/gen_targeted.py" /tmp/rt-wasm-targeted
python3 "$AUDIT/diff.py" /tmp/rt-wasm-targeted "$BIN/harness" "$BIN/oracle" "$AUDIT/v8_validate.mjs"
python3 - <<'EOF'
rows = [l.rstrip("\n").split("\t") for l in open("/tmp/rt-wasm-targeted/results.tsv")][1:]
mism = [r for r in rows if (r[2] == "valid") != (r[5] == "OK")]
print("  spec expectation vs wasmparser(WASM2) mismatches:", len(mism), [r[1] for r in mism])
EOF

echo ""
echo "==> three-way differential: fuzz corpus ($FUZZ_COUNT modules, seed 20261123)"
rm -rf /tmp/rt-wasm-fuzz
python3 "$AUDIT/gen_fuzz.py" /tmp/rt-wasm-fuzz "$FUZZ_COUNT"
python3 "$AUDIT/diff.py" /tmp/rt-wasm-fuzz "$BIN/harness" "$BIN/oracle" "$AUDIT/v8_validate.mjs" --timeout 600

echo ""
echo "==> Native vs Wasm32 (4 modes)"
python3 "$AUDIT/wasm32_modes.py" /tmp/rt-wasm-targeted "$BIN" "$RT_MJS"
python3 "$AUDIT/wasm32_modes.py" /tmp/rt-wasm-fuzz "$BIN" "$RT_MJS"

echo ""
echo "==> DoS / complexity probes (Pion validate_bytes vs wasmparser WASM2 validate)"
rm -rf /tmp/rt-wasm-dos
python3 "$AUDIT/gen_dos.py" /tmp/rt-wasm-dos
python3 "$AUDIT/run_dos.py" /tmp/rt-wasm-dos "$BIN/harness" "$BIN/oracle" --timeout 300

echo ""
echo "==> per-file results: /tmp/rt-wasm-targeted/results.tsv  /tmp/rt-wasm-fuzz/results.tsv"
