# `mermaid` (Pure Pion Mermaid Parser + Sugiyama/Dagre Layout Engine)

Pure Pion, zero-JS, zero-DOM (`linkedom`-free), zero-`World` Mermaid diagram parser, Sugiyama/Dagre layered graph layout engine, Sequence 2D layout engine, unified `Scene` IR, SVG renderer, and canonical topology JSON serializer.

## Supported Diagrams

Currently implemented (5 core diagram families):

- **Flowchart (`flowchart` / `graph` `TD|TB|BT|LR|RL`)**: YAML frontmatter (`---...---`), Unicode IDs, all 14 node shapes (`[]`, `()`, `([])`, `[[]]`, `[()]`, `(())`, `((()))`, `{}`, `{{}}`, `>]`, `[/ /]`, `[\ \]`, `[/ \]`, `[\ /]`) plus v11 `@{ shape, label }` syntax, all edge styles & arrows (`-->`, `---`, `-.->`, `==>`, `~~~`, `<-->`, `o--o`, `x--x`, `--x`, `--o`), pipe & inline labels (with or without spaces, e.g. `A--text-->B`), edge IDs (`e1@-->`) and edge attributes (`e1@{...}`), chaining, `&` multi-source/multi-target, nested `subgraph ... end` with per-subgraph `direction` and cluster-to-cluster edges, `classDef`/`class`/`:::`/`style`, `accTitle`/`accDescr` (single & multi-line), `%%` comments, entity decoding (`#quot;`, `#amp;`, `#9829;`), markdown strings, and `<br/>` multi-line labels.
- **Sequence Diagram (`sequenceDiagram`)**: `participant`/`actor` aliases (incl. `create participant`, `@{ type }`, `box ... end`), all arrow kinds (incl. bidirectional `<<->>` / `<<-->>` and central connections `()`), activations (`+`/`-`, `activate`/`deactivate`), `Note left of / right of / over`, nested `loop`/`alt`/`else`/`opt`/`par`/`and`/`critical`/`option`/`break`/`rect` blocks (iterative layout, stack-safe on deep nesting), `autonumber` (`start step` / `off`), `link`/`links`, `accTitle`/`accDescr`, semicolon-separated statements, and full 2D coordinate layout.
- **State Diagram (`stateDiagram` / `stateDiagram-v2`)**: scoped `[*]` start/end nodes, transitions with labels, `state "Desc" as id`, `id : desc`, `:::class`, nested composite states `state Foo { ... }`, `--` concurrency regions, `<<choice>>`/`<<fork>>`/`<<join>>`, inline, multiline, and floating `note`, `hide empty description`, `direction`.
- **Class Diagram (`classDiagram`)**: class blocks, bracket labels `class A["Label"]`, fields/methods/visibility (`+`/`-`/`#`/`~`), generics `~T~`, annotations `<<interface>>`/`<<abstract>>`, namespaces (including backtick-quoted names), all single-way and two-way UML relation kinds and cardinalities, `classDef`/`:::`/`callback`.
- **ER Diagram (`erDiagram`)**: Unicode & quoted entities, aliases, attributes (`type name PK/FK/UK "comment"`), symbolic (`||`, `|o`, `o|`, `}|`, `|{`, `}o`, `o{`) and word cardinalities (`one or more to zero or more`, etc.), identifying (`--`) and non-identifying (`..`) relationships, `style`/`classDef`/`class`.

*Not yet implemented*: `pie`, `gantt`, `mindmap`, `gitGraph`, `timeline`, `quadrantChart`, `journey`, `xychart-beta`, `block-beta`, `sankey-beta`.

## Public API

- `parse(src : String) -> Result[Diagram, ParseError]`
- `layout(diagram : Diagram) -> Scene`
- `layout_sugiyama(input : GraphInput) -> Scene`
- `measure_layout(scene : Scene) -> LayoutMetrics`
- `render_svg(scene : Scene) -> String`
- `render(src : String) -> Result[String, ParseError]`
- `canonical_graph_json(d : Diagram) -> String`

## Architecture

- `src/ast.pion` — Immutable AST & `ParseError` definitions
- `src/lex.pion` — Byte-level scanning, quote unescaping, JSON/XML escaping
- `src/parser.pion` + `src/parser_{flow,seq,state,class,er}.pion` — Five diagram parsers
- `src/sugiyama.pion` — Pure Pion cluster-aware Sugiyama/Dagre layered graph layout (iterative stack-safe DFS cycle breaking, longest-path + source tightening + rank-doubling for edge labels & parallel edges, O(N+G) post-order group hierarchy, cluster-preserving barycenter multi-sweep crossing minimization with Fenwick-tree crossing counter, O(V+E) constraint-DAG X compaction & vertical cluster-padded Y spacing, band-safe polyline routing, `TB`/`BT`/`LR`/`RL` transforms)
- `src/layout_seq.pion` — Iterative, stack-safe Sequence Diagram 2D layout engine
- `src/scene.pion` — Unified `Scene` IR + `measure_layout` quality metrics
- `src/svg.pion` — Deterministic, XML/UTF-8-safe SVG emitter with multi-shape geometry, inline styles, multi-line `<tspan>` labels, and class/ER member rendering
- `src/canon.pion` — Deterministic canonical topology JSON serializer
- `wasm_smoke/` — Wasm32 compilation verification target
- `bench/` — Head-to-head benchmarks vs official Node.js `mermaid` + `@dagrejs/dagre`

## Benchmarks (`Darwin arm64`, `scripts/bench_compare.py --warmup 1 --rounds 5`, SHA-256 verified)

### Steady-State Pure Compute (amortizes process startup)

1. **Parse + Canonical Topology JSON (`--iters 50`, 6 diagrams incl. 320-node flowchart, 1,120,750 B total input, `sha256:2f819d7bc0dd394d...`)**:
   - `node-mermaid` (official `mermaid` + `linkedom`): **13,376.880 ms** median (~267.5 ms/pass), **252.36 MiB** Peak RSS
   - `pion-mermaid` (Pion Native `--release`): **45.997 ms** median (~0.92 ms/pass), **2.72 MiB** Peak RSS (**290.82x faster**)
   - *Methodology note*: CPU profiling (`node --cpu-prof`) shows ~78–84% of `node-mermaid`'s time in this benchmark is spent in `assignWithDepth` (mermaid's config deep-merge invoked per vertex/class/state), while the jison parser itself is ~2–3%. The 290x figure therefore reflects end-to-end "Pion vs official `mermaid` as shipped", not raw parser-vs-parser throughput alone.
2. **Layered Graph Layout (`--iters 20`, 50 / 200 / 500 nodes, 1,088 edges incl. cycles & long edges, 442,380 B total input, `sha256:477f544c81534122...`)**:
   - `node-dagre` (official `@dagrejs/dagre`): **8,041.165 ms** median (~402.1 ms/pass), **318.91 MiB** Peak RSS
   - `pion-sugiyama` (Pion Native `--release`): **27.840 ms** median (~1.39 ms/pass), **2.88 MiB** Peak RSS (**288.84x faster**)
   - *Methodology note*: `@dagrejs/dagre` defaults to `ranker: "network-simplex"` (~55% of its runtime), whereas `pion-sugiyama` uses longest-path + source tightening. Even against `ranker: "longest-path"`, Pion remains ~100x+ faster.

### Cold-Start CLI (1x process startup + execution, for reference)

1. **Parse + Canonical Topology JSON (`--iters 1`, `sha256:12ff4e02e48548c4...`)**:
   - `node-mermaid`: **381.285 ms** median, **108.47 MiB** Peak RSS
   - `pion-mermaid`: **8.518 ms** median, **2.64 MiB** Peak RSS (**44.76x faster**)
2. **Layered Graph Layout (`--iters 1`, `sha256:a61c633038f51153...`)**:
   - `node-dagre`: **572.356 ms** median, **234.11 MiB** Peak RSS
   - `pion-sugiyama`: **9.809 ms** median, **2.88 MiB** Peak RSS (**58.35x faster**)
