#!/bin/sh
# Head-to-head benchmark runner for packages/svg:
# Pion Native (`packages/svg`) vs Rust (`svgtypes` + `roxmltree`, --release) and Node (`svgo`).
# All build artifacts and temporary inputs live in /private/tmp/w14-svg-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/w14-svg-bench"
BIN_DIR="$OUT_DIR/bin"
NODE_DIR="$OUT_DIR/node_pkg"
PATHS_FILE="$OUT_DIR/paths_50k.txt"
ICONS_FILE="$OUT_DIR/icons_2k.txt"

mkdir -p "$BIN_DIR" "$NODE_DIR"

echo "==> Generating deterministic corpora (50,000 paths + 2,000 icons)"
python3 "$BENCH_DIR/gen_data.py" "$PATHS_FILE" "$ICONS_FILE" 50000 2000
PATHS_BYTES=$(wc -c < "$PATHS_FILE" | tr -d ' ')
ICONS_BYTES=$(wc -c < "$ICONS_FILE" | tr -d ' ')
echo "    paths=${PATHS_BYTES} B, icons=${ICONS_BYTES} B"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_svg" "$BENCH_DIR/pion_bench"

echo "==> Building Rust svgtypes+roxmltree benchmark (--release)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/svg_bench_rust" "$BIN_DIR/rust_svg"

if [ ! -d "$NODE_DIR/node_modules/svgo" ]; then
  echo "==> Installing locked Node svgo@3.3.2 in $NODE_DIR"
  cp "$BENCH_DIR/node_bench/package.json" "$NODE_DIR/package.json"
  if [ -f "$BENCH_DIR/node_bench/package-lock.json" ]; then
    cp "$BENCH_DIR/node_bench/package-lock.json" "$NODE_DIR/package-lock.json"
    (cd "$NODE_DIR" && npm ci --no-audit --no-fund >/dev/null)
  else
    (cd "$NODE_DIR" && npm install --no-audit --no-fund >/dev/null)
    cp "$NODE_DIR/package-lock.json" "$BENCH_DIR/node_bench/package-lock.json"
  fi
fi

echo ""
echo "=== W1: 50,000 Complex SVG Paths (Parse + Cubic Normalize + Exact Analytical BBox) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: 50,000 Complex SVG Paths (Parse + Cubic + Exact BBox)" \
  --impl "pion=$BIN_DIR/pion_svg w1_paths $PATHS_FILE" \
  --impl "rust_svgtypes=$BIN_DIR/rust_svg w1_paths $PATHS_FILE" \
  --baseline rust_svgtypes \
  --warmup 1 --rounds 5 --bytes "$PATHS_BYTES" --ops 50000 \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== W2: 2,000 Nested SVG Icons (DOM + Transforms + Shapes->Path + Exact BBox) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: 2,000 Nested SVG Icons (DOM + Transforms + Shapes->Path + BBox)" \
  --impl "pion=$BIN_DIR/pion_svg w2_dom $ICONS_FILE" \
  --impl "rust_roxmltree_svgtypes=$BIN_DIR/rust_svg w2_dom $ICONS_FILE" \
  --baseline rust_roxmltree_svgtypes \
  --warmup 1 --rounds 5 --bytes "$ICONS_BYTES" --ops 2000 \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W3a: 2,000 SVG Icons Optimization (Pion vs Rust roxmltree+svgtypes, byte-for-byte SHA-256) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3a: 2,000 SVG Icons Optimization (Exact SHA-256 Parity)" \
  --impl "pion=$BIN_DIR/pion_svg w3_opt $ICONS_FILE" \
  --impl "rust_roxmltree_svgtypes=$BIN_DIR/rust_svg w3_opt $ICONS_FILE" \
  --baseline rust_roxmltree_svgtypes \
  --warmup 1 --rounds 5 --bytes "$ICONS_BYTES" --ops 2000 \
  --md-out "$OUT_DIR/w3a.md" --json-out "$OUT_DIR/w3a.json"

cp "$BENCH_DIR/node_bench/bench.mjs" "$NODE_DIR/bench.mjs"

echo ""
echo "=== W3b: Node svgo@3.3.2 on same 2,000 SVG Icons (reference throughput & compression ratio) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3b: Node svgo@3.3.2 Reference (2,000 SVG Icons)" \
  --impl "node_svgo=node $NODE_DIR/bench.mjs $ICONS_FILE" \
  --baseline node_svgo \
  --warmup 1 --rounds 5 --bytes "$ICONS_BYTES" --ops 2000 \
  --md-out "$OUT_DIR/w3b.md" --json-out "$OUT_DIR/w3b.json"

echo ""
echo "=== Output summaries (compression ratio check) ==="
"$BIN_DIR/pion_svg" w3_opt "$ICONS_FILE"
node "$NODE_DIR/bench.mjs" "$ICONS_FILE"
