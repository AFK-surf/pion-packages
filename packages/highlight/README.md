# `highlight`

Pure Pion zero-allocation, line-state incremental syntax highlighting engine (16 core languages + Markdown), designed to replace JavaScript `shiki` / `prismjs` across `still.fail`, `board`, and `invar/code_field`.

Zero regex backtracking, zero JavaScript, zero C glue, zero `World` dependency, `Send`-safe immutable value types, and dual-target verified on **Native (`arm64_apple`)** and **WebAssembly (`wasm32`)**.

## Supported Languages (17 Languages & Aliases)

| Language | Canonical & Aliases | Highlights & Incremental State |
| --- | --- | --- |
| `Pion` | `pion`, `mbt`, `moonbit` | Nested `/* /* */ */` comments, `#|` multiline raw strings, `\{expr}` interpolation, `#verify` attributes, `pub val struct` |
| `Rust` | `rust`, `rs` | Nested `/* /* */ */` comments, `r#"..."#` / `r##"..."##` raw strings, lifetimes `'a` vs chars `'x'`, `#[derive]` / `#![no_std]`, `println!` macros, `std::` namespaces |
| `Go` | `go`, `golang` | Backtick `` `...` `` multiline raw strings, runes, `:=` / `<-` channel ops, `/* */` comments |
| `TypeScript` | `typescript`, `ts`, `tsx`, `mts`, `cts` | Multiline template literals `` `...${expr}...` `` with nested braces, `@Decorator`, TS type keywords & builtins, BigInt `1_000n` |
| `JavaScript` | `javascript`, `js`, `jsx`, `mjs`, `cjs` | Multiline template literals with `${...}` interpolation, `/* */` comments, ES operators (`===`, `??`, `?.`, `...`) |
| `Python` | `python`, `py`, `py3`, `pyi` | Multiline `"""..."""` / `'''...'''` strings, prefixed `f"`/`r"`/`b"` strings, `@decorator`, `#` comments, `:=`/`//`/`**` |
| `C` | `c`, `h` | Preprocessor `#include`/`#define`/`#ifdef`, `/* */` comments, `42UL`/`0xFFu`/`1.5f` suffixes |
| `Cpp` | `cpp`, `c++`, `cc`, `cxx`, `hpp`, `hh`, `hxx` | `template`/`constexpr`/`noexcept`/`nullptr`, `std::` namespaces, `[[nodiscard]]` attributes, `1'000'000ULL` digit separators |
| `Json` | `json`, `jsonc`, `jsonl` | Property keys `"k":` vs string values `"v"`, JSONC comments, scientific numbers, `true`/`false`/`null` |
| `Toml` | `toml` | `[table]` & `[[array]]` headers, dotted keys `a.b = 1`, multiline `"""..."""` / `'''...'''`, `#` comments |
| `Yaml` | `yaml`, `yml` | Mapping keys, `|`/`>` multiline block scalars (indentation-tracked), `&anchor`/`*alias`, `---` separators |
| `Sql` | `sql`, `postgres`, `postgresql`, `mysql`, `sqlite` | Case-insensitive keywords & types, `--` and `/* */` comments, `'O''Brien'` doubled-quote strings |
| `Shell` | `shell`, `sh`, `bash`, `zsh`, `shellscript` | `#!` shebang & `#` comments, `$VAR`/`${VAR:-default}`/`$?`, quotes, pipes & redirects |
| `Html` | `html`, `htm`, `xml`, `svg`, `xhtml`, `markup` | Tags, multiline attributes, `<!-- -->` multiline comments, `<!DOCTYPE>`, embedded `<script>` (JS) & `<style>` (CSS) |
| `Css` | `css`, `scss` | Selectors (`.cls`, `#id`), `@media` at-rules, properties, `#hex` colors, numeric units (`16px`, `1.5rem`, `100%`), `!important` |
| `Diff` | `diff`, `patch` | `diff --git`, `---`/`+++`, `@@ ... @@` headers, `+` added lines, `-` deleted lines |
| `Markdown` | `markdown`, `md` | Headings, fenced code blocks ```` ``` ```` / `~~~`, inline `` `code` ``, blockquotes, links |

## Architecture

1. **Zero-Allocation Byte Scanner (`src/scanner_util.pion`, `src/keywords.pion`)**:
   - Single-pass O(n) byte scanner (`src[i]`) with zero intermediate substring allocations in the hot path.
   - First-byte-dispatched keyword/type/constant classifiers (`eq_word` / `eq_word_ci`) — no hash-table or regex overhead.
2. **Compact `val struct` Spans & Incremental `LineState` (`src/types.pion`, `src/api.pion`)**:
   - `Span { start, end, kind }` slices directly into the original `String` by byte offset.
   - `LineState { mode, depth, delim }` packs cross-line state (nested block comment depth, Rust raw string `#` count, JS/TS template `${...}` brace depth, Python/TOML triple-quotes, HTML comment/tag/`<script>`/`<style>`, YAML block scalar indent, Markdown fence) into three integers.
   - `highlight(lang, src)` runs the exact same line scanner as `highlight_line(lang, state, line)` without splitting into substrings, guaranteeing **100% span-for-span equivalence** between full-file and line-by-line incremental highlighting.
3. **HTML Serializer (`highlight_html`)**:
   - Emits `<span class="hl-...">...</span>` with full HTML entity escaping (`&`, `<`, `>`, `"`, `'`), leaving `Plain` text unwrapped and newlines outside spans.

## Public API

```pion
pub enum Language { Pion, Rust, Go, TypeScript, JavaScript, Python, C, Cpp, Json, Toml, Yaml, Sql, Shell, Html, Css, Diff, Markdown }
pub enum TokenKind { Plain, Keyword, Type, Function, String, Number, Comment, Operator, Punctuation, Constant, Attribute, Property, Tag, Variable, Namespace, DiffAdd, DiffDel, DiffHeader }
pub val struct Span { pub start : Int, pub end : Int, pub kind : TokenKind }
pub val struct LineState { pub mode : Int, pub depth : Int, pub delim : Int }

pub fn LineState::initial() -> LineState
pub fn resolve_language(name : String) -> Option[Language]
pub fn token_kind_class(k : TokenKind) -> String
pub fn highlight(lang : Language, src : String) -> Array[Span]
pub fn highlight_line(lang : Language, state : LineState, line : String) -> (Array[Span], LineState)
pub fn highlight_html(lang : Language, src : String) -> String
```

## Verification & Head-to-Head Benchmark

- **Tests**: **204 tests** across `languages_test.pion` (32), `systems_lang_test.pion` (48), `scripting_lang_test.pion` (40), `data_web_lang_test.pion` (48), and `invariants_test.pion` (36 — including 17-language incremental `highlight_line` == `highlight` exact span equivalence, full byte coverage, UTF-8 CJK/Emoji, unclosed delimiters, and 10 KB adversarial O(n) stress tests).
- **Wasm32**: `pionc build --target wasm32 packages/highlight/wasm_smoke -o /tmp/highlight_smoke.wasm` (passes with 0 errors).
- **Head-to-Head Benchmark** (`Darwin arm64`, 9 languages: Rust, TypeScript, Go, Python, JSON, YAML, C, CSS, HTML; 37,800 B × 220 = **8,316,000 B**, `--warmup 1 --rounds 5`, strictly interleaved, mandatory SHA-256 verification of lossless reconstructed source bytes):

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `node-prismjs`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `node-prismjs` (Node v24.22.2) | 1354.656 | 1230.325 | 1715.957 | 6.14 | 87.48 MiB | 1.00x (baseline) |
| `pion-highlight` (Native `--release`) | 112.973 | 110.089 | 125.756 | 73.61 | 2.31 MiB | **11.99x** |

_SHA-256 verified identical across all implementations and rounds: `1fec95f5f26869f0e95b351d3f462b36a883947e103e513529b074855eceeb80` (428 B)._

### Token Granularity Comparison (1 iteration = 9 files, 37,800 B)

| Language | Source Bytes | `pion-highlight` Spans | `node-prismjs` Leaves |
| --- | ---: | ---: | ---: |
| `rust` | 7,451 | 2,071 | 1,975 |
| `typescript` | 5,799 | 1,703 | 1,643 |
| `go` | 4,363 | 1,363 | 1,231 |
| `python` | 5,107 | 1,167 | 1,111 |
| `json` | 2,639 | 859 | 803 |
| `yaml` | 2,943 | 559 | 463 |
| `c` | 4,039 | 1,403 | 1,311 |
| `css` | 2,607 | 871 | 667 |
| `html` | 2,852 | 836 | 804 |
| **Total** | **37,800** | **10,832** (5,876 non-plain, 18 `TokenKind`s) | **10,008** (6,424 typed tokens) |
