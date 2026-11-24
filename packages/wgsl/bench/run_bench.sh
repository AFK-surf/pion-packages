#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/wgsl:
# Pion Native (`packages/wgsl`) vs Rust `naga` (=24.0.0, --release)
# Workload: WGSL parse + validate + MSL 2.x emit + GLSL ES 3.00/450 emit
# on realistic PBR + Compute Reduction + Particle Physics shaders.
# All build artifacts and temporary inputs live in /tmp to keep git worktree clean.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-wgsl-bench"
BIN_DIR="$OUT_DIR/bin"
ITERS="${WGSL_BENCH_ITERS:-200}"

mkdir -p "$BIN_DIR"

echo "==> Generating WGSL corpus (PBR + Compute Reduce + Particle Sim) -> $OUT_DIR"
CORPUS_BYTES=$(python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR")
TOTAL_BYTES=$((CORPUS_BYTES * ITERS))
TOTAL_COMPILES=$((7 * ITERS))
echo "    corpus=${CORPUS_BYTES} B (3 shaders), iters=${ITERS}, total=${TOTAL_BYTES} B, compiles=${TOTAL_COMPILES}"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_wgsl" "$BENCH_DIR/pion_bench"

echo "==> Building Rust naga benchmark (--release, target in /tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust_bench/Cargo.toml"
cp "$OUT_DIR/rust-target/release/wgsl_bench_naga" "$BIN_DIR/rust_naga"

echo ""
echo "=== WGSL Parse + Validate + MSL/GLSL Emit (${ITERS}x 3-Shader Corpus = ${TOTAL_BYTES} B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WGSL Parse + Validate + MSL/GLSL Emit (${ITERS}x PBR+Reduce+Particles)" \
  --impl "pion_wgsl=$BIN_DIR/pion_wgsl $OUT_DIR $ITERS" \
  --impl "rust_naga=$BIN_DIR/rust_naga $OUT_DIR $ITERS" \
  --baseline rust_naga \
  --warmup 1 --rounds 5 --bytes "$TOTAL_BYTES" --ops "$TOTAL_COMPILES" \
  --md-out "$OUT_DIR/bench.md" --json-out "$OUT_DIR/bench.json"
