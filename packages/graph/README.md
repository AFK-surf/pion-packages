# `graph` — Pure Pion Graph Data Structures & Algorithms

Pure Pion, zero-`World`, zero-dependency, `Send`-safe graph data structures and classic graph algorithms modeled after Rust [`petgraph`](https://github.com/petgraph/petgraph) (`=0.8.3`) and Go [`gonum/graph`](https://pkg.go.dev/gonum.org/v1/gonum/graph). Designed for compiler CFG/SSA analysis, DAG scheduling, layout engines, and shortest-path/network-flow workloads on both **Native** and **WebAssembly (`wasm32`)** targets.

## Features

- **Core Graph Representations**:
  - `DiGraph[N, E]`: mutable flat-index directed adjacency-list graph with intrusive out/in edge lists (O(1) `add_node`/`add_edge`, O(deg) `remove_edge`/`remove_node` with dense swap-remove reindexing, O(deg) bidirectional out/in traversal in insertion order, full support for parallel multi-edges and self-loops).
  - `UnGraph[N, E]`: mutable flat-index undirected adjacency-list graph with intrusive incident edge lists, parallel multi-edges, and self-loops.
  - `CsrGraph[E]`: immutable Compressed Sparse Row directed graph (`from_digraph`, `from_edges` in O(V + E)) with contiguous outgoing neighbor slices and specialized kernels (`csr_dijkstra`, `csr_tarjan_scc`, `csr_toposort`, `csr_dominators`).
  - Lightweight `val struct` handles `NodeId` and `EdgeId`, plus `UnionFind` (path halving + union by rank).
- **Traversal & Connectivity (100% Iterative, Zero Recursion)**:
  - `bfs`, `ungraph_bfs`, `dfs_preorder`, `dfs_postorder`, `dfs_full` (discovery/finish times), `ungraph_dfs_preorder`.
  - `tarjan_scc` and `kosaraju_scc` (both guaranteed deterministic **reverse topological order**, sink SCCs first).
  - `connected_components`, `connected_component_count`.
  - `bridges` (tracks `parent_edge` so parallel edges are properly recognized as non-bridges) and `articulation_points` (Tarjan low-link, sorted by `NodeId`).
  - `is_bipartite` (BFS 2-coloring, detects odd cycles and self-loops).
- **DAG & Compiler CFG/SSA Analysis**:
  - `toposort` (Kahn's algorithm with binary min-heap for deterministic **lexicographically smallest** topological order; returns `Err(HasCycle(node))` on cycles).
  - `find_cycle` & `is_cyclic` (iterative 3-color DFS returning exact cycle node paths, including self-loops).
  - `dominators` (Cooper-Harvey-Kennedy iterative algorithm using flat `FixedArray[Int]` tables with zero `HashMap`/`HashSet` overhead): `immediate_dominator`, `dominates`, `strict_dominators`, `all_dominators`, `immediately_dominated_by`, and `dominance_frontiers` (for SSA phi-node placement).
  - `transitive_closure` and `transitive_reduction` on DAGs (bitset DP in reverse topological order).
- **Shortest Paths, Minimum Spanning Trees & Network Flow**:
  - `dijkstra` / `dijkstra_i64` / `csr_dijkstra` (binary min-heap, early exit on optional `goal`, rejects negative weights with `Err(NegativeWeight)` and `Int64` overflow with `Err(WeightOverflow)`).
  - `astar` (heuristic search with negative edge/heuristic and overflow guards).
  - `bellman_ford` & `find_negative_cycle` (negative weights + negative-cycle detection & cycle path extraction).
  - `floyd_warshall` (all-pairs shortest paths with negative weights, overflow checks, and negative-cycle detection).
  - `kruskal_mst` / `kruskal_mst_i64` (O(E) Floyd bottom-up min-heapify + early exit + `UnionFind`) and `prim_mst` (binary min-heap, supports disconnected spanning forests).
  - `dinic_max_flow` (`Int64` capacities, BFS level graph + iterative DFS with current-arc optimization and dead-node pruning; returns exact `max_flow`, per-edge `edge_flows`, and minimum S-T cut `source_side`).
- **Export**:
  - `digraph_to_dot` and `ungraph_to_dot` (Graphviz DOT format with proper escaping of `"`, `\`, `\n`, `\r`, `\t`, and ASCII control characters).
- **Day-1 Red-Team Safety**:
  - 100% iterative algorithms verified on **100,000-node deep chains and cycles** with zero stack overflow on both Native and `wasm32`.
  - Strict bounds checking on invalid `NodeId`/`EdgeId`, empty/isolated graphs, self-loops, parallel edges, negative weights/capacities, and `Int64` arithmetic overflow.

## Verification

```sh
pionc fmt --check packages/graph
pionc check --json packages/graph
pionc test --json packages/graph
pionc build -o /private/tmp/graph-smoke/smoke_debug packages/graph/wasm_smoke
pionc build --release -o /private/tmp/graph-smoke/smoke_release packages/graph/wasm_smoke
pionc build --target wasm32 -o /private/tmp/graph-smoke/smoke_debug.wasm packages/graph/wasm_smoke
pionc build --target wasm32 --release -o /private/tmp/graph-smoke/smoke_release.wasm packages/graph/wasm_smoke
pionc run --target wasm32 packages/graph/wasm_smoke
pionc run --target wasm32 --release packages/graph/wasm_smoke
```

All 24 unit + red-team tests pass, and `packages/graph/wasm_smoke` (including a 100,000-node chain running `tarjan_scc`, `toposort`, and `dominators`) builds and exits `0` across all 4 modes (Native/Wasm32 × debug/release; `smoke_release.wasm` is `48 KiB`).

## Head-to-Head Benchmarks (`Darwin arm64`, `--warmup 1 --rounds 5`)

Measured via `sh packages/graph/bench/run_bench.sh` using `scripts/bench_compare.py` (strictly interleaved rounds, mandatory byte-identical stdout SHA-256 verification across all implementations):

- **Pion**: `packages/graph` (`pionc build --release`)
- **Rust**: `petgraph = "=0.8.3"` (`cargo build --release` with `opt-level = 3`, `lto = true`, `codegen-units = 1`)

### W1: Dijkstra Single-Source Shortest Path (50,000 nodes / 250,000 edges × 3 rounds, 750k edge relaxations)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 63.167 | 58.783 | 97.871 | 84.22 | 14.75 MiB | 0.65x |
| `pion_csr` | 45.747 | 44.403 | 46.488 | 61.00 | 19.00 MiB | 0.90x |
| `rust_petgraph` | 41.033 | 38.635 | 56.597 | 54.71 | 10.36 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `7d2284ef80a7958750d57f68f5b7c13e778b90566e1aa519f59de9fa21baa83e`._

### W2: Tarjan SCC + Topological Sort (100,000 nodes / 400,000 edges each, 800k edges total)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 65.516 | 62.279 | 67.346 | 81.90 | 50.97 MiB | 0.64x |
| `pion_csr` | 60.431 | 56.862 | 64.310 | 75.54 | 57.14 MiB | 0.69x |
| `rust_petgraph` | 41.648 | 38.664 | 42.557 | 52.06 | 34.41 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `765842299691f19a22f0cdf0c8aa82872f1736b55d15c90b19522f0eedae1b3f`._

### W3: Kruskal Minimum Spanning Tree (50,000 nodes / 200,000 undirected edges)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 35.236 | 32.020 | 40.108 | 176.18 | 17.80 MiB | 0.67x |
| `rust_petgraph` | 23.705 | 23.341 | 28.572 | 118.53 | 12.52 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `99042b7e421ab0d812b17c519414d5c6b0d1622c526fd32fa3fd30314527198e`._

### W4: CFG Dominators (20,000 nodes / 60,000 edges × 5 rounds, 300k edge inspections)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_petgraph`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_digraph` | 22.485 | 21.154 | 24.188 | 74.95 | 5.52 MiB | **1.70x** |
| `pion_csr` | 20.015 | 18.047 | 20.937 | 66.72 | 7.27 MiB | **1.91x** |
| `rust_petgraph` | 38.231 | 37.751 | 38.731 | 127.44 | 8.61 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `8e7d2450047cbab918a4750d47eaac42b7146df5ba268c76f74c387920aabd2f`._

### Honest Benchmark Notes & Scope Boundaries

- **Where Pion leads**: On **W4 (CFG Dominators)**, `packages/graph` is **1.70x–1.91x faster** than Rust `petgraph =0.8.3` with lower peak RSS (`5.52–7.27 MiB` vs `8.61 MiB`). This is because `packages/graph` runs Cooper-Harvey-Kennedy purely over dense `FixedArray[Int]` indices and intrusive `first_in`/`next_in` (or CSR predecessor) arrays, avoiding `petgraph`'s `HashMap`/`HashSet` predecessor table allocations.
- **Where Pion is close or trails**:
  - On **W1 (Dijkstra)**, `pion_csr` (`45.75 ms`, `0.90x`) is within 10% of LTO-optimized Rust `petgraph` (`41.03 ms`), while `pion_digraph` (`63.17 ms`, `0.65x`) pays pointer-chasing cost on intrusive edge lists. Note also that `packages/graph` performs checked `Int64` negative-weight and overflow guards on every edge relaxation.
  - On **W2 (Tarjan SCC + Toposort)**, Pion (`60.43–65.52 ms`, `0.64x–0.69x`) trails Rust (`41.65 ms`) in part because Pion's `toposort` uses Kahn's algorithm with a binary min-heap (`O((V + E) log V)`) to guarantee the deterministic **lexicographically smallest** topological order, whereas `petgraph::algo::toposort` runs an `O(V + E)` DFS producing an arbitrary valid order; `pion_csr` also includes `CsrGraph::from_digraph` construction inside the measured wall time.
  - On **W3 (Kruskal MST)**, Pion (`35.24 ms`, `0.67x`) uses O(E) Floyd min-heapify + early exit + `UnionFind`, trailing Rust (`23.71 ms`) due to bounds-checked array indexing and `Int64` overflow checks.
- **Scope boundaries**: Shortest-path, MST, and flow weights use exact `Int64` arithmetic with explicit overflow/negative checks (no IEEE-754 `Float` NaN ordering hazards). `DiGraph`/`UnGraph` use `petgraph::Graph`-style swap-remove reindexing on deletion rather than generational tombstones (`StableGraph`).
