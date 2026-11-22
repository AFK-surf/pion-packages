#!/bin/sh
# Head-to-head benchmark runner for packages/crdt (Pion Native vs Node.js official yjs).
# All build artifacts and Node dependencies are placed in /tmp to keep the git worktree clean.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/tmp/pion-crdt-bench"
BIN_DIR="$OUT_DIR/bin"
NODE_DIR="$OUT_DIR/node"

mkdir -p "$BIN_DIR" "$NODE_DIR"

if [ ! -d "$NODE_DIR/node_modules/yjs" ]; then
  if [ -d "/tmp/crdt-node/node_modules/yjs" ]; then
    ln -sfn /tmp/crdt-node/node_modules "$NODE_DIR/node_modules"
  else
    echo "==> Installing official yjs into $NODE_DIR"
    (cd "$NODE_DIR" && npm init -y >/dev/null 2>&1 && npm install yjs >/dev/null 2>&1)
  fi
fi

export YJS_MODULE="$NODE_DIR/node_modules/yjs"

echo "==> Building Pion Native benchmarks (--release)"
pionc build --release -o "$BIN_DIR/pion_text" "$BENCH_DIR/pion_text"
pionc build --release -o "$BIN_DIR/pion_sync" "$BENCH_DIR/pion_sync"

echo ""
echo "=== WORKLOAD 1: Sequential + Random Text Edits (20,000 ops x 10 iters) + v1 Encode/Decode ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CRDT: Sequential + Random Text Edits (20k ops x 10) + v1 Encode" \
  --impl "pion=$BIN_DIR/pion_text 20000 10" \
  --impl "node_yjs=node $BENCH_DIR/bench_node_text.mjs 20000 10" \
  --baseline node_yjs \
  --warmup 1 --rounds 5 --ops 200000 \
  --md-out "$OUT_DIR/text_edit.md" --json-out "$OUT_DIR/text_edit.json"

echo ""
echo "=== WORKLOAD 2: Two-Client Concurrent Mixed Edits (2 x 5,000 ops x 10 iters) + Incremental v1 Sync ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "CRDT: 2-Client Concurrent Text+Array+Map (10k ops x 10) + v1 Sync" \
  --impl "pion=$BIN_DIR/pion_sync 5000 10" \
  --impl "node_yjs=node $BENCH_DIR/bench_node_sync.mjs 5000 10" \
  --baseline node_yjs \
  --warmup 1 --rounds 5 --ops 100000 \
  --md-out "$OUT_DIR/concurrent_sync.md" --json-out "$OUT_DIR/concurrent_sync.json"
