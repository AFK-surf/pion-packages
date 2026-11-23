#!/bin/sh
# Head-to-head benchmark runner for packages/qrcode:
# Pion Native (--release) vs Rust (`qrcode = 0.14`, --release --locked).
# All build artifacts and Cargo target dir are isolated in /tmp/w12-qrcode-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/w12-qrcode-bench"
BIN_DIR="$OUT_DIR/bin"
ROUNDS="${BENCH_ROUNDS:-5}"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
PION_CACHE_DIR="$OUT_DIR/pion-cas" pionc build --release -o "$BIN_DIR/pion_qrcode_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust (qrcode 0.14) benchmark (--release --locked, isolated in $OUT_DIR)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/Cargo.lock" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release --locked \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/qrcode-bench-rust" "$BIN_DIR/rust_qrcode_bench"

echo ""
echo "=== W1: Batch URL / 2FA OTP URI Encode (10,000 ops, v2-v6 M/Q, auto best mask) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W1: Batch URL / 2FA OTP URI Encode (10,000 ops, v2-v6 M/Q, auto best mask)" \
  --impl "pion=$BIN_DIR/pion_qrcode_bench w1" \
  --impl "rust_qrcode=$BIN_DIR/rust_qrcode_bench w1" \
  --baseline rust_qrcode \
  --warmup 1 --rounds "$ROUNDS" --ops 10000 \
  --md-out "$OUT_DIR/bench_w1.md" --json-out "$OUT_DIR/bench_w1.json"

echo ""
echo "=== W2: Large Multi-Version Encode (300 ops, v10-v40 JSON/Binary + RS Interleaving) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W2: Large Multi-Version Encode (300 ops, v10-v40 JSON/Binary + RS Interleaving)" \
  --impl "pion=$BIN_DIR/pion_qrcode_bench w2" \
  --impl "rust_qrcode=$BIN_DIR/rust_qrcode_bench w2" \
  --baseline rust_qrcode \
  --warmup 1 --rounds "$ROUNDS" --ops 300 \
  --md-out "$OUT_DIR/bench_w2.md" --json-out "$OUT_DIR/bench_w2.json"

echo ""
echo "=== W3: End-to-End Encode + Compact SVG Generation (5,000 ops, vCard/Login QR) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3: End-to-End Encode + Compact SVG Generation (5,000 ops, vCard/Login QR)" \
  --impl "pion=$BIN_DIR/pion_qrcode_bench w3" \
  --impl "rust_qrcode=$BIN_DIR/rust_qrcode_bench w3" \
  --baseline rust_qrcode \
  --warmup 1 --rounds "$ROUNDS" --ops 5000 \
  --md-out "$OUT_DIR/bench_w3.md" --json-out "$OUT_DIR/bench_w3.json"
