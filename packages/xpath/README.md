# `xpath` — Pure-Pion W3C XPath 1.0 Query Engine

Pure-Pion, zero-C-dependency (no `libxml2`), no-`World` **W3C XPath 1.0** query engine built on top of `packages/xml` (`xml::Document`), supporting all **13 axes**, all **27 core library functions**, compile-once `XPathExpr::parse` + reusable evaluation, external variables (`$var`) and namespace prefix bindings (`XPathContext`), and bounded resource limits (`XPathLimits`).

- **Zero C dependencies / No `World`**: Pure Pion, runs identically on Native and `wasm32` (4-mode byte-identical across `native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel`).
- **Read-Only `XPathDoc` View (`src/doc.pion`)**:
  - Reuses `xml::Document`'s flat pre-order DFS node/attribute arrays directly with zero DOM duplication.
  - Precomputes `subtree_end` in a single O(N) reverse pass for contiguous O(1)-per-node `descendant`, `descendant-or-self`, `following`, and `preceding` axis scans (`j < id` is an ancestor iff `subtree_end[j] >= id`).
  - Zero-copy namespace slice inheritance (`elem_ns_start`/`elem_ns_end`) with built-in `xml` namespace and `xmlns=""` undeclaration support, plus `id_map` indexing `xml:id` and `id` attributes for O(1) `id()`.
- **Full W3C XPath 1.0 Grammar & §3.7 Disambiguation (`src/lexer.pion`, `src/parser.pion`, `src/ast.pion`)**:
  - Exact §3.7 preceding-token lexical disambiguation for `*`, `and`, `or`, `mod`, `div` vs NCName/QName/NameTest (`* * *`, `div div mod`, `and and or`, `/root/node`, `child::child`).
  - All abbreviated syntax (`.`, `..`, `@attr`, `//`) with exact `//item[1]` vs `(//item)[1]` semantics.
  - All NodeTests (`*`, `prefix:*`, `NCName`, `prefix:local`, `node()`, `text()`, `comment()`, `processing-instruction()`, `processing-instruction('target')`).
  - Depth-bounded recursive-descent parser compiling into a flat AST arena (`XPathExpr`).
- **Complete Evaluator (`src/eval.pion`, `src/num.pion`)**:
  - All 13 axes: `child`, `descendant`, `parent`, `ancestor`, `following-sibling`, `preceding-sibling`, `following`, `preceding`, `attribute`, `namespace`, `self`, `descendant-or-self`, `ancestor-or-self`.
  - Reverse-axis proximity position in step predicates (`preceding-sibling::*[1]`, `ancestor::*[1]`) vs forward document order in `FilterExpr` (`(preceding-sibling::*)[1]`).
  - Multi-level predicates, Union `|` sorted merge + deduplication, `//child` container fusion fast path.
  - Full arithmetic (`+`, `-`, `*`, `div`, `mod`), IEEE-754 `NaN`/`±Infinity`/`-0.0`, short-circuiting `and`/`or`, and existential NodeSet comparisons (`=`, `!=`, `<`, `<=`, `>`, `>=`).
  - All 27 W3C XPath 1.0 core functions:
    - Node-set (7): `last`, `position`, `count`, `id`, `local-name`, `namespace-uri`, `name`
    - String (10): `string`, `concat`, `starts-with`, `contains`, `substring-before`, `substring-after`, `substring` (IEEE-754 `round`/NaN/Inf & Unicode scalar values), `string-length` (Unicode scalar values), `normalize-space`, `translate`
    - Boolean (5): `boolean`, `not`, `true`, `false`, `lang`
    - Number (5): `number`, `sum`, `floor`, `ceiling`, `round` (`round(-0.5) == -0.0`, ties toward `+∞`)
  - Bounded `XPathLimits` (`max_depth`, `max_steps`, `max_nodes`, `max_output_bytes`) preventing stack overflow and exponential query DoS on both Native and Wasm32.

## Quick Start

```pion
import "xpath"

let doc = xpath::XPathDoc::parse(
  "<catalog xmlns:bk=\"urn:book\"><bk:book price=\"25\"><bk:title>Pion</bk:title></bk:book></catalog>",
)
let expr = xpath::XPathExpr::parse("string(//b:book[@price >= $min]/b:title)")
let ctx = xpath::XPathContext::new()
  .with_namespace("b", "urn:book")
  .with_variable("min", xpath::XPathValue::Number(20.0))
```

## Verification

```sh
pionc fmt --check packages/xpath
pionc check --json packages/xpath
pionc test packages/xpath
```

4-mode `wasm_smoke` (each with a clean `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/private/tmp/w15-xpath-nd pionc run packages/xpath/wasm_smoke
PION_CACHE_DIR=/private/tmp/w15-xpath-nr pionc run --release packages/xpath/wasm_smoke
PION_CACHE_DIR=/private/tmp/w15-xpath-wd pionc run --target wasm32 packages/xpath/wasm_smoke
PION_CACHE_DIR=/private/tmp/w15-xpath-wr pionc run --target wasm32 --release packages/xpath/wasm_smoke
```

All 4 modes exit `0` with byte-identical stdout:
`xpath_wasm_smoke: OK checks=4` (`sha256:027ade4d1cea32076b32165728a79ef96996fe9c7716100e6fe20782f5c6ffda`).

## Head-to-Head Benchmarks vs Rust `sxd-xpath` (`0.4.2`) + `sxd-document` (`0.3.2`)

Run with:

```sh
sh packages/xpath/bench/run_bench.sh
```

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification across all rounds and implementations; Rust locked via `bench/rust_bench/Cargo.lock` and compiled `--release`):

### W1: Large XML (`866,214 B`, 3,000 books) Precompiled 10 Composite XPath Queries (`5x`)

10 precompiled composite XPath 1.0 queries (multi-axis, compound predicates, `following-sibling::`, Union `|`, `sum()`, `contains()`, `starts-with()`, `normalize-space()`, `string-length()`) evaluated 5 rounds against a single parsed catalog.
SHA-256: `960c749ce1272f703bb6918c5dbb3dbe5e1172d4810486d766091fd6c6ae462e`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_sxd`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 92.892 | 90.096 | 92.967 | 18578450.00 | 13.62 MiB | **3.62x** |
| `rust_sxd` | 336.082 | 315.702 | 348.669 | 67216458.40 | 23.47 MiB | 1.00x (baseline) |

### W2: High-Frequency XPath Compile + Eval (`20,000x`)

20,000 iterations compiling and evaluating 10 short path/attribute/predicate/function XPath expressions (`count`, `sum`, `concat`, `starts-with`, `preceding-sibling::`, `string-length`) against a 50-item XML store.
SHA-256: `921d3a9311cc1d2006e799721bbf98dc1fa178daa218ca79c43a8c6ee3d8a7c0`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_sxd`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 273.331 | 271.693 | 280.272 | 13666.57 | 2.48 MiB | **1.50x** |
| `rust_sxd` | 409.851 | 408.362 | 412.037 | 20492.54 | 3.09 MiB | 1.00x (baseline) |

### W3: Deep Recursive Axes + Aggregation (`5x`)

Deep hierarchical org/dept/team/project/milestone XML (`156,950 B`) queried with `descendant-or-self::*`, `ancestor::`, `following-sibling::`, `normalize-space()`, and `sum()`.
SHA-256: `53319d5181e2fbf4a1e26116d96b446232dbf8dfe9a141872762b1f846ca587a`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_sxd`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 35.808 | 35.617 | 37.450 | 7161616.80 | 5.02 MiB | **1.52x** |
| `rust_sxd` | 54.291 | 50.860 | 56.428 | 10858258.20 | 7.06 MiB | 1.00x (baseline) |

### Objective Performance & Scope Notes

- **Flat-Array DOM & Contiguous Axis Scans**: Reusing `packages/xml`'s flat `Array[NodeData]` + `subtree_end` enables contiguous linear scans for `descendant`, `descendant-or-self`, `following`, and `preceding`, plus zero-copy `//child` container fusion and zero-allocation span comparison for `NodeTest::Name` / `QName`, yielding 1.50x–3.62x speedups and 1.25x–1.72x lower peak RSS vs `sxd-xpath`.
- **Known Scope Boundaries**: `packages/xpath` implements W3C XPath 1.0 (not XPath 2.0/3.1). `id()` indexes `xml:id` and unprefixed `id` attributes since `packages/xml` disables external DTDs by default.
