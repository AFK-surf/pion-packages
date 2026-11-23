#!/bin/sh
# Head-to-head steady-state benchmark runner for packages/webvtt:
# Pion Native (`packages/webvtt`, --release) vs Go reference parser (`go build`).
# All build artifacts and temporary inputs are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-webvtt-bench"
BIN_DIR="$OUT_DIR/bin"
DATA_FILE="$OUT_DIR/corpus.vtt"
CUES="${WEBVTT_BENCH_CUES:-8000}"
ITERS="${WEBVTT_BENCH_ITERS:-20}"

PIONC_BIN="${PIONC:-}"
if [ -z "$PIONC_BIN" ]; then
  if command -v pionc >/dev/null 2>&1; then
    PIONC_BIN=$(command -v pionc)
  elif [ -x "${HOME:-}/.pion/bin/pionc" ]; then
    PIONC_BIN="${HOME}/.pion/bin/pionc"
  fi
fi

mkdir -p "$BIN_DIR"

echo "==> Generating realistic ${CUES}-cue WebVTT corpus -> $DATA_FILE"
python3 "$BENCH_DIR/gen_data.py" "$DATA_FILE" "$CUES"
FILE_BYTES=$(wc -c < "$DATA_FILE" | tr -d ' ')
TOTAL_BYTES=$((FILE_BYTES * ITERS))
echo "    file=${FILE_BYTES} B, cues=${CUES}, iters=${ITERS}, total=${TOTAL_BYTES} B"

echo "==> Building Pion Native benchmark (--release)"
"$PIONC_BIN" build --release -o "$BIN_DIR/pion_webvtt" "$BENCH_DIR/pion_bench"

echo "==> Building Go WebVTT reference benchmark"
(cd "$BENCH_DIR/go_bench" && go build -o "$BIN_DIR/go_webvtt" .)

echo ""
echo "=== W3C WebVTT Steady-State Parse + PlainText + Timeline Query (${ITERS}x ${CUES} cues) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "W3C WebVTT Steady-State Parse + PlainText + Timeline (${ITERS}x ${CUES} cues)" \
  --impl "pion=$BIN_DIR/pion_webvtt $DATA_FILE $ITERS" \
  --impl "go_ref=$BIN_DIR/go_webvtt $DATA_FILE $ITERS" \
  --baseline go_ref \
  --warmup 1 --rounds 5 --bytes "$TOTAL_BYTES" --ops "$ITERS" \
  --md-out "$OUT_DIR/bench.md" --json-out "$OUT_DIR/bench.json"
