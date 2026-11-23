#!/bin/sh
# Head-to-head benchmark runner for packages/handlebars:
# Pion Native (`packages/handlebars` --release) vs Rust (`handlebars` 6.4.4 --locked --release).
# All temporary artifacts and generated corpora live in /private/tmp/w16-handlebars-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w16-handlebars-bench"
BIN_DIR="$OUT_DIR/bin"

W1_ITERS="${HBS_W1_ITERS:-1000}"
W2_ITERS="${HBS_W2_ITERS:-2000}"
W3_ITERS="${HBS_W3_ITERS:-200}"

mkdir -p "$BIN_DIR"

echo "==> Generating Handlebars benchmark corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_hbs" "$BENCH_DIR/pion_bench"

echo "==> Building Rust handlebars benchmark (--locked --release)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --locked --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/handlebars_bench_rust" "$BIN_DIR/rust_hbs"

echo ""
echo "=== W1: E-commerce HTML Page SSR (${W1_ITERS} precompiled renders) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: E-commerce HTML Page SSR (${W1_ITERS} precompiled renders)" \
  --impl "pion=$BIN_DIR/pion_hbs w1 $OUT_DIR $W1_ITERS" \
  --impl "rust_handlebars=$BIN_DIR/rust_hbs w1 $OUT_DIR $W1_ITERS" \
  --baseline rust_handlebars \
  --warmup 1 --rounds 5 --ops "$W1_ITERS" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: AI Prompt Compile + Render E2E (${W2_ITERS} iters) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: AI Prompt Compile + Render E2E (${W2_ITERS} iters)" \
  --impl "pion=$BIN_DIR/pion_hbs w2 $OUT_DIR $W2_ITERS" \
  --impl "rust_handlebars=$BIN_DIR/rust_hbs w2 $OUT_DIR $W2_ITERS" \
  --baseline rust_handlebars \
  --warmup 1 --rounds 5 --ops "$W2_ITERS" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: High-Escape-Density 500-Row HTML Table (${W3_ITERS} renders) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: High-Escape-Density 500-Row HTML Table (${W3_ITERS} renders)" \
  --impl "pion=$BIN_DIR/pion_hbs w3 $OUT_DIR $W3_ITERS" \
  --impl "rust_handlebars=$BIN_DIR/rust_hbs w3 $OUT_DIR $W3_ITERS" \
  --baseline rust_handlebars \
  --warmup 1 --rounds 5 --ops "$W3_ITERS" \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
