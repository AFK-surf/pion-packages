#!/bin/sh
# Head-to-head benchmark runner for packages/webm:
# Pion Native (--release) vs Rust matroska-demuxer 0.6 (--release).
# All build artifacts, Cargo lockfile, and ffmpeg corpora are isolated in /tmp/pion-webm-bench.
set -eu

export PATH="${HOME:-}/.cargo/bin:/opt/homebrew/bin:${PATH:-}"

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-webm-bench"
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

echo "==> Generating real ffmpeg WebM corpora -> $OUT_DIR"
python3 "$BENCH_DIR/gen_data.py" "$OUT_DIR"

VP9_OPUS="$OUT_DIR/vp9_opus.webm"
OPUS_AUDIO="$OUT_DIR/opus_audio.webm"
AV1_OPUS="$OUT_DIR/av1_opus.webm"
MSE_INIT="$OUT_DIR/mse_init.webm"
MSE_MEDIA="$OUT_DIR/mse_media.webm"

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_webm_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust matroska-demuxer benchmark (--release, isolated in /tmp)"
rm -rf "$OUT_DIR/rust-proj"
mkdir -p "$OUT_DIR/rust-proj"
cp -R "$BENCH_DIR/rust/Cargo.toml" "$BENCH_DIR/rust/src" "$OUT_DIR/rust-proj/"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$OUT_DIR/rust-proj/Cargo.toml"
cp "$OUT_DIR/rust-target/release/webm-bench-rust" "$BIN_DIR/rust_webm_bench"

VP9_BYTES=$(wc -c < "$VP9_OPUS" | tr -d ' ')
OPUS_BYTES=$(wc -c < "$OPUS_AUDIO" | tr -d ' ')
AV1_BYTES=$(wc -c < "$AV1_OPUS" | tr -d ' ')
MSE_BYTES=$(( $(wc -c < "$MSE_INIT" | tr -d ' ') + $(wc -c < "$MSE_MEDIA" | tr -d ' ') ))

echo ""
echo "=== BENCH 1: VP9 + Opus WebM Full Demux (x 200) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WebM Demux: VP9 + Opus 12s (x 200)" \
  --impl "pion=$BIN_DIR/pion_webm_bench full $VP9_OPUS 200" \
  --impl "rust_matroska=$BIN_DIR/rust_webm_bench full $VP9_OPUS 200" \
  --baseline rust_matroska \
  --warmup 1 --rounds 5 --bytes "$((VP9_BYTES * 200))" \
  --md-out "$OUT_DIR/bench_vp9_opus.md" --json-out "$OUT_DIR/bench_vp9_opus.json"

echo ""
echo "=== BENCH 2: Pure Opus WebM Audio Demux (x 200) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WebM Demux: Pure Opus 60s Audio (x 200)" \
  --impl "pion=$BIN_DIR/pion_webm_bench full $OPUS_AUDIO 200" \
  --impl "rust_matroska=$BIN_DIR/rust_webm_bench full $OPUS_AUDIO 200" \
  --baseline rust_matroska \
  --warmup 1 --rounds 5 --bytes "$((OPUS_BYTES * 200))" \
  --md-out "$OUT_DIR/bench_opus_audio.md" --json-out "$OUT_DIR/bench_opus_audio.json"

echo ""
echo "=== BENCH 3: AV1 + Opus WebM Full Demux (x 200) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WebM Demux: AV1 + Opus 10s (x 200)" \
  --impl "pion=$BIN_DIR/pion_webm_bench full $AV1_OPUS 200" \
  --impl "rust_matroska=$BIN_DIR/rust_webm_bench full $AV1_OPUS 200" \
  --baseline rust_matroska \
  --warmup 1 --rounds 5 --bytes "$((AV1_BYTES * 200))" \
  --md-out "$OUT_DIR/bench_av1_opus.md" --json-out "$OUT_DIR/bench_av1_opus.json"

echo ""
echo "=== BENCH 4: YouTube MSE Init + Cluster Media Segment (x 200) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WebM MSE: Init + Cluster Media Segment (x 200)" \
  --impl "pion=$BIN_DIR/pion_webm_bench mse $MSE_INIT $MSE_MEDIA 200" \
  --impl "rust_matroska=$BIN_DIR/rust_webm_bench mse $MSE_INIT $MSE_MEDIA 200" \
  --baseline rust_matroska \
  --warmup 1 --rounds 5 --bytes "$((MSE_BYTES * 200))" \
  --md-out "$OUT_DIR/bench_mse.md" --json-out "$OUT_DIR/bench_mse.json"
