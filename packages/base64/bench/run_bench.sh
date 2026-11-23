#!/bin/sh
# Head-to-head benchmark runner for packages/base64:
# Pion Native (--release) vs Go stdlib (encoding/base64, base32, hex)
# vs Rust base64 =0.22.1 / hex =0.4.3 / data-encoding =2.11.1 (--release).
# Builds, Cargo.lock and go.sum live under $OUT_DIR, never in the worktree.
# Usage: sh run_bench.sh [size_bytes] [rounds]
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="${OUT_DIR:-/tmp/pion-base64-bench}"
BIN_DIR="$OUT_DIR/bin"
SIZE="${1:-4194304}"
ROUNDS="${2:-16}"

mkdir -p "$BIN_DIR" "$OUT_DIR/rust-build/src" "$OUT_DIR/go-build"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_base64_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Go stdlib benchmark"
cp "$BENCH_DIR/go/go.mod" "$BENCH_DIR/go/main.go" "$OUT_DIR/go-build/"
(cd "$OUT_DIR/go-build" && go build -o "$BIN_DIR/go_base64_bench" .)

echo "==> Building Rust benchmark (--release)"
cp "$BENCH_DIR/rust/Cargo.toml" "$OUT_DIR/rust-build/Cargo.toml"
cp "$BENCH_DIR/rust/src/main.rs" "$OUT_DIR/rust-build/src/main.rs"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --quiet \
  --manifest-path "$OUT_DIR/rust-build/Cargo.toml"
cp "$OUT_DIR/rust-target/release/base64-bench-rust" "$BIN_DIR/rust_base64_bench"

# Bytes processed per run: the side that is not the generated input is
# derived by the encoder, so report MB/s against the raw input size.
TOTAL=$((SIZE * ROUNDS))
for MODE in b64_encode b64_decode url_encode url_decode b32_encode b32_decode hex_encode hex_decode; do
  echo ""
  echo "=== $MODE: $ROUNDS x $SIZE bytes ==="
  python3 "$ROOT_DIR/scripts/bench_compare.py" \
    --title "base64 $MODE ($ROUNDS x $SIZE B)" \
    --impl "pion=$BIN_DIR/pion_base64_bench $MODE $SIZE $ROUNDS" \
    --impl "go_stdlib=$BIN_DIR/go_base64_bench $MODE $SIZE $ROUNDS" \
    --impl "rust=$BIN_DIR/rust_base64_bench $MODE $SIZE $ROUNDS" \
    --baseline rust \
    --warmup 1 --rounds 5 --bytes "$TOTAL" \
    --md-out "$OUT_DIR/$MODE.md" --json-out "$OUT_DIR/$MODE.json"
done
