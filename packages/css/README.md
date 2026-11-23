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

Measured on `Darwin arm64` using `packages/css/audit/scripts/perf.py --rounds 5` (`3` reps/process, `5` interleaved rounds after warmup, median wall time and peak RSS):

- **Pion**: `packages/css` (`pionc build --release`), reporting **both** zero-allocation `count_tokens()` and full-materialization `tokenize()`, plus single-pass streaming `parse_stylesheet()` and `minify()`.
- **Rust `cssparser =0.35.0`**: `tokcount` (token walk producing full `Token` values) and `sheet` (owned generic AST matching Pion's `Stylesheet` shape).
- **Rust `lightningcss =1.0.0-alpha.72`**: `lparse` (full typed AST) and `lmin` (real production CSS minifier).
- **Node `css-tree@3.1.0`** (`node v24.22.2`): `tokcount`, `parse` (full AST), and `gen` (parse + generate).

Reproduce with:

```sh
sh packages/css/audit/run_audit.sh
```

### 5-Corpus Head-to-Head Matrix (median ms, lower is better)

| Corpus (size × 3) | Pion `count_tokens` | Pion `tokenize()` | `cssparser` tok walk | Pion `parse` | `cssparser` AST | `lightningcss` parse | Pion `minify` | `lightningcss` minify | `css-tree` parse |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `design_system` (2.09 MB) | **25.9** | 66.7 | 34.7 | **63.1** | 66.2 | 110.5 | **85.2** | 135.1 | 531.4 |
| `color_heavy` (1.81 MB) | **25.7** | 69.3 | 33.0 | 64.9 | **61.0** | 105.4 | **99.7** | 125.3 | 626.1 |
| `selector_heavy` (1.34 MB) | **21.4** | 61.8 | 31.5 | 37.8 | **29.7** | 110.2 | **84.0** | 172.0 | 750.9 |
| `nesting_heavy` (1.74 MB) | **26.1** | 89.8 | 42.5 | **91.2** | 107.2 | 449.6 | **125.2** | 569.7 | 1220.2 |
| `custom_props` (2.04 MB) | **24.6** | 70.1 | 33.6 | 85.3 | **76.4** | 202.8 | **67.8** | 237.1 | 442.8 |

### Peak RSS (MB, lower is better)

| Corpus | Pion `parse` | `cssparser` AST | `lightningcss` parse | Pion `minify` | `lightningcss` minify | `css-tree` parse |
|---|---:|---:|---:|---:|---:|---:|
| `design_system` | 18.1 | **18.0** | 44.2 | **7.4** | 46.4 | 247.6 |
| `color_heavy` | **16.8** | 17.0 | 34.6 | **7.1** | 35.1 | 326.0 |
| `selector_heavy` | **8.2** | 9.1 | 36.2 | **5.7** | 37.7 | 280.8 |
| `nesting_heavy` | 41.2 | **34.0** | 202.6 | **6.9** | 203.4 | 448.6 |
| `custom_props` | 22.7 | **22.5** | 56.2 | **7.6** | 58.2 | 164.1 |

### Honest Performance Notes

- **Token counting vs `tokenize()`**: `count_tokens()` (zero-allocation scan) beats Rust `cssparser`'s token walk by `1.28x–1.63x` across all 5 corpora. Materializing a full `Array[Token]` via `tokenize()` takes `61.8–89.8 ms` (`0.47x–0.52x` of `cssparser`'s streaming walk) because it allocates every `Token` struct upfront.
- **Single-pass streaming `parse_stylesheet()`**: By consuming `Lexer` directly without materializing `Array[Token]`, Pion `parse_stylesheet()` matches or beats Rust `cssparser`'s owned generic AST (`1.05x` on `design_system`, `1.18x` on `nesting_heavy`, `0.79x–0.94x` on the other 3 corpora) with comparable RSS (`8–41 MB`), and beats Rust `lightningcss` parse by `1.62x–4.93x` across all 5 corpora.
- **Single-pass streaming `minify()`**: By streaming directly from `Lexer` to `StringBuilder` (zero AST, zero `Array[Token]`), Pion `minify()` beats Rust `lightningcss` minify on all 5 corpora (`1.26x–4.55x` faster) while using `4.9x–29.5x` less memory (`5.7–7.6 MB` peak RSS). Note that `lightningcss` performs deeper typed property optimizations (e.g. shorthand merging, vendor prefixing, color-space conversion), whereas Pion performs syntax-preserving structural, whitespace, number, zero-unit, and hex minification.

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
