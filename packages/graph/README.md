# `graph` — Pure Pion Graph Data Structures & Algorithms

Pure Pion, zero-`World`, zero-dependency, `Send`-safe graph data structures and classic graph algorithms modeled after Rust [`petgraph`](https://github.com/petgraph/petgraph) (`=0.8.3`) and Go [`gonum/graph`](https://pkg.go.dev/gonum.org/v1/gonum/graph). Designed for compiler CFG/SSA analysis, DAG scheduling, layout engines, and shortest-path/network-flow workloads on both **Native** and **WebAssembly (`wasm32`)** targets.

## Features

- **Core Graph Representations**:
  - `DiGraph[N, E]`: mutable flat-index directed adjacency-list graph with intrusive out/in edge lists (`O(1)` `add_node`/`add_edge`, `O(deg)` `remove_edge`/`remove_node` with `petgraph`-aligned newest-first edge swap-remove reindexing, `O(deg)` bidirectional out/in traversal in insertion order, full support for parallel multi-edges and self-loops).
  - `UnGraph[N, E]`: mutable flat-index undirected adjacency-list graph with intrusive incident edge lists, parallel multi-edges, and self-loops.
  - `CsrGraph[E]`: immutable Compressed Sparse Row directed graph (`from_digraph`, `from_edges` in `O(V + E)` with explicit `InvalidArgument` size guards) with contiguous outgoing neighbor slices and specialized kernels (`csr_dijkstra`, `csr_tarjan_scc`, `csr_toposort`, `csr_toposort_any`, `csr_dominators`).
  - Lightweight `val struct` handles `NodeId` and `EdgeId`, plus `UnionFind` (path halving + union by rank).
- **Traversal & Connectivity (100% Iterative, Zero Recursion)**:
  - `bfs`, `ungraph_bfs`, `dfs_preorder`, `dfs_postorder`, `dfs_full` (discovery/finish times), `ungraph_dfs_preorder`.
  - `tarjan_scc` and `kosaraju_scc` (both guaranteed deterministic **reverse topological order**, sink SCCs first).
  - `connected_components`, `connected_component_count`.
  - `bridges` (tracks `parent_edge` so parallel edges are properly recognized as non-bridges) and `articulation_points` (Tarjan low-link, sorted by `NodeId`).
  - `is_bipartite` (BFS 2-coloring, detects odd cycles and self-loops).
- **DAG & Compiler CFG/SSA Analysis**:
  - `toposort` (Kahn's algorithm with zero-allocation binary min-heap for deterministic **lexicographically smallest** topological order) and `toposort_any` (`O(V + E)` FIFO queue). On cycles, both return `Err(HasCycle(node))` where `node` is guaranteed to lie on a directed cycle.
  - `find_cycle` & `is_cyclic` (iterative 3-color DFS returning exact cycle node paths, including self-loops).
  - `dominators` (Cooper-Harvey-Kennedy iterative algorithm using flat `FixedArray[Int]` tables with zero `HashMap`/`HashSet` overhead): `immediate_dominator`, `dominates`, `strict_dominators`, `all_dominators`, `immediately_dominated_by`, and `dominance_frontiers` (full Cytron et al. semantics including back-edges and self-loops targeting the entry root).
  - `transitive_reduction` (`O(V + E)` memory with `O(1)` fast-skips for out-degree `<= 1` / all-sink neighbors and epoch-stamped topological-pruned DFS) and `transitive_closure` (bitset DP with explicit `Int64` size guard).
- **Shortest Paths, Minimum Spanning Trees & Network Flow**:
  - `dijkstra` / `dijkstra_i64` / `csr_dijkstra` (zero-allocation binary min-heap, early exit on optional `goal`, rejects negative weights with `Err(NegativeWeight)` and true shortest-path `Int64` overflow with `Err(WeightOverflow)` while ignoring non-improving overflowing candidates).
  - `astar` (supports admissible non-consistent heuristics via closed-node re-opening, with negative edge/heuristic and overflow guards).
  - `bellman_ford` & `find_negative_cycle` (fast `Int64` path with exact 128-bit signed fallback so large-weight negative cycles always report `NegativeCycle` / extract the cycle rather than false `WeightOverflow`).
  - `floyd_warshall` (fast single-array `Int64` kernel for bounded non-negative weights, exact 128-bit signed kernel for negative/huge weights, explicit `node_count` size guard).
  - `kruskal_mst` / `kruskal_mst_i64` (adaptive 11-bit LSD Radix Sort skipping zero-variance digits + inlined `UnionFind`) and `prim_mst` (binary min-heap, supports disconnected spanning forests).
  - `dinic_max_flow` (`Int64` capacities, BFS level graph + iterative DFS with current-arc optimization and dead-node pruning; returns exact `max_flow`, per-edge `edge_flows`, and minimum S-T cut `source_side`).
- **Export**:
  - `digraph_to_dot` and `ungraph_to_dot` (Graphviz DOT format with proper escaping of `"`, `\`, `\n`, `\r`, `\t`, and ASCII control characters).
- **Red-Team Hardening**:
  - 100% iterative algorithms verified on **100,000-node deep chains, cycles, stars, and random graphs** across all 4 modes (Native/Wasm32 × debug/release) with 0 stack overflows, 0 traps, and byte-identical outputs.
  - Differential-fuzzed across **10 seeds × 1,000 random graphs × 22 sections** against Rust `petgraph =0.8.3` + exact `i128`/`u128`/brute-force oracles with **0 correctness mismatches** and **0 pointer-integrity violations** across 400,000 random mutations.

## Verification

```sh
pionc fmt --check packages/graph
pionc check --json packages/graph
pionc test --json packages/graph
sh packages/graph/audit/run_audit.sh
pionc build -o /private/tmp/graph-smoke/smoke_debug packages/graph/wasm_smoke
pionc build --release -o /private/tmp/graph-smoke/smoke_release packages/graph/wasm_smoke
pionc build --target wasm32 -o /private/tmp/graph-smoke/smoke_debug.wasm packages/graph/wasm_smoke
pionc build --target wasm32 --release -o /private/tmp/graph-smoke/smoke_release.wasm packages/graph/wasm_smoke
node "$HOME/.pion/share/pion/pion_wasm_rt.mjs" /private/tmp/graph-smoke/smoke_debug.wasm
node "$HOME/.pion/share/pion/pion_wasm_rt.mjs" /private/tmp/graph-smoke/smoke_release.wasm
```

All 29 unit + red-team regression tests pass, 20/21 audit tests pass (only `p2_neighbor_order_matches_petgraph` intentionally differs because `DiGraph` preserves insertion-order iteration rather than `petgraph`'s LIFO order), and `packages/graph/wasm_smoke` exits `0` across all 4 modes.

## Head-to-Head Benchmarks (`Darwin arm64`, `--warmup 1 --rounds 5`)

Measured via `sh packages/graph/bench/run_bench.sh` using `scripts/bench_compare.py` (strictly interleaved rounds, mandatory byte-identical stdout SHA-256 verification across all implementations):

- **Pion**: `packages/graph` (`pionc build --release`)
- **Rust**: `petgraph = "=0.8.3"` (`cargo build --release` with `opt-level = 3`, `lto = true`, `codegen-units = 1`)

### W1: Dijkstra Single-Source Shortest Path (50,000 nodes / 250,000 edges × 3 rounds, 750k edge relaxations)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 69.541 | 61.842 | 93.057 | 92.72 | 14.78 MiB | 0.91x |
| `pion_csr` | 47.174 | 45.962 | 48.540 | 62.90 | 19.03 MiB | **1.34x** |
| `rust_petgraph` | 63.012 | 56.597 | 73.541 | 84.02 | 10.36 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `7d2284ef80a7958750d57f68f5b7c13e778b90566e1aa519f59de9fa21baa83e`._

### W2: Tarjan SCC + Topological Sort (100,000 nodes / 400,000 edges each, 800k edges total)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 79.203 | 69.790 | 80.445 | 99.00 | 50.98 MiB | 0.60x |
| `pion_csr` | 80.140 | 67.131 | 91.331 | 100.18 | 57.16 MiB | 0.59x |
| `rust_petgraph` | 47.419 | 44.977 | 58.554 | 59.27 | 34.41 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `765842299691f19a22f0cdf0c8aa82872f1736b55d15c90b19522f0eedae1b3f`._

### W3: Kruskal Minimum Spanning Tree (50,000 nodes / 200,000 undirected edges)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 20.565 | 18.085 | 24.096 | 102.83 | 20.88 MiB | **1.27x** |
| `rust_petgraph` | 26.138 | 25.721 | 28.549 | 130.69 | 12.52 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `99042b7e421ab0d812b17c519414d5c6b0d1622c526fd32fa3fd30314527198e`._

### W4: CFG Dominators (20,000 nodes / 60,000 edges × 5 rounds, 300k edge inspections)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 24.869 | 22.975 | 26.494 | 82.90 | 5.55 MiB | **1.68x** |
| `pion_csr` | 21.727 | 21.237 | 22.014 | 72.42 | 7.28 MiB | **1.92x** |
| `rust_petgraph` | 41.751 | 40.911 | 42.089 | 139.17 | 8.61 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `8e7d2450047cbab918a4750d47eaac42b7146df5ba268c76f74c387920aabd2f`._

### Additional Adversarial Benchmarks (`packages/graph/audit/bench_adversarial.sh`, SHA-256 verified)

| Workload | Pion (ms) | Rust `petgraph` (ms) | Speedup | Peak RSS (Pion / Rust) |
| --- | ---: | ---: | ---: | --- |
| `A2_dinic_layers` (200 layers × 10) | 14.2 | 25.9 | **1.83x** | 6 / 5 MiB |
| `A9_floyd_dense` (300 dense) | 24.3 | 31.9 | **1.31x** | 6 / 7 MiB |
| `A10_tred_chain` (20k chain) | 13.7 | 1255.9 | **91.46x** | **7 / 912 MiB** |
| `A10b_tred_star` (100k out-star) | 58.3 | 21.0 | 0.36x | **28 / 22 MiB** (down from 1,217 MiB) |
| `A11_dominators_rand` (50k / 200k) | 52.6 | 63.0 | **1.20x** | 27 / 29 MiB |

### Honest Benchmark Notes & Scope Boundaries

- **Where Pion leads end-to-end**: **W1 Dijkstra CSR (`1.34x`)**, **W3 Kruskal MST (`1.27x`, kernel `1.98x`)**, **W4 CFG Dominators (`1.68x–1.92x`)**, **Dinic Max-Flow (`1.83x`)**, **Floyd-Warshall (`1.31x`)**, and **Transitive Reduction on chains (`91.46x`, `7 MiB` vs `912 MiB`)**.
- **Where Pion trails end-to-end**: **W2 (Tarjan SCC + Toposort, `0.60x`)** and build-dominated workloads (`B0_build_dense` `0.30x`, `B0_build_rand` `0.24x`). Although the Tarjan SCC kernel itself is **2.4x–5.0x faster** than `petgraph`, `DiGraph::add_edge` currently pays `pionc 0.1.0` runtime overhead from heap-boxing `Result[EdgeId, GraphError]` + `EdgeId` + `NodeId` per call and 8-byte `Array[Int]` slots (yielding ~1.5x RSS vs Rust's 24-byte `Edge` struct). `W2` also calls `toposort` (lex-smallest binary heap) rather than `toposort_any` (`O(V + E)`).
- **Compatibility & scope boundaries**:
  - Shortest-path, MST, and flow weights use exact `Int64` arithmetic (with exact 128-bit fallback in `bellman_ford`, `find_negative_cycle`, and `floyd_warshall`) rather than IEEE-754 `Float`.
  - `DiGraph::remove_node` unlinks incident edges newest-first to match `petgraph::Graph` `EdgeId` swap-remove layout (`0 / 10,000` layout mismatches in differential fuzzing).
  - `DiGraph` iterates outgoing/incoming neighbors in **insertion order** (FIFO), whereas `petgraph` iterates newest-first (LIFO); this is an intentional documented design choice preserved for existing callers and tests.
