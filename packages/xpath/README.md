# `xpath` — Pure-Pion W3C XPath 1.0 Query Engine

Pure-Pion, zero-C-dependency (no `libxml2`), no-`World` **W3C XPath 1.0** query engine built on top of `packages/xml` (`xml::Document`), supporting all **13 axes**, all **27 core library functions**, compile-once `XPathExpr::parse` + reusable evaluation, external variables (`$var`) and namespace prefix bindings (`XPathContext`), and bounded resource limits (`XPathLimits`).

- **Zero C dependencies / No `World`**: Pure Pion, runs identically on Native and `wasm32` (4-mode byte-identical across `native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel` over all 11,705 differential corpus queries and `wasm_smoke`).
- **Read-Only `XPathDoc` View (`src/doc.pion`)**:
  - Reuses `packages/xml`'s flat pre-order DFS node/attribute arrays directly with zero DOM duplication.
  - `XPathDoc::parse` accepts safe `<!DOCTYPE ...>` declarations (including internal subsets) while keeping external entities / XXE blocked.
  - Precomputes `subtree_end` in a single O(N) reverse pass for contiguous O(1)-per-node `descendant`, `descendant-or-self`, `following`, and `preceding` axis scans (`j < id` is an ancestor iff `subtree_end[j] >= id`).
  - Zero-copy namespace slice inheritance (`elem_ns_start`/`elem_ns_end`) with built-in `xml` namespace (preserved even under explicit `xmlns:xml="http://www.w3.org/XML/1998/namespace"`) and `xmlns=""` undeclaration support, plus `id_map` indexing `xml:id` and `id` attributes for O(1) `id()`.
- **Full W3C XPath 1.0 Grammar & §3.7 Disambiguation (`src/lexer.pion`, `src/parser.pion`, `src/ast.pion`)**:
  - Exact §3.7 preceding-token lexical disambiguation for `*`, `and`, `or`, `mod`, `div` vs NCName/QName/NameTest (`* * *`, `div div mod`, `and and or`, `/root/node`, `child::child`).
  - All abbreviated syntax (`.`, `..`, `@attr`, `//`) with exact `//item[1]` vs `(//item)[1]` semantics.
  - Depth-bounded recursive-descent parser compiling into a flat AST arena (`XPathExpr`), honouring caller-specified `XPathLimits.max_depth` while evaluating flat left-associative chains (`or`, `and`, `+`/`-`, `*`/`div`/`mod`, `|`) iteratively in O(1) recursion depth.
- **Exact Pure-Pion IEEE-754 Number Semantics (`src/float_ieee.pion`, `src/num.pion`)**:
  - **§4.2 `number → string`**: Pure-Pion exact integer formatting + Ryu shortest round-trip decimal generation with **no exponent notation** (zero dependency on host `Double::to_string`, 100% deterministic across Native and Wasm32).
  - **§4.4 `string → number`**: Correctly rounded Eisel-Lemire zero-allocation fast path + arbitrary-precision decimal fallback (handles 310+ digit fractions without overflow to `NaN`).
  - **§3.5 `mod`**: Bit-exact IEEE-754 truncating remainder (`fmod`) via binary mantissa long division, preserving `-0.0` sign of the dividend.
- **Complete Evaluator (`src/eval.pion`)**:
  - All 13 axes: `child`, `descendant`, `parent`, `ancestor`, `following-sibling`, `preceding-sibling`, `following`, `preceding`, `attribute`, `namespace`, `self`, `descendant-or-self`, `ancestor-or-self`.
  - Reverse-axis proximity position in step predicates (`preceding-sibling::*[1]`, `ancestor::*[1]`) vs forward document order in `FilterExpr` (`(preceding-sibling::*)[1]`).
  - Multi-level predicates, Union `|` sorted merge + deduplication, `//child` container fusion and `//@attr` attribute fusion fast paths.
  - **O(n + m) Node-Set Comparisons**: Hash-set lookup for `=`, single-pass distinctness check for `!=`, and min/max numeric reduction for `<`/`<=`/`>`/`>=`.
  - **Lazy Cached & Budgeted `string-value`**: Per-evaluation lazy cache for multi-child subtrees (such as `/`) with step and `max_output_bytes` budgeting across string-value construction and string functions.
  - Non-aliasing immutable-style `XPathContext::with_namespace` / `with_variable` builders, with automatic document-order normalization & deduplication for external `NodeSet` variables.
  - All 27 W3C XPath 1.0 core functions:
    - Node-set (7): `last`, `position`, `count`, `id`, `local-name`, `namespace-uri`, `name`
    - String (10): `string`, `concat`, `starts-with`, `contains`, `substring-before`, `substring-after`, `substring` (IEEE-754 `round`/NaN/Inf & Unicode scalar values), `string-length` (Unicode scalar values), `normalize-space`, `translate`
    - Boolean (5): `boolean`, `not`, `true`, `false`, `lang`
    - Number (5): `number`, `sum`, `floor`, `ceiling`, `round` (`round(-0.5) == -0.0`, ties toward `+∞`)
  - Bounded `XPathLimits` (default: `max_depth = 128`, `max_steps = 10,000,000`, `max_nodes = 1,000,000`, `max_output_bytes = 16 MiB`) preventing stack overflow and exponential query DoS on both Native and Wasm32 while handling multi-megabyte documents out of the box.

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
sh scripts/verify.sh packages/xpath
```

4-mode `wasm_smoke` (each with a clean `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/private/tmp/fix-xpath-nd pionc run packages/xpath/wasm_smoke
PION_CACHE_DIR=/private/tmp/fix-xpath-nr pionc run --release packages/xpath/wasm_smoke
PION_CACHE_DIR=/private/tmp/fix-xpath-wd pionc run --target wasm32 packages/xpath/wasm_smoke
PION_CACHE_DIR=/private/tmp/fix-xpath-wr pionc run --target wasm32 --release packages/xpath/wasm_smoke
```

All 4 modes exit `0` with byte-identical stdout:
`xpath_wasm_smoke: OK checks=5` (`sha256:030d392658c8f5b76ac5955227be388f8f4d7a45969ed076890ecfd7a12c7c4e`).

## Head-to-Head Benchmarks vs Rust `sxd-xpath` (`0.4.2`) and C `libxml2` (`-O2`)

Run with:

```sh
sh packages/xpath/bench/run_bench.sh
```

Measured on `Darwin arm64` (shared machine; interleaved runs show ~5–20% run-to-run spread under background load) via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory 3-way stdout SHA-256 verification across all rounds and implementations; Rust locked via `bench/rust_bench/Cargo.lock` with `--locked --release`; C `libxml2` compiled with `cc -O2`):

### W1: Large XML (`866,214 B`, 3,000 books) Precompiled 10 Composite XPath Queries (`5x`)

10 precompiled composite XPath 1.0 queries (multi-axis, compound predicates, `following-sibling::`, Union `|`, `sum()`, `contains()`, `starts-with()`, `normalize-space()`, `string-length()`) evaluated 5 rounds against a single parsed catalog.
SHA-256: `960c749ce1272f703bb6918c5dbb3dbe5e1172d4810486d766091fd6c6ae462e`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_sxd`) | vs `c_libxml2` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 101.466 | 98.242 | 106.200 | 20293133.20 | 13.88 MiB | **3.16x** | 0.84x |
| `rust_sxd` | 320.295 | 306.022 | 353.030 | 64059050.00 | 23.47 MiB | 1.00x (baseline) | 0.27x |
| `c_libxml2` | 85.358 | 85.057 | 95.077 | 17071666.60 | 13.55 MiB | 3.75x | 1.00x |

### W2: High-Frequency XPath Compile + Eval (`20,000x`)

20,000 iterations compiling and evaluating 10 short path/attribute/predicate/function XPath expressions (`count`, `sum`, `concat`, `starts-with`, `preceding-sibling::`, `string-length`) against a 50-item XML store.
SHA-256: `921d3a9311cc1d2006e799721bbf98dc1fa178daa218ca79c43a8c6ee3d8a7c0`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_sxd`) | vs `c_libxml2` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 420.083 | 367.487 | 502.978 | 21004.15 | 2.73 MiB | **1.28x** | 0.71x |
| `rust_sxd` | 535.888 | 446.566 | 620.731 | 26794.38 | 3.09 MiB | 1.00x (baseline) | 0.56x |
| `c_libxml2` | 299.880 | 267.442 | 359.178 | 14994.01 | 2.08 MiB | 1.79x | 1.00x |

### W3: Deep Recursive Axes + Aggregation (`5x`)

Deep hierarchical org/dept/team/project/milestone XML (`156,950 B`) queried with `descendant-or-self::*`, `ancestor::`, `following-sibling::`, `normalize-space()`, and `sum()`.
SHA-256: `53319d5181e2fbf4a1e26116d96b446232dbf8dfe9a141872762b1f846ca587a`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_sxd`) | vs `c_libxml2` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 49.204 | 48.329 | 54.591 | 9840841.80 | 5.20 MiB | **1.42x** | 0.86x |
| `rust_sxd` | 69.649 | 64.537 | 75.074 | 13929750.00 | 7.03 MiB | 1.00x (baseline) | 0.60x |
| `c_libxml2` | 42.092 | 40.499 | 42.588 | 8418341.60 | 4.55 MiB | 1.65x | 1.00x |

### W4: Large Node-Set Comparisons (`//a = != < > //b`, 8,000 × 8,000, `5x`)

Existential node-set comparisons (`=`, `!=`, `<`, `>`) over disjoint 8,000-element node-sets (`182,939 B`).
SHA-256: `e3d9fad7da7df0e73b85590e7b061a2bbb32b731955b21fd2adc1ae6563095a3`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_sxd`) | vs `c_libxml2` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 36.693 | 35.221 | 37.184 | 7338675.00 | 10.00 MiB | **7.53x** | **15.95x** |
| `rust_sxd` | 276.451 | 256.049 | 329.514 | 55290125.00 | 23.98 MiB | 1.00x (baseline) | 2.12x |
| `c_libxml2` | 585.176 | 582.833 | 591.021 | 117035183.40 | 7.45 MiB | 0.47x | 1.00x |

### W5: > 1 MB Document (`1,188,939 B`, 50,000 elements + attributes under default `XPathLimits`, `5x`)

Large document queries (`count(/r/e)`, `count(//@k)`, `count(//e[@k >= 25000])`, `sum(//e[@k < 1000]/@k)`) exercising default `XPathLimits` (`max_nodes = 1,000,000`, `max_steps = 10,000,000`) and `//@attr` fusion.
SHA-256: `943118fc2175b897031ee26c9fb1f4e8135d6efb15ab60e6cf2c326bd2604d84`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_sxd`) | vs `c_libxml2` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 168.141 | 163.345 | 171.299 | 33628183.20 | 27.69 MiB | **2.41x** | **1.16x** |
| `rust_sxd` | 404.483 | 398.055 | 410.510 | 80896575.00 | 46.75 MiB | 1.00x (baseline) | 0.48x |
| `c_libxml2` | 195.615 | 194.295 | 204.427 | 39123050.00 | 29.89 MiB | 2.07x | 1.00x |

### Objective Performance & Scope Notes

- **Where `pion` wins**: Outperforms Rust `sxd-xpath` across all 5 workloads (**1.28x–7.53x** faster, **1.13x–2.40x** lower peak RSS), and outperforms C `libxml2` on **W4** (**15.95x** faster via O(n+m) hash-set `=`, single-pass `!=`, and min/max relational reduction) and **W5** (**1.16x** faster via flat-array contiguous scans and `//@attr` fusion, with lower peak RSS).
- **Where `c_libxml2` wins**: On **W1** (`0.84x`), **W2** (`0.71x`), and **W3** (`0.86x`), C `libxml2` (`-O2`) remains 14–29% faster, especially on high-frequency short query compilation (`W2`) where C stack allocation and pointer-based ASTs avoid GC/heap overhead.
- **Default `XPathLimits`**: `XPathLimits::default()` sets `max_depth = 128`, `max_steps = 10,000,000`, `max_nodes = 1,000,000` (aligned with `packages/xml`'s default node cap), and `max_output_bytes = 16 MiB`. Callers needing higher or tighter bounds can pass a custom `XPathLimits` via `XPathContext::with_limits` + `eval_with` / `XPathExpr::parse_with_limits`.
- **Known Scope Boundaries**: `packages/xpath` implements W3C XPath 1.0 (not XPath 2.0/3.1). `id()` indexes `xml:id` and unprefixed `id` attributes; `XPathDoc::parse` accepts `<!DOCTYPE ...>` declarations and internal subsets while blocking external DTD/entity fetches (XXE-safe).
