#!/bin/sh
# Head-to-head benchmark runner for packages/webp:
# Pion Native (--release) vs Go golang.org/x/image/webp.
# All build artifacts and generated WebP corpora are isolated in /tmp/pion-webp-bench.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-webp-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Building Go golang.org/x/image/webp reference & corpus generator"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_webp_bench" .)

echo "==> Generating deterministic 512x512 WebP corpora -> $DATA_DIR"
"$BIN_DIR/go_webp_bench" gen "$DATA_DIR"
ls -lh "$DATA_DIR"/*.webp

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_webp_bench" "$BENCH_DIR/pion_bench"

VP8L_FILE="$DATA_DIR/vp8l_512x512.webp"
VP8_FILE="$DATA_DIR/vp8_512x512.webp"
VP8X_FILE="$DATA_DIR/vp8x_alph_512x512.webp"

ITERS=30
RGBA_BYTES=$((512 * 512 * 4 * ITERS))

echo ""
echo "=== BENCH 1: VP8L Lossless 512x512 RGBA -> RGBA8888 (x$ITERS = 30 MiB RGBA) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WebP VP8L Lossless 512x512 -> RGBA8888 (x$ITERS)" \
  --impl "pion=$BIN_DIR/pion_webp_bench $VP8L_FILE $ITERS" \
  --impl "go_x_image_webp=$BIN_DIR/go_webp_bench decode $VP8L_FILE $ITERS" \
  --baseline go_x_image_webp \
  --warmup 1 --rounds 5 --bytes "$RGBA_BYTES" \
  --md-out "$OUT_DIR/bench_vp8l.md" --json-out "$OUT_DIR/bench_vp8l.json"

echo ""
echo "=== BENCH 2: VP8 Lossy 512x512 -> RGBA8888 (x$ITERS = 30 MiB RGBA) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WebP VP8 Lossy 512x512 -> RGBA8888 (x$ITERS)" \
  --impl "pion=$BIN_DIR/pion_webp_bench $VP8_FILE $ITERS" \
  --impl "go_x_image_webp=$BIN_DIR/go_webp_bench decode $VP8_FILE $ITERS" \
  --baseline go_x_image_webp \
  --warmup 1 --rounds 5 --bytes "$RGBA_BYTES" \
  --md-out "$OUT_DIR/bench_vp8.md" --json-out "$OUT_DIR/bench_vp8.json"

echo ""
echo "=== BENCH 3: VP8X + ALPH (VP8L Alpha + VP8 Lossy) 512x512 -> RGBA8888 (x$ITERS = 30 MiB RGBA) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WebP VP8X+ALPH 512x512 -> RGBA8888 (x$ITERS)" \
  --impl "pion=$BIN_DIR/pion_webp_bench $VP8X_FILE $ITERS" \
  --impl "go_x_image_webp=$BIN_DIR/go_webp_bench decode $VP8X_FILE $ITERS" \
  --baseline go_x_image_webp \
  --warmup 1 --rounds 5 --bytes "$RGBA_BYTES" \
  --md-out "$OUT_DIR/bench_vp8x_alph.md" --json-out "$OUT_DIR/bench_vp8x_alph.json"
