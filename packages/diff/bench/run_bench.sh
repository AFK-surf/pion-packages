#!/bin/sh
# Head-to-head benchmark: Pion Native (`packages/diff`) vs Rust `imara-diff` (--release)
# Mandatory stdout SHA-256 byte-for-byte verification via scripts/bench_compare.py.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
TMP_DIR="/tmp/diff-bench"
mkdir -p "$TMP_DIR"

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

echo "==> Generating benchmark corpus in $TMP_DIR"
python3 "$SCRIPT_DIR/gen_corpus.py"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release "$SCRIPT_DIR/pion_diff" -o "$TMP_DIR/bench_pion"

echo "==> Building Rust imara-diff benchmark (--release)"
rm -rf "$TMP_DIR/rust_src"
cp -R "$SCRIPT_DIR/rust_diff" "$TMP_DIR/rust_src"
cargo build --release --manifest-path "$TMP_DIR/rust_src/Cargo.toml" --target-dir "$TMP_DIR/rust-target"
RUST_BIN="$TMP_DIR/rust-target/release/bench_diff_rust"

BEFORE="$TMP_DIR/large_refactor_before.rs"
AFTER="$TMP_DIR/large_refactor_after.rs"
BYTES_TOTAL=$(python3 -c "import os; print(os.path.getsize('$BEFORE') + os.path.getsize('$AFTER'))")

# Steady-state iterations per process so Pion runtime >= 100ms
ITERS_HIST=50
ITERS_MYERS=30
TOTAL_BYTES_HIST=$((BYTES_TOTAL * ITERS_HIST))
TOTAL_BYTES_MYERS=$((BYTES_TOTAL * ITERS_MYERS))

echo ""
echo "==> Workload 1: Histogram Diff + Indent Slider + Unified Diff (10K-line refactor x $ITERS_HIST)"
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Diff: Histogram + Indent Slider + Unified Diff (10K-line refactor x $ITERS_HIST)" \
  --impl "pion=$TMP_DIR/bench_pion $BEFORE $AFTER histogram $ITERS_HIST" \
  --impl "rust-imara-diff=$RUST_BIN $BEFORE $AFTER histogram $ITERS_HIST" \
  --baseline rust-imara-diff \
  --warmup 1 --rounds 5 \
  --bytes "$TOTAL_BYTES_HIST" \
  --ops "$ITERS_HIST" \
  --json-out "$TMP_DIR/bench_histogram.json" \
  --md-out "$TMP_DIR/bench_histogram.md"

echo ""
echo "==> Workload 2: Myers Diff + Indent Slider + Unified Diff (10K-line refactor x $ITERS_MYERS)"
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Diff: Myers + Indent Slider + Unified Diff (10K-line refactor x $ITERS_MYERS)" \
  --impl "pion=$TMP_DIR/bench_pion $BEFORE $AFTER myers $ITERS_MYERS" \
  --impl "rust-imara-diff=$RUST_BIN $BEFORE $AFTER myers $ITERS_MYERS" \
  --baseline rust-imara-diff \
  --warmup 1 --rounds 5 \
  --bytes "$TOTAL_BYTES_MYERS" \
  --ops "$ITERS_MYERS" \
  --json-out "$TMP_DIR/bench_myers.json" \
  --md-out "$TMP_DIR/bench_myers.md"

if [ -f "$TMP_DIR/helix_syntax_before.rs" ] && [ -f "$TMP_DIR/helix_syntax_after.rs" ]; then
  HB="$TMP_DIR/helix_syntax_before.rs"
  HA="$TMP_DIR/helix_syntax_after.rs"
  HBYTES=$(python3 -c "import os; print(os.path.getsize('$HB') + os.path.getsize('$HA'))")
  HITERS=200
  HTOTAL=$((HBYTES * HITERS))
  echo ""
  echo "==> Workload 3: Real-world helix_syntax.rs Histogram Diff (x $HITERS)"
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "Diff: Real-world helix_syntax.rs Histogram + Unified Diff (x $HITERS)" \
    --impl "pion=$TMP_DIR/bench_pion $HB $HA histogram $HITERS" \
    --impl "rust-imara-diff=$RUST_BIN $HB $HA histogram $HITERS" \
    --baseline rust-imara-diff \
    --warmup 1 --rounds 5 \
    --bytes "$HTOTAL" \
    --ops "$HITERS" \
    --json-out "$TMP_DIR/bench_helix_hist.json" \
    --md-out "$TMP_DIR/bench_helix_hist.md"
fi
