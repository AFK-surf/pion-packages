#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/toml:
# Pion Native (`packages/toml`) vs Rust `toml` (--release) vs Go `BurntSushi/toml`.
# All build artifacts and temporary inputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-toml-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_FILE="$OUT_DIR/corpus.toml"
ITERS="${TOML_BENCH_ITERS:-50}"

mkdir -p "$BIN_DIR"

echo "==> Generating realistic TOML corpus -> $DATA_FILE"
python3 "$BENCH_DIR/gen_data.py" "$DATA_FILE" 240
FILE_BYTES=$(wc -c < "$DATA_FILE" | tr -d ' ')
TOTAL_BYTES=$((FILE_BYTES * ITERS))
echo "    file=${FILE_BYTES} B, iters=${ITERS}, total=${TOTAL_BYTES} B"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_toml" "$BENCH_DIR/pion_bench"

echo "==> Building Rust toml benchmark (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/toml_bench_rust" "$BIN_DIR/rust_toml"

echo "==> Building Go BurntSushi/toml benchmark"
(cd "$BENCH_DIR/go_bench" && go build -o "$BIN_DIR/go_toml" .)

echo ""
echo "=== TOML v1.0.0 Steady-State Parse (${ITERS}x ${FILE_BYTES} B = ${TOTAL_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "TOML v1.0.0 Steady-State Parse (${ITERS}x Corpus)" \
  --impl "pion=$BIN_DIR/pion_toml $DATA_FILE $ITERS" \
  --impl "rust_toml=$BIN_DIR/rust_toml $DATA_FILE $ITERS" \
  --impl "go_burntsushi=$BIN_DIR/go_toml $DATA_FILE $ITERS" \
  --baseline rust_toml \
  --warmup 1 --rounds 5 --bytes "$TOTAL_BYTES" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench.md" --json-out "$OUT_DIR/bench.json"
