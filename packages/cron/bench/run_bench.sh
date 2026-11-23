#!/bin/sh
# Head-to-head 3-way benchmark runner for packages/cron
# (Pion Native vs Rust croner 2.1.0 vs Go robfig/cron/v3 3.0.1).
# All build artifacts and temporary inputs are placed in /private/tmp.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-cron-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_FILE="$OUT_DIR/exprs_100.txt"

mkdir -p "$BIN_DIR"

echo "==> Generating 100 production cron expressions -> $DATA_FILE"
python3 "$BENCH_DIR/gen_data.py" "$DATA_FILE"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_cron_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust croner benchmark (--release, target in /private/tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust/Cargo.toml"
cp "$OUT_DIR/rust-target/release/cron_bench_rust" "$BIN_DIR/rust_cron_bench"

echo "==> Building Go robfig/cron/v3 benchmark"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_cron_bench" .)

echo ""
echo "=== WORKLOAD 1: Parse 100 Production Cron Expressions x 1,000 Rounds (100k ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Cron W1: Parse 100 Production Expressions (100k ops)" \
  --impl "pion=$BIN_DIR/pion_cron_bench parse $DATA_FILE" \
  --impl "rust_croner=$BIN_DIR/rust_cron_bench parse $DATA_FILE" \
  --impl "go_robfig=$BIN_DIR/go_cron_bench parse $DATA_FILE" \
  --baseline rust_croner \
  --warmup 1 --rounds 5 --ops 100000 \
  --md-out "$OUT_DIR/w1_parse.md" --json-out "$OUT_DIR/w1_parse.json"

echo ""
echo "=== WORKLOAD 2: Step 100 Expressions x 1,000 Future Triggers (100k next_after ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Cron W2: Next-After 100 Expressions x 1,000 Triggers (100k ops)" \
  --impl "pion=$BIN_DIR/pion_cron_bench next $DATA_FILE" \
  --impl "rust_croner=$BIN_DIR/rust_cron_bench next $DATA_FILE" \
  --impl "go_robfig=$BIN_DIR/go_cron_bench next $DATA_FILE" \
  --baseline rust_croner \
  --warmup 1 --rounds 5 --ops 100000 \
  --md-out "$OUT_DIR/w2_next.md" --json-out "$OUT_DIR/w2_next.json"

echo ""
echo "=== WORKLOAD 3: Sparse / Rare Dates Across Centuries (Leap Day 29 Feb, Year-End, 10k ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Cron W3: Sparse / Rare Dates Stepping (10k ops)" \
  --impl "pion=$BIN_DIR/pion_cron_bench sparse" \
  --impl "rust_croner=$BIN_DIR/rust_cron_bench sparse" \
  --impl "go_robfig=$BIN_DIR/go_cron_bench sparse" \
  --baseline rust_croner \
  --warmup 1 --rounds 5 --ops 10000 \
  --md-out "$OUT_DIR/w3_sparse.md" --json-out "$OUT_DIR/w3_sparse.json"

echo ""
echo "=== WORKLOAD 4: Friday the 13th (DOM AND DOW, 10k ops, Pion vs Rust croner) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Cron W4: Friday the 13th (DOM AND DOW, 10k ops)" \
  --impl "pion=$BIN_DIR/pion_cron_bench fri13" \
  --impl "rust_croner=$BIN_DIR/rust_cron_bench fri13" \
  --baseline rust_croner \
  --warmup 1 --rounds 5 --ops 10000 \
  --md-out "$OUT_DIR/w4_fri13.md" --json-out "$OUT_DIR/w4_fri13.json"
