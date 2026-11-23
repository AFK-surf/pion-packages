#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/graphql:
# Pion Native (`packages/graphql` --release) vs Rust `apollo-parser =0.8.4` (--release) vs Node.js `graphql@16.10.0`.
# All build artifacts and temporary inputs live in /private/tmp to keep git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-graphql-bench"
BIN_DIR="$OUT_DIR/bin"
NODE_PKG="$OUT_DIR/node_pkg"
SDL_FILE="$OUT_DIR/schema.graphql"
Q_FILE="$OUT_DIR/queries.graphql"

SDL_MODULES="${GQL_SDL_MODULES:-1400}"
SDL_ITERS="${GQL_SDL_ITERS:-3}"
Q_COUNT="${GQL_Q_COUNT:-200}"
Q_ITERS="${GQL_Q_ITERS:-100}"
RT_ITERS="${GQL_RT_ITERS:-50}"

mkdir -p "$BIN_DIR" "$NODE_PKG"

echo "==> Generating GraphQL benchmark corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR" "$SDL_MODULES" "$Q_COUNT"
SDL_BYTES=$(wc -c < "$SDL_FILE" | tr -d ' ')
Q_BYTES=$(wc -c < "$Q_FILE" | tr -d ' ')
SDL_TOTAL_BYTES=$((SDL_BYTES * SDL_ITERS))
Q_TOTAL_OPS=$((Q_COUNT * Q_ITERS))
RT_TOTAL_BYTES=$((Q_BYTES * RT_ITERS))
RT_TOTAL_OPS=$((Q_COUNT * RT_ITERS))
echo "    sdl=${SDL_BYTES} B, queries=${Q_BYTES} B (${Q_COUNT} queries)"

if [ ! -d "$NODE_PKG/node_modules/graphql" ]; then
  echo "==> Installing Node graphql@16.10.0 in $NODE_PKG"
  (cd "$NODE_PKG" && npm init -y >/dev/null 2>&1 && npm install --no-audit --no-fund graphql@16.10.0 >/dev/null)
fi

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_graphql" "$BENCH_DIR/pion_bench"

echo "==> Building Rust apollo-parser benchmark (--release, target in /private/tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/graphql_bench_rust" "$BIN_DIR/rust_graphql"

echo ""
echo "=== Workload 1: Large Schema SDL Parse (${SDL_ITERS}x ${SDL_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 1: Large Schema SDL Parse" \
  --impl "pion=$BIN_DIR/pion_graphql sdl $SDL_FILE $SDL_ITERS" \
  --impl "rust_apollo=$BIN_DIR/rust_graphql sdl $SDL_FILE $SDL_ITERS" \
  --impl "node_graphqljs=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js sdl $SDL_FILE $SDL_ITERS" \
  --baseline rust_apollo \
  --warmup 1 --rounds 5 --bytes "$SDL_TOTAL_BYTES" \
  --md-out "$OUT_DIR/bench_sdl.md" --json-out "$OUT_DIR/bench_sdl.json"

echo ""
echo "=== Workload 2: Complex Executable Query Parse + Static Validation (${Q_TOTAL_OPS} queries) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 2: Executable Query Parse + Static Validation (20k queries)" \
  --impl "pion=$BIN_DIR/pion_graphql queries $Q_FILE $Q_ITERS" \
  --impl "rust_apollo=$BIN_DIR/rust_graphql queries $Q_FILE $Q_ITERS" \
  --impl "node_graphqljs=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js queries $Q_FILE $Q_ITERS" \
  --baseline rust_apollo \
  --warmup 1 --rounds 5 --ops "$Q_TOTAL_OPS" \
  --md-out "$OUT_DIR/bench_queries.md" --json-out "$OUT_DIR/bench_queries.json"

echo ""
echo "=== Workload 3: Query Minify + Parse + Print Round-trip (${RT_TOTAL_OPS} queries) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Workload 3: Query Minify + Parse + Print Round-trip" \
  --impl "pion=$BIN_DIR/pion_graphql roundtrip $Q_FILE $RT_ITERS" \
  --impl "rust_apollo=$BIN_DIR/rust_graphql roundtrip $Q_FILE $RT_ITERS" \
  --impl "node_graphqljs=NODE_PATH=$NODE_PKG/node_modules node $BENCH_DIR/node_bench/bench.js roundtrip $Q_FILE $RT_ITERS" \
  --baseline rust_apollo \
  --warmup 1 --rounds 5 --bytes "$RT_TOTAL_BYTES" --ops "$RT_TOTAL_OPS" \
  --md-out "$OUT_DIR/bench_roundtrip.md" --json-out "$OUT_DIR/bench_roundtrip.json"
