#!/bin/sh
# One-shot red-team audit for packages/woff2.
#   sh packages/woff2/audit/run_audit.sh [all|build|unit|real|vectors|limits|bombs|fuzz|prof]
# All artifacts (binaries, Cargo target, Python venv, corpora, reports) go to $AUDIT_OUT, default
# /private/tmp/pion-woff2-audit (the real path of /tmp on macOS, so wasm32 runs see the same paths).
# Nothing is written inside the repository.
set -u
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
AUDIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$AUDIT_DIR/../../.." && pwd)
AUDIT_OUT=${AUDIT_OUT:-/private/tmp/pion-woff2-audit}
BIN="$AUDIT_OUT/bin"
PY="$AUDIT_OUT/venv/bin/python"
SECTION=${1:-all}
FUZZ_N=${FUZZ_N:-12000}
mkdir -p "$BIN"
export AUDIT_OUT
export PYTHONDONTWRITEBYTECODE=1

venv() {
  if [ ! -x "$PY" ]; then
    python3 -m venv "$AUDIT_OUT/venv" || exit 1
    "$AUDIT_OUT/venv/bin/pip" -q install "fonttools==4.60.2" "brotli" || exit 1
  fi
}

build() {
  echo "==> build: Pion native (--release, debug) + wasm32, Rust wuff =0.2.10 (artifacts in $AUDIT_OUT)"
  pionc fmt --check "$AUDIT_DIR" || exit 1
  pionc check --json "$AUDIT_DIR" || exit 1
  rm -f "$BIN"/pion_audit "$BIN"/pion_audit_debug "$BIN"/pion_audit.wasm "$BIN"/rust_audit
  pionc build --release -o "$BIN/pion_audit" "$AUDIT_DIR" || exit 1
  pionc build -o "$BIN/pion_audit_debug" "$AUDIT_DIR" || exit 1
  pionc build --release --target wasm32 -o "$BIN/pion_audit.wasm" "$AUDIT_DIR" || exit 1
  rm -rf "$AUDIT_OUT/rust-proj" && mkdir -p "$AUDIT_OUT/rust-proj"
  cp -R "$AUDIT_DIR/diff/rust/Cargo.toml" "$AUDIT_DIR/diff/rust/src" "$AUDIT_OUT/rust-proj/"
  CARGO_TARGET_DIR="$AUDIT_OUT/rust-target" cargo build -q --release \
    --manifest-path "$AUDIT_OUT/rust-proj/Cargo.toml" || exit 1
  # rm + cp (not cp over): macOS kills a binary whose signed pages were replaced in place
  cp "$AUDIT_OUT/rust-target/release/woff2-audit-rust" "$BIN/rust_audit"
}

unit() {
  echo "==> unit: red-team Pion tests, one process per test (redteam_* FAIL while a defect exists; control_* PASS)"
  bad=0
  for t in $(grep -o '^test "[a-z0-9_]*"' "$AUDIT_DIR/redteam_test.pion" | cut -d'"' -f2); do
    out=$(pionc test --json --filter "$t" "$AUDIT_DIR" 2>&1)
    if echo "$out" | grep -q '"ok":true' && ! echo "$out" | grep -q '"ok":false'; then r=PASS; else r=FAIL; fi
    echo "$out" | grep -q 'out of bounds' && r="$r ($(echo "$out" | grep -o 'pion panic: index[^"]*' | head -1 | cut -c1-60))"
    case "$t" in redteam_*) k=RED ;; *) k=CTRL ;; esac
    printf "  %-4s %-62s %s\n" "$k" "$t" "$r"
    [ "$k" = CTRL ] && [ "${r%% *}" != PASS ] && bad=1
  done
  return $bad
}

bombs() {
  echo "==> bombs: tiny inputs vs. peak RSS / time (Pion native --release vs wuff)"
  "$PY" "$AUDIT_DIR/difftest.py" bombs
}

prof() {
  echo "==> prof: decode vs. decompression-stage timing on the bench corpus (Arial / Monaco)"
  python3 "$ROOT_DIR/packages/woff2/bench/gen_data.py" "$AUDIT_OUT/benchcorp" >/dev/null || exit 1
  python3 "$AUDIT_DIR/prof.py" "$BIN" 20 7 "$AUDIT_OUT/benchcorp/arial.woff2" \
    "$AUDIT_OUT/benchcorp/monaco.woff2" "$AUDIT_OUT/benchcorp/arial.woff"
}

rc=0
case "$SECTION" in
  build) venv; build ;;
  unit) unit || rc=1 ;;
  real|vectors|limits|fuzz) venv; "$PY" "$AUDIT_DIR/difftest.py" "$SECTION" --fuzz "$FUZZ_N" || rc=1 ;;
  bombs) venv; bombs ;;
  prof) prof ;;
  all)
    venv
    build
    unit || rc=1
    for s in real vectors limits fuzz; do "$PY" "$AUDIT_DIR/difftest.py" "$s" --fuzz "$FUZZ_N" || rc=1; done
    bombs
    prof
    ;;
  *) echo "unknown section $SECTION"; exit 2 ;;
esac
cd "$ROOT_DIR" && git status --porcelain --ignored -- packages/woff2 | grep -v '^?? packages/woff2/audit/$' \
  && { echo "worktree NOT clean"; rc=1; }
exit $rc
