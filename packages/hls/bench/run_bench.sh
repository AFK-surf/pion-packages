#!/bin/sh
# Differential oracle + fair head-to-head benchmark runner for packages/hls:
# Pion Native (`packages/hls`, --release) vs Rust `m3u8-rs 6.0.0` (--release --locked).
# All build artifacts and generated corpora live in /tmp/pion-hls-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-hls-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
BENCH_ITERS="${HLS_BENCH_ITERS:-50}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating HLS Master/Media/LL-HLS corpora -> $DATA_DIR"
COUNTS=$(python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR")
DIFF_N=$(echo "$COUNTS" | awk '{print $1}')
BENCH_N=$(echo "$COUNTS" | awk '{print $2}')
BENCH_BYTES=$(wc -c < "$DATA_DIR/bench_corpus.txt" | tr -d ' ')
echo "    diff=${DIFF_N} playlists, bench=${BENCH_N} playlists (${BENCH_BYTES} B)"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_hls" "$BENCH_DIR/pion_bench"

echo "==> Building Rust m3u8-rs benchmark (--release --locked, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/hls_rust_bench" "$BIN_DIR/rust_hls"

echo "==> Running differential oracle (Pion vs Rust m3u8-rs)"
"$BIN_DIR/pion_hls" diff "$DATA_DIR/diff_corpus.txt" > "$OUT_DIR/diff_pion.txt"
"$BIN_DIR/rust_hls" diff "$DATA_DIR/diff_corpus.txt" > "$OUT_DIR/diff_rust.txt"
python3 "$BENCH_DIR/diff_oracle.py" "$OUT_DIR/diff_pion.txt" "$OUT_DIR/diff_rust.txt"

echo ""
echo "=== HLS Parse Benchmark (${BENCH_N} playlists x ${BENCH_ITERS} iters) ==="
TOTAL_OPS=$((BENCH_N * BENCH_ITERS))
TOTAL_BYTES=$((BENCH_BYTES * BENCH_ITERS))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "HLS RFC 8216 + LL-HLS Parse (${TOTAL_OPS} playlists)" \
  --impl "pion_hls=$BIN_DIR/pion_hls bench $DATA_DIR/bench_corpus.txt $BENCH_ITERS" \
  --impl "rust_m3u8_rs=$BIN_DIR/rust_hls bench $DATA_DIR/bench_corpus.txt $BENCH_ITERS" \
  --baseline rust_m3u8_rs \
  --warmup 1 --rounds 5 --bytes "$TOTAL_BYTES" --ops "$TOTAL_OPS" \
  --md-out "$OUT_DIR/bench.md" --json-out "$OUT_DIR/bench.json"
