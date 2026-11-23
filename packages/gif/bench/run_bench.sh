#!/bin/sh
# Head-to-head benchmark runner for packages/gif:
# Pion Native (--release) vs Go stdlib image/gif.
# All build artifacts and generated GIF corpora are isolated in /tmp/pion-gif-bench.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-gif-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_DIR="$OUT_DIR/data"

mkdir -p "$BIN_DIR" "$DATA_DIR"

echo "==> Building Go image/gif reference & corpus generator"
(cd "$BENCH_DIR/go" && go build -o "$BIN_DIR/go_gif_bench" .)

echo "==> Generating deterministic GIF corpora -> $DATA_DIR"
"$BIN_DIR/go_gif_bench" gen "$DATA_DIR"
ls -lh "$DATA_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_gif_bench" "$BENCH_DIR/pion_bench"

STATIC_GIF="$DATA_DIR/static_512x512.gif"
ANIM_GIF="$DATA_DIR/anim_256x256_24f.gif"

STATIC_RGBA_BYTES=$((512 * 512 * 4 * 60))
ANIM_RGBA_BYTES=$((256 * 256 * 4 * 24 * 30))

echo ""
echo "=== BENCH 1: Static 512x512 Texture GIF Decode -> RGBA8888 (x60 = 60 MiB RGBA) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "GIF Decode Static 512x512 Texture -> RGBA8888 (x60)" \
  --impl "pion=$BIN_DIR/pion_gif_bench decode_first $STATIC_GIF 60" \
  --impl "go_image_gif=$BIN_DIR/go_gif_bench decode_first $STATIC_GIF 60" \
  --baseline go_image_gif \
  --warmup 1 --rounds 5 --bytes "$STATIC_RGBA_BYTES" \
  --md-out "$OUT_DIR/bench_static.md" --json-out "$OUT_DIR/bench_static.json"

echo ""
echo "=== BENCH 2: Animated 256x256x24f GIF Full Compositing -> RGBA8888 (x30 = 180 MiB RGBA) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "GIF Decode Animated 256x256 x 24 Frames (4 Disposals + Transparency) -> RGBA8888 (x30)" \
  --impl "pion=$BIN_DIR/pion_gif_bench decode_all $ANIM_GIF 30" \
  --impl "go_image_gif=$BIN_DIR/go_gif_bench decode_all $ANIM_GIF 30" \
  --baseline go_image_gif \
  --warmup 1 --rounds 5 --bytes "$ANIM_RGBA_BYTES" \
  --md-out "$OUT_DIR/bench_anim.md" --json-out "$OUT_DIR/bench_anim.json"
