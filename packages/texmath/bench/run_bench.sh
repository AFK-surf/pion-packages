#!/bin/sh
# Head-to-head benchmark: Pion native `texmath` vs Node.js official `KaTeX`.
# Usage: KATEX_PATH=/path/to/node_modules/katex sh packages/texmath/bench/run_bench.sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
PIONC_BIN="${PIONC:-$(command -v pionc 2>/dev/null || echo "$HOME/.pion/bin/pionc")}"
TMP_BIN="/tmp/texmath_bench_pion_$$"
trap 'rm -f "$TMP_BIN"' EXIT

"$PIONC_BIN" build --release "$SCRIPT_DIR/pion_bench" -o "$TMP_BIN"

KATEX_SPEC="${KATEX_PATH:-katex}"
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "TeX Math Parse + MathML (500 formulas x 20 = 10,000 ops)" \
  --baseline node-katex \
  --impl "node-katex=KATEX_PATH=$KATEX_SPEC node $SCRIPT_DIR/katex_bench.mjs $SCRIPT_DIR/corpus.txt 20" \
  --impl "pion-texmath=$TMP_BIN $SCRIPT_DIR/corpus.txt 20" \
  --warmup 1 --rounds 5 --ops 10000
