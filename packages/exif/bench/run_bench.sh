#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/exif:
# Pion Native (`packages/exif`, --release) vs Rust `kamadak-exif` (0.6.2, --release).
# All build artifacts and generated corpora live in /tmp/pion-exif-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-exif-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
ITERS="${EXIF_BENCH_ITERS:-10000}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating deterministic EXIF corpus (JPEG + BE TIFF + WebP + PNG) -> $DATA_DIR"
CORPUS_BYTES=$(python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR")
TOTAL_BYTES=$((CORPUS_BYTES * ITERS))
TOTAL_OPS=$((4 * ITERS))
echo "    corpus=${CORPUS_BYTES} B (4 files), iters=${ITERS}, total=${TOTAL_BYTES} B, parses=${TOTAL_OPS}"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_exif" "$BENCH_DIR/pion_bench"

echo "==> Building Rust kamadak-exif benchmark (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/exif_bench_kamadak" "$BIN_DIR/rust_kamadak"

echo ""
echo "=== EXIF Parse 4-Container Corpus (${ITERS}x = ${TOTAL_OPS} parses, ${TOTAL_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "EXIF Parse JPEG+TIFF(BE)+WebP+PNG (${TOTAL_OPS} parses)" \
  --impl "pion_exif=$BIN_DIR/pion_exif $DATA_DIR $ITERS" \
  --impl "rust_kamadak_exif=$BIN_DIR/rust_kamadak $DATA_DIR $ITERS" \
  --baseline rust_kamadak_exif \
  --warmup 1 --rounds 5 --bytes "$TOTAL_BYTES" --ops "$TOTAL_OPS" \
  --md-out "$OUT_DIR/bench.md" --json-out "$OUT_DIR/bench.json"
