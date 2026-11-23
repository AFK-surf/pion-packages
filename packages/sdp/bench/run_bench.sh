#!/bin/sh
# Head-to-head benchmark runner for packages/sdp:
# Pion Native (--release) vs Rust webrtc-rs `sdp` 0.9 (--release).
# All build artifacts, Cargo lockfile, and corpora are isolated in /tmp/pion-sdp-bench.
set -eu

export PATH="${HOME:-}/.cargo/bin:/opt/homebrew/bin:${PATH:-}"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-sdp-bench"
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

echo "==> Generating Chrome / Google Meet WebRTC SDP corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

OFFER="$OUT_DIR/meet_offer.sdp"
ANSWER="$OUT_DIR/meet_answer.sdp"
OFFER_BYTES=$(wc -c < "$OFFER" | tr -d ' ')
ANSWER_BYTES=$(wc -c < "$ANSWER" | tr -d ' ')

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_sdp_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust sdp benchmark (--release, isolated in /tmp/pion-sdp-bench)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/sdp-bench-rust" "$BIN_DIR/rust_sdp_bench"

ITERS=2000

echo ""
echo "=== BENCH 1: Google Meet Offer SDP Parse (${OFFER_BYTES} B x ${ITERS}) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "SDP Parse: Google Meet Offer (${OFFER_BYTES} B x ${ITERS})" \
  --impl "pion=$BIN_DIR/pion_sdp_bench parse $OFFER $ITERS" \
  --impl "rust_sdp=$BIN_DIR/rust_sdp_bench parse $OFFER $ITERS" \
  --baseline rust_sdp \
  --warmup 1 --rounds 5 --bytes "$((OFFER_BYTES * ITERS))" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench_offer_parse.md" --json-out "$OUT_DIR/bench_offer_parse.json"

echo ""
echo "=== BENCH 2: Google Meet Offer SDP Roundtrip Parse+Serialize (${OFFER_BYTES} B x ${ITERS}) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "SDP Roundtrip (Parse+Serialize): Google Meet Offer (${OFFER_BYTES} B x ${ITERS})" \
  --impl "pion=$BIN_DIR/pion_sdp_bench roundtrip $OFFER $ITERS" \
  --impl "rust_sdp=$BIN_DIR/rust_sdp_bench roundtrip $OFFER $ITERS" \
  --baseline rust_sdp \
  --warmup 1 --rounds 5 --bytes "$((OFFER_BYTES * ITERS))" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench_offer_roundtrip.md" --json-out "$OUT_DIR/bench_offer_roundtrip.json"

echo ""
echo "=== BENCH 3: Google Meet SFU Answer SDP Roundtrip Parse+Serialize (${ANSWER_BYTES} B x ${ITERS}) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "SDP Roundtrip (Parse+Serialize): Google Meet SFU Answer (${ANSWER_BYTES} B x ${ITERS})" \
  --impl "pion=$BIN_DIR/pion_sdp_bench roundtrip $ANSWER $ITERS" \
  --impl "rust_sdp=$BIN_DIR/rust_sdp_bench roundtrip $ANSWER $ITERS" \
  --baseline rust_sdp \
  --warmup 1 --rounds 5 --bytes "$((ANSWER_BYTES * ITERS))" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench_answer_roundtrip.md" --json-out "$OUT_DIR/bench_answer_roundtrip.json"
