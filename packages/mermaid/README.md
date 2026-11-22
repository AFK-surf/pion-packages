# `mermaid` (Pure Pion Mermaid Parser + Sugiyama/Dagre Layout Engine)

Pure Pion, zero-JS, zero-DOM (`linkedom`-free), zero-`World` Mermaid diagram parser, Sugiyama/Dagre layered graph layout engine, Sequence 2D layout engine, unified `Scene` IR, SVG renderer, and canonical topology JSON serializer.

## Supported Diagrams

- **Flowchart (`flowchart` / `graph` `TD|TB|BT|LR|RL`)**: all 14 node shapes (`[]`, `()`, `([])`, `[[]]`, `[()]`, `(())`, `((()))`, `{}`, `{{}}`, `>]`, `[/ /]`, `[\ \]`, `[/ \]`, `[\ /]`), all edge styles & arrows (`-->`, `---`, `-.->`, `==>`, `~~~`, `<-->`, `o--o`, `x--x`, `--x`, `--o`), pipe & inline labels, edge IDs (`e1@-->`), chaining, `&` multi-source/multi-target, nested `subgraph ... end` with per-subgraph `direction`, `classDef`/`class`/`:::`/`style`, `%%` comments, quoted/escaped labels.
- **Sequence Diagram (`sequenceDiagram`)**: `participant`/`actor` aliases, all 8 arrow kinds (`->`, `-->`, `->>`, `-->>`, `-x`, `--x`, `-)`, `--)`), activations (`+`/`-`, `activate`/`deactivate`), `Note left of / right of / over`, nested `loop`/`alt`/`else`/`opt`/`par`/`and`/`critical`/`option`/`break`/`rect` blocks, `autonumber`, and full 2D coordinate layout.
- **State Diagram (`stateDiagram` / `stateDiagram-v2`)**: `[*]` start/end nodes, transitions with labels, `state "Desc" as id`, `id : desc`, nested composite states `state Foo { ... }`, `<<choice>>`/`<<fork>>`/`<<join>>`, inline and multiline `note`, `direction`.
- **Class Diagram (`classDiagram`)**: class blocks, fields/methods/visibility (`+`/`-`/`#`/`~`), generics `~T~`, annotations `<<interface>>`/`<<abstract>>`, namespaces (including backtick-quoted names), all UML relation kinds and cardinalities.
- **ER Diagram (`erDiagram`)**: entities, aliases, attributes (`type name PK/FK/UK "comment"`), all cardinality markers (`||`, `|o`, `o|`, `}|`, `|{`, `}o`, `o{`), identifying (`--`) and non-identifying (`..`) relationships.

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
- `src/sugiyama.pion` — Pure Pion Sugiyama/Dagre layered graph layout (DFS cycle breaking, longest-path + source tightening ranking, dummy node normalization, multi-sweep barycenter crossing minimization with Fenwick-tree crossing counter, neighbor-aligned order-preserving X compaction, bottom-up nested subgraph bounding boxes, polyline routing, `TB`/`BT`/`LR`/`RL` transforms)
- `src/layout_seq.pion` — Sequence Diagram 2D layout engine
- `src/scene.pion` — Unified `Scene` IR + `measure_layout` quality metrics
- `src/svg.pion` — Deterministic SVG emitter
- `src/canon.pion` — Deterministic canonical topology JSON serializer
- `wasm_smoke/` — Wasm32 compilation verification target
- `bench/` — Head-to-head benchmarks vs official Node.js `mermaid` + `@dagrejs/dagre`

## Benchmarks (`Darwin arm64`, `scripts/bench_compare.py --warmup 1 --rounds 5`, SHA-256 verified)

### Steady-State Pure Compute (amortizes process startup)

1. **Parse + Canonical Topology JSON (`--iters 50`, 6 diagrams incl. 320-node flowchart, 1,120,750 B total input, `sha256:2f819d7bc0dd394d...`)**:
   - `node-mermaid` (official `mermaid` + `linkedom`): **13,376.880 ms** median (~267.5 ms/pass), **252.36 MiB** Peak RSS
   - `pion-mermaid` (Pion Native `--release`): **45.997 ms** median (~0.92 ms/pass), **2.72 MiB** Peak RSS (**290.82x faster**)
2. **Layered Graph Layout (`--iters 20`, 50 / 200 / 500 nodes, 1,088 edges incl. cycles & long edges, 442,380 B total input, `sha256:477f544c81534122...`)**:
   - `node-dagre` (official `@dagrejs/dagre`): **8,041.165 ms** median (~402.1 ms/pass), **318.91 MiB** Peak RSS
   - `pion-sugiyama` (Pion Native `--release`): **27.840 ms** median (~1.39 ms/pass), **2.88 MiB** Peak RSS (**288.84x faster**)

### Cold-Start CLI (1x process startup + execution, for reference)

1. **Parse + Canonical Topology JSON (`--iters 1`, `sha256:12ff4e02e48548c4...`)**:
   - `node-mermaid`: **381.285 ms** median, **108.47 MiB** Peak RSS
   - `pion-mermaid`: **8.518 ms** median, **2.64 MiB** Peak RSS (**44.76x faster**)
2. **Layered Graph Layout (`--iters 1`, `sha256:a61c633038f51153...`)**:
   - `node-dagre`: **572.356 ms** median, **234.11 MiB** Peak RSS
   - `pion-sugiyama`: **9.809 ms** median, **2.88 MiB** Peak RSS (**58.35x faster**)
