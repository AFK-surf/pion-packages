# `handlebars`

Pure-Pion **Handlebars 4.x + Mustache 1.4.2** template engine (`v0.1.0`) with zero C/FFI dependencies, zero `World` dependency, and zero module-level mutable state.

## Highlights

- **100% Pure Pion & Dual-Target (`Native` + `Wasm32`)** — compiles and runs identically across `native_dbg`, `native_rel`, `wasm_dbg`, and `wasm_rel` with verified byte-for-byte identical stdout SHA-256 and zero Wasm32 traps.
- **Pre-Compiled AST & Streaming `StringBuilder` Output** — templates and partials are lexed, whitespace-normalized, and parsed once (`Registry::register_template`, `Registry::register_partial`, `Registry::compile`) into a compact AST and rendered directly into a `StringBuilder` with explicit `Result[String, HandlebarsError]` error handling.
- **Mustache Spec v1.4.2 Compliance**:
  - Interpolation `{{name}}`, unescaped `{{{name}}}` and `{{& name}}`, dotted names with Mustache initial-segment context precedence, implicit iterator `{{.}}`.
  - Truthy/falsy sections `{{#x}}...{{/x}}`, list iteration, object context push, inverted sections `{{^x}}...{{/x}}`, and `{{^}}` else shorthand.
  - Inline comments `{{! ... }}` and Handlebars block comments `{{!-- ... --}}`.
  - Partials `{{> partial}}` with Mustache standalone-line indentation and recursion.
  - Dynamic Mustache delimiter switching `{{=<% %>=}}` (scoped to the current template; does not leak out of partials).
  - Full Mustache standalone-line whitespace stripping (`\n` and `\r\n`).
- **Handlebars 4.x Feature Set**:
  - **Paths & Data Variables**: `a.b.c`, `a/b/c`, `../parent`, `../../ancestor`, `./local`, `this`, bracket segment literals `[a.b]` / `[with space]`, `@root`, `@index`, `@first`, `@last`, `@key`, and parent data frames `@../index`.
  - **Built-in Helpers**: `{{#if}}` (with chained `{{else if}}`, `{{else}}`, `includeZero=true`), `{{#unless}}` (`includeZero=true`), `{{#each}}` (arrays & ordered objects with `@index`/`@key`/`@first`/`@last` and `{{else}}`), `{{#with}}`, `{{lookup obj key}}`, and `{{log ...}}` (pure `World`-free no-op).
  - **Subexpressions & Block Parameters**: arbitrary nested subexpressions `(eq (len items) 0)`, named hash arguments `k=v`, and block parameters `as |item idx|`.
  - **Whitespace Control & Escaping**: `{{~ ... ~}}` and `{{{~ ... ~}}}` left/right whitespace stripping, raw blocks `{{{{raw}}}}...{{{{/raw}}}}`, escaped mustaches `\{{...}}` and `\\{{...}}`.
  - **Partials**: context & hash arguments `{{> partial ctx k=v}}`, dynamic partial names `{{> (helper)}}`, partial blocks `{{#> layout}}...{{/layout}}` with `{{> @partial-block}}`, and scoped inline partials `{{#*inline "name"}}...{{/inline}}`.
  - **Strict HTML Escaping & Modes**: `escape_html` escapes all 7 official Handlebars.js `escapeExpression` characters (`&`, `<`, `>`, `"`, `'`, `` ` ``, `=`), plus `Value::safe_string`, `set_no_escape(true)`, and `set_strict_mode(true)` (`ErrorKind::StrictUndefined`).
  - **Custom Helpers**: register inline or block helpers via `Registry::register_helper` with full access to `params`, `hash`, `this_val`, `root`, `data_get`, `fn_render`, and `inverse_render`.
  - **JSON / JSON5 Data Model Binding**: `Value::from_json` and `Value::from_json5` backed by `packages/json5`.
- **Explicit Security & DoS Limits (`HandlebarsLimits`)**:
  - `max_template_bytes` (default `4 MiB`) — rejects oversized templates before lexing (`ErrorKind::TemplateSizeLimitExceeded`).
  - `max_depth` (default `64`) — bounds block and subexpression nesting at compile and render time (`ErrorKind::DepthLimitExceeded`).
  - `max_partial_depth` (default `32`) — stops recursive partial bombs like `{{> self}}` (`ErrorKind::PartialDepthLimitExceeded`).
  - `max_steps` (default `10,000,000`) — bounds evaluation steps and loop iterations (`ErrorKind::StepLimitExceeded`).
  - `max_output_bytes` (default `16 MiB`) — prevents exponential output amplification before allocation (`ErrorKind::OutputLimitExceeded`).

## Quickstart

```pion
import "handlebars"

fn example() -> Result[String, handlebars::HandlebarsError] {
  let reg = handlebars::Registry::new()
  match reg.register_partial("badge", "<span class=\"badge\">{{label}}</span>") {
    Ok(()) => ()
    Err(e) => return Err(e)
  }
  match reg.register_template(
    "card",
    "<h2>{{title}}</h2><ul>{{~#each items as |item idx|~}}<li>{{idx}}: {{item}} {{> badge label=\"ok\"}}</li>{{~/each~}}</ul>",
  ) {
    Ok(()) => ()
    Err(e) => return Err(e)
  }
  let data = handlebars::Value::object([
    ("title", handlebars::Value::string("Pion <Handlebars> & Co.")),
    (
      "items",
      handlebars::Value::array([
        handlebars::Value::string("Fast"),
        handlebars::Value::string("Safe"),
      ]),
    ),
  ])
  reg.render("card", data)
}
```

### Untrusted Templates with Tight Limits

```pion
let limits = handlebars::HandlebarsLimits::{
  max_depth: 16,
  max_partial_depth: 8,
  max_steps: 100000L,
  max_output_bytes: 262144,
  max_template_bytes: 65536,
}
let reg = handlebars::Registry::with_limits(limits)
reg.set_strict_mode(true)
```

## Verification

```sh
# Format, type-check, and run all 25 compliance + DoS tests
sh scripts/verify.sh packages/handlebars

# 4-mode Native + Wasm32 smoke verification (all exit 0, identical SHA-256)
pionc run packages/handlebars/wasm_smoke
pionc build --release -o /private/tmp/w16-handlebars-smoke packages/handlebars/wasm_smoke && /private/tmp/w16-handlebars-smoke
pionc run --target wasm32 packages/handlebars/wasm_smoke
pionc run --release --target wasm32 packages/handlebars/wasm_smoke
```

4-mode `wasm_smoke` verified stdout SHA-256 (`native_dbg` / `native_rel` / `wasm_dbg` / `wasm_rel`):
`e320082463201cfbfefe45a8575dcedcbee95e4eab0e7d3e35e50d6ca4e23043`.

## Head-to-Head Benchmark

Benchmarked via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte identity) on `Darwin arm64` against **Rust `handlebars = 6.4.4`** (`--locked --release`, `opt-level = 3`, `lto = "thin"`, `codegen-units = 1`). Run with `sh packages/handlebars/bench/run_bench.sh`.

### W1: E-commerce HTML Page SSR (`1,000` precompiled renders, nested `{{#each}}` + `{{#if}}` + 2 partials + HTML escape)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_handlebars`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 136.435 | 135.399 | 142.611 | 136435.38 | 2.62 MiB | **1.73x** |
| `rust_handlebars` | 236.607 | 235.477 | 238.033 | 236606.92 | 3.03 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all rounds: `941ceac34df86a8d61f51201fd7db1e11f2ff606608f2f3cceac593b0c1e7c2f`._

### W2: AI Prompt Compile + Render E2E (`2,000` iterations, `with` + `lookup` + `as |tool idx|` + `{{~ ~}}` + `(eq ...)` subexpression)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_handlebars`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 27.218 | 26.756 | 28.697 | 13608.90 | 2.30 MiB | **2.72x** |
| `rust_handlebars` | 74.071 | 72.878 | 75.355 | 37035.65 | 2.98 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all rounds: `1d969b9d099a6539e8b5cee3930b2550e8fc12caa4603a7ae42effca95556ee2`._

### W3: High-Escape-Density 500-Row HTML Table (`200` precompiled renders, heavy `& < > " '` escaping)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_handlebars`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 109.521 | 107.406 | 110.272 | 547604.17 | 3.38 MiB | **1.35x** |
| `rust_handlebars` | 148.297 | 147.296 | 150.926 | 741482.50 | 3.70 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all rounds: `8f6ac54870af1f0a20f04e88c9f1e6c56c08a45ee7fa49015ad108002e3caae7`._

## Notes & Scope

- **No `eval` / dynamic JS lambdas**: Mustache lambda callbacks (JS function values in data) are not part of the JSON data model; use `Registry::register_helper` for custom inline and block logic.
- **No `World` / filesystem auto-loading**: templates and partials are registered in memory so the library stays 100% `World`-free and Wasm32-safe.
- **Object lookup**: `Value::Object` stores insertion-ordered `(String, Value)` pairs for deterministic `{{#each}}` iteration; lookup is linear in the object's key count (fast for typical template contexts, O(K) for very wide objects).
