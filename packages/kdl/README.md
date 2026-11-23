# `kdl` — Pure-Pion KDL v2.0.0 & v1.0.0 Parser, AST, Formatter & Query Engine

Pure-Pion, zero-dependency, `World`-free, `Send`-clean (no module-level mutable state) implementation of the **KDL Document Language v2.0.0** (plus **KDL v1.0.0** compatibility mode), differential-tested against the official KDL 2.0.0 test suite (`kdl-org/kdl@6ceecd8`) and Rust **`kdl` 6.7.1**.

## Compliance & Capabilities

- **Zero dependencies / No `World` / `Send`-clean**: Pure Pion, runs identically on Native and `wasm32` (4-mode byte-identical across `native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel`), with no module-level mutable globals.
- **Official KDL v2.0.0 Test Suite (`kdl-org/kdl@6ceecd8`, 319 cases)**: **317 / 319 PASS** (verified via `sh packages/kdl/audit/run_audit.sh`; official CC-BY-SA test files are fetched on demand rather than vendored).
  - **2 remaining official cases (`hex`, `hex_int`)**: `KdlValue::Int(Int64)` intentionally bounds integers to signed 64-bit (`[-2^63, 2^63 - 1]`, permitted by the KDL 2.0.0 specification) and raises an explicit `KdlErrorKind::NumberOverflow` on out-of-range literals instead of silently wrapping.
  - **2 official invalid cases stricter than Rust `kdl 6.7.1`**: correctly rejects literal `U+007F` (`unicode_delete_fail`) and single-line `#"""..."""#` (`multiline_raw_string_single_line_err_fail`), which Rust `kdl 6.7.1` accepts.
  - **Spec-vs-suite alignment**: treats VT (`U+000B`) as `unicode-space` (matching the official test `vertical_tab_whitespace` and Rust `kdl`), and accepts `n{a}` without space before `{` (matching Rust `kdl 6.7.1`) while `format_compact` strictly emits a space before `{` (`n 1 {a}`).
- **Parser (`src/parser.pion`, `src/utf8.pion`)**:
  - Strict UTF-8 validation (`parse` / `parse_bytes`), leading UTF-8 BOM (`U+FEFF`) handling, and rejection of all KDL v2 disallowed literal code points (`U+0000`–`U+0008`, `U+000E`–`U+001F`, `U+007F`, bidi controls, mid-document BOM) and lone surrogates.
  - Bare identifier strings, quoted strings (`\n`, `\r`, `\t`, `\\`, `\"`, `\b`, `\f`, `\s`, `\u{...}`, and `\<ws/nl>` whitespace escapes), multi-line quoted strings (`"""..."""`) resolving whitespace escapes *before* closing-line dedent and remaining escapes *after* dedent, and single-/multi-line raw strings (`#"..."#`, `#"""..."""#`).
  - Full Unicode whitespace (`U+0009`, `U+000B`, `U+0020`, `U+00A0`, `U+1680`, `U+2000`–`U+200A`, `U+202F`, `U+205F`, `U+3000`) and Unicode newlines (`CRLF`, `CR`, `LF`, `NEL`, `FF`, `LS`, `PS`).
  - Single-line (`//`) comments, arbitrarily nested multi-line (`/* /* ... */ */`) block comments, line continuations (`\` in all `node-space` positions including inside `(type)` and around `=`), strict semicolon validation (rejecting stray `;`), and Slashdash (`/-`) on nodes, arguments, properties, and children blocks.
  - Type annotations on nodes, arguments, and property values, rejecting type annotations on property keys.
  - Decimal, hexadecimal (`0x`), octal (`0o`), and binary (`0b`) `Int64` integers (including exact `Int64::MIN`), bit-exact IEEE-754 binary64 floats (Eisel-Lemire 128-bit fast path + exact fallback, verified against 20,000 generated floats), special floats (`#inf`, `#-inf`, `#nan`), and keywords (`#true`, `#false`, `#null`).
  - O(N) amortized duplicate property last-wins deduplication preserving the **last occurrence's position** (promoting to a per-node hash map only for wide nodes with > 8 properties).
  - Preserves explicit empty children blocks (`node {}`) via `KdlNode.has_children_block`.
- **KDL v1.0.0 Compatibility Mode (`parse_v1` / `parse_v1_with_limits`)**:
  - Supports bare `true`/`false`/`null`, `r"..."` and `r#"..."#` raw strings, `\/` escape, and v1 identifier rules (including `#` in identifiers).
- **Lossless Iterative Formatters (`src/format.pion`, `src/float_fmt.pion`)**:
  - `format(doc)` (4-space indented canonical KDL v2) and `format_compact(doc)` (compact single-line `;`-separated KDL v2 with space before `{`), using pure-Pion Ryu shortest round-trip IEEE-754 formatting and an explicit iterative stack.
- **Navigation & Query Engine (`src/types.pion`, `src/query.pion`)**:
  - Ergonomic AST accessors: `doc.get(name)`, `doc.get_all(name)`, `doc.get_arg(name)`, `node.arg(i)`, `node.args()`, `node.prop(key)`, `node.props()`, `node.children()`, `node.child(name)`, `node.children_named(name)`.
  - Iterative O(nodes × steps) pre-order DP selector engine `query(doc, selector)`: direct child (`>` / `/`), descendant (`>>` / whitespace), global descendant (`>> name`), wildcard (`*`), type annotations (`(type)name`), property & positional-argument filters (`[key]`, `[key=val]`, `[key!=val]`, `[0=val]`, `["0"=val]` for quoted numeric property names, full KDL numeric literals including floats/hex/octal/binary/exponents), and deduplicated comma unions (`sel1, sel2`).
  - Note: this is a lightweight CSS-style selector dialect; full KQL extensions (`||`, `top()`, `[]`, `[val()]`) are not implemented.
- **Stack-Safe Iterative Execution & `KdlLimits`**:
  - `KdlLimits` (`max_depth`, `max_nodes`, `max_tokens`; `0` disables a limit, negative values are rejected with `LimitExceeded`) plus iterative stacks in parser, formatter, equality, and query engine prevent Native `SIGSEGV` and Wasm32 `RangeError` even at 200,000 nesting levels.

## Quick Start

```pion
import "kdl"

let src =
  "(app)service \"api-gateway\" port=8080 tls=#true {\n" +
  "    route \"/v1/health\" method=\"GET\" auth=#false\n" +
  "    route \"/v1/users\" method=\"POST\" auth=#true\n" +
  "}\n"

let doc = kdl::parse(src)
// doc.get("service"), node.prop("port"), kdl::query(doc, "service > route[auth=#true]")
// kdl::format(doc), kdl::format_compact(doc)
```

## Verification

```sh
sh scripts/verify.sh packages/kdl
sh packages/kdl/audit/run_audit.sh
```

4-mode `wasm_smoke` (each with a clean `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/private/tmp/fix-kdl-smoke-nd pionc run packages/kdl/wasm_smoke
PION_CACHE_DIR=/private/tmp/fix-kdl-smoke-nr pionc run --release packages/kdl/wasm_smoke
PION_CACHE_DIR=/private/tmp/fix-kdl-smoke-wd pionc run --target wasm32 packages/kdl/wasm_smoke
PION_CACHE_DIR=/private/tmp/fix-kdl-smoke-wr pionc run --target wasm32 --release packages/kdl/wasm_smoke
```

All 4 modes exit `0` with byte-identical stdout:
`kdl_wasm_smoke: OK checks=5` (`sha256:9c359791a97bfc98cd6eaf75ffac75b16940b3df80a5a505d9ea618ad2b51c5b`).

## Head-to-Head Benchmarks vs Rust `kdl` `v6.7.1` (`--release --locked`)

Run with:

```sh
sh packages/kdl/bench/run_bench.sh
```

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification across all rounds and implementations):

### W1: Large Realistic KDL v2 Config Parse (`3x 2,685,430 B = 8,056,290 B`)

Zellij / Niri / build-manifest style configuration with 3,000 typed service blocks, nested layouts, panes, keybinds, and resource limits.
SHA-256: `4d53407706d3d19918aecc2724ad2571cd19c5eaf5ab7e4e51886669968dd049`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_kdl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 204.810 | 183.415 | 231.165 | 39.34 | 68269972.00 | 25.97 MiB | **19.53x** |
| `rust_kdl` | 3999.952 | 3333.310 | 4269.924 | 2.01 | 1333317403.00 | 104.06 MiB | 1.00x (baseline) |

### W2: Mixed KDL v2 Parse + Format + Re-Parse Roundtrip (`20x 73,467 B = 1,469,340 B`)

Deeply nested pipeline blocks with multi-line strings (`"""..."""` dedent), raw strings (`#"..."#` & `#"""..."""#`), type annotations, slashdashed nodes/entries, hex integers, and `#inf`, parsed, formatted, and re-parsed.
SHA-256: `758d0f0b4d56e5efb1b5d01be493e62008420a3f870c153a95f1e64aee996d46`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_kdl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 109.090 | 79.628 | 131.802 | 13.47 | 5454502.05 | 2.97 MiB | **13.78x** |
| `rust_kdl` | 1503.416 | 1493.248 | 1515.206 | 0.98 | 75170795.85 | 8.17 MiB | 1.00x (baseline) |

### W3: High-Frequency Small Config Parse + Extract (`8,000x 468 B = 3,744,000 B`)

Microservice / plugin hot-reload workload parsing a 468 B KDL v2 config 8,000 times and extracting authenticated routes and upstream weights — comparing both AST accessors (`pion_accessor` vs `rust_kdl`) and Pion's real selector engine (`pion_query`, calling `kdl::query`).
SHA-256: `5bc8e0df8a0fcc2a46a9701703ac571027b030131c9f41db8ae2dccbdecdc8aa`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_kdl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_accessor` | 137.341 | 117.834 | 140.242 | 27.26 | 17167.59 | 2.05 MiB | **11.38x** |
| `pion_query` | 125.344 | 107.025 | 171.369 | 29.87 | 15667.97 | 2.08 MiB | **12.46x** |
| `rust_kdl` | 1562.345 | 1502.230 | 1789.984 | 2.40 | 195293.16 | 2.52 MiB | 1.00x (baseline) |

### W4: Wide Node (`100,000` Distinct Properties) Parse (`3x 1,277,790 B = 3,833,370 B`)

Adversarial wide-node stress test with 100,000 distinct properties on a single node, exercising O(N) hash-map property deduplication.
SHA-256: `a2cbf936e0011859bb72b8a17787ce30223ac0474f5fac6dbdbd79bfe3fd4bad`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_kdl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 154.170 | 150.589 | 182.812 | 24.86 | 51390097.33 | 29.86 MiB | **10.18x** |
| `rust_kdl` | 1569.316 | 1461.177 | 1718.436 | 2.44 | 523105263.67 | 84.44 MiB | 1.00x (baseline) |

### Objective Performance & Fairness Notes

- **Architecture difference (AST vs lossless CST)**:
  - Rust `kdl` `v6.7.1` is a **format-preserving lossless CST parser** (`winnow` + `miette`) that retains exact source formatting trivia (comments, whitespace, raw number/string representations, spans) and uses `i128` integers to support source-preserving editing.
  - `packages/kdl` is a **semantic AST parser** using a single-pass hand-written byte scanner, iterative block stack, `Int64` + Eisel-Lemire `Double`, and canonical/compact formatting — trading comment/whitespace trivia preservation and `i128` range for 10x–19x higher throughput and 1.2x–4.0x lower peak RSS. These numbers compare against the reference Rust crate, not against an equivalent AST-only Rust parser.
- **W2 formatting workload difference**: Rust `kdl` runs `doc.autoformat()` and `doc.to_string()` over the CST (rewriting trivia nodes), whereas Pion runs `kdl::format(doc)` directly from the semantic AST. Both perform parse → canonical format → re-parse, though Rust does additional CST trivia rewriting.
- **W3 accessors vs query engine**: Rust `kdl 6.7.1` ships its query API disabled, so the baseline (`rust_kdl`) and `pion_accessor` both use direct AST/CST accessors; `pion_query` additionally benchmarks Pion's real `kdl::query` selector engine on the same workload with identical stdout SHA-256.
- **Safety**: All recursive tree operations (`parse`, `format`, `format_compact`, `query`, `KdlDocument::equals`) use explicit iterative heap stacks bounded by `KdlLimits`, avoiding Native `SIGSEGV` and Wasm32 `RangeError`.
