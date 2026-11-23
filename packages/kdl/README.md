# `kdl` — Pure-Pion KDL v2.0.0 & v1.0.0 Parser, AST, Formatter & Query Engine

Pure-Pion, zero-dependency, `World`-free implementation of the **KDL Document Language v2.0.0** (plus **KDL v1.0.0** compatibility mode), aligned with the official KDL v2.0.0 Specification and Rust **`kdl` 6.x**.

- **Zero dependencies / No `World`**: Pure Pion, runs identically on Native and `wasm32` (4-mode byte-identical across `native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel`).
- **Complete KDL v2.0.0 Compliance (`src/parser.pion`, `src/utf8.pion`)**:
  - Strict UTF-8 validation (`parse` / `parse_bytes`), leading UTF-8 BOM (`U+FEFF`) handling, and rejection of all KDL v2 disallowed literal code points (`U+0000`–`U+0008`, `U+000E`–`U+001F`, `U+007F`, bidi controls, mid-document BOM) and lone surrogates.
  - Bare identifier strings (including Unicode, signed `+foo`/`-foo`, dotted `.foo`, and rejection of bare `true`/`false`/`null`/`inf`/`-inf`/`nan`), quoted strings (`\n`, `\r`, `\t`, `\\`, `\"`, `\b`, `\f`, `\s`, `\u{...}`, and `\<ws/nl>` whitespace escapes), multi-line quoted strings (`"""..."""`) with spec-exact closing-line indentation stripping and CRLF normalization, and single-/multi-line raw strings (`#"..."#`, `#"""..."""#`).
  - Full Unicode whitespace (`U+0009`, `U+0020`, `U+00A0`, `U+1680`, `U+2000`–`U+200A`, `U+202F`, `U+205F`, `U+3000`) and Unicode newlines (`CRLF`, `CR`, `LF`, `NEL`, `VT`, `FF`, `LS`, `PS`).
  - Single-line (`//`) comments, arbitrarily nested multi-line (`/* /* ... */ */`) block comments, line continuations (`\`), and Slashdash (`/-`) on nodes, arguments, properties, and children blocks.
  - Type annotations on nodes, arguments, and property values (`(u8)42`, `( date ) "2026-11-23"`, `( #"raw-t"# ) #true`), rejecting type annotations on property keys.
  - Decimal, hexadecimal (`0x`), octal (`0o`), and binary (`0b`) `Int64` integers (including exact `Int64::MIN`), exact IEEE-754 binary64 floats (Eisel-Lemire 128-bit fast path + exact fallback), special floats (`#inf`, `#-inf`, `#nan`), and keywords (`#true`, `#false`, `#null`).
  - Duplicate property last-wins semantics.
- **KDL v1.0.0 Compatibility Mode (`parse_v1` / `parse_v1_with_limits`)**:
  - Supports bare `true`/`false`/`null`, `r"..."` and `r#"..."#` raw strings, `\/` escape, and v1 identifier rules.
- **Lossless Iterative Formatters (`src/format.pion`, `src/float_fmt.pion`)**:
  - `format(doc)` (4-space indented canonical KDL v2) and `format_compact(doc)` (compact single-line `;`-separated KDL v2), using pure-Pion Ryu shortest round-trip IEEE-754 formatting and an explicit iterative stack.
- **Navigation & Query Engine (`src/types.pion`, `src/query.pion`)**:
  - Ergonomic AST accessors: `doc.get(name)`, `doc.get_all(name)`, `doc.get_arg(name)`, `node.arg(i)`, `node.args()`, `node.prop(key)`, `node.props()`, `node.children()`, `node.child(name)`, `node.children_named(name)`.
  - Iterative selector query engine `query(doc, selector)`: direct child (`>` / `/`), descendant (`>>` / whitespace), global descendant (`>> name`), wildcard (`*`), type annotations (`(type)name`), property & positional-argument filters (`[key]`, `[key=val]`, `[key!=val]`, `[0=val]`), and comma unions.
- **Stack-Safe Iterative Execution & `KdlLimits`**:
  - `KdlLimits` (`max_depth`, `max_nodes`, `max_tokens`) plus iterative stacks in parser, formatter, equality, and query engine prevent Native `SIGSEGV` and Wasm32 `RangeError` even at hundreds of nesting levels.

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
```

4-mode `wasm_smoke` (each with a clean `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/private/tmp/w15-kdl-nd pionc run packages/kdl/wasm_smoke
PION_CACHE_DIR=/private/tmp/w15-kdl-nr pionc run --release packages/kdl/wasm_smoke
PION_CACHE_DIR=/private/tmp/w15-kdl-wd pionc run --target wasm32 packages/kdl/wasm_smoke
PION_CACHE_DIR=/private/tmp/w15-kdl-wr pionc run --target wasm32 --release packages/kdl/wasm_smoke
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
| `pion` | 135.839 | 135.115 | 136.950 | 59.31 | 45279611.00 | 25.39 MiB | **13.93x** |
| `rust_kdl` | 1891.609 | 1840.264 | 1929.983 | 4.26 | 630536222.33 | 104.06 MiB | 1.00x (baseline) |

### W2: Mixed KDL v2 Parse + Format + Re-Parse Roundtrip (`20x 73,467 B = 1,469,340 B`)

Deeply nested pipeline blocks with multi-line strings (`"""..."""` dedent), raw strings (`#"..."#` & `#"""..."""#`), type annotations, slashdashed nodes/entries, hex integers, and `#inf`, parsed, formatted, and re-parsed.
SHA-256: `758d0f0b4d56e5efb1b5d01be493e62008420a3f870c153a95f1e64aee996d46`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_kdl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 51.571 | 51.135 | 52.934 | 28.49 | 2578570.85 | 2.91 MiB | **13.92x** |
| `rust_kdl` | 717.621 | 713.116 | 726.531 | 2.05 | 35881072.95 | 8.20 MiB | 1.00x (baseline) |

### W3: High-Frequency Small Config Parse + Extract Query (`8,000x 468 B = 3,744,000 B`)

Microservice / plugin hot-reload workload parsing a 468 B KDL v2 config 8,000 times and extracting authenticated routes and upstream weights.
SHA-256: `5bc8e0df8a0fcc2a46a9701703ac571027b030131c9f41db8ae2dccbdecdc8aa`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_kdl`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 69.880 | 69.560 | 71.550 | 53.58 | 8735.05 | 2.00 MiB | **14.04x** |
| `rust_kdl` | 981.383 | 972.675 | 1033.158 | 3.81 | 122672.86 | 2.47 MiB | 1.00x (baseline) |

### Objective Performance & Tradeoff Notes

- **Why `packages/kdl` is ~14x faster than Rust `kdl` `v6.7.1`**:
  - Rust `kdl` `v6.7.1` is a **format-preserving CST parser** (`winnow` + `miette`) that retains exact source formatting trivia (comments, whitespace, raw number/string representations, spans) and uses `i128` integers to support lossless source-preserving editing.
  - `packages/kdl` is a **semantic AST parser** using a single-pass hand-written byte scanner, iterative block stack, `Int64` + Eisel-Lemire `Double`, and canonical/compact formatting — trading comment/whitespace trivia preservation and `i128` range for ~14x higher throughput and 1.2x–4.1x lower peak RSS.
- **Safety**: All recursive tree operations (`parse`, `format`, `format_compact`, `query`, `KdlDocument::equals`) use explicit iterative heap stacks bounded by `KdlLimits`, avoiding Native `SIGSEGV` and Wasm32 `RangeError`.
