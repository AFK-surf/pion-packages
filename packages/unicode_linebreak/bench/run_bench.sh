#!/bin/sh
# Differential oracle & fair head-to-head benchmark runner for packages/unicode_linebreak:
# Pion Native (`packages/unicode_linebreak`, --release) vs Rust `icu_segmenter 2.x` (--release).
# All build artifacts and temporary outputs live in /tmp/pion-unicode-linebreak-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-unicode-linebreak-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
ITERS="${ULB_BENCH_ITERS:-200}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating differential & benchmark corpora -> $DATA_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_linebreak" "$BENCH_DIR/pion_bench"

echo "==> Building Rust icu_segmenter benchmark (--release, target in /tmp)"
LOCK_FLAG=""
if [ -f "$BENCH_DIR/rust_bench/Cargo.lock" ]; then
  LOCK_FLAG="--locked"
fi
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release $LOCK_FLAG \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/unicode_linebreak_rust_bench" "$BIN_DIR/rust_linebreak"

echo ""
echo "=== Differential Oracle: Pion unicode_linebreak vs Rust icu_segmenter ==="
"$BIN_DIR/pion_linebreak" diff "$DATA_DIR/diff_corpus.tsv" > "$OUT_DIR/pion.diff"
"$BIN_DIR/rust_linebreak" diff "$DATA_DIR/diff_corpus.tsv" > "$OUT_DIR/rust.diff"
TOTAL_DIFF=$(wc -l < "$DATA_DIR/diff_corpus.tsv" | tr -d ' ')
if diff -u "$OUT_DIR/rust.diff" "$OUT_DIR/pion.diff"; then
  echo "PASS: ${TOTAL_DIFF}/${TOTAL_DIFF} differential cases matched byte-for-byte (0 deviations)"
else
  echo "FAIL: divergence detected between Pion unicode_linebreak and Rust icu_segmenter!" >&2
  exit 1
fi

echo ""
echo "=== Head-to-Head Benchmark 1: Multilingual Web/News Layout Corpus (x ${ITERS} iters) ==="
C1_BYTES=$(wc -c < "$DATA_DIR/bench_multilingual.txt" | tr -d ' ')
C1_TOTAL=$((C1_BYTES * ITERS))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "UAX #14 Line Breaking (Multilingual Web/News, ${C1_BYTES} B x ${ITERS})" \
  --impl "pion_linebreak=$BIN_DIR/pion_linebreak bench $DATA_DIR/bench_multilingual.txt $ITERS" \
  --impl "rust_icu_segmenter=$BIN_DIR/rust_linebreak bench $DATA_DIR/bench_multilingual.txt $ITERS" \
  --baseline rust_icu_segmenter \
  --warmup 1 --rounds 5 --bytes "$C1_TOTAL" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench_multilingual.md" --json-out "$OUT_DIR/bench_multilingual.json"

echo ""
echo "=== Head-to-Head Benchmark 2: Dense Tech Spec / Numbers / Punctuation Corpus (x ${ITERS} iters) ==="
C2_BYTES=$(wc -c < "$DATA_DIR/bench_spec_dense.txt" | tr -d ' ')
C2_TOTAL=$((C2_BYTES * ITERS))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "UAX #14 Line Breaking (Dense Tech Spec / Numbers / Punctuation, ${C2_BYTES} B x ${ITERS})" \
  --impl "pion_linebreak=$BIN_DIR/pion_linebreak bench $DATA_DIR/bench_spec_dense.txt $ITERS" \
  --impl "rust_icu_segmenter=$BIN_DIR/rust_linebreak bench $DATA_DIR/bench_spec_dense.txt $ITERS" \
  --baseline rust_icu_segmenter \
  --warmup 1 --rounds 5 --bytes "$C2_TOTAL" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench_spec_dense.md" --json-out "$OUT_DIR/bench_spec_dense.json"
