#!/bin/sh
# Differential oracle & fair head-to-head benchmark runner for packages/idna:
# Pion Native (`packages/idna`, --release) vs Rust `idna 1.1.0` (--release).
# All build artifacts and temporary outputs live in /tmp/pion-idna-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-idna-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
ITERS="${IDNA_BENCH_ITERS:-200}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating differential & benchmark corpora -> $DATA_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_idna" "$BENCH_DIR/pion_bench"

echo "==> Building Rust idna benchmark (--release, target in /tmp)"
LOCK_FLAG=""
if [ -f "$BENCH_DIR/rust_bench/Cargo.lock" ]; then
  LOCK_FLAG="--locked"
fi
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release $LOCK_FLAG \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/idna_rust_bench" "$BIN_DIR/rust_idna"

echo ""
echo "=== Differential Oracle: Pion idna vs Rust idna 1.1.0 ==="
"$BIN_DIR/pion_idna" diff "$DATA_DIR/diff_corpus.tsv" > "$OUT_DIR/pion.diff"
"$BIN_DIR/rust_idna" diff "$DATA_DIR/diff_corpus.tsv" > "$OUT_DIR/rust.diff"
TOTAL_DIFF=$(wc -l < "$DATA_DIR/diff_corpus.tsv" | tr -d ' ')
if diff -u "$OUT_DIR/rust.diff" "$OUT_DIR/pion.diff"; then
  echo "PASS: ${TOTAL_DIFF}/${TOTAL_DIFF} differential cases matched byte-for-byte (0 deviations)"
else
  echo "FAIL: divergence detected between Pion idna and Rust idna!" >&2
  exit 1
fi

echo ""
echo "=== Head-to-Head Benchmark 1: Multilingual IDN Corpus (200 domains x ${ITERS} iters, ToASCII + ToUnicode) ==="
MIXED_BYTES=$(wc -c < "$DATA_DIR/bench_mixed.txt" | tr -d ' ')
MIXED_TOTAL=$((MIXED_BYTES * ITERS))
MIXED_OPS=$((200 * ITERS * 2))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "IDNA UTS #46 ToASCII+ToUnicode (Multilingual IDN, 200x${ITERS})" \
  --impl "pion_idna=$BIN_DIR/pion_idna bench $DATA_DIR/bench_mixed.txt $ITERS" \
  --impl "rust_idna=$BIN_DIR/rust_idna bench $DATA_DIR/bench_mixed.txt $ITERS" \
  --baseline rust_idna \
  --warmup 1 --rounds 5 --bytes "$MIXED_TOTAL" --ops "$MIXED_OPS" \
  --md-out "$OUT_DIR/bench_mixed.md" --json-out "$OUT_DIR/bench_mixed.json"

echo ""
echo "=== Head-to-Head Benchmark 2: Real-World Traffic Corpus (70% ASCII / 30% IDN, 200x${ITERS}) ==="
RW_BYTES=$(wc -c < "$DATA_DIR/bench_realworld.txt" | tr -d ' ')
RW_TOTAL=$((RW_BYTES * ITERS))
RW_OPS=$((200 * ITERS * 2))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "IDNA UTS #46 ToASCII+ToUnicode (Real-World 70% ASCII / 30% IDN, 200x${ITERS})" \
  --impl "pion_idna=$BIN_DIR/pion_idna bench $DATA_DIR/bench_realworld.txt $ITERS" \
  --impl "rust_idna=$BIN_DIR/rust_idna bench $DATA_DIR/bench_realworld.txt $ITERS" \
  --baseline rust_idna \
  --warmup 1 --rounds 5 --bytes "$RW_TOTAL" --ops "$RW_OPS" \
  --md-out "$OUT_DIR/bench_realworld.md" --json-out "$OUT_DIR/bench_realworld.json"
