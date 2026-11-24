#!/bin/sh
# Head-to-head benchmark runner for packages/webp:
# Pion Native (--release) vs Go golang.org/x/image/webp (decode) and in-process C libwebp (lossless encode).
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

echo "==> Building in-process C libwebp lossless encode reference (-O2 -lwebp)"
WEBP_CFLAGS=""
WEBP_LIBS="-lwebp"
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libwebp; then
  WEBP_CFLAGS=$(pkg-config --cflags libwebp)
  WEBP_LIBS=$(pkg-config --libs libwebp)
fi
# shellcheck disable=SC2086
cc -O2 $WEBP_CFLAGS "$BENCH_DIR/c/libwebp_encode_bench.c" -o "$BIN_DIR/libwebp_encode_bench" $WEBP_LIBS

echo "==> Generating deterministic 512x512 WebP corpora -> $DATA_DIR"
"$BIN_DIR/go_webp_bench" gen "$DATA_DIR"
ls -lh "$DATA_DIR"/*.webp

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_webp_bench" "$BENCH_DIR/pion_bench"

VP8L_FILE="$DATA_DIR/vp8l_512x512.webp"
VP8_FILE="$DATA_DIR/vp8_512x512.webp"
VP8X_FILE="$DATA_DIR/vp8x_alph_512x512.webp"
ALPHA_RGBA="$DATA_DIR/alpha_512.rgba"

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

ENC_ITERS=10
ENC_RGBA_BYTES=$((512 * 512 * 4 * ENC_ITERS))
echo ""
echo "=== BENCH 4: VP8L Lossless Encode 512x512 RGBA (exact, in-process, x$ENC_ITERS = 10 MiB RGBA) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "WebP VP8L Lossless Encode 512x512 RGBA exact in-process (x$ENC_ITERS)" \
  --impl "pion=$BIN_DIR/pion_webp_bench encode $ALPHA_RGBA 512 512 $ENC_ITERS exact $OUT_DIR/pion_alpha_512.webp" \
  --impl "libwebp_z4=$BIN_DIR/libwebp_encode_bench $ALPHA_RGBA 512 512 4 $ENC_ITERS exact $OUT_DIR/libwebp_z4_alpha_512.webp" \
  --baseline libwebp_z4 \
  --warmup 1 --rounds 5 --bytes "$ENC_RGBA_BYTES" \
  --md-out "$OUT_DIR/bench_vp8l_encode.md" --json-out "$OUT_DIR/bench_vp8l_encode.json"

echo ""
echo "=== Cross-verify Pion-encoded 512x512 WebP with golang.org/x/image/webp ==="
"$BIN_DIR/go_webp_bench" verify-rgba "$OUT_DIR/pion_alpha_512.webp" "$ALPHA_RGBA" exact
"$BIN_DIR/go_webp_bench" verify-rgba "$OUT_DIR/libwebp_z4_alpha_512.webp" "$ALPHA_RGBA" exact
echo "Input RGBA SHA-256: $(shasum -a 256 "$ALPHA_RGBA" 2>/dev/null || sha256sum "$ALPHA_RGBA")"
ls -l "$OUT_DIR/pion_alpha_512.webp" "$OUT_DIR/libwebp_z4_alpha_512.webp"
