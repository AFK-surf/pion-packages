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
  - `toposort` (Kahn's algorithm with inlined `FixedArray` 4-ary min-heap and deferred root sift-down for deterministic **lexicographically smallest** topological order) and `toposort_any` (`O(V + E)` FIFO queue). On cycles, both return `Err(HasCycle(node))` where `node` is guaranteed to lie on a directed cycle.
  - `find_cycle` & `is_cyclic` (iterative 3-color DFS returning exact cycle node paths, including self-loops).
  - `dominators` (Cooper-Harvey-Kennedy iterative algorithm using flat `FixedArray[Int]` tables with zero `HashMap`/`HashSet` overhead): `immediate_dominator`, `dominates`, `strict_dominators`, `all_dominators`, `immediately_dominated_by`, and `dominance_frontiers` (full Cytron et al. semantics including back-edges and self-loops targeting the entry root).
  - `transitive_reduction` (`O(V + E)` memory with `O(1)` fast-skips for out-degree `<= 1` / all-sink neighbors and epoch-stamped topological-pruned DFS) and `transitive_closure` (bitset DP with explicit `Int64` size guard).
- **Shortest Paths, Minimum Spanning Trees & Network Flow**:
  - `dijkstra` / `dijkstra_i64` / `csr_dijkstra` (inlined indexed 4-ary min-heap with `O(V)` fixed memory and in-place decrease-key, early exit on optional `goal`, rejects negative weights with `Err(NegativeWeight)` and true shortest-path `Int64` overflow with `Err(WeightOverflow)` while ignoring non-improving overflowing candidates).
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

## Head-to-Head Benchmarks (`Linux x86_64`, `--warmup 1 --rounds 5`)

Measured via `sh packages/graph/bench/run_bench.sh` using `scripts/bench_compare.py` (strictly interleaved rounds, mandatory byte-identical stdout SHA-256 verification across all implementations):

- **Pion**: `packages/graph` (`pionc build --release`)
- **Rust**: `petgraph = "=0.8.3"` (`cargo build --release` with `opt-level = 3`, `lto = true`, `codegen-units = 1`)

### W1: Dijkstra Single-Source Shortest Path (50,000 nodes / 250,000 edges × 3 rounds, 750k edge relaxations)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 64.228 | 48.887 | 86.843 | 85.64 | 11.28 MiB | **1.38x** |
| `pion_csr` | 49.432 | 37.944 | 67.156 | 65.91 | 13.03 MiB | **1.79x** |
| `rust_petgraph` | 88.427 | 72.632 | 140.735 | 117.90 | 11.28 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `7d2284ef80a7958750d57f68f5b7c13e778b90566e1aa519f59de9fa21baa83e`._

### W2: Tarjan SCC + Topological Sort (100,000 nodes / 400,000 edges each, 800k edges total)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 111.820 | 93.781 | 131.573 | 139.78 | 33.56 MiB | 0.61x |
| `pion_csr` | 148.297 | 132.550 | 182.901 | 185.37 | 38.49 MiB | 0.46x |
| `rust_petgraph` | 68.248 | 55.642 | 93.631 | 85.31 | 33.67 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `765842299691f19a22f0cdf0c8aa82872f1736b55d15c90b19522f0eedae1b3f`._

### W3: Kruskal Minimum Spanning Tree (50,000 nodes / 200,000 undirected edges)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 26.644 | 25.200 | 28.428 | 133.22 | 13.06 MiB | **2.04x** |
| `rust_petgraph` | 54.394 | 51.931 | 59.380 | 271.97 | 11.96 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `99042b7e421ab0d812b17c519414d5c6b0d1622c526fd32fa3fd30314527198e`._

### W4: CFG Dominators (20,000 nodes / 60,000 edges × 5 rounds, 300k edge inspections)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 26.801 | 22.174 | 29.223 | 89.34 | 11.28 MiB | **3.02x** |
| `pion_csr` | 18.251 | 17.110 | 22.872 | 60.84 | 11.28 MiB | **4.43x** |
| `rust_petgraph` | 80.872 | 71.384 | 98.906 | 269.57 | 11.28 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `8e7d2450047cbab918a4750d47eaac42b7146df5ba268c76f74c387920aabd2f`._

### Additional Adversarial Benchmarks (`packages/graph/audit/bench_adversarial.sh`, SHA-256 verified)

| Workload | Pion (ms) | Rust `petgraph` (ms) | Speedup |
| --- | ---: | ---: | ---: |
| `A1_bellman_ford` (20k / 80k) | 22.1 | 24.4 | **1.11x** |
| `A2_dinic_layers` (200 layers × 10) | 6.6 | 10.8 | **1.64x** |
| `A9_floyd_dense` (300 dense) | 19.7 | 26.5 | **1.35x** |
| `A10_tred_chain` (20k chain) | 6.6 | 942.2 | **143.19x** |
| `A10b_tred_star` (100k out-star) | 24.3 | 15.0 | 0.62x |
| `A11_dominators_rand` (50k / 200k) | 66.2 | 119.5 | **1.81x** |
| `A13_prim` (50k / 200k) | 146.6 | 155.3 | **1.06x** |

### Honest Benchmark Notes & Scope Boundaries

- **Where Pion leads end-to-end**: **W1 Dijkstra DiGraph (`1.38x`) & CSR (`1.79x`)**, **W3 Kruskal MST (`2.04x`, kernel `3.67x`)**, **W4 CFG Dominators (`3.02x–4.43x`, kernel `5.15x`)**, **Dinic Max-Flow (`1.64x`)**, **Floyd-Warshall (`1.35x`)**, **Bellman-Ford (`1.11x`)**, **Prim MST (`1.06x`)**, and **Transitive Reduction on chains (`143.19x`)**.
- **Where Pion trails end-to-end**: **W2 (Tarjan SCC + Toposort, `0.61x`, down from `154.6 ms` to `111.8 ms`, Peak RSS `33.56 MiB` vs Rust `33.67 MiB`)** and build-dominated workloads (`B0_build_dense` `0.42x`, `B0_build_rand` `0.33x`). Although the Tarjan SCC kernel itself is **1.68x faster** than `petgraph` (`37.7 ms` vs `63.2 ms` on 100k/400k random graphs), constructing two 100k-node / 400k-edge graphs (`800,000` `DiGraph::add_edge` calls) currently pays `pionc 0.1.0` per-call heap-boxing overhead for `NodeId`, `EdgeId`, and `Result[EdgeId, GraphError]` (~58 ms for construction alone). `W2` also calls `toposort` (lex-smallest 4-ary heap) rather than `toposort_any` (`O(V + E)`).
- **Compatibility & scope boundaries**:
  - Shortest-path, MST, and flow weights use exact `Int64` arithmetic (with exact 128-bit fallback in `bellman_ford`, `find_negative_cycle`, and `floyd_warshall`) rather than IEEE-754 `Float`.
  - `DiGraph::remove_node` unlinks incident edges newest-first to match `petgraph::Graph` `EdgeId` swap-remove layout (`0 / 10,000` layout mismatches in differential fuzzing).
  - `DiGraph` iterates outgoing/incoming neighbors in **insertion order** (FIFO), whereas `petgraph` iterates newest-first (LIFO); this is an intentional documented design choice preserved for existing callers and tests.
