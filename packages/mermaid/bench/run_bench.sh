#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
BENCH_DIR="$ROOT_DIR/packages/mermaid/bench"
DATA_DIR="/tmp/mermaid-bench-data"
BIN_DIR="/tmp/mermaid-bench-bin"
NODE_DIR="${MERMAID_BENCH_NODE_DIR:-/tmp/mermaid-bench-node}"
PARSE_ITERS="${PARSE_ITERS:-50}"
LAYOUT_ITERS="${LAYOUT_ITERS:-20}"
mkdir -p "$DATA_DIR" "$BIN_DIR"

export PATH="$HOME/.pion/bin:$PATH"

echo "==> Generating deterministic corpora in $DATA_DIR"
python3 "$BENCH_DIR/gen_corpus.py" "$DATA_DIR"
PARSE_BYTES=$(wc -c < "$DATA_DIR/parse_corpus.txt" | tr -d ' ')
LAYOUT_BYTES=$(wc -c < "$DATA_DIR/layout_graphs.txt" | tr -d ' ')
PARSE_STEADY_BYTES=$((PARSE_BYTES * PARSE_ITERS))
LAYOUT_STEADY_BYTES=$((LAYOUT_BYTES * LAYOUT_ITERS))

echo "==> Building Pion Native (--release) benchmark binaries into $BIN_DIR"
pionc build --release "$BENCH_DIR/bench_parse" -o "$BIN_DIR/bench_parse"
pionc build --release "$BENCH_DIR/bench_layout" -o "$BIN_DIR/bench_layout"

echo ""
echo "==> Benchmark 1A (Steady-State, --iters $PARSE_ITERS): Parse + Canonical Topology JSON"
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Mermaid Parse + Canonical JSON — Steady-State (${PARSE_ITERS}x corpus, 6 diagrams incl. 320-node flowchart)" \
  --impl "node-mermaid=MERMAID_BENCH_NODE_DIR=$NODE_DIR node $BENCH_DIR/bench_node_parse.mjs $DATA_DIR/parse_corpus.txt --iters $PARSE_ITERS" \
  --impl "pion-mermaid=$BIN_DIR/bench_parse $DATA_DIR/parse_corpus.txt --iters $PARSE_ITERS" \
  --baseline node-mermaid \
  --warmup 1 --rounds 5 --bytes "$PARSE_STEADY_BYTES" \
  --md-out "$DATA_DIR/bench_parse_steady.md" \
  --json-out "$DATA_DIR/bench_parse_steady.json"

echo ""
echo "==> Benchmark 1B (Cold-Start, --iters 1): Parse + Canonical Topology JSON"
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Mermaid Parse + Canonical JSON — Cold-Start (1x CLI startup + parse)" \
  --impl "node-mermaid=MERMAID_BENCH_NODE_DIR=$NODE_DIR node $BENCH_DIR/bench_node_parse.mjs $DATA_DIR/parse_corpus.txt --iters 1" \
  --impl "pion-mermaid=$BIN_DIR/bench_parse $DATA_DIR/parse_corpus.txt --iters 1" \
  --baseline node-mermaid \
  --warmup 1 --rounds 5 --bytes "$PARSE_BYTES" \
  --md-out "$DATA_DIR/bench_parse_cold.md" \
  --json-out "$DATA_DIR/bench_parse_cold.json"

echo ""
echo "==> Benchmark 2A (Steady-State, --iters $LAYOUT_ITERS): Layered Graph Layout (50/200/500 nodes)"
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Sugiyama / Dagre Layered Graph Layout — Steady-State (${LAYOUT_ITERS}x 50/200/500 nodes)" \
  --impl "node-dagre=MERMAID_BENCH_NODE_DIR=$NODE_DIR node $BENCH_DIR/bench_node_layout.mjs $DATA_DIR/layout_graphs.txt --iters $LAYOUT_ITERS" \
  --impl "pion-sugiyama=$BIN_DIR/bench_layout $DATA_DIR/layout_graphs.txt --iters $LAYOUT_ITERS" \
  --baseline node-dagre \
  --warmup 1 --rounds 5 --bytes "$LAYOUT_STEADY_BYTES" \
  --md-out "$DATA_DIR/bench_layout_steady.md" \
  --json-out "$DATA_DIR/bench_layout_steady.json"

echo ""
echo "==> Benchmark 2B (Cold-Start, --iters 1): Layered Graph Layout (50/200/500 nodes)"
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Sugiyama / Dagre Layered Graph Layout — Cold-Start (1x CLI startup + layout)" \
  --impl "node-dagre=MERMAID_BENCH_NODE_DIR=$NODE_DIR node $BENCH_DIR/bench_node_layout.mjs $DATA_DIR/layout_graphs.txt --iters 1" \
  --impl "pion-sugiyama=$BIN_DIR/bench_layout $DATA_DIR/layout_graphs.txt --iters 1" \
  --baseline node-dagre \
  --warmup 1 --rounds 5 --bytes "$LAYOUT_BYTES" \
  --md-out "$DATA_DIR/bench_layout_cold.md" \
  --json-out "$DATA_DIR/bench_layout_cold.json"

echo ""
echo "==> Layout Quality Metrics Comparison (crossings, total edge length, canvas area)"
echo "--- Pion Sugiyama ---"
"$BIN_DIR/bench_layout" "$DATA_DIR/layout_graphs.txt" --iters 1 --metrics
echo "--- Node.js @dagrejs/dagre ---"
MERMAID_BENCH_NODE_DIR="$NODE_DIR" node "$BENCH_DIR/bench_node_layout.mjs" "$DATA_DIR/layout_graphs.txt" --iters 1 --metrics
