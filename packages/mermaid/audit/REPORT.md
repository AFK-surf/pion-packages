# Red-team audit: `packages/mermaid` vs official `mermaid` + `@dagrejs/dagre`

Target `AFK-surf/pion-packages@7a40e8f`, branch `audit/redteam-mermaid`. References are
**mermaid 12.3.0** (parsed through `mermaid.mermaidAPI.getDiagramFromText` under `linkedom`, the
same entry point as `bench/bench_node_parse.mjs`) and **@dagrejs/dagre 3.1.3**. Toolchain:
`pionc 0.1.0`, Node 24, Apple M5 Max (Darwin arm64).

Everything below is reproduced by one command, and no file outside `packages/mermaid/audit/` is
touched:

```sh
export PATH="$HOME/.pion/bin:$PATH"
sh packages/mermaid/audit/run_audit.sh          # all 6 steps, ~5-8 min, artefacts in $TMPDIR/mermaid-redteam
pionc test packages/mermaid/audit                # step 1 alone (red-team suite)
STEPS="2 3" sh packages/mermaid/audit/run_audit.sh   # parse differential + geometry only
```

## Bottom line

| Attack surface | Verdict | Evidence |
|---|---|---|
| 1. Parsing correctness / coverage | **Pion loses.** 110-case differential: 49 identical, **19 silently different graphs**, **27 valid diagrams rejected** (17 of the 5 "supported" kinds + 10 other common kinds), **5 invalid inputs accepted** | `run_audit.sh` step 2, 43 failing tests |
| 2. Layout geometry | **Pion loses badly.** On 17 realistic graphs Pion has geometric defects in **14**; dagre, given the *identical* node and label boxes, has **0** defects on all 17 | step 3, 10 failing tests, SVG exhibits from step 3 |
| 3. Performance | **Attack failed on speed, succeeded on robustness.** No input found where Pion is slower than mermaid + dagre (adversarial head-to-head: 86x to 237x faster over two runs, SHA-256 verified). But the published 290x parse figure is 78-84% mermaid's config deep-merge, Pion's numbers are bought partly by skipped work, and Pion **segfaults** or goes super-linear on inputs mermaid rejects up front | steps 4 and 6 |
| 4. Security / robustness | XSS escaping **holds** (control test passes). But Pion **crashes the host process (SIGSEGV)** on a 300 KB sequence diagram and on a 4 MB flowchart, has **no input limits**, and emits ill-formed XML / invalid JSON / invalid UTF-8 | steps 4 and 5, 2 failing tests |

`pionc test packages/mermaid/audit`: **60 FAIL / 63** (P0 11, P1 31, P2 18, all 3 `control:`
tests pass). The 137 upstream-ported tests of `packages/mermaid` still pass, which is itself a
finding: the ported suite does not cover any of the defects below.

## P0: silent wrong output, crashes, broken layout

| # | Finding | Repro (input → Pion vs official) | Test |
|---|---|---|---|
| P0-1 | **SIGSEGV on deep sequence nesting.** `seq_layout_stmts` (`src/layout_seq.pion:92`) recurses per nested block; 20 000 nested `loop` (309 KB) kills the process. Not a `Result`, not catchable, takes down any host embedding the library | `probe gen seqnest 20000 > f; probe time f` → exit 139 (10 000 nested is fine). mermaid also cannot lay this out, but fails with a catchable `RangeError` (and its default `maxTextSize` rejects the input first) | step 4 |
| P0-2 | **SIGSEGV on a long chain.** `dfs_break_cycles` (`src/sugiyama.pion:109`) is recursive; a 200 000-edge chain (4.2 MB) segfaults. mermaid with its default config refuses it with a catchable `Edge limit exceeded … limit is 500` | `probe gen chain 200000` → exit 139 | step 4 |
| P0-3 | **Clusters are not laid out as clusters.** Subgraph/namespace/composite boxes are bounding boxes computed *after* placement (`src/sugiyama.pion` step 8); ordering and x-assignment ignore membership, so boxes swallow foreign nodes and overlap each other | `g_subgraphs_cross_linked`: `left` box contains `r1`,`r2`; `right` contains `l2`; boxes overlap. dagre (same boxes): disjoint, 0 intrusions. Same on class namespaces (`Infra` box contains `Order`,`Customer`) and state composites | 3 tests |
| P0-4 | **Edge labels get no space.** Labels are dropped at the polyline midpoint; no label rank / label dummy node as dagre does | `A -->|request| B; A -->|retry| B; B -->|response| A`: all three labels stacked on one spot, overlapping both nodes. dagre: 0 collisions | `P0 layout: labels of parallel edges` |
| P0-5 | **Transitions out of a composite start at its `[*]`.** `layout_state` (`src/scene.pion`) rewrites any edge touching a composite to its *first child*, which is usually the `[*]` start pseudo-state | `Running --> Paused : pause` is drawn `__start_0 → __start_1` | `P0 layout: transition OUT of a composite` |
| P0-6 | **`A--text-->B` invents a node.** Inline label without spaces becomes node `text` and two unlabelled edges | mermaid: 1 edge `A→B` label `text`. Pion: nodes `A,B,text` | `P0 flow: A--text-->B` |
| P0-7 | **Sequence `box … end` rejected.** `box` is skipped, its `end` is a stray end | Pion: `unexpected 'end' without open block` | `P0 seq: box` |
| P0-8 | **`A<<->>B` invents participant `A<<`** (bidirectional arrows, mermaid ≥ 11) | participants `A<<,B` | `P0 seq: bidirectional` |
| P0-9 | **State `A:::cls --> B` invents state `A:::cls`** | states `A:::bad,B` | `P0 state: A:::cls` |
| P0-10 | **Class `Animal <|--|> Zebra` targets class `\|> Zebra`** | relation `to = '\|> Zebra'` | `P0 class: two-way relation` |
| P0-11 | **Class `classDef` / `:::` invent classes** | `class Animal:::someclass` + `classDef someclass fill:#f96` → classes `Animal:::someclass`, `classDef someclass fill` | `P0 class: classDef` |

## P1: rejects valid mermaid, wrong structure, ill-formed output, DoS

| # | Finding | Evidence |
|---|---|---|
| P1-1 | YAML frontmatter (`---\ntitle: …\n---`) rejected: `unsupported or unknown diagram type: ---` | test |
| P1-2 | Unicode ids rejected (`开始 --> 结束`, ER `客户 ||--o{ 订单`): `invalid node identifier` | 2 tests |
| P1-3 | v11 syntax rejected: `A@{ shape: cyl }`, `e1@{ animate: true }`; seq `participant D@{ "type": "database" }` becomes participant id `D@{ "type" : "database" }` | 3 tests |
| P1-4 | Seq `autonumber 10 5`, `autonumber off`, `accTitle:` / `accDescr:` rejected | 3 tests |
| P1-5 | Seq `A->>()B` invents participant `()B`; `A->>B: hi; B->>A: yo` is one message instead of two | 2 tests |
| P1-6 | Edge to a subgraph id (`one --> two`) creates phantom nodes `one`, `two` instead of linking the clusters | test |
| P1-7 | State: every `[*]` makes a new start/end node (2 starts + 2 ends where mermaid has `root_start`, `root_end`); `--` concurrency regions are discarded; `A -->` is accepted and invents a state named `""`; transition into an empty composite is dropped from the layout | 4 tests |
| P1-8 | Class `class Animal["Animal with a label"]` creates a second class whose id is the whole literal | test |
| P1-9 | ER word cardinality (`CAR one or more to zero or more DRIVER : drives`) rejected | test |
| P1-10 | 10 common diagram kinds rejected outright: pie, gantt, mindmap, gitGraph, timeline, quadrantChart, journey, xychart, block, sankey | 7 tests + differential |
| P1-11 | Parallel edges `A-->B` twice get byte-identical polylines (indistinguishable); fan-out labels overlap; self-loop label sits on the node; long edge `n0->n5` cuts through `m0` | 4 tests |
| P1-12 | A U+0001 in any label makes `render_svg` ill-formed XML and `canonical_graph_json` invalid JSON (`xml_escape` / `json_escape` pass C0 controls through) | 2 tests, step 5 |
| P1-13 | `<br/>` in a label renders as the literal text `<br/>` (multi-line labels unsupported) | test, step 5 |
| P1-14 | **Super-linear blowups with no input limit** (mermaid's shipped `maxEdges: 500` / `maxTextSize: 50000` reject all of these before any work). See the DoS table below | step 4 |

## P2: rendering completeness and leniency

* SVG ignores `classDef`/`style`/`linkStyle` colours; hexagon, cylinder, parallelogram, trapezoid
  are all emitted as `<rect>`; class members and ER attributes never reach the SVG; arrowheads other
  than `arrow` are not drawn (6 tests).
* Entity codes `#quot; #amp; #9829;` are not decoded (mermaid shows `" & ♥`); markdown strings
  keep their backticks; `subgraph "My Title"` makes `My Title` the id; `classDef foo,bar` defines a
  single class named `foo,bar` (4 tests).
* Accepts what mermaid rejects: `A[foo (bar)]`, `A->>B` without `: text`, `web-xray->>db` (all
  syntax errors in mermaid) (2 tests + differential).
* Rejects: seq `link`/`links`, state `hide empty description`, floating `note "x" as N1`, class
  `callback`, ER `style`/`classDef`/`class`, flowchart multi-line `accDescr { … }` (6 tests).
* Invalid UTF-8 in the input is copied byte-for-byte into the SVG (output is not valid UTF-8).

## Step 3 detail: geometry, same boxes, two engines

`probe scene` dumps Pion's scene; `geom/dagre_ref.mjs` re-lays out **the same nodes, sizes,
clusters, edges and label boxes with the same nodesep/ranksep/edgesep/margins** in dagre; both go
through the same checker (`geom/geom_check.py`: node overlap, cluster intrusion, sibling cluster
overlap, edge through node, label/node and label/label overlap, out of canvas, dangling edges,
coincident parallel edges, detached endpoints).

| case | Pion defects | dagre defects | Pion defect kinds | crossings P/D | edge length P/D | area P/D |
|---|---:|---:|---|---|---|---|
| `g_subgraphs_cross_linked` | 4 | 0 | group_contains_foreign_node,sibling_group_overlap | 1/2 | 928/1043 | 141120/175474 |
| `g_subgraph_with_outside_middle_node` | 1 | 0 | group_contains_foreign_node | 0/0 | 398/365 | 87616/86336 |
| `g_three_clusters_interleaved` | 7 | 0 | edge_through_node,group_contains_foreign_node,sibling_group_overlap | 0/2 | 840/1352 | 119599/197904 |
| `g_nested_clusters_with_cross_edges` | 1 | 0 | group_contains_foreign_node | 0/0 | 634/854 | 100492/190380 |
| `g_fanout_long_labels` | 3 | 0 | label_overlaps_label | 0/0 | 295/467 | 55776/110856 |
| `g_parallel_labelled_edges` | 9 | 0 | coincident_parallel_edges,label_overlaps_label,label_overlaps_node | 0/0 | 150/386 | 18252/42840 |
| `g_parallel_unlabelled_edges` | 2 | 0 | coincident_parallel_edges | 0/0 | 150/160 | 18592/18592 |
| `g_self_loop_labelled` | 3 | 0 | label_overlaps_node,out_of_canvas | 0/0 | 265/344 | 35560/56261 |
| `g_cycle_back_edges` | 0 | 0 | - | 0/2 | 1228/1160 | 113950/113520 |
| `g_long_edges_skip_ranks` | 1 | 0 | edge_through_node | 0/0 | 1603/1348 | 159544/165760 |
| `g_wide_bipartite_reversed` | 0 | 0 | - | 0/1 | 2964/2810 | 223497/206756 |
| `g_disconnected_components` | 0 | 0 | - | 0/0 | 256/272 | 121040/123532 |
| `g_mixed_shapes_labels` | 1 | 0 | coincident_parallel_edges | 0/0 | 324/353 | 96624/101504 |
| `g_state_composites` | 7 | 0 | coincident_parallel_edges,group_contains_foreign_node,label_overlaps_label,sibling_group_overlap | 0/0 | 593/1483 | 119720/284999 |
| `g_class_namespaces` | 3 | 0 | group_contains_foreign_node,sibling_group_overlap | 0/0 | 466/578 | 98272/131600 |
| `g_er_many` | 1 | 0 | label_overlaps_label | 0/0 | 526/576 | 100440/120888 |
| `g_lr_subgraph_cross` | 3 | 0 | group_contains_foreign_node,sibling_group_overlap | 0/0 | 486/701 | 75140/147968 |

Read the last three columns together with the defect columns: Pion's smaller area and shorter
edges on these graphs are exactly the space dagre spends keeping clusters disjoint and labels
readable. They are not a quality win.

## Step 4 detail: crash / DoS (Pion = parse + layout + SVG in one process)

| input (generator in `probe gen`) | size | Pion | official |
|---|---:|---|---|
| `chain 100000` | 1.98 MB | ok 0.24 s, 232 MB | — |
| `chain 200000` | 4.18 MB | **SIGSEGV** | default config: catchable `Edge limit exceeded` |
| `chain 3000` | 52 KB | ok | dagre: catchable `RangeError: Maximum call stack size exceeded` (Pion wins: fine up to 100 000) |
| `seqnest 10000` | 149 KB | ok 0.01 s | mermaid parse: catchable `RangeError: Maximum call stack size exceeded` (Pion wins here) |
| `seqnest 20000` | 309 KB | **SIGSEGV** in 0.02 s | catchable `RangeError` (or the 50 000-char `maxTextSize` guard with the default config) |
| `scc 500 / 1000 / 2000` | 23 / 47 / 101 KB | 0.46 s / 1.5 s / **22–67 s, 1.0 GB RSS, 39 MB SVG** | default config rejects (> 500 edges); with limits lifted dagre needs 35–92 s, 3.5 GB at n=500 |
| `nest 20000 / 50000` (nested empty subgraphs, 2 nodes) | 0.39 / 0.99 MB | 2.4–4.4 s / **14–31 s** (quadratic group bounding-box loop; a 5.6x time jump for 2.5x input) | default config rejects (> 50 000 chars) |
| `subgraphs 20000` | 2.6 MB | **12–31 s** | default config rejects |
| `dense 120` (complete DAG, 7140 edges) | 0.1 MB | 2.5–3.9 s, 132 MB | with limits lifted: dagre > 100 s, 4.2 GB |

Pion has no `maxEdges`/`maxTextSize`/depth guard at all, and two of its failure modes are
uncatchable process kills. (Timings are ranges over runs on a shared machine; ratios within one run are
stable.)

## Step 6 detail: is the 290x real?

* **Parse (290.82x).** `node --cpu-prof` on the repository's own `bench_node_parse.mjs`:
  **78-84%** (two runs) of mermaid's time is `assignWithDepth`, the deep merge that `getConfig()` performs every
  time `addVertex`/`addClass`/`addState` runs; the jison parser itself is ~2-3%. So the benchmark
  mostly measures mermaid's config cloning, and Pion skips that work plus frontmatter/directive
  processing, entity encoding and sanitising entirely, while rejecting 27/110 valid inputs. As a
  "parser vs parser" claim the figure is inflated; as "Pion vs mermaid as shipped" it is real.
* **Layout (288.84x).** dagre's network-simplex ranker is ~55% of its time (same 5-iteration run:
  2.68 s network-simplex vs 1.17 s `ranker: "longest-path"`, which is what Pion does). Even
  against longest-path dagre, Pion stays two orders of magnitude faster. On the benchmark's own
  corpus (no clusters, no labels) Pion's layout metrics are genuinely better (g500 crossings
  248 vs 414); that corpus avoids precisely the two features Pion does not implement (step 3).
* **Adversarial head-to-head** through `scripts/bench_compare.py` (`--warmup 1 --rounds 5`,
  identical stdout SHA-256), mermaid parse + dagre vs Pion parse + layout + SVG:

  | input | mermaid + dagre median | Pion median | Pion speed-up |
  |---|---:|---:|---:|
  | `subgraphs 300` | 3301 ms, 518 MiB | 14.0 ms, 6.0 MiB | 236.6x |
  | `wide 2000` | 1831 ms, 323 MiB | 15.6 ms, 10.8 MiB | 117.5x |
  | `dense 40` | 2693 ms, 510 MiB | 30.3 ms, 7.5 MiB | 88.9x |
  | `scc 200` | 3855 ms, 880 MiB | 32.4 ms, 13.6 MiB | 119.1x |

  No input was found where Pion is slower. That attack is recorded as failed.

## Not defects (checked, held up)

* XSS: `<script>`, attribute break-out through edge labels and `'`/`&` are escaped
  (`control: XSS payloads…` passes; step 5 shows no raw `<script` and no `" onload=`).
* Node overlap: zero node/node overlaps in every Pion scene; reversed cycles, wide bipartite and
  disconnected components are clean.
* Long arrows (`A ---…---> B`, 100 000 dashes) scale linearly.

## Files

| path | what |
|---|---|
| `pion.toml`, `tests/redteam_test.pion` (`src` → `tests` symlink) | red-team suite: `pionc test packages/mermaid/audit`. `pionc` only discovers `*_test.pion` in the package root or `src/`, hence the symlink |
| `probe/` | Pion CLI: `parse` (normalised topology), `scene` (geometry JSON), `svg`, `time`, `count`, `gen` (adversarial generators) |
| `diff/corpus.mmd`, `diff/mermaid_ref.mjs`, `diff/compare.py` | 110-case parse differential against official mermaid |
| `geom/layout.mmd`, `geom/dagre_ref.mjs`, `geom/geom_check.py`, `geom/compare_geom.py`, `geom/scene_svg.py` | geometry audit and side-by-side exhibits |
| `bench/mermaid_dagre_full.mjs` | official parse + dagre pipeline for DoS probes and `bench_compare.py` |
| `run_audit.sh` | one-shot runner, writes only to `$AUDIT_OUT` |
