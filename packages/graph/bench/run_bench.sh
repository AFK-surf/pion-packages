#!/bin/sh
# Head-to-head benchmark runner for packages/graph
# (Pion Native DiGraph & CsrGraph vs Rust petgraph =0.8.3 --release).
# All build artifacts and temporary outputs are placed in /private/tmp.
set -eu

BENCH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$BENCH_DIR/../../.." && pwd)
OUT_DIR="/private/tmp/pion-graph-bench"
BIN_DIR="$OUT_DIR/bin"

mkdir -p "$BIN_DIR"

echo "==> Building Pion Native benchmark (--release)"
pionc build --release -o "$BIN_DIR/pion_graph_bench" "$BENCH_DIR/pion_bench"

echo "==> Building Rust petgraph =0.8.3 benchmark (--release, target in /private/tmp)"
CARGO_TARGET_DIR="$OUT_DIR/rust-target" cargo build --release \
  --manifest-path "$BENCH_DIR/rust/Cargo.toml"
cp "$OUT_DIR/rust-target/release/graph_bench_rust" "$BIN_DIR/rust_graph_bench"

echo ""
echo "=== W1: Dijkstra Single-Source Shortest Path (50k nodes, 250k edges, 3 rounds) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Graph W1: Dijkstra SSSP (50k nodes / 250k edges x3)" \
  --impl "pion_digraph=$BIN_DIR/pion_graph_bench w1_dijkstra" \
  --impl "pion_csr=$BIN_DIR/pion_graph_bench w1_dijkstra_csr" \
  --impl "rust_petgraph=$BIN_DIR/rust_graph_bench w1_dijkstra" \
  --baseline rust_petgraph \
  --warmup 1 --rounds 5 --ops 750000 \
  --md-out "$OUT_DIR/w1_dijkstra.md" --json-out "$OUT_DIR/w1_dijkstra.json"

echo ""
echo "=== W2: Tarjan SCC + Topological Sort (100k nodes, 400k edges each) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Graph W2: Tarjan SCC + Toposort (100k nodes / 400k edges)" \
  --impl "pion_digraph=$BIN_DIR/pion_graph_bench w2_scc_topo" \
  --impl "pion_csr=$BIN_DIR/pion_graph_bench w2_scc_topo_csr" \
  --impl "rust_petgraph=$BIN_DIR/rust_graph_bench w2_scc_topo" \
  --baseline rust_petgraph \
  --warmup 1 --rounds 5 --ops 800000 \
  --md-out "$OUT_DIR/w2_scc_topo.md" --json-out "$OUT_DIR/w2_scc_topo.json"

echo ""
echo "=== W3: Kruskal Minimum Spanning Tree (50k nodes, 200k undirected edges) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Graph W3: Kruskal MST (50k nodes / 200k edges)" \
  --impl "pion=$BIN_DIR/pion_graph_bench w3_kruskal" \
  --impl "rust_petgraph=$BIN_DIR/rust_graph_bench w3_kruskal" \
  --baseline rust_petgraph \
  --warmup 1 --rounds 5 --ops 200000 \
  --md-out "$OUT_DIR/w3_kruskal.md" --json-out "$OUT_DIR/w3_kruskal.json"

echo ""
echo "=== W4: CFG Dominators (20k nodes, 60k edges x5 rounds) ==="
python3 "$ROOT_DIR/scripts/bench_compare.py" \
  --title "Graph W4: CFG Dominators (20k nodes / 60k edges x5)" \
  --impl "pion_digraph=$BIN_DIR/pion_graph_bench w4_dominators" \
  --impl "pion_csr=$BIN_DIR/pion_graph_bench w4_dominators_csr" \
  --impl "rust_petgraph=$BIN_DIR/rust_graph_bench w4_dominators" \
  --baseline rust_petgraph \
  --warmup 1 --rounds 5 --ops 300000 \
  --md-out "$OUT_DIR/w4_dominators.md" --json-out "$OUT_DIR/w4_dominators.json"
