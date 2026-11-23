#!/bin/sh
# Head-to-head benchmark runner for packages/cli
# (Pion Native vs Rust clap 4.5.32 vs Go spf13/pflag v1.0.6).
# All build artifacts and temporary outputs are placed in /private/tmp.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-cli-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_cli_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust clap benchmark (--release, target in /private/tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust/Cargo.toml"
cp "$OUT_DIR/rust-target/release/cli_bench_rust" "$BIN_DIR/rust_cli_bench"

echo "==> Building Go spf13/pflag benchmark"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_cli_bench" .)

echo ""
echo "=== W1: Complex CLI (30 options + 5-level subcommand) x 50,000 parses ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CLI W1: Complex CLI (30 opts + 5-level subcommand, 50k parses)" \
  --impl "pion=$BIN_DIR/pion_cli_bench w1" \
  --impl "rust_clap=$BIN_DIR/rust_cli_bench w1" \
  --impl "go_pflag=$BIN_DIR/go_cli_bench w1" \
  --baseline rust_clap \
  --warmup 1 --rounds 5 --ops 50000 \
  --md-out "$OUT_DIR/w1.md" --json-out "$OUT_DIR/w1.json"

echo ""
echo "=== W2: 100k-arg batch (short clustering + repeated append + -- terminator) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CLI W2: 100k-arg Batch (short clusters + append + -- terminator)" \
  --impl "pion=$BIN_DIR/pion_cli_bench w2" \
  --impl "rust_clap=$BIN_DIR/rust_cli_bench w2" \
  --impl "go_pflag=$BIN_DIR/go_cli_bench w2" \
  --baseline rust_clap \
  --warmup 1 --rounds 5 --ops 100000 \
  --md-out "$OUT_DIR/w2.md" --json-out "$OUT_DIR/w2.json"

echo ""
echo "=== W3: Typo Suggestion + Help Rendering (20k ops, Pion vs Rust clap) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CLI W3: Typo Suggestion + Help Generation (20k ops)" \
  --impl "pion=$BIN_DIR/pion_cli_bench w3" \
  --impl "rust_clap=$BIN_DIR/rust_cli_bench w3" \
  --baseline rust_clap \
  --warmup 1 --rounds 5 --ops 20000 \
  --md-out "$OUT_DIR/w3.md" --json-out "$OUT_DIR/w3.json"
