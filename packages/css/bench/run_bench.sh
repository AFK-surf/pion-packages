#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/css:
# Pion Native (`packages/css`) vs Rust `cssparser =0.35.0` (--release) vs Node.js `css-tree@3.1.0`.
# All build artifacts and temporary inputs live in /private/tmp to keep git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-css-bench"
BIN_DIR="$OUT_DIR/bin"
NODE_PKG="$OUT_DIR/node_pkg"
CORPUS_FILE="$OUT_DIR/design_system.css"

BLOCKS="${CSS_BENCH_BLOCKS:-6000}"
TOK_ITERS="${CSS_TOK_ITERS:-5}"
PARSE_ITERS="${CSS_PARSE_ITERS:-3}"
MINIFY_ITERS="${CSS_MINIFY_ITERS:-2}"

mkdir -p "$BIN_DIR" "$NODE_PKG"

echo "==> Generating design-system CSS corpus ($BLOCKS blocks) -> $CORPUS_FILE"
python3 "$BENCH_DIR/gen_data.py" "$CORPUS_FILE" "$BLOCKS"
FILE_BYTES=$(wc -c < "$CORPUS_FILE" | tr -d ' ')
TOK_BYTES=$((FILE_BYTES * TOK_ITERS))
PARSE_BYTES=$((FILE_BYTES * PARSE_ITERS))
MINIFY_BYTES=$((FILE_BYTES * MINIFY_ITERS))
echo "    corpus=${FILE_BYTES} B"

if [ ! -d "$NODE_PKG/node_modules/css-tree" ]; then
  echo "==> Installing Node css-tree@3.1.0 in $NODE_PKG"
  (cd "$NODE_PKG" && npm init -y >/dev/null 2>&1 && npm install --no-audit --no-fund css-tree@3.1.0 >/dev/null)
fi

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_css" "$BENCH_DIR/pion_bench"

echo "==> Building Rust cssparser benchmark (--release, target in /private/tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/css_bench_rust" "$BIN_DIR/rust_css"

echo ""
echo "=== Workload 1: Large Design-System CSS Tokenize (${TOK_ITERS}x ${FILE_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 1: Large Design-System CSS Tokenize" \
  --impl "pion=$BIN_DIR/pion_css tokenize $CORPUS_FILE $TOK_ITERS" \
  --impl "rust_cssparser=$BIN_DIR/rust_css tokenize $CORPUS_FILE $TOK_ITERS" \
  --impl "node_csstree=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js tokenize $CORPUS_FILE $TOK_ITERS" \
  --baseline rust_cssparser \
  --warmup 1 --rounds 5 --bytes "$TOK_BYTES" \
  --md-out "$OUT_DIR/bench_tokenize.md" --json-out "$OUT_DIR/bench_tokenize.json"

echo ""
echo "=== Workload 2: Stylesheet AST Parse + Rule/Declaration/Important Count (${PARSE_ITERS}x ${FILE_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 2: Stylesheet AST Parse + Rule/Declaration Count" \
  --impl "pion=$BIN_DIR/pion_css parse $CORPUS_FILE $PARSE_ITERS" \
  --impl "rust_cssparser=$BIN_DIR/rust_css parse $CORPUS_FILE $PARSE_ITERS" \
  --impl "node_csstree=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js parse $CORPUS_FILE $PARSE_ITERS" \
  --baseline rust_cssparser \
  --warmup 1 --rounds 5 --bytes "$PARSE_BYTES" \
  --md-out "$OUT_DIR/bench_parse.md" --json-out "$OUT_DIR/bench_parse.json"

echo ""
echo "=== Workload 3: CSS Minify Throughput (${MINIFY_ITERS}x ${FILE_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 3: CSS Minify Throughput" \
  --impl "pion=$BIN_DIR/pion_css minify $CORPUS_FILE $MINIFY_ITERS" \
  --impl "rust_cssparser=$BIN_DIR/rust_css minify $CORPUS_FILE $MINIFY_ITERS" \
  --impl "node_csstree=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js minify $CORPUS_FILE $MINIFY_ITERS" \
  --baseline rust_cssparser \
  --warmup 1 --rounds 5 --bytes "$MINIFY_BYTES" \
  --md-out "$OUT_DIR/bench_minify.md" --json-out "$OUT_DIR/bench_minify.json"
