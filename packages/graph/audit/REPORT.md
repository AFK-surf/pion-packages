# Red-team audit — `packages/graph` vs Rust `petgraph =0.8.3`

Target: `feat/pkg-graph` @ `a38f2c2` (Wave 8). Branch `audit/redteam-graph` only adds `packages/graph/audit/**`;
`packages/graph/src/**` and the package's own tests are untouched.

Machine: Darwin arm64 (Apple Silicon), `pionc 0.1.0` (AFK-surf/pion@81b8fb0), `cargo 1.100.0`, node v24.22.2.
Reproduce everything with:

```sh
sh packages/graph/audit/run_audit.sh            # ~1 min; outputs under /private/tmp/graph-redteam
sh packages/graph/audit/run_audit.sh --quick    # 2 seeds x 300 cases, no benchmarks
pionc test packages/graph/audit                 # 10 p1_/p2_ FAIL (= evidence), 11 ctl_ pass
```

## How the evidence was produced

| Piece | What it does |
|---|---|
| `rust_oracle/` | petgraph `=0.8.3` (`--release`, LTO). `fuzz`: same LCG, same draw order as the Pion runner; prints one canonical line per (case, section). Where petgraph itself is not trustworthy the line is an **exact reference** instead (i128 Floyd–Warshall, u128 Dinic, brute-force bridges / articulation points by deletion, brute-force dominance frontiers from the definition) and petgraph's own answer is printed as `<section>_pg`. `stress`: adversarial benchmark workloads with byte-identical checksum lines. `dump <seed> <case>`: print the generated graphs of any failing case. |
| `runner/` | Pion runner (`fuzz` / `stress` / `probe`), built native debug+release and wasm32 debug+release. In `fuzz` it also checks the intrusive out/in/adjacency lists of `DiGraph`/`UnGraph` after **every** mutation (bounded walks, `first/last` consistency, each edge linked exactly once). |
| `fuzz.py` | Diffs the two streams section by section, separates correctness from petgraph-layout compatibility, and counts petgraph's own disagreements with ground truth. |
| `redteam_test.pion` | Minimal deterministic reproductions (`p1_`/`p2_` fail on purpose) + controls (`ctl_`). |
| `bench_adversarial.sh`, `split_bench.py` | Head-to-head through `scripts/bench_compare.py` (SHA-256 of stdout enforced) + build-vs-algorithm cost split. |

Random graphs: 1–10 nodes (1/8 of cases 20–40), up to 3·V edges, 25 % forced parallel edges, self-loops,
weight families `{0..9}`, `{-3..9}` (negative edges & cycles), `{Int64::MAX/2 - k, 0..9}`, `{0,1}` (zero-weight
cycles), `{0..999}`. Each case also runs 40 random `add_node / add_edge / remove_edge / remove_node` operations on
a `DiGraph` and an `UnGraph` (swap-remove of the last node / last edge, self-loops and parallel edges on the
moved node included). Run: 10 seeds × 1000 cases.

## Findings (Pion worse than upstream / than the definition)

| ID | Sev | Area | Finding | Evidence |
|---|---|---|---|---|
| F1 | **P1** | `astar` | Closed nodes are never re-opened. With an admissible but inconsistent heuristic A* returns a **suboptimal cost**, and the cost it reports is **not the weight of the path it returns** (g-score/predecessor of a closed node are overwritten after it was expanded). petgraph re-opens and is optimal. | `p1_astar_admissible_inconsistent_heuristic_is_optimal`: petgraph `Some((12, [0,2,3,4]))`, Pion cost **15** with path `0,2,3,4` (weight 12). Fuzz: 8 / 5993 A* cases wrong (6 with cost ≠ path weight), petgraph 0 wrong. |
| F2 | **P1** | `Dominators::dominance_frontiers` | Every frontier entry whose target is the **entry node** is dropped (loop back-edge or self-loop to the root). The CHK "join point has ≥ 2 preds" shortcut assumes the root has no predecessors and the runner walk stops at `idom(root) = root`. For SSA construction this loses the φ at a loop header that is the function entry. | `p1_dominance_frontier_back_edge_to_entry` (`0→1→0`: want DF(0)=DF(1)={0}, got {}), `p1_dominance_frontier_entry_self_loop`. Fuzz: **4048 / 10000** cases, all of them exactly "entry missing from some DF set" (classified over 1211/3000 mismatches: 100 % root-only, no other error). Irreducible CFG, unreachable nodes, deep diamonds: 0 errors. petgraph has no DF API; ground truth = Cytron definition computed from petgraph's idoms. |
| F3 | **P1** | `floyd_warshall` | Aborts with `Err(WeightOverflow)` as soon as **any candidate** `d[i][k] + d[k][j]` overflows, although every true shortest distance fits in `Int64`. petgraph skips overflowing candidates and returns the right matrix. | `p1_floyd_warshall_overflowing_candidate_is_not_an_error` (`0→1 = MAX-10, 1→2 = 100, 0→2 = 5`: petgraph `d02=5, d01=MAX-10, d12=100`, Pion `Err(WeightOverflow)`). Fuzz: 153 / 10000 graphs with `Int64::MAX/2` weights wrongly rejected (exact i128 reference fits). |
| F4 | **P1** | `transitive_reduction` / `transitive_closure` | Reachability bitset is `V × ⌈V/64⌉` words **regardless of edge count**: 1.2 GiB for a 100 000-node out-star (petgraph: 22 MiB, 18× faster), and at V ≥ 370 728 `n * words` overflows the 32-bit `Int` → **panic (native) / trap (wasm32)** on a 370 800-node star that petgraph reduces in 20 ms / 77 MiB. | run_audit §6: `tred_star_370800` → `pion panic: index 5794 out of bounds (len 0)` (native and wasm32); `A10b_tred_star`: Pion 261 ms / 1217 MiB vs petgraph 14 ms / 22 MiB. (On a 20 000 chain, whose closure is Θ(V²), petgraph is the one that blows up: 958 ms / 912 MiB vs Pion 24 ms / 55 MiB — petgraph always builds the closure.) |
| F5 | **P1 perf** | `DiGraph` / `UnGraph` construction | Building the graph is **3–5× slower** than petgraph and uses ~1.5× the RSS; this, not the algorithms, is what the W1–W3 headline ratios measure. | `B0_build_dense` (1.33 M edges) 82.7 ms vs 22.3 ms (0.27×, 143 vs 95 MiB); `B0_build_rand` (400 k edges) 43.3 vs 13.9 ms (0.32×). Split table below: algorithm-only time is at parity or faster for Tarjan (2.4×), Kosaraju (3.7×), dominators (2.7×), Dinic (6.8×), Bellman-Ford (1.6×), Prim (1.0×), Toposort (1.1×). README's explanation of W1 ("pion_digraph pays pointer-chasing cost on intrusive edge lists") is not supported: petgraph uses the same intrusive lists and the Dijkstra kernel itself is 0.68–1× petgraph. |
| F6 | P2 | `toposort` | `Err(HasCycle(node))` names the lowest-index node with residual indegree > 0, which is often **not on any cycle** (merely downstream of one). README/`graph_error_to_string` say "a cycle involving node". petgraph's `Cycle(node)` is on a cycle. | `p2_toposort_cycle_node_is_on_a_cycle` (`1→0, 1⇄2` → `HasCycle(0)`). Fuzz: **1430 / 10000** cyclic graphs. |
| F7 | P2 | `bellman_ford`, `find_negative_cycle`, `floyd_warshall` | A reachable negative cycle with large weights is reported as `WeightOverflow` (overflow check fires while the cycle is being relaxed); `find_negative_cycle` returns an error instead of the cycle. | `p2_bellman_ford_large_negative_cycle_is_negative_cycle`, `p2_floyd_warshall_large_negative_cycle_is_negative_cycle` (`0⇄1`, both `-(MAX/2)`). |
| F8 | P2 | `dijkstra` / `dijkstra_i64` (and `astar`) | `Err(WeightOverflow)` when a **non-improving** relaxation overflows, although the exact answer exists. petgraph 0.8.3 release returns `d2 = 5` (debug panics), so this is a robustness gap rather than a regression vs debug. | `p2_dijkstra_non_improving_overflow_is_not_an_error`. |
| F9 | P2 | size guards (`CsrGraph::from_edges`, `floyd_warshall`) | `Int` is 32-bit. `CsrGraph::from_edges(Int::MAX, [])` → `node_count + 1` wraps → native panic "container length exceeds maximum", wasm32 **`RuntimeError: memory access out of bounds`** (trap, different failure per target). `floyd_warshall` on 46 341 nodes → `n*n` wraps → `index 0 out of bounds` panic. `from_edges(1e9, [])` allocates **24 GB RSS** with no limit. All should be `Err(InvalidArgument)`. | run_audit §6 probes `csr_from_edges_intmax`, `floyd_46341`, `csr_from_edges_1e9`. |
| F10 | P2 compat | `remove_node` EdgeIds | Incident edges are removed oldest-first (petgraph: newest-first), so after `remove_node` the surviving `EdgeId`s differ from petgraph's although README promises "petgraph::Graph-style swap-remove reindexing". | `p2_remove_node_edge_index_layout_matches_petgraph` (petgraph: `e0 = 0→0 (w2), e1 = 0→1 (w3)`); fuzz `ops_lay` 1179 / 10000, `uops_lay` 797 / 10000. The edge **multiset** and all neighbour sets are identical (`ops_ms` / `uops_ms` 0 / 10000). |
| F11 | P2 compat | neighbour order | Neighbours iterate in insertion order, petgraph newest-first (documented in README); BFS/DFS/SCC member orders therefore differ from petgraph. | `p2_neighbor_order_matches_petgraph`; fuzz `ops_ord` 9075 / 10000. |

No P0 (memory corruption, pointer corruption, infinite loop, stack overflow, mode divergence) was found in the
graph structures or algorithms at realistic sizes.

## What held up (0 mismatches in 10 000 random graphs unless noted)

| Section | Checked against | Result |
|---|---|---|
| `DiGraph` / `UnGraph` add/remove churn (400 000 ops each, integrity check after every op) | petgraph multiset + own list-integrity walk | **0** multiset mismatches, **0** integrity violations (no dangling / duplicate / cyclic links, `last_out`/`last_in` always correct, self-loop on the moved node, `(last, removed)` / `(removed, last)` and parallel edges all fine) |
| `tarjan_scc`, `kosaraju_scc` | petgraph SCC sets + reverse-topological invariant on Pion's raw order | 0 / 0 |
| `is_cyclic`, `toposort` validity | petgraph | 0 (only the F6 node choice differs) |
| `dominators` (idom of every node, incl. irreducible loops, unreachable nodes, entry with in-edges) | petgraph `simple_fast` | 0 |
| `dijkstra_i64`, `bellman_ford`, `find_negative_cycle` (cycle validated hop by hop, weight < 0) | petgraph | 0 / 0 / 0 |
| `floyd_warshall` | exact i128 reference | 153 (F3 only) |
| `kruskal_mst_i64`, `prim_mst` (forests, ties, negative weights) | exact reference (petgraph Kruskal total) | 0 / 0 |
| `dinic_max_flow` + full certificate (capacity, conservation, saturated cut = flow, no back flow into source side) | u128 Dinic reference | 0 |
| `bridges`, `articulation_points` (parallel edges, self-loops, forests) | brute force by deletion | 0 / 0 |
| `transitive_reduction`, `transitive_closure` | petgraph `dag_transitive_reduction_closure` | 0 / 0 |

### Upstream petgraph 0.8.3 defects found by the same harness (Pion is right)

| Section | petgraph disagrees with ground truth | Example (also a `ctl_` test) |
|---|---|---|
| `bridges` | 4715 / 10000 — skips the parent *node* instead of the parent *edge*, so every doubled edge is a "bridge" | `0=1` twice → petgraph `[0, 1]`, Pion `[]` |
| `floyd_warshall` | 1594 / 10000 — resets `d[i][i] = 0` after loading edges (misses negative self-loops) and `i64::MAX + negative` turns "unreachable" into `MAX-3` | `0→0 = -1` → petgraph `Ok(0)`, Pion `NegativeCycle` |
| `min_spanning_tree_prim` | 2403 / 10000 — spans only the component of the first node | 2 components → petgraph 1 edge, Pion 2 |
| `find_negative_cycle` | 4 / 7996 — returns `[0]` although there is no `0→0` edge | see `ctl_find_negative_cycle_is_a_real_cycle_beats_petgraph` |
| `dinics` (u64) | 1 — four `~2^62` parallel capacities: petgraph silently wraps to flow **7**, Pion `Err(WeightOverflow)` | `ctl_dinic_huge_capacity_reports_overflow_not_wrapped_value` |

## Native / Wasm32 × debug / release

* Fuzz stream (seed 1, 1000 cases, all sections): native debug, native release, wasm32 debug, wasm32 release —
  **byte-identical** (`adcb0bd0…`).
* 100 000-node chain / cycle / star / random(4·V edges) and 2000-node dense (1.33 M edges), every algorithm
  (`all` = Dijkstra, CSR Dijkstra, Bellman-Ford, A*, Tarjan, toposort, find_cycle, BFS/DFS pre/post/full,
  dominators, Dinic, Kruskal, Prim, bridges, articulation points, components, bipartite) plus Kosaraju,
  CSR Tarjan and dominance frontiers: **80 runs, 0 non-zero exits, 0 stack overflows, 0 traps, 0 mode-divergent
  outputs** (`modes/summary.txt`). Wasm32 runs at ~2× native wall time.
* `ctl_100k_cycle_no_stack_overflow`: one 100 000-node SCC (deepest Tarjan/Kosaraju/dominator stacks), Dinic on the
  ring, `find_cycle` of length 100 000.
* Divergence only on the F9 inputs: native panics, wasm32 traps with `memory access out of bounds`.

## Benchmarks

`bench_adversarial.sh` (warmup 1, 5 interleaved rounds, SHA-256 of stdout identical for both implementations).
Times include process start and building the same `DiGraph` + `UnGraph` from one edge list in both languages.

| Workload | Pion ms | petgraph ms | Pion speed | Peak RSS Pion / petgraph |
|---|---:|---:|---:|---|
| A1 Bellman-Ford, rand 20k / 80k | 21.9 | 15.4 | 0.70× | 13 / 10 MiB |
| A2 Dinic, 200 layers × 10 complete, caps ≤ 1e9 | 13.2 | 20.9 | **1.59×** | 6 / 5 MiB |
| A3 bridges, 100k chain | 23.7 | 12.2 | 0.51× | 26 / 18 MiB |
| A4 articulation points, 100k star | 18.5 | 11.6 | 0.63× | 23 / 17 MiB |
| A5 A* (h = 0), rand 50k / 200k | 32.0 | 18.5 | 0.58× | 27 / 22 MiB |
| A6 Dijkstra, dense 2000 / 1.33 M | 82.9 | 25.0 | 0.30× | 143 / 95 MiB |
| A7 CSR Dijkstra, dense 2000 / 1.33 M | 93.9 | 24.1 | 0.26× | 163 / 95 MiB |
| A8 remove half the nodes, rand 20k / 80k | 22.8 | 11.8 | 0.52× | 12 / 8 MiB |
| A9 Floyd-Warshall, dense 300 | 51.3 | 29.5 | 0.57× | 6 / 7 MiB |
| A10 transitive reduction, 20k chain | 23.6 | 958.5 | 40.6× (petgraph builds the Θ(V²) closure) | 55 / 912 MiB |
| A10b transitive reduction, 100k out-star | 260.8 | 14.4 | **0.06×** (F4) | **1217 / 22 MiB** |
| A11 dominators, rand 50k / 200k | 37.0 | 42.9 | **1.16×** | 27 / 29 MiB |
| A12 Kosaraju, rand 100k / 400k | 60.0 | 51.7 | 0.86× | 54 / 33 MiB |
| A13 Prim, rand 50k / 200k | 80.4 | 52.7 | 0.65× | 30 / 23 MiB |
| A14 toposort, 100k chain | 20.2 | 12.3 | 0.61× | 23 / 11 MiB |
| B0 build only, dense 2000 / 1.33 M | 82.7 | 22.3 | **0.27×** | 143 / 95 MiB |
| B0 build only, rand 100k / 400k | 43.3 | 13.9 | **0.32×** | 52 / 31 MiB |

Build-vs-algorithm split (`split_bench.py`, median of 7 runs, algorithm = total − build-only; sub-2 ms values are noise):

| Workload | build Pion | build petgraph | algo Pion | algo petgraph | algo petgraph/Pion |
|---|---:|---:|---:|---:|---:|
| rand 50k Dijkstra | 16.9 | 6.5 | 16.0 | 10.9 | 0.68× |
| rand 100k Tarjan | 38.4 | 8.1 | 8.5 | 20.5 | 2.40× |
| rand 100k Kosaraju | 39.8 | 8.1 | 7.4 | 27.5 | 3.74× |
| rand 50k Kruskal | 19.5 | 6.2 | 24.6 | 13.3 | **0.54×** |
| rand 50k Prim | 18.8 | 5.8 | 50.6 | 50.4 | 1.00× |
| rand 20k Bellman-Ford | 13.3 | 4.5 | 2.9 | 4.6 | 1.57× |
| rand 50k dominators | 19.0 | 5.6 | 11.8 | 31.3 | 2.66× |
| layers 2002 Dinic | 4.8 | 3.4 | 1.5 | 10.1 | 6.75× |
| dense 300 Floyd-Warshall | 5.4 | 2.9 | 41.3 | 20.1 | **0.49×** |
| rand 20k remove half the nodes | 8.6 | 4.1 | 8.5 | 2.3 | **0.27×** |

Answers to the W1–W4 questions:

* **W1 (Dijkstra, 0.65×)** and **W3 (Kruskal, 0.67×)**: most of the gap is graph construction (F5). The Dijkstra
  kernel itself is 0.68–1× petgraph; Kruskal's kernel is genuinely slower (0.54×).
* **W2 (SCC + toposort, 0.64–0.69×)**: Tarjan's kernel is 2.4× *faster* than petgraph; the gap is construction of
  two 100k/400k graphs. There is **no O(V+E) `toposort_any`**: `toposort` always pays the binary heap
  (`O((V+E) log V)`) for the lexicographically smallest order; on the chain the heap never holds more than one
  element so it is at parity, on wide DAGs it is the log factor.
* **W4 (dominators, 1.7–1.9×)**: confirmed (1.16× end-to-end, 2.7× kernel).
* Kernels that are genuinely slower: Floyd-Warshall (0.49×: separate `reachable` array plus a checked add per inner
  step), `remove_node` (0.27×: incident edges removed one by one through the general `remove_edge`, each re-walking
  the endpoint lists), Kruskal (0.54×).

## Suggested fixes (for the implementer; not applied here)

* F1: re-open a node when its g-score improves (drop the `closed` short-circuit or clear `closed[v]` on
  improvement), and take the reported cost from the same g-score that the path reconstruction uses.
* F2: treat the root as having a virtual entry predecessor: for `b == root` process every reachable predecessor
  and walk the runner up to *and including* the root.
* F3/F8: a positive overflow in a relaxation candidate can never be a shortest distance — skip it (petgraph does);
  report `WeightOverflow` only if a true distance is unrepresentable.
* F4: compute the reduction per node with a sparse/epoch-stamped visited set (`O(V·E)` worst case, `O(V+E)` memory),
  or at least guard `n * words` and return `Err(InvalidArgument)`.
* F6: return a node of a non-trivial SCC (or `find_cycle` on the residual graph).
* F7: negative-side overflow while relaxing is a negative cycle — saturate and finish the detection pass.
* F9: guard `node_count + 1`, `n * n`, `n * words` against `Int` overflow and return `Err(InvalidArgument)`.
* F10: unlink incident edges newest-first (or document that EdgeIds after `remove_node` differ from petgraph).

## Files

```
audit/pion.toml, redteam_test.pion     unit evidence (pionc test packages/graph/audit)
audit/runner/                          Pion fuzz / stress / probe runner
audit/rust_oracle/                     petgraph =0.8.3 oracle (Cargo.lock pinned)
audit/fuzz.py                          differential comparator
audit/bench_adversarial.sh             head-to-head benchmarks via scripts/bench_compare.py
audit/split_bench.py                   build-vs-algorithm split
audit/run_audit.sh                     everything above, outputs to /private/tmp/graph-redteam
```
