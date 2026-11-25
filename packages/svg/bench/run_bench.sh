#!/bin/sh
# Head-to-head benchmark runner for packages/svg:
# Pion Native (`packages/svg`) vs Rust (`svgtypes` + `kurbo` + `roxmltree`, --release) and Node (`svgo`).
# All build artifacts and temporary inputs live in /private/tmp/fix-svg-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="${TMPDIR:-/tmp}/fix-svg-bench"
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

echo "==> Building Rust svgtypes+kurbo+roxmltree benchmark (--release --locked)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/svg_bench_rust" "$BIN_DIR/rust_svg"

if [ ! -d "$NODE_DIR/node_modules/svgo" ]; then
  echo "==> Installing locked Node svgo@3.3.2 in $NODE_DIR"
  cp "$BENCH_DIR/node_bench/package.json" "$NODE_DIR/package.json"
  cp "$BENCH_DIR/node_bench/package-lock.json" "$NODE_DIR/package-lock.json"
  (cd "$NODE_DIR" && npm ci --no-audit --no-fund >/dev/null)
fi

echo ""
echo "=== W1a: 50,000 Complex SVG Paths (Exact SHA-256 parity: Pion vs Rust svgtypes + same F.6.5 arc/bbox) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1a: 50,000 Paths (Exact SHA-256 Parity, Same Algorithm)" \
  --impl "pion=$BIN_DIR/pion_svg w1_paths $PATHS_FILE" \
  --impl "rust_svgtypes_same_algo=$BIN_DIR/rust_svg w1_paths $PATHS_FILE" \
  --baseline rust_svgtypes_same_algo \
  --warmup 1 --rounds 5 --bytes "$PATHS_BYTES" --ops 50000 \
  --md-out "$OUT_DIR/w1a.md" --json-out "$OUT_DIR/w1a.json"

echo ""
echo "=== W1b: 50,000 Complex SVG Paths (Idiomatic Upstream Rust: svgtypes SimplifyingPathParser + kurbo bbox) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1b: Idiomatic Upstream Rust (svgtypes + kurbo 0.11.3)" \
  --impl "rust_svgtypes_kurbo=$BIN_DIR/rust_svg w1_kurbo $PATHS_FILE" \
  --baseline rust_svgtypes_kurbo \
  --warmup 1 --rounds 5 --bytes "$PATHS_BYTES" --ops 50000 \
  --md-out "$OUT_DIR/w1b.md" --json-out "$OUT_DIR/w1b.json"

echo ""
echo "=== W2: 2,000 Nested SVG Icons (Exact SHA-256 parity: DOM + Transforms + Shapes->Path + Exact BBox) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: 2,000 Nested SVG Icons (Exact SHA-256 Parity)" \
  --impl "pion=$BIN_DIR/pion_svg w2_dom $ICONS_FILE" \
  --impl "rust_roxmltree_svgtypes=$BIN_DIR/rust_svg w2_dom $ICONS_FILE" \
  --baseline rust_roxmltree_svgtypes \
  --warmup 1 --rounds 5 --bytes "$ICONS_BYTES" --ops 2000 \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W3a: 2,000 SVG Icons Optimization (Exact SHA-256 parity: Pion vs Rust roxmltree+svgtypes) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3a: 2,000 SVG Icons Optimization (Exact SHA-256 Parity)" \
  --impl "pion=$BIN_DIR/pion_svg w3_opt $ICONS_FILE" \
  --impl "rust_roxmltree_svgtypes=$BIN_DIR/rust_svg w3_opt $ICONS_FILE" \
  --baseline rust_roxmltree_svgtypes \
  --warmup 1 --rounds 5 --bytes "$ICONS_BYTES" --ops 2000 \
  --md-out "$OUT_DIR/w3a.md" --json-out "$OUT_DIR/w3a.json"

cp "$BENCH_DIR/node_bench/bench.mjs" "$NODE_DIR/bench.mjs"

echo ""
echo "=== W3b: Node svgo@3.3.2 Reference (non-equivalent multi-plugin output; startup + steady-state split) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3b: Node svgo@3.3.2 Non-Equivalent Reference (2,000 SVG Icons)" \
  --impl "node_svgo=node $NODE_DIR/bench.mjs $ICONS_FILE" \
  --baseline node_svgo \
  --warmup 1 --rounds 5 --bytes "$ICONS_BYTES" --ops 2000 \
  --md-out "$OUT_DIR/w3b.md" --json-out "$OUT_DIR/w3b.json"

echo ""
echo "=== Output summaries (compression ratio & svgo startup split) ==="
"$BIN_DIR/pion_svg" w3_opt "$ICONS_FILE"
node "$NODE_DIR/bench.mjs" "$ICONS_FILE"
