#!/bin/sh
# Head-to-head benchmark runner for packages/stun:
# Pion Native (--release) vs Rust webrtc-rs/stun (--release).
# All build artifacts and Cargo target dir are isolated in /tmp/pion-stun-bench.
set -eu

export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-stun-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_stun_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust webrtc-rs/stun benchmark (--release, isolated in $OUT_DIR)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/stun-bench-rust" "$BIN_DIR/rust_stun_bench"

echo ""
echo "=== BENCH 1: WebRTC ICE STUN Encode + Sign (100,000 packets: Binding Req + IPv4/IPv6 Resp) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "STUN WebRTC ICE Encode + Sign (100k packets: Request + IPv4/IPv6 Response, MI + FP)" \
  --impl "pion=$BIN_DIR/pion_stun_bench encode_sign" \
  --impl "rust_webrtc_stun=$BIN_DIR/rust_stun_bench encode_sign" \
  --baseline rust_webrtc_stun \
  --warmup 1 --rounds 5 --ops 100000 \
  --md-out "$OUT_DIR/bench_encode_sign.md" --json-out "$OUT_DIR/bench_encode_sign.json"

echo ""
echo "=== BENCH 2: WebRTC ICE STUN Decode + Verify FP + Verify MI (100,000 packets) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "STUN WebRTC ICE Decode + Verify FP + Verify MI (100k packets)" \
  --impl "pion=$BIN_DIR/pion_stun_bench decode_verify" \
  --impl "rust_webrtc_stun=$BIN_DIR/rust_stun_bench decode_verify" \
  --baseline rust_webrtc_stun \
  --warmup 1 --rounds 5 --ops 100000 \
  --md-out "$OUT_DIR/bench_decode_verify.md" --json-out "$OUT_DIR/bench_decode_verify.json"
