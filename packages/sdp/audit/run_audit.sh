#!/bin/sh
# Red-team audit of packages/sdp v0.1.0: one command reproduces every piece of evidence.
#
#   sh packages/sdp/audit/run_audit.sh [all|tests|diff|fuzz|amp|perf]
#
# Pion packages/sdp vs Rust webrtc-rs `sdp` =0.9.0 and Mozilla `webrtc-sdp` =0.3.17 (--release),
# Native --release vs Wasm32 --release (node) parity. Needs pionc ($HOME/.pion/bin), cargo,
# node, python3. Every artefact (binaries, CARGO_TARGET_DIR, corpora, fuzz output) goes to
# $AUDIT_OUT (default /private/tmp/pion-sdp-audit); the git worktree stays clean.
set -eu

AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
OUT=${AUDIT_OUT:-/private/tmp/pion-sdp-audit}
BIN="$OUT/bin"
WHAT=${1:-all}
FUZZ_CASES=${FUZZ_CASES:-6000}
FUZZ_SEEDS=${FUZZ_SEEDS:-"1 2 3"}
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
export PYTHONDONTWRITEBYTECODE=1
WASM_RT="$HOME/.pion/share/pion/pion_wasm_rt.mjs"
mkdir -p "$BIN"

step() { printf '\n==== %s ====\n' "$*"; }
# Run with a wall-clock cap so a hang is reported instead of blocking the audit.
capped() { # seconds cmd...  (exit 124 = hang)
  if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi
}

build() {
  step "toolchain"
  pionc --version; cargo --version; node --version; python3 --version
  echo "audited: $(git -C "$ROOT_DIR" log -1 --format='%h %s' -- packages/sdp/src)"
  step "build: Pion probe native --release / debug, wasm32 --release / debug"
  pionc build --release -o "$BIN/probe" "$AUDIT_DIR/probe"
  pionc build -o "$BIN/probe_debug" "$AUDIT_DIR/probe"
  pionc build --release --target wasm32 -o "$BIN/probe.wasm" "$AUDIT_DIR/probe"
  pionc build --target wasm32 -o "$BIN/probe_debug.wasm" "$AUDIT_DIR/probe"
  step "build: Rust oracle (webrtc-rs sdp =0.9.0 + webrtc-sdp =0.3.17, --release; copied to \$AUDIT_OUT)"
  rm -rf "$OUT/rust-oracle" && mkdir -p "$OUT/rust-oracle"
  cp -R "$AUDIT_DIR/rust/Cargo.toml" "$AUDIT_DIR/rust/src" "$OUT/rust-oracle/"
  CARGO_TARGET_DIR="$OUT/rust-target" cargo build --release --quiet \
    --manifest-path "$OUT/rust-oracle/Cargo.toml"
  cp "$OUT/rust-target/release/sdp-audit-oracle" "$BIN/oracle"
}

run_tests() {
  step "pionc fmt/check/test: audit/redteam_test.pion (redteam_* FAIL = evidence; control_* must PASS)"
  (cd "$AUDIT_DIR" && pionc fmt --check . && pionc check --json . > "$OUT/check.json")
  (cd "$AUDIT_DIR" && pionc test --json -p sdp_redteam_audit . > "$OUT/tests.json" 2> "$OUT/tests.stderr") || true
  python3 - "$OUT/tests.json" <<'PY'
import json, sys, collections
t = open(sys.argv[1]).read()
d = json.loads(t[t.find("{"):])
c = collections.Counter()
for x in d["tests"]:
    lvl = x["name"].split("_")[1] if x["name"].startswith("redteam_") else "control"
    c[(lvl, x["ok"])] += 1
print(f"total={d['total']} passed={d['passed']} failed={d['failed']}")
for lvl in ("p0", "p1", "p2", "control"):
    print(f"  {lvl:8s} fail={c[(lvl, False)]:3d} pass={c[(lvl, True)]:3d}")
for x in d["tests"]:
    print(("  PASS " if x["ok"] else "  FAIL ") + x["name"])
bad = [x["name"] for x in d["tests"] if x["name"].startswith("control_") and not x["ok"]]
if bad:
    print("!! CONTROL FAILURES:", bad)
    sys.exit(1)
PY
  grep "pion panic" "$OUT/tests.stderr" | sed 's#^.*redteam_test.pion:#  redteam_test.pion:#' | cut -c1-200 || true
  step "package's own suite still green (pionc test packages/sdp)"
  pionc test --json "$AUDIT_DIR/.." 2>/dev/null | python3 -c 'import json,sys;t=sys.stdin.read();d=json.loads(t[t.find("{"):]);print("sdp_test.pion total=%d passed=%d failed=%d"%(d["total"],d["passed"],d["failed"]))'
}

run_diff() {
  step "differential: Pion vs webrtc-rs sdp 0.9.0 vs Mozilla webrtc-sdp 0.3.17"
  python3 "$AUDIT_DIR/diff/gen_corpus.py" "$OUT/corpus.tsv"
  "$BIN/probe" diff "$OUT/corpus.tsv" > "$OUT/pion.out"
  "$BIN/oracle" "$OUT/corpus.tsv" > "$OUT/rust.out"
  python3 "$AUDIT_DIR/diff/compare.py" "$OUT/pion.out" "$OUT/rust.out" --md "$OUT/diff.md"
  step "4-mode parity of the differential verdicts (native rel/dbg, wasm32 rel/dbg)"
  "$BIN/probe_debug" diff "$OUT/corpus.tsv" > "$OUT/pion_debug.out"
  node "$WASM_RT" "$BIN/probe.wasm" diff "$OUT/corpus.tsv" > "$OUT/pion_wasm.out"
  node "$WASM_RT" "$BIN/probe_debug.wasm" diff "$OUT/corpus.tsv" > "$OUT/pion_wasm_debug.out"
  shasum -a 256 "$OUT/pion.out" "$OUT/pion_debug.out" "$OUT/pion_wasm.out" "$OUT/pion_wasm_debug.out"
  n=$(shasum -a 256 "$OUT/pion.out" "$OUT/pion_debug.out" "$OUT/pion_wasm.out" "$OUT/pion_wasm_debug.out" | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
  [ "$n" = 1 ] && echo "PARITY OK: 4 modes byte-identical" || { echo "PARITY MISMATCH"; exit 1; }
}

run_fuzz() {
  step "structure-aware fuzz: parse -> summary -> serialize -> parse, native --release vs wasm32 --release"
  total=0
  for s in $FUZZ_SEEDS; do
    capped 600 "$BIN/probe" fuzz "$FUZZ_CASES" "$s" > "$OUT/fuzz_native_$s.out"
    capped 600 node "$WASM_RT" "$BIN/probe.wasm" fuzz "$FUZZ_CASES" "$s" > "$OUT/fuzz_wasm_$s.out"
    tail -1 "$OUT/fuzz_native_$s.out"
    if cmp -s "$OUT/fuzz_native_$s.out" "$OUT/fuzz_wasm_$s.out"; then
      echo "  seed $s: native == wasm32 (byte-identical output incl. verdict FNV)"
    else
      echo "  seed $s: NATIVE/WASM32 MISMATCH"; diff "$OUT/fuzz_native_$s.out" "$OUT/fuzz_wasm_$s.out" | head; exit 1
    fi
    grep VIOLATION "$OUT/fuzz_native_$s.out" | head -3 || true
    total=$((total + FUZZ_CASES))
  done
  echo "fuzz total cases per target: $total (0 panic / 0 trap / 0 hang if this line is reached)"
}

rss() { /usr/bin/time -l "$@" 2> "$OUT/time.txt" || true; grep -iE "maximum resident" "$OUT/time.txt" || cat "$OUT/time.txt" | tail -3; }

run_amp() {
  step "P0 amplification: one session-level a=ice-options line x N m-lines (default ParseLimits)"
  for m in 1 16 64 256; do rss "$BIN/probe" amp "$m" 400000 ice-options; done
  step "P0 amplification under wasm32 --release (4 GiB linear memory)"
  for m in 64 256; do
    /usr/bin/time -l node "$WASM_RT" "$BIN/probe.wasm" amp "$m" 400000 ice-options > "$OUT/amp_wasm.out" 2> "$OUT/amp_wasm.err" || echo "  exit=$? (trap)"
    cat "$OUT/amp_wasm.out"; grep -E "RangeError|maximum resident" "$OUT/amp_wasm.err" | head -2
  done
  step "P1 amplification: session-level a=fingerprint value copied per m-line"
  for m in 1 64 256; do rss "$BIN/probe" amp "$m" 400000 fingerprint; done
}

run_perf() {
  step "complexity: wall-clock phases at n, 4n, 16n (linear => ~4x per step)"
  for k in attrs media cands bundle; do
    for n in 16000 64000 256000; do "$BIN/probe" perf "$k" "$n"; done
  done
}

build
case "$WHAT" in
  all) run_tests; run_diff; run_fuzz; run_amp; run_perf ;;
  tests) run_tests ;;
  diff) run_diff ;;
  fuzz) run_fuzz ;;
  amp) run_amp ;;
  perf) run_perf ;;
  *) echo "unknown target: $WHAT" >&2; exit 2 ;;
esac
step "done; artefacts in $OUT"
echo "git status --porcelain --ignored (must be empty):"
git -C "$ROOT_DIR" status --porcelain --ignored
