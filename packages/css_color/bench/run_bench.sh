#!/bin/sh
# Differential oracle + fair head-to-head benchmark runner for packages/css_color:
# Pion Native (`packages/css_color`, --release) vs Rust Linebender `color 0.3.3` (--release --locked).
# All build artifacts and generated corpora live in /tmp/pion-css-color-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-css-color-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"
PARSE_ITERS="${CSS_COLOR_PARSE_ITERS:-100}"
CONV_ITERS="${CSS_COLOR_CONV_ITERS:-200}"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Generating CSS Color 4/5 corpus -> $DATA_DIR"
COUNTS=$(python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR")
PARSE_N=$(echo "$COUNTS" | awk '{print $1}')
MIX_N=$(echo "$COUNTS" | awk '{print $2}')
GAMUT_N=$(echo "$COUNTS" | awk '{print $3}')
PARSE_BYTES=$(wc -c < "$DATA_DIR/parse_corpus.txt" | tr -d ' ')
echo "    parse=${PARSE_N} cases (${PARSE_BYTES} B), color-mix=${MIX_N} cases, wide-gamut=${GAMUT_N} cases"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_css_color" "$BENCH_DIR/pion_bench"

echo "==> Building Rust Linebender color 0.3.3 benchmark (--release --locked, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/css_color_rust_bench" "$BIN_DIR/rust_css_color"

echo "==> Running differential oracle (Pion vs Rust color 0.3.3)"
"$BIN_DIR/pion_css_color" diff "$DATA_DIR/parse_corpus.txt" "$DATA_DIR/mix_corpus.txt" "$DATA_DIR/gamut_corpus.txt" > "$OUT_DIR/diff_pion.txt"
"$BIN_DIR/rust_css_color" diff "$DATA_DIR/parse_corpus.txt" "$DATA_DIR/mix_corpus.txt" > "$OUT_DIR/diff_rust.txt"
python3 "$BENCH_DIR/diff_oracle.py" "$OUT_DIR/diff_pion.txt" "$OUT_DIR/diff_rust.txt"

echo ""
echo "=== Scenario A: CSS Color 4 Parse + sRGB Convert (${PARSE_N} cases x ${PARSE_ITERS} iters) ==="
TOTAL_PARSE_OPS=$((PARSE_N * PARSE_ITERS))
TOTAL_PARSE_BYTES=$((PARSE_BYTES * PARSE_ITERS))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CSS Color 4 Parse + sRGB Convert (${TOTAL_PARSE_OPS} ops)" \
  --impl "pion_css_color=$BIN_DIR/pion_css_color bench_parse $DATA_DIR/parse_corpus.txt $PARSE_ITERS" \
  --impl "rust_color=$BIN_DIR/rust_css_color bench_parse $DATA_DIR/parse_corpus.txt $PARSE_ITERS" \
  --baseline rust_color \
  --warmup 1 --rounds 5 --bytes "$TOTAL_PARSE_BYTES" --ops "$TOTAL_PARSE_OPS" \
  --md-out "$OUT_DIR/bench_parse.md" --json-out "$OUT_DIR/bench_parse.json"

echo ""
echo "=== Scenario B: 4-Stage Color Space Pipeline sRGB->Oklch->P3->Lab->sRGB (${PARSE_N} colors x ${CONV_ITERS} iters) ==="
TOTAL_CONV_OPS=$((PARSE_N * CONV_ITERS))
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CSS Color 4 Space Pipeline sRGB->Oklch->P3->Lab->sRGB (${TOTAL_CONV_OPS} ops)" \
  --impl "pion_css_color=$BIN_DIR/pion_css_color bench_convert $DATA_DIR/parse_corpus.txt $CONV_ITERS" \
  --impl "rust_color=$BIN_DIR/rust_css_color bench_convert $DATA_DIR/parse_corpus.txt $CONV_ITERS" \
  --baseline rust_color \
  --warmup 1 --rounds 5 --ops "$TOTAL_CONV_OPS" \
  --md-out "$OUT_DIR/bench_convert.md" --json-out "$OUT_DIR/bench_convert.json"
