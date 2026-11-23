#!/bin/sh
# Head-to-head benchmark runner for packages/template (Pion Native vs Rust minijinja 3.1.0 --release).
# All build artifacts and temporary outputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-template-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_ssr" "$BENCH_DIR/pion_ssr"
pionc build --release -o "$BIN_DIR/pion_prompt" "$BENCH_DIR/pion_prompt"
pionc build --release -o "$BIN_DIR/pion_e2e" "$BENCH_DIR/pion_e2e"

echo "==> Building Rust minijinja 3.1.0 benchmarks (--release, Cargo in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/bench_ssr" "$BIN_DIR/rust_ssr"
cp "$OUT_DIR/rust-target/release/bench_prompt" "$BIN_DIR/rust_prompt"
cp "$OUT_DIR/rust-target/release/bench_e2e" "$BIN_DIR/rust_e2e"

SSR_BYTES=$("$BIN_DIR/pion_ssr" | awk -F= '/^total_bytes=/{print $2}')
PROMPT_BYTES=$("$BIN_DIR/pion_prompt" | awk -F= '/^total_bytes=/{print $2}')
E2E_BYTES=$("$BIN_DIR/pion_e2e" | awk -F= '/^total_bytes=/{print $2}')

echo ""
echo "=== BENCH 1: HTML Page SSR Rendering (10,000 renders, $SSR_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Template Bench 1: HTML Page SSR (extends + for + auto-escape, 10,000 renders)" \
  --impl "pion=$BIN_DIR/pion_ssr" \
  --impl "rust_minijinja=$BIN_DIR/rust_ssr" \
  --baseline rust_minijinja \
  --warmup 1 --rounds 5 --ops 10000 --bytes "$SSR_BYTES" \
  --md-out "$OUT_DIR/ssr.md" --json-out "$OUT_DIR/ssr.json"

echo ""
echo "=== BENCH 2: AI Agent Prompt Template Rendering (20,000 renders, $PROMPT_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Template Bench 2: AI Agent Prompt (conditionals + tools + tojson, 20,000 renders)" \
  --impl "pion=$BIN_DIR/pion_prompt" \
  --impl "rust_minijinja=$BIN_DIR/rust_prompt" \
  --baseline rust_minijinja \
  --warmup 1 --rounds 5 --ops 20000 --bytes "$PROMPT_BYTES" \
  --md-out "$OUT_DIR/prompt.md" --json-out "$OUT_DIR/prompt.json"

echo ""
echo "=== BENCH 3: Compile + Render End-to-End (2,000 iterations, $E2E_BYTES B) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Template Bench 3: Compile + Render End-to-End (3 templates, 2,000 iterations)" \
  --impl "pion=$BIN_DIR/pion_e2e" \
  --impl "rust_minijinja=$BIN_DIR/rust_e2e" \
  --baseline rust_minijinja \
  --warmup 1 --rounds 5 --ops 2000 --bytes "$E2E_BYTES" \
  --md-out "$OUT_DIR/e2e.md" --json-out "$OUT_DIR/e2e.json"
