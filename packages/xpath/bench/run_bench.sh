#!/bin/sh
# Head-to-head benchmark runner for packages/xpath:
# Pion Native (`packages/xpath` --release) vs Rust `sxd-xpath` 0.4.2 (--release --locked)
# vs C `libxml2` (-O2).
# All build artifacts and caches live in /private/tmp/w15-xpath-bench to keep the git worktree 100% clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="${XPATH_BENCH_OUT:-/private/tmp/w15-xpath-bench}"
DATA_DIR="$OUT_DIR/data"
BIN_DIR="$OUT_DIR/bin"

W1_ROUNDS="${XPATH_W1_ROUNDS:-5}"
W2_ITERS="${XPATH_W2_ITERS:-20000}"
W3_ROUNDS="${XPATH_W3_ROUNDS:-5}"
W4_ROUNDS="${XPATH_W4_ROUNDS:-5}"
W5_ROUNDS="${XPATH_W5_ROUNDS:-5}"

mkdir -p "$DATA_DIR" "$BIN_DIR"

echo "==> Generating deterministic XML corpora (W1..W5)"
python3 "$BENCH_DIR/gen_data.py" "$DATA_DIR"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="$OUT_DIR/pion-cache" pionc build --release -o "$BIN_DIR/pion_xpath" "$BENCH_DIR/pion_bench"

echo "==> Building Rust sxd-xpath benchmark (--release --locked)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/xpath_rust_bench" "$BIN_DIR/rust_xpath"

echo "==> Building C libxml2 benchmark (-O2)"
XML2_CFLAGS=$(xml2-config --cflags 2>/dev/null || echo "-I$(xcrun --show-sdk-path 2>/dev/null)/usr/include/libxml2")
cc -O2 -w $XML2_CFLAGS "$BENCH_DIR/c_bench/libxml2_bench.c" -lxml2 -o "$BIN_DIR/c_libxml2"

echo ""
echo "=== W1: Large XML (~866 KB, 3,000 books) Precompiled 10 Composite XPath Queries (${W1_ROUNDS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Large XML (~866 KB) Precompiled 10 Composite XPath Batch Eval (${W1_ROUNDS}x)" \
  --impl "pion=$BIN_DIR/pion_xpath w1 $DATA_DIR/w1.xml $W1_ROUNDS" \
  --impl "rust_sxd=$BIN_DIR/rust_xpath w1 $DATA_DIR/w1.xml $W1_ROUNDS" \
  --impl "c_libxml2=$BIN_DIR/c_libxml2 w1 $DATA_DIR/w1.xml $W1_ROUNDS" \
  --baseline rust_sxd \
  --warmup 1 --rounds 5 --ops "$W1_ROUNDS" \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: High-Frequency XPath Compile + Eval (${W2_ITERS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: High-Frequency XPath Compile + Eval (${W2_ITERS}x)" \
  --impl "pion=$BIN_DIR/pion_xpath w2 $DATA_DIR/w2.xml $W2_ITERS" \
  --impl "rust_sxd=$BIN_DIR/rust_xpath w2 $DATA_DIR/w2.xml $W2_ITERS" \
  --impl "c_libxml2=$BIN_DIR/c_libxml2 w2 $DATA_DIR/w2.xml $W2_ITERS" \
  --baseline rust_sxd \
  --warmup 1 --rounds 5 --ops "$W2_ITERS" \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: Deep Recursive Axes + Aggregation (${W3_ROUNDS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: Deep Recursive Axes (descendant-or-self/ancestor/following-sibling + sum/normalize-space) (${W3_ROUNDS}x)" \
  --impl "pion=$BIN_DIR/pion_xpath w3 $DATA_DIR/w3.xml $W3_ROUNDS" \
  --impl "rust_sxd=$BIN_DIR/rust_xpath w3 $DATA_DIR/w3.xml $W3_ROUNDS" \
  --impl "c_libxml2=$BIN_DIR/c_libxml2 w3 $DATA_DIR/w3.xml $W3_ROUNDS" \
  --baseline rust_sxd \
  --warmup 1 --rounds 5 --ops "$W3_ROUNDS" \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"

echo ""
echo "=== W4: Large Node-Set Comparisons (//a = != < > //b, 8k x 8k) (${W4_ROUNDS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W4: Large Node-Set Comparisons (//a = != < > //b, 8k x 8k) (${W4_ROUNDS}x)" \
  --impl "pion=$BIN_DIR/pion_xpath w4 $DATA_DIR/w4.xml $W4_ROUNDS" \
  --impl "rust_sxd=$BIN_DIR/rust_xpath w4 $DATA_DIR/w4.xml $W4_ROUNDS" \
  --impl "c_libxml2=$BIN_DIR/c_libxml2 w4 $DATA_DIR/w4.xml $W4_ROUNDS" \
  --baseline rust_sxd \
  --warmup 1 --rounds 5 --ops "$W4_ROUNDS" \
  --md-out "$OUT_DIR/bench_w4.md" --json-out "$OUT_DIR/bench_w4.json"

echo ""
echo "=== W5: > 1 MB Document (~1.4 MB, 50k elements + attrs under default limits) (${W5_ROUNDS}x) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W5: > 1 MB Document (~1.4 MB, 50k elements + attrs under default limits) (${W5_ROUNDS}x)" \
  --impl "pion=$BIN_DIR/pion_xpath w5 $DATA_DIR/w5.xml $W5_ROUNDS" \
  --impl "rust_sxd=$BIN_DIR/rust_xpath w5 $DATA_DIR/w5.xml $W5_ROUNDS" \
  --impl "c_libxml2=$BIN_DIR/c_libxml2 w5 $DATA_DIR/w5.xml $W5_ROUNDS" \
  --baseline rust_sxd \
  --warmup 1 --rounds 5 --ops "$W5_ROUNDS" \
  --md-out "$OUT_DIR/bench_w5.md" --json-out "$OUT_DIR/bench_w5.json"
