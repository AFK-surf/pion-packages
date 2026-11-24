#!/bin/sh
# Differential oracle & fair head-to-head benchmark runner for packages/opentype:
# Pion Native (`packages/opentype`, --release) vs Rust `ttf-parser 0.25.1` (--release).
# All build artifacts and temporary outputs live in /tmp/pion-opentype-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-opentype-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
ITERS="${OPENTYPE_BENCH_ITERS:-200}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating synthetic 512-glyph variable font fallback -> $DATA_DIR/synthetic_512.ttf"
SYNTH_BYTES=$(python3 "$BENCH_DIR/gen_fallback_font.py" "$DATA_DIR/synthetic_512.ttf")
echo "    synthetic_512.ttf = ${SYNTH_BYTES} B"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_opentype" "$BENCH_DIR/pion_bench"

echo "==> Building Rust ttf-parser benchmark (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/opentype_rust_bench" "$BIN_DIR/rust_opentype"

echo ""
echo "=== Differential Oracle: Pion opentype vs Rust ttf-parser 0.25.1 ==="
diff_font() {
  label="$1"
  path="$2"
  idx="$3"
  "$BIN_DIR/pion_opentype" diff "$path" "$idx" > "$OUT_DIR/pion.diff"
  "$BIN_DIR/rust_opentype" diff "$path" "$idx" > "$OUT_DIR/rust.diff"
  if diff -u "$OUT_DIR/rust.diff" "$OUT_DIR/pion.diff"; then
    echo "  PASS [$label (face $idx)]: 0 deviations"
    sed 's/^/    /' "$OUT_DIR/pion.diff"
  else
    echo "  FAIL [$label (face $idx)]: divergence detected!" >&2
    exit 1
  fi
}

diff_font "synthetic_512.ttf" "$DATA_DIR/synthetic_512.ttf" 0

BENCH_FONT="$DATA_DIR/synthetic_512.ttf"
BENCH_LABEL="synthetic_512.ttf"
BENCH_SIZE="$SYNTH_BYTES"

if [ -f "/System/Library/Fonts/Supplemental/Arial.ttf" ]; then
  diff_font "Arial.ttf" "/System/Library/Fonts/Supplemental/Arial.ttf" 0
  BENCH_FONT="/System/Library/Fonts/Supplemental/Arial.ttf"
  BENCH_LABEL="Arial.ttf"
  BENCH_SIZE=$(wc -c < "$BENCH_FONT" | tr -d ' ')
fi
if [ -f "/System/Library/Fonts/Supplemental/Georgia.ttf" ]; then
  diff_font "Georgia.ttf" "/System/Library/Fonts/Supplemental/Georgia.ttf" 0
fi
if [ -f "/System/Library/Fonts/Supplemental/Times New Roman.ttf" ]; then
  diff_font "Times New Roman.ttf" "/System/Library/Fonts/Supplemental/Times New Roman.ttf" 0
fi
if [ -f "/System/Library/Fonts/Supplemental/Courier New.ttf" ]; then
  diff_font "Courier New.ttf" "/System/Library/Fonts/Supplemental/Courier New.ttf" 0
fi
if [ -f "/System/Library/Fonts/Helvetica.ttc" ]; then
  diff_font "Helvetica.ttc" "/System/Library/Fonts/Helvetica.ttc" 0
  diff_font "Helvetica.ttc" "/System/Library/Fonts/Helvetica.ttc" 1
fi
if [ -f "/System/Library/Fonts/SFNS.ttf" ]; then
  diff_font "SFNS.ttf (Variable Font)" "/System/Library/Fonts/SFNS.ttf" 0
fi

echo ""
echo "=== Head-to-Head Benchmark: $BENCH_LABEL (${ITERS} iters: parse + 256 cmap/hmtx + 64 glyf outlines) ==="
TOTAL_BYTES=$((BENCH_SIZE * ITERS))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "OpenType Parse + cmap/hmtx + 64 Outlines ($BENCH_LABEL, ${ITERS}x)" \
  --impl "pion_opentype=$BIN_DIR/pion_opentype bench $BENCH_FONT 0 $ITERS" \
  --impl "rust_ttf_parser=$BIN_DIR/rust_opentype bench $BENCH_FONT 0 $ITERS" \
  --baseline rust_ttf_parser \
  --warmup 1 --rounds 5 --bytes "$TOTAL_BYTES" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench_main.md" --json-out "$OUT_DIR/bench_main.json"

echo ""
echo "=== Head-to-Head Benchmark: synthetic_512.ttf (${ITERS} iters) ==="
SYNTH_TOTAL=$((SYNTH_BYTES * ITERS))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "OpenType Parse + cmap/hmtx + 64 Outlines (synthetic_512.ttf, ${ITERS}x)" \
  --impl "pion_opentype=$BIN_DIR/pion_opentype bench $DATA_DIR/synthetic_512.ttf 0 $ITERS" \
  --impl "rust_ttf_parser=$BIN_DIR/rust_opentype bench $DATA_DIR/synthetic_512.ttf 0 $ITERS" \
  --baseline rust_ttf_parser \
  --warmup 1 --rounds 5 --bytes "$SYNTH_TOTAL" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench_synth.md" --json-out "$OUT_DIR/bench_synth.json"
