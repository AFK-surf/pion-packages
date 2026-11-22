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

## Benchmarks (`Darwin arm64`, `--warmup 1 --rounds 5`, SHA-256 verified)

1. **Parse + Canonical Topology JSON** (6 diagrams incl. 320-node flowchart, 44,397 B stdout, `sha256:01503cfb8beab764...`):
   - `node-mermaid` (official `mermaid` + `linkedom`): **405.351 ms** median, **92.23 MiB** RSS
   - `pion-mermaid` (Pion Native `--release`): **8.995 ms** median, **2.66 MiB** RSS (**45.07x faster**)
2. **Layered Graph Layout** (50 / 200 / 500 nodes, 1,088 edges incl. cycles & long edges, `sha256:c84da338384d484d...`):
   - `node-dagre` (official `@dagrejs/dagre`): **566.553 ms** median, **233.17 MiB** RSS
   - `pion-sugiyama` (Pion Native `--release`): **10.383 ms** median, **2.88 MiB** RSS (**54.57x faster**)
