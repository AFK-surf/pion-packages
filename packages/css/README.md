# `css`

Pure Pion **W3C CSS Syntax Level 3** tokenizer, fault-tolerant iterative stylesheet & declaration-block AST parser, **Selectors Level 4** specificity calculator, **Media Queries Level 4** parser, **CSS Color Level 4** parser (including all 148 named colors), and CSS formatter / minifier.

- **Zero C dependencies / zero `World` dependency** — compiles and runs identically on **Native** and **`wasm32`** (verified across all 4 modes: Native/Wasm32 × debug/release via `wasm_smoke`).
- **Full CSS Syntax Level 3 tokenizer** — 256-byte ASCII classification LUT, zero-copy fast paths for unescaped identifiers/strings/numbers, `\r\n`/`\r`/`\f` → `\n` and NUL (`\u{0000}`) → `U+FFFD` input preprocessing, invalid UTF-8 byte replacement, full CSS escapes (`\` + 1–6 hex digits + optional single whitespace, clamping `0`/surrogates/`> 0x10FFFF` to `U+FFFD`), `Ident`, `Function`, `AtKeyword`, `Hash(Id | Unrestricted)`, `Str`/`BadString` (with `\<newline>` line continuation), `Url`/`BadUrl`, `Number`/`Percentage`/`Dimension`, `UnicodeRange`, `Cdo`/`Cdc`, `Delim`, `Whitespace`, punctuation, and unclosed-EOF comments in O(N).
- **100% iterative AST parser & specificity evaluator (0 recursion)** — explicit heap stacks for stylesheet blocks, CSS nesting (`&`, nested qualified rules, nested `@media`), `@font-face`/`@supports`/`@keyframes`/`@import`/`@layer`/`@charset`/`@container`, case-insensitive `!important`, verbatim custom property (`--*`) whitespace/case preservation, and fault-tolerant recovery on malformed declarations/rules.
- **Day-1 security & resource budgets** — configurable `ParseOptions { max_depth, max_tokens, max_rules }` (default `256` / `2_000_000` / `500_000`), verified against 50,000-level nested `{`/`(`/ `@media {` (0 SIGSEGV), 50k unclosed comments/strings/escapes (strict O(N)), and NUL / invalid UTF-8 raw bytes.

## API

```pion
// Core error & limits
pub enum CssErrorKind { LimitExceeded, InvalidColor, InvalidSelector, InvalidMediaQuery, InvalidSyntax, Unimplemented }
pub struct CssError { pub kind : CssErrorKind, pub offset : Int, pub line : Int, pub col : Int, pub message : String }
pub val struct ParseOptions { pub max_depth : Int, pub max_tokens : Int, pub max_rules : Int }

// Tokenizer (W3C CSS Syntax Level 3)
pub fn tokenize(src : String) -> Result[Array[Token], CssError]
pub fn tokenize_with_options(src : String, opts : ParseOptions) -> Result[Array[Token], CssError]
pub fn tokenize_bytes(src : Bytes) -> Result[Array[Token], CssError]
pub fn tokenize_bytes_with_options(src : Bytes, opts : ParseOptions) -> Result[Array[Token], CssError]
pub fn count_tokens(src : String) -> Result[Int, CssError]
pub fn count_non_ws_tokens(src : String) -> Result[Int, CssError]

// Stylesheet & Declaration Block Parser
pub fn parse_stylesheet(src : String) -> Result[Stylesheet, CssError]
pub fn parse_stylesheet_with_options(src : String, opts : ParseOptions) -> Result[Stylesheet, CssError]
pub fn parse_stylesheet_bytes(src : Bytes) -> Result[Stylesheet, CssError]
pub fn parse_declarations(src : String) -> Result[Array[Declaration], CssError]
pub fn parse_declarations_with_options(src : String, opts : ParseOptions) -> Result[Array[Declaration], CssError]

// Selectors Level 4 Specificity
pub val struct Specificity { pub ids : Int, pub classes : Int, pub elements : Int }
pub fn selector_specificity(selector : String) -> Result[Specificity, CssError]
pub fn selector_list_specificity(selectors : String) -> Result[Array[Specificity], CssError]
pub fn max_specificity(selectors : String) -> Result[Specificity, CssError]

// Media Queries Level 4
pub fn parse_media_query_list(src : String) -> Result[Array[MediaQuery], CssError]

// CSS Color Level 4 (hex, rgb/rgba, hsl/hsla, 148 named colors, transparent, currentcolor)
pub val struct Color { pub r : Int, pub g : Int, pub b : Int, pub a : Double, pub is_current_color : Bool }
pub fn parse_color(src : String) -> Result[Color, CssError]
pub fn Color::to_hex(self : Color) -> String
pub fn Color::to_css(self : Color) -> String
pub fn Color::to_minified_css(self : Color) -> String

// Serializer & Minifier
pub fn to_css(sheet : Stylesheet) -> String
pub fn minify(src : String) -> Result[String, CssError]
pub fn minify_with_options(src : String, opts : ParseOptions) -> Result[String, CssError]
pub fn minify_stylesheet(sheet : Stylesheet) -> String
```

## Example

```pion
import "css"

let src = "/* card */ .card > .title { color: #ffffff; margin: 0px 0.5rem; width: calc(10px + 20px); --gap:  12px ; }"
match css::parse_stylesheet(src) {
  Ok(sheet) => {
    let pretty = css::to_css(sheet)
    let compact = css::minify_stylesheet(sheet)
    let spec = css::selector_specificity("#app .card:not(.hidden)")
    let col = css::parse_color("rgb(255 0 128 / 50%)")
    let mq = css::parse_media_query_list("screen and (width >= 768px)")
    let _ = (pretty, compact, spec, col, mq)
  }
  Err(e) => {
    let _ = e.to_string()
  }
}
```

## Head-to-Head Benchmarks

Measured on `Darwin arm64` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved rotation, **mandatory stdout SHA-256 byte-for-byte verification** across all implementations and rounds).

- **Pion**: `packages/css` (`pionc build --release`)
- **Rust**: `cssparser =0.35.0` (`cargo build --release`, `opt-level = 3`, `lto = true`)
- **Node.js**: `css-tree@3.1.0` (`node v24.22.2`)
- **Corpus**: deterministic 2.09 MB realistic design-system CSS stylesheet (`6,000` component rules + `1,500` `@media` rules + `@font-face`, `calc(...)`, `!important`, custom properties `--ds-gap-*`, comments).

Reproduce with:

```sh
sh packages/css/bench/run_bench.sh
```

### Workload 1: Large Design-System CSS Tokenize (`5x` 2.09 MB = 10.44 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_cssparser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **29.686** | 28.064 | 30.724 | **351.75** | 5.78 MiB | **1.08x** |
| `rust_cssparser` | 32.088 | 29.818 | 32.929 | 325.42 | 3.81 MiB | 1.00x (baseline) |
| `node_csstree` | 131.138 | 126.901 | 145.367 | 79.63 | 67.45 MiB | 0.24x |

_SHA-256 verified identical across all implementations and rounds: `6f6fb94bb07de68e0f3ad3b25ccd54d4e49bc2be13b4f1a0102a45e8f26c7a85`._

### Workload 2: Stylesheet AST Parse + Rule/Declaration/Important Count (`3x` 2.09 MB = 6.27 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_cssparser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 114.701 | 107.574 | 154.690 | 54.62 | 47.75 MiB | 0.21x |
| `rust_cssparser` | **23.799** | 22.613 | 26.141 | **263.25** | 3.83 MiB | 1.00x (baseline) |
| `node_csstree` | 388.135 | 352.918 | 408.555 | 16.14 | 264.19 MiB | 0.06x |

_SHA-256 verified identical across all implementations and rounds: `4fe1f3226b3cda156d74bffa8cac013e7390e720fecf96ad6abe2c8de1cd4ec3`._

### Workload 3: CSS Minify Throughput (`2x` 2.09 MB = 4.18 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_cssparser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 124.818 | 123.266 | 132.286 | 33.46 | 49.53 MiB | 0.20x |
| `rust_cssparser` | **24.496** | 23.812 | 33.334 | **170.51** | 6.97 MiB | 1.00x (baseline) |
| `node_csstree` | 308.406 | 299.117 | 671.752 | 13.54 | 248.69 MiB | 0.08x |

_SHA-256 verified identical across all implementations and rounds: `d1fc6cd5cccb2251816137e6e2477b59d97906ea70bf1b6c1c3b5f95f304edaf`._

### Honest Performance Notes

- **Where Pion leads**:
  - On **streaming CSS tokenization** (Workload 1), Pion reaches **351.75 MB/s** (`1.08x` faster than Rust `cssparser`, `4.42x` faster than Node `css-tree`, and `11.7x` lower RSS than Node `css-tree`), thanks to the 256-byte LUT and zero-allocation scan loop.
  - Across **full AST parsing** (Workload 2) and **AST-based minification** (Workload 3), Pion is **3.38x** and **2.47x** faster than Node `css-tree` while using **5.0x–5.5x less memory** (47–50 MiB vs 248–264 MiB).
- **Where Pion currently trails Rust `cssparser`**:
  - In Workloads 2 and 3, `rust_cssparser` operates as a zero-AST streaming callback parser (3.8–7.0 MiB RSS) without materializing an intermediate `Vec<Token>` or full AST. In contrast, `packages/css` currently materializes a full `Array[Token]` before building `Stylesheet` AST nodes, and `minify` re-tokenizes each declaration value and prelude string.
  - Moving `parse_stylesheet` and `minify` to a single-pass streaming tokenizer (without materializing the intermediate `Array[Token]`) is the clearest path to closing the remaining gap with Rust `cssparser` while keeping RSS under 15 MiB.

## Verification

- `pionc fmt --check packages/css` — pass
- `pionc check --json packages/css` — pass (0 diagnostics)
- `pionc test --json packages/css` — **27 / 27 passed** (W3C CSS Syntax 3 tokenizer, stylesheet/declaration parser, Selectors Level 4 specificity, all 148 CSS Color 4 named colors + hex/rgb/hsl, Media Queries Level 4, serializer/minifier, and Day-1 red-team suite)
- `packages/css/wasm_smoke` — all 4 modes pass with exit code `0`:
  - Native debug & Native release
  - `wasm32` debug & `wasm32` release executed under `node ~/.pion/share/pion/pion_wasm_rt.mjs`
