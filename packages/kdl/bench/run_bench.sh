#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/kdl:
# Pion Native (`packages/kdl`) vs Rust `kdl` 6.x (`--release --locked`).
# All temporary artifacts are placed in /private/tmp/w15-kdl-bench to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w15-kdl-bench"
BIN_DIR="$OUT_DIR/bin"
W1_FILE="$OUT_DIR/w1_large_config.kdl"
W2_FILE="$OUT_DIR/w2_mixed_roundtrip.kdl"
W3_FILE="$OUT_DIR/w3_hot_reload.kdl"

W1_SECTIONS="${KDL_W1_SECTIONS:-3000}"
W1_ITERS="${KDL_W1_ITERS:-3}"
W2_BLOCKS="${KDL_W2_BLOCKS:-120}"
W2_ITERS="${KDL_W2_ITERS:-20}"
W3_ITERS="${KDL_W3_ITERS:-8000}"

mkdir -p "$BIN_DIR"

echo "==> Generating deterministic benchmark corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" w1 "$W1_FILE" "$W1_SECTIONS"
python3 "$BENCH_DIR/gen_data.py" w2 "$W2_FILE" "$W2_BLOCKS"
python3 "$BENCH_DIR/gen_data.py" w3 "$W3_FILE"

W1_BYTES=$(wc -c < "$W1_FILE" | tr -d ' ')
W2_BYTES=$(wc -c < "$W2_FILE" | tr -d ' ')
W3_BYTES=$(wc -c < "$W3_FILE" | tr -d ' ')
W1_TOTAL_BYTES=$((W1_BYTES * W1_ITERS))
W2_TOTAL_BYTES=$((W2_BYTES * W2_ITERS))
W3_TOTAL_BYTES=$((W3_BYTES * W3_ITERS))
echo "    W1=${W1_BYTES} B x ${W1_ITERS} = ${W1_TOTAL_BYTES} B"
echo "    W2=${W2_BYTES} B x ${W2_ITERS} = ${W2_TOTAL_BYTES} B"
echo "    W3=${W3_BYTES} B x ${W3_ITERS} = ${W3_TOTAL_BYTES} B"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="$OUT_DIR/pion-cache" pionc build --release -o "$BIN_DIR/pion_kdl" "$BENCH_DIR/pion_bench"

echo "==> Building Rust kdl benchmark (--release --locked, target in /private/tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/kdl_bench_rust" "$BIN_DIR/rust_kdl"

echo ""
echo "=== W1: Large Realistic KDL v2 Config Parse (${W1_ITERS}x ${W1_BYTES} B = ${W1_TOTAL_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Large Realistic KDL v2 Config Parse (${W1_ITERS}x ${W1_BYTES} B)" \
  --impl "pion=$BIN_DIR/pion_kdl w1 $W1_FILE $W1_ITERS" \
  --impl "rust_kdl=$BIN_DIR/rust_kdl w1 $W1_FILE $W1_ITERS" \
  --baseline rust_kdl \
  --warmup 1 --rounds 5 --bytes "$W1_TOTAL_BYTES" --ops "$W1_ITERS" \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== W2: Deeply Nested + Multiline/Raw/Types/Slashdash Parse + Format Roundtrip (${W2_ITERS}x ${W2_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Mixed KDL v2 Parse + Format + Re-Parse Roundtrip (${W2_ITERS}x ${W2_BYTES} B)" \
  --impl "pion=$BIN_DIR/pion_kdl w2 $W2_FILE $W2_ITERS" \
  --impl "rust_kdl=$BIN_DIR/rust_kdl w2 $W2_FILE $W2_ITERS" \
  --baseline rust_kdl \
  --warmup 1 --rounds 5 --bytes "$W2_TOTAL_BYTES" --ops "$W2_ITERS" \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W3: High-Frequency Small Config Parse + Query (${W3_ITERS}x ${W3_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: High-Frequency Small Config Parse + Extract Query (${W3_ITERS}x ${W3_BYTES} B)" \
  --impl "pion=$BIN_DIR/pion_kdl w3 $W3_FILE $W3_ITERS" \
  --impl "rust_kdl=$BIN_DIR/rust_kdl w3 $W3_FILE $W3_ITERS" \
  --baseline rust_kdl \
  --warmup 1 --rounds 5 --bytes "$W3_TOTAL_BYTES" --ops "$W3_ITERS" \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json"
