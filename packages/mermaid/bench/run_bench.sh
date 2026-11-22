#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
BENCH_DIR="$ROOT_DIR/packages/mermaid/bench"
DATA_DIR="/tmp/mermaid-bench-data"
BIN_DIR="/tmp/mermaid-bench-bin"
NODE_DIR="${MERMAID_BENCH_NODE_DIR:-/tmp/mermaid-bench-node}"
mkdir -p "$DATA_DIR" "$BIN_DIR"

export PATH="$HOME/.pion/bin:$PATH"

echo "==> Generating deterministic corpora in $DATA_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR"
PARSE_BYTES=$(wc -c < "$DATA_DIR/parse_corpus.txt" | tr -d ' ')
LAYOUT_BYTES=$(wc -c < "$DATA_DIR/layout_graphs.txt" | tr -d ' ')

echo "==> Building Pion Native (--release) benchmark binaries into $BIN_DIR"
pionc build --release "$BENCH_DIR/bench_parse" -o "$BIN_DIR/bench_parse"
pionc build --release "$BENCH_DIR/bench_layout" -o "$BIN_DIR/bench_layout"

echo ""
echo "==> Benchmark 1: Parse + Canonical Topology JSON (Pion Native vs Node.js official mermaid)"
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Mermaid Parse + Canonical Topology JSON (6 diagrams, 320-node large flowchart)" \
  --impl "node-mermaid=MERMAID_BENCH_NODE_DIR=$NODE_DIR node $BENCH_DIR/bench_node_parse.mjs $DATA_DIR/parse_corpus.txt" \
  --impl "pion-mermaid=$BIN_DIR/bench_parse $DATA_DIR/parse_corpus.txt" \
  --baseline node-mermaid \
  --warmup 1 --rounds 5 --bytes "$PARSE_BYTES" \
  --md-out "$DATA_DIR/bench_parse.md" \
  --json-out "$DATA_DIR/bench_parse.json"

echo ""
echo "==> Benchmark 2: Layered Graph Layout (Pion Sugiyama vs Node.js official @dagrejs/dagre, 50/200/500 nodes)"
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Sugiyama / Dagre Layered Graph Layout (50 / 200 / 500 nodes)" \
  --impl "node-dagre=MERMAID_BENCH_NODE_DIR=$NODE_DIR node $BENCH_DIR/bench_node_layout.mjs $DATA_DIR/layout_graphs.txt" \
  --impl "pion-sugiyama=$BIN_DIR/bench_layout $DATA_DIR/layout_graphs.txt" \
  --baseline node-dagre \
  --warmup 1 --rounds 5 --bytes "$LAYOUT_BYTES" \
  --md-out "$DATA_DIR/bench_layout.md" \
  --json-out "$DATA_DIR/bench_layout.json"

echo ""
echo "==> Layout Quality Metrics Comparison (crossings, total edge length, canvas area)"
echo "--- Pion Sugiyama ---"
"$BIN_DIR/bench_layout" "$DATA_DIR/layout_graphs.txt" --metrics
echo "--- Node.js @dagrejs/dagre ---"
MERMAID_BENCH_NODE_DIR="$NODE_DIR" node "$BENCH_DIR/bench_node_layout.mjs" "$DATA_DIR/layout_graphs.txt" --metrics
