#!/bin/sh
# Head-to-head benchmark runner for packages/csp:
# Pion Native (--release) vs Rust CSP3 + Fetch CORS reference (--release).
# All build artifacts and Cargo target dir are isolated in /tmp/pion-csp-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-csp-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_csp_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust CSP3 + Fetch CORS benchmark (--release, isolated in $OUT_DIR)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/csp-bench-rust" "$BIN_DIR/rust_csp_bench"

echo ""
echo "=== BENCH 1: Real-World CSP3 Parse + Eval (10k policies + 100k checks: Twitter/X, YouTube, GitHub, Google Meet, Figma) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CSP3 Real-World Parse + Eval (10k policies + 100k checks: X, YouTube, GitHub, Meet, Figma)" \
  --impl "pion=$BIN_DIR/pion_csp_bench csp" \
  --impl "rust_csp=$BIN_DIR/rust_csp_bench csp" \
  --baseline rust_csp \
  --warmup 1 --rounds 5 --ops 100000 \
  --md-out "$OUT_DIR/bench_csp.md" --json-out "$OUT_DIR/bench_csp.json"

echo ""
echo "=== BENCH 2: WHATWG Fetch CORS Preflight + Response + Origin Batch Eval (200k ops) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WHATWG Fetch CORS Preflight + Response + Origin Batch Eval (200k ops)" \
  --impl "pion=$BIN_DIR/pion_csp_bench cors" \
  --impl "rust_csp=$BIN_DIR/rust_csp_bench cors" \
  --baseline rust_csp \
  --warmup 1 --rounds 5 --ops 200000 \
  --md-out "$OUT_DIR/bench_cors.md" --json-out "$OUT_DIR/bench_cors.json"
