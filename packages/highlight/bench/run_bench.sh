#!/bin/sh
# Head-to-head benchmark: Pion native `highlight` vs Node.js official `prismjs`.
# Usage: PRISM_PATH=/tmp/prism-bench/node_modules/prismjs sh packages/highlight/bench/run_bench.sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../../.." && pwd)
PIONC_BIN="${PIONC:-$(command -v pionc 2>/dev/null || echo "$HOME/.pion/bin/pionc")}"
TMP_BIN="/tmp/highlight_bench_pion_$$"
trap 'rm -f "$TMP_BIN"' EXIT

"$PIONC_BIN" build --release "$SCRIPT_DIR/pion_bench" -o "$TMP_BIN"

PRISM_SPEC="${PRISM_PATH:-prismjs}"
ITERS="${BENCH_ITERS:-220}"
CORPUS_BYTES=$(wc -c < "$SCRIPT_DIR/corpus.txt" | tr -d ' ')
# Compute exact source bytes across all entries x iters
TOTAL_BYTES=$(node -e "
const fs = require('fs');
const raw = fs.readFileSync(process.argv[1], 'utf8');
let total = 0, cur = [], active = false;
for (const line of raw.split('\n')) {
  if (line.length > 11 && line.startsWith('===LANG:') && line.endsWith('===')) {
    if (active) total += Buffer.byteLength(cur.join('\n'), 'utf8');
    cur = []; active = true;
  } else if (active) cur.push(line);
}
if (active) total += Buffer.byteLength(cur.join('\n'), 'utf8');
console.log(total * Number(process.argv[2]));
" "$SCRIPT_DIR/corpus.txt" "$ITERS")

python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Syntax Highlighting (9 languages, ${TOTAL_BYTES} B steady-state)" \
  --baseline node-prismjs \
  --impl "node-prismjs=PRISM_PATH=$PRISM_SPEC node $SCRIPT_DIR/prism_bench.mjs $SCRIPT_DIR/corpus.txt $ITERS" \
  --impl "pion-highlight=$TMP_BIN $SCRIPT_DIR/corpus.txt $ITERS" \
  --warmup 1 --rounds 5 --bytes "$TOTAL_BYTES"
