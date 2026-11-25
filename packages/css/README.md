# `css`

Pure Pion **W3C CSS Syntax Level 3** (2019+) tokenizer, fault-tolerant single-pass streaming stylesheet & declaration-block AST parser, **Selectors Level 4** validator & specificity calculator, **Media Queries Level 4** iterative parser, **CSS Color Level 4** parser (148 named colors + hex/rgb/hsl/hwb/lab/lch/oklab/oklch/`color()`/`none`), and CSS formatter / single-pass streaming minifier.

- **Zero C dependencies / zero `World` dependency** — compiles and runs identically on **Native** and **`wasm32`** (byte-identical SHA-256 across all 4 modes: Native/Wasm32 × debug/release).
- **W3C CSS Syntax Level 3 (2019+) tokenizer** — 256-byte ASCII classification LUT, zero-copy fast paths for unescaped identifiers/strings/numbers, `\r\n`/`\r`/`\f` → `\n` and NUL (`\u{0000}`) → `U+FFFD` preprocessing, WHATWG maximal-subpart invalid UTF-8 replacement in both `String` and `Bytes` entry points, full CSS escapes, IEEE-754 `-0` sign preservation, `Ident`, `Function`, `AtKeyword`, `Hash(Id | Unrestricted)`, `Str`/`BadString`, `Url`/`BadUrl`, `Number`/`Percentage`/`Dimension`, `Cdo`/`Cdc`, `Delim`, `Whitespace`, punctuation, and O(N) unclosed-EOF comments. (`<unicode-range-token>` removed per CSS Syntax 3 2019 so `u+a` selectors tokenize accurately.)
- **100% iterative, single-pass streaming parser, selector validator, media parser & minifier (0 recursion)** — explicit heap stacks everywhere (`parser.pion`, `selector.pion`, `media.pion`, `serialize.pion`); `parse_stylesheet` and `minify` consume a zero-allocation streaming `Lexer` without materializing an intermediate `Array[Token]`; CSS Nesting preserves exact declaration / nested-rule source order in both `to_css` and `minify`; custom properties (`--*`) preserve `{}` block values, `!important`, and CSS Variables 1 whitespace semantics; `minify` obeys W3C CSS Syntax 3 §9.2 token-separation rules and is 100% idempotent.
- **Day-1 security & resource budgets** — configurable `ParseOptions { max_depth, max_tokens, max_rules }` (default `256` block depth / `10_000_000` non-whitespace tokens / `500_000` rules), verified linear O(N) with 0 crashes against 50,000-level nested `{`/`(`/ `[` / `@media {` / `:is(` / `calc(`, 10 MB unclosed comments/strings, and 1 MB escape runs.

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

// Stylesheet & Declaration Block Parser (single-pass streaming)
pub fn parse_stylesheet(src : String) -> Result[Stylesheet, CssError]
pub fn parse_stylesheet_with_options(src : String, opts : ParseOptions) -> Result[Stylesheet, CssError]
pub fn parse_stylesheet_bytes(src : Bytes) -> Result[Stylesheet, CssError]
pub fn parse_declarations(src : String) -> Result[Array[Declaration], CssError]
pub fn parse_declarations_with_options(src : String, opts : ParseOptions) -> Result[Array[Declaration], CssError]

// Selectors Level 4 Validation & Specificity
pub val struct Specificity { pub ids : Int, pub classes : Int, pub elements : Int }
pub fn selector_specificity(selector : String) -> Result[Specificity, CssError]
pub fn selector_list_specificity(selectors : String) -> Result[Array[Specificity], CssError]
pub fn max_specificity(selectors : String) -> Result[Specificity, CssError]

// Media Queries Level 4 (100% iterative)
pub fn parse_media_query_list(src : String) -> Result[Array[MediaQuery], CssError]

// CSS Color Level 4 (hex, rgb/rgba, hsl/hsla, hwb, lab, lch, oklab, oklch, color(), none, 148 named colors)
pub val struct Color { pub r : Int, pub g : Int, pub b : Int, pub a : Double, pub is_current_color : Bool }
pub fn parse_color(src : String) -> Result[Color, CssError]
pub fn Color::to_hex(self : Color) -> String
pub fn Color::to_css(self : Color) -> String
pub fn Color::to_minified_css(self : Color) -> String

// Serializer & Single-Pass Streaming Minifier
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
    let col = css::parse_color("oklch(0.6 0.1 200)")
    let mq = css::parse_media_query_list("screen and (width >= 768px)")
    let _ = (pretty, compact, spec, col, mq)
  }
  Err(e) => {
    let _ = e.to_string()
  }
}
```

## Head-to-Head Benchmarks (Like-for-Like)

Measured on `Linux x86_64` using the 5-corpus adversarial suite (`packages/css/audit/scripts/perf.py` corpora, `3` reps/process, `5` strictly interleaved rounds after warmup, median wall time and kernel peak RSS):

- **Pion**: `packages/css` (`pionc build --release`), reporting **both** zero-allocation `count_tokens()` and full-materialization `tokenize()`, plus single-pass streaming `parse_stylesheet()` and `minify()`.
- **Rust `cssparser =0.35.0`**: `tokcount` (token walk producing full `Token` values) and `sheet` (owned generic AST matching Pion's `Stylesheet` shape).
- **Rust `lightningcss =1.0.0-alpha.72`**: `lparse` (full typed AST) and `lmin` (real production CSS minifier).

Reproduce with:

```sh
sh packages/css/audit/run_audit.sh
```

### 5-Corpus Head-to-Head Matrix (median ms, lower is better)

| Corpus (size × 3) | Pion `count_tokens` | Pion `tokenize()` | `cssparser` tok walk | Pion `parse` | `cssparser` AST | `lightningcss` parse | Pion `minify` | `lightningcss` minify |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `design_system` (2.09 MB) | **20.5** | 81.8 | 39.6 | **82.8** (`1.14x`) | 94.3 | 189.4 | **67.2** (`4.02x`) | 270.1 |
| `color_heavy` (1.81 MB) | **21.2** | 99.6 | 43.0 | **54.1** (`1.88x`) | 101.5 | 202.8 | **100.9** (`2.44x`) | 246.0 |
| `selector_heavy` (1.34 MB) | **15.3** | 94.0 | 31.4 | **21.4** (`2.11x`) | 45.2 | 195.5 | **48.0** (`5.00x`) | 239.9 |
| `nesting_heavy` (1.74 MB) | **21.5** | 89.8 | 42.1 | **77.2** (`1.63x`) | 125.9 | 548.1 | **95.6** (`6.39x`) | 610.5 |
| `custom_props` (2.04 MB) | **23.7** | 76.4 | 36.9 | **46.9** (`2.15x`) | 101.0 | 188.0 | **40.4** (`4.36x`) | 176.3 |

### Peak RSS (MB, lower is better)

| Corpus | Pion `parse` | `cssparser` AST | `lightningcss` parse | Pion `minify` | `lightningcss` minify |
|---|---:|---:|---:|---:|---:|
| `design_system` | **15.1** | 19.4 | 40.8 | **14.0** | 42.6 |
| `color_heavy` | **16.0** | 19.1 | 34.5 | **14.0** | 35.5 |
| `selector_heavy` | **14.0** | 14.0 | 37.1 | **14.0** | 39.5 |
| `nesting_heavy` | **32.6** | 36.5 | 181.0 | **14.0** | 182.7 |
| `custom_props` | **18.0** | 24.3 | 51.4 | **14.0** | 53.4 |

### Honest Performance Notes

- **Token counting vs `tokenize()`**: `count_tokens()` (zero-allocation scan) beats Rust `cssparser`'s token walk by `1.56x–2.05x` across all 5 corpora. Materializing a full `Array[Token]` via `tokenize()` takes `76.4–99.6 ms` because it allocates every `Token` struct upfront.
- **Single-pass streaming `parse_stylesheet()`**: Using module-level LUTs, zero-`Result`-boxing streaming `Lexer`, fast byte-level prelude/declaration scanners, `val struct` parse frames, and shared scratch buffers with exact-capacity AST slicing, Pion `parse_stylesheet()` beats Rust `cssparser`'s owned generic AST on **all 5 corpora** (`1.14x` on `design_system`, `1.88x` on `color_heavy`, `2.11x` on `selector_heavy`, `1.63x` on `nesting_heavy`, `2.15x` on `custom_props`) while matching or beating `cssparser` peak RSS across all 5 corpora (`14.0–32.6 MB` vs `14.0–36.5 MB`), and beats Rust `lightningcss` parse by `2.29x–9.14x`.
- **Single-pass streaming `minify()`**: By streaming directly from `Lexer` to `StringBuilder` with zero-allocation hex/unit/function checks, Pion `minify()` beats Rust `lightningcss` minify on all 5 corpora (`2.44x–6.39x` faster) while using `2.5x–13.1x` less memory (`14.0 MB` peak RSS). Note that `lightningcss` performs deeper typed property optimizations (e.g. shorthand merging, vendor prefixing, color-space conversion), whereas Pion performs syntax-preserving structural, whitespace, number, zero-unit, and hex minification.

## Verification

- `pionc fmt --check packages/css` — pass
- `pionc check --json packages/css` — pass (0 diagnostics)
- `pionc test --json packages/css` — **32 / 32 passed**
- `pionc test --json -p css_audit packages/css/audit` — **34 / 34 passed** (0 P0/P1/P2/control failures)
- `sh packages/css/audit/run_audit.sh`:
  - `tok_diff.py` (17,904 cases + 2,014 raw-byte inputs): **99.85%** `pion==cssparser`, **2,014 / 2,014 (100%)** `tokenize_bytes==cssparser(lossy)`, **0** invalid UTF-8 in `tokenize(String)`
  - `minify_diff.py` (2,114 cases): **0 / 1,991 (0.0%)** generated semantic breaks, **0** `to_css` semantic breaks, **0** strict-parser rejections, **0** non-idempotent cases
  - `dos.py` (20 probes × N/2N): **20 / 20** linear, **0** crashes
  - `wasm4.py` (12 corpora × 4 modes): **12 / 12** byte-identical SHA-256 across Native debug/release & Wasm32 debug/release under Node, **0** traps
- `packages/css/wasm_smoke` — all 4 modes pass with exit code `0`
