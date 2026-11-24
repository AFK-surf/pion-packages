#!/bin/sh
# Differential oracle & fair head-to-head benchmark runner for packages/unicode_segment:
# Pion Native (`packages/unicode_segment`, --release) vs Rust `unicode-segmentation 1.12.0` (--release).
# All build artifacts and temporary outputs live in /tmp/pion-unicode-segment-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-unicode-segment-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
ITERS="${SEG_BENCH_ITERS:-40}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating differential & benchmark corpora -> $DATA_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_segment" "$BENCH_DIR/pion_bench"

echo "==> Building Rust unicode-segmentation benchmark (--release, target in /tmp)"
LOCK_FLAG=""
if [ -f "$BENCH_DIR/rust_bench/Cargo.lock" ]; then
  LOCK_FLAG="--locked"
fi
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release $LOCK_FLAG \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/unicode_segment_rust_bench" "$BIN_DIR/rust_segment"

echo ""
echo "=== Differential Oracle: Pion unicode_segment vs Rust unicode-segmentation 1.12.0 ==="
"$BIN_DIR/pion_segment" diff "$DATA_DIR/diff_corpus.txt" > "$OUT_DIR/pion.diff"
"$BIN_DIR/rust_segment" diff "$DATA_DIR/diff_corpus.txt" > "$OUT_DIR/rust.diff"
TOTAL_DIFF=$(wc -l < "$DATA_DIR/diff_corpus.txt" | tr -d ' ')
if diff -u "$OUT_DIR/rust.diff" "$OUT_DIR/pion.diff"; then
  echo "PASS: ${TOTAL_DIFF}/${TOTAL_DIFF} differential cases matched byte-for-byte (0 deviations)"
else
  echo "FAIL: divergence detected between Pion unicode_segment and Rust unicode-segmentation!" >&2
  exit 1
fi

echo ""
echo "=== Head-to-Head Benchmark 1: Multilingual Web/Social Corpus (x${ITERS} iters, G+W+UW+S) ==="
M_BYTES=$(wc -c < "$DATA_DIR/bench_multilingual.txt" | tr -d ' ')
M_TOTAL=$((M_BYTES * ITERS * 4))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "UAX #29 Grapheme+Word+Sentence (Multilingual Web/Social, x${ITERS})" \
  --impl "pion_segment=$BIN_DIR/pion_segment bench $DATA_DIR/bench_multilingual.txt $ITERS" \
  --impl "rust_segment=$BIN_DIR/rust_segment bench $DATA_DIR/bench_multilingual.txt $ITERS" \
  --baseline rust_segment \
  --warmup 1 --rounds 5 --bytes "$M_TOTAL" \
  --md-out "$OUT_DIR/bench_multilingual.md" --json-out "$OUT_DIR/bench_multilingual.json"

echo ""
echo "=== Head-to-Head Benchmark 2: Technical Docs & Dense Punctuation Corpus (x${ITERS} iters, G+W+UW+S) ==="
T_BYTES=$(wc -c < "$DATA_DIR/bench_technical.txt" | tr -d ' ')
T_TOTAL=$((T_BYTES * ITERS * 4))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "UAX #29 Grapheme+Word+Sentence (Technical Docs & Punctuation, x${ITERS})" \
  --impl "pion_segment=$BIN_DIR/pion_segment bench $DATA_DIR/bench_technical.txt $ITERS" \
  --impl "rust_segment=$BIN_DIR/rust_segment bench $DATA_DIR/bench_technical.txt $ITERS" \
  --baseline rust_segment \
  --warmup 1 --rounds 5 --bytes "$T_TOTAL" \
  --md-out "$OUT_DIR/bench_technical.md" --json-out "$OUT_DIR/bench_technical.json"
