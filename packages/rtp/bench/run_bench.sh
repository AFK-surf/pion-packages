#!/bin/sh
# Head-to-head benchmark runner for packages/rtp:
# Pion Native (--release) vs Rust webrtc-rs (`rtp` + `rtcp` + `webrtc-srtp`, --release).
# All build artifacts and Cargo target dir are isolated in /tmp/pion-rtp-bench.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-rtp-bench"
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

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_rtp_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust webrtc-rs (rtp + rtcp + webrtc-srtp) benchmark (--release, isolated in /tmp/pion-rtp-bench)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/rtp-bench-rust" "$BIN_DIR/rust_rtp_bench"

echo ""
echo "=== BENCH 1: RTP Parse + Marshal (1200 B WebRTC video + 3 RFC 5285 one-byte exts x 50,000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "RTP Parse+Marshal (1200 B + RFC 5285 1-byte exts x 50,000)" \
  --impl "pion=$BIN_DIR/pion_rtp_bench rtp 50000" \
  --impl "rust_webrtc=$BIN_DIR/rust_rtp_bench rtp 50000" \
  --baseline rust_webrtc \
  --warmup 1 --rounds 5 --ops 50000 \
  --md-out "$OUT_DIR/bench_rtp.md" --json-out "$OUT_DIR/bench_rtp.json"

echo ""
echo "=== BENCH 2: RTCP Compound Parse + Marshal (SR + PLI + NACK x 50,000) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "RTCP Compound Parse+Marshal (SR+PLI+NACK x 50,000)" \
  --impl "pion=$BIN_DIR/pion_rtp_bench rtcp 50000" \
  --impl "rust_webrtc=$BIN_DIR/rust_rtp_bench rtcp 50000" \
  --baseline rust_webrtc \
  --warmup 1 --rounds 5 --ops 50000 \
  --md-out "$OUT_DIR/bench_rtcp.md" --json-out "$OUT_DIR/bench_rtcp.json"

echo ""
echo "=== BENCH 3: SRTP Protect + Unprotect (AES128_CM_HMAC_SHA1_80, 5,000 x 1200 B = 12 MB) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "SRTP AES128_CM_HMAC_SHA1_80 Protect+Unprotect (5,000 x 1200 B)" \
  --impl "pion=$BIN_DIR/pion_rtp_bench srtp_cm 5000" \
  --impl "rust_webrtc=$BIN_DIR/rust_rtp_bench srtp_cm 5000" \
  --baseline rust_webrtc \
  --warmup 1 --rounds 5 --bytes 12000000 \
  --md-out "$OUT_DIR/bench_srtp_cm.md" --json-out "$OUT_DIR/bench_srtp_cm.json"

echo ""
echo "=== BENCH 4: SRTP Protect + Unprotect (AEAD_AES_128_GCM, 5,000 x 1200 B = 12 MB) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "SRTP AEAD_AES_128_GCM Protect+Unprotect (5,000 x 1200 B)" \
  --impl "pion=$BIN_DIR/pion_rtp_bench srtp_gcm 5000" \
  --impl "rust_webrtc=$BIN_DIR/rust_rtp_bench srtp_gcm 5000" \
  --baseline rust_webrtc \
  --warmup 1 --rounds 5 --bytes 12000000 \
  --md-out "$OUT_DIR/bench_srtp_gcm.md" --json-out "$OUT_DIR/bench_srtp_gcm.json"
