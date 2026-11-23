#!/bin/sh
# Head-to-head benchmark runner for packages/glsl:
# Pion Native (--release) vs Rust `glsl` crate 7.0.0 (--release),
# plus real macOS OpenGL 4.1 Core `glCompileShader` validation.
# All build artifacts, Cargo lockfile, and corpora are isolated in /tmp/pion-glsl-bench.
set -eu

export PATH="${HOME:-}/.cargo/bin:/opt/homebrew/bin:${PATH:-}"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-glsl-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

echo "==> Generating real WebGL 1.0 / 2.0 shader corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$OUT_DIR"

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_glsl_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust glsl-7.0.0 benchmark (--release, isolated in /tmp/pion-glsl-bench)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/glsl-bench-rust" "$BIN_DIR/rust_glsl_bench"

echo "==> Translating all corpus shaders, printing GLSL 410 SHA-256 & validating on macOS OpenGL 4.1 Core"
"$BIN_DIR/pion_glsl_bench" vert "$OUT_DIR/threejs_pbr_es100.vert" 1 "$OUT_DIR/threejs_pbr_410.vert" > /dev/null
"$BIN_DIR/pion_glsl_bench" frag "$OUT_DIR/threejs_pbr_es100.frag" 1 "$OUT_DIR/threejs_pbr_410.frag" > /dev/null
"$BIN_DIR/pion_glsl_bench" vert "$OUT_DIR/shadertoy_es300.vert" 1 "$OUT_DIR/shadertoy_410.vert" > /dev/null
"$BIN_DIR/pion_glsl_bench" frag "$OUT_DIR/shadertoy_es300.frag" 1 "$OUT_DIR/shadertoy_410.frag" > /dev/null
"$BIN_DIR/pion_glsl_bench" frag "$OUT_DIR/postprocess_2d_es100.frag" 1 "$OUT_DIR/postprocess_2d_410.frag" > /dev/null
shasum -a 256 \
  "$OUT_DIR/threejs_pbr_410.vert" \
  "$OUT_DIR/threejs_pbr_410.frag" \
  "$OUT_DIR/shadertoy_410.vert" \
  "$OUT_DIR/shadertoy_410.frag" \
  "$OUT_DIR/postprocess_2d_410.frag"

if [ "$(uname -s)" = "Darwin" ]; then
  clang -O2 -Wall -Wno-deprecated-declarations "$BENCH_DIR/verify_gl41.c" -framework OpenGL -o "$BIN_DIR/verify_gl41"
  "$BIN_DIR/verify_gl41" \
    "vert:$OUT_DIR/threejs_pbr_410.vert" \
    "frag:$OUT_DIR/threejs_pbr_410.frag" \
    "vert:$OUT_DIR/shadertoy_410.vert" \
    "frag:$OUT_DIR/shadertoy_410.frag" \
    "frag:$OUT_DIR/postprocess_2d_410.frag"
fi

THREEJS_BYTES=$(wc -c < "$OUT_DIR/threejs_pbr_es100.frag" | tr -d ' ')
SHADERTOY_BYTES=$(wc -c < "$OUT_DIR/shadertoy_es300.frag" | tr -d ' ')
POSTPROC_BYTES=$(wc -c < "$OUT_DIR/postprocess_2d_es100.frag" | tr -d ' ')
ITERS=500

echo ""
echo "=== BENCH 1: Three.js PBR (GLSL ES 1.00 Fragment x $ITERS) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "GLSL ES 1.00 -> 410 Core: Three.js PBR Fragment (x$ITERS)" \
  --impl "pion=$BIN_DIR/pion_glsl_bench frag $OUT_DIR/threejs_pbr_es100.frag $ITERS" \
  --impl "rust_glsl=$BIN_DIR/rust_glsl_bench frag $OUT_DIR/threejs_pbr_es100.frag $ITERS" \
  --baseline rust_glsl \
  --warmup 1 --rounds 5 --bytes "$((THREEJS_BYTES * ITERS))" \
  --md-out "$OUT_DIR/bench_threejs.md" --json-out "$OUT_DIR/bench_threejs.json"

echo ""
echo "=== BENCH 2: WebGL2 Shadertoy Raymarching (GLSL ES 3.00 Fragment x $ITERS) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "GLSL ES 3.00 -> 410 Core: WebGL2 Shadertoy Fragment (x$ITERS)" \
  --impl "pion=$BIN_DIR/pion_glsl_bench frag $OUT_DIR/shadertoy_es300.frag $ITERS" \
  --impl "rust_glsl=$BIN_DIR/rust_glsl_bench frag $OUT_DIR/shadertoy_es300.frag $ITERS" \
  --baseline rust_glsl \
  --warmup 1 --rounds 5 --bytes "$((SHADERTOY_BYTES * ITERS))" \
  --md-out "$OUT_DIR/bench_shadertoy.md" --json-out "$OUT_DIR/bench_shadertoy.json"

echo ""
echo "=== BENCH 3: 2D Post-Process Bloom/Chromatic (GLSL ES 1.00 Fragment x $ITERS) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "GLSL ES 1.00 -> 410 Core: 2D Post-Process Fragment (x$ITERS)" \
  --impl "pion=$BIN_DIR/pion_glsl_bench frag $OUT_DIR/postprocess_2d_es100.frag $ITERS" \
  --impl "rust_glsl=$BIN_DIR/rust_glsl_bench frag $OUT_DIR/postprocess_2d_es100.frag $ITERS" \
  --baseline rust_glsl \
  --warmup 1 --rounds 5 --bytes "$((POSTPROC_BYTES * ITERS))" \
  --md-out "$OUT_DIR/bench_postproc.md" --json-out "$OUT_DIR/bench_postproc.json"
