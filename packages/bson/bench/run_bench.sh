#!/bin/sh
# Head-to-head benchmark runner for packages/bson:
# Pion Native (packages/bson) vs Rust (bson 2.13, --release --locked).
# All build artifacts and temporary inputs are placed in /tmp/w13-bson-bench.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/w13-bson-bench"
BIN_DIR="$OUT_DIR/bin"
CORPUS_FILE="$OUT_DIR/corpus_1000.bson"

mkdir -p "$BIN_DIR"

echo "==> Generating 1,000 composite BSON 1.1 documents -> $CORPUS_FILE"
python3 "$BENCH_DIR/gen_corpus.py" "$CORPUS_FILE" 1000
CORPUS_BYTES=$(wc -c < "$CORPUS_FILE" | tr -d ' ')
TOTAL_50K_BYTES=$((CORPUS_BYTES * 50))
TOTAL_20K_BYTES=$((CORPUS_BYTES * 20))

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust bson benchmark (--release --locked, target in /tmp)"
rm -rf "$OUT_DIR/rust-build"
cp -R "$BENCH_DIR/rust_bench" "$OUT_DIR/rust-build"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bson_rust_bench" "$BIN_DIR/rust_bench"

echo ""
echo "=== W1: BSON Decode (50,000 composite documents) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "BSON W1: Decode 50,000 Composite Documents" \
  --impl "pion=$BIN_DIR/pion_bench decode $CORPUS_FILE 50" \
  --impl "rust_bson=$BIN_DIR/rust_bench decode $CORPUS_FILE 50" \
  --baseline rust_bson \
  --warmup 1 --rounds 5 --ops 50000 --bytes "$TOTAL_50K_BYTES" \
  --md-out "$OUT_DIR/w1_decode.md" --json-out "$OUT_DIR/w1_decode.json"

echo ""
echo "=== W2: BSON Encode (50,000 composite documents) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "BSON W2: Encode 50,000 Composite Documents" \
  --impl "pion=$BIN_DIR/pion_bench encode $CORPUS_FILE 50" \
  --impl "rust_bson=$BIN_DIR/rust_bench encode $CORPUS_FILE 50" \
  --baseline rust_bson \
  --warmup 1 --rounds 5 --ops 50000 --bytes "$TOTAL_50K_BYTES" \
  --md-out "$OUT_DIR/w2_encode.md" --json-out "$OUT_DIR/w2_encode.json"

echo ""
echo "=== W3: BSON <-> Extended JSON v2 (Canonical + Relaxed, 20,000 documents) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "BSON W3: Extended JSON v2 Canonical + Relaxed Roundtrip (20,000 docs)" \
  --impl "pion=$BIN_DIR/pion_bench extjson $CORPUS_FILE 20" \
  --impl "rust_bson=$BIN_DIR/rust_bench extjson $CORPUS_FILE 20" \
  --baseline rust_bson \
  --warmup 1 --rounds 5 --ops 20000 --bytes "$TOTAL_20K_BYTES" \
  --md-out "$OUT_DIR/w3_extjson.md" --json-out "$OUT_DIR/w3_extjson.json"
