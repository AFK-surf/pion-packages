#!/bin/sh
# Head-to-head benchmark runner for packages/decimal:
#   Pion Native (--release) vs Rust rust_decimal (=1.37.2 --release).
# All build artifacts, Cargo lockfile, and generated inputs are isolated in /tmp.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-decimal-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_FILE="$OUT_DIR/decimals_50k.txt"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic 50k mixed decimal corpus -> $DATA_FILE"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"
DATA_BYTES=$(wc -c < "$DATA_FILE" | tr -d ' ')
PARSE_TOTAL_BYTES=$((DATA_BYTES * 10))

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_parse_fmt" "$BENCH_DIR/pion_parse_fmt"
pionc build --release -o "$BIN_DIR/pion_arith" "$BENCH_DIR/pion_arith"
pionc build --release -o "$BIN_DIR/pion_sort_agg" "$BENCH_DIR/pion_sort_agg"

echo "==> Building Rust rust_decimal (=1.37.2 --release, project & lockfile in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bench_parse_fmt" "$BIN_DIR/rust_parse_fmt"
cp "$OUT_DIR/rust-target/release/bench_arith" "$BIN_DIR/rust_arith"
cp "$OUT_DIR/rust-target/release/bench_sort_agg" "$BIN_DIR/rust_sort_agg"

echo ""
echo "=== BENCH 1 (PARSE+FMT): 50k Mixed Decimals x 10 rounds = 500k ops ($PARSE_TOTAL_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Decimal Parse + Format (500k ops)" \
  --impl "pion=$BIN_DIR/pion_parse_fmt $DATA_FILE" \
  --impl "rust_decimal=$BIN_DIR/rust_parse_fmt $DATA_FILE" \
  --baseline rust_decimal \
  --warmup 1 --rounds 5 --ops 500000 --bytes "$PARSE_TOTAL_BYTES" \
  --md-out "$OUT_DIR/parse_fmt.md" --json-out "$OUT_DIR/parse_fmt.json"

echo ""
echo "=== BENCH 2 (ARITH): Billing Stream 400k tx x 5 ops = 2M ops ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Decimal Billing Arithmetic Stream (2M ops)" \
  --impl "pion=$BIN_DIR/pion_arith" \
  --impl "rust_decimal=$BIN_DIR/rust_arith" \
  --baseline rust_decimal \
  --warmup 1 --rounds 5 --ops 2000000 \
  --md-out "$OUT_DIR/arith.md" --json-out "$OUT_DIR/arith.json"

echo ""
echo "=== BENCH 3 (SORT+AGG+ROUND): 50k Decimals x 10 rounds = 500k ops ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Decimal Sort + Aggregate + Banker's Round (500k ops)" \
  --impl "pion=$BIN_DIR/pion_sort_agg $DATA_FILE" \
  --impl "rust_decimal=$BIN_DIR/rust_sort_agg $DATA_FILE" \
  --baseline rust_decimal \
  --warmup 1 --rounds 5 --ops 500000 \
  --md-out "$OUT_DIR/sort_agg.md" --json-out "$OUT_DIR/sort_agg.json"
