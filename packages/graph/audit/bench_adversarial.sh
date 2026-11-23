#!/bin/sh
# Adversarial head-to-head benchmarks: Pion (DiGraph/UnGraph/CsrGraph, --release) vs Rust petgraph =0.8.3
# (--release, lto). Both print byte-identical checksum lines, verified by scripts/bench_compare.py SHA-256.
#   sh bench_adversarial.sh ORACLE RUNNER ROOT OUT [ROUNDS]
set -eu
ORACLE=$1; RUNNER=$2; ROOT=$3; OUT=$4; ROUNDS=${5:-5}
mkdir -p "$OUT"
run() { # name family n algo ops [pion_algo]
  name=$1; fam=$2; n=$3; algo=$4; ops=$5; palgo=${6:-$4}
  python3 "$ROOT/scripts/bench_compare.py" --title "graph adversarial $name ($fam n=$n)" \
    --impl "pion=$RUNNER stress $fam $n $palgo" \
    --impl "rust_petgraph=$ORACLE stress $fam $n $algo" \
    --baseline rust_petgraph --warmup 1 --rounds "$ROUNDS" --ops "$ops" \
    --md-out "$OUT/$name.md" --json-out "$OUT/$name.json" >"$OUT/$name.log" 2>&1 || { echo "  $name: FAILED (see $OUT/$name.log)"; tail -5 "$OUT/$name.log"; return 0; }
  python3 - "$OUT/$name.json" "$name" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); name = sys.argv[2]
r = {x["name"]: x for x in d["results"]} if isinstance(d, dict) and "results" in d else {x["name"]: x for x in d}
p, q = r["pion"], r["rust_petgraph"]
k = "median_ms"
print(f"  {name:22s} pion {p[k]:9.1f} ms  petgraph {q[k]:9.1f} ms  pion/petgraph speed {q[k]/p[k]:5.2f}x  rss pion {(p['peak_rss_bytes'] or 0)/1048576:.0f}MiB vs petgraph {(q['peak_rss_bytes'] or 0)/1048576:.0f}MiB")
PY
}
run A1_bellman_ford     rand   20000  bf          80000
run A2_dinic_layers     layers 2002   dinic       19920
run A3_bridges_chain    chain  100000 bridges     100000
run A4_artic_star       star   100000 ap          100000
run A5_astar_h0         rand   50000  astar       200000
run A6_dijkstra_dense   dense  2000   dij         1332667
run A7_dijkstra_csr     dense  2000   dij         1332667 csr_dij
run A8_remove_nodes     rand   20000  removenodes 10000
run A9_floyd_dense      dense  300    floyd       27000000
run A10_tred_chain      chain  20000  tred        20000   # petgraph also builds the O(V^2) closure here
run A11_dominators_rand rand   50000  dom         200000
run A12_kosaraju        rand   100000 kosaraju    400000
run A13_prim            rand   50000  prim        200000
run A14_toposort_chain  chain  100000 topo        100000
# construction-only baselines (same graphs, no algorithm): separates DiGraph+UnGraph build cost from algorithm cost
run B0_build_dense      dense  2000   none        1332667
run B0_build_rand       rand   100000 none        400000
# memory: transitive reduction on a sparse DAG whose closure is tiny (out-star) -- Pion allocates V*V/64 words
run A10b_tred_star      star   100000 tred        100000
