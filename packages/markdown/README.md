# `markdown` — Pure Pion CommonMark 0.31.2 + GFM + CJK-Friendly Markdown Parser & HTML Renderer

Idiomatic pure Pion port of Rust [`pulldown-cmark`](https://github.com/pulldown-cmark/pulldown-cmark) (`v0.13.1`, MIT License), targeting both **Native** (`arm64_apple`, `amd64_*`, etc.) and **WebAssembly (`wasm32`)** with zero C glue and zero `World` dependency.

## Upstream Reference & License

- **Upstream**: [`pulldown-cmark/pulldown-cmark`](https://github.com/pulldown-cmark/pulldown-cmark) `v0.13.1` (MIT)
- **Specification**: [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) + GitHub Flavored Markdown (GFM) Tables, Strikethrough, Task Lists, Autolink Literals + CommonMark CJK-friendly emphasis amendments (Unicode 17)

## Compliance & Test Coverage (`725 / 725` PASS)

| Suite | Passed | Notes |
| --- | ---: | --- |
| CommonMark 0.31.2 official `spec.txt` | **652 / 652** | 100% byte-for-byte HTML parity |
| GFM Tables (`gfm_table.rs`) | **9 / 9** | Column alignment, escaped pipes, paragraph interruption |
| GFM Strikethrough (`gfm_strikethrough.rs`) | **3 / 3** | Single `~` and double `~~` delimiters with strict flanking rules |
| GFM Task Lists (`gfm_tasklist.rs`) | **2 / 2** | Checked/unchecked checkboxes, empty markers, nested lists |
| GFM Autolink Literals | **8 / 8** | `www.*`, `http(s)://*`, `ftp://*`, `mailto:*`, `xmpp:*`, emails, entity & punct trimming |
| Smart Punctuation (`smart_punct.rs`) | **16 / 16** | O(N) single-pass curly quotes, em/en dashes, ellipses |
| CJK-Friendly Emphasis (`cjk_friendly_emphasis.rs` + toggle) | **11 / 11** | Full Unicode 17 CJK ranges, IVS & variation selectors |
| Pathological & Extended Tests (`extensions_test.pion` + 10k stress) | **7 / 7** | Iterative block rendering (50k+ nesting, 0 SIGSEGV), O(N) inline parsing, `parse_with_offsets`, footnotes, YAML/Pluses frontmatter |
| Tree AST & Plain-Text Extraction (`ast_plain_text_test.pion`) | **17 / 17** | Full `Document`/`Block`/`Inline` AST, GFM tables/tasklists/footnotes/frontmatter, grapheme-safe `max_chars` (CJK, Emoji ZWJ, combining marks, flags), `<script>`/`<style>` & HTML entity stripping, O(N) text coalescing, 50k `>` & 32k `- ` stack safety, AST vs Event consistency |
| Red-Team P0 / P1 Audit (`audit/tests/redteam_test.pion`) | **P0 6/6, P1 41/41, OK 8/8** | 0 SIGSEGV, 0 direct-vs-parse divergences across 85,152 differential cases |
| Red-Team v0.3.0 Audit (`audit_v030/run_audit.sh`) | **P1 7/7, P2 7/7, PRE 1/1, OK 10/10** | Full `FUZZ=20000` `exit 0`: 0 AST-vs-event mismatches, 0 `plain_text` invariant violations (`I1`–`I4`), 6/6 linear scaling probes, 19/19 4-mode SHA-256 parity |
| Upstream `pulldown-cmark 0.13.1` `table` / `strikethrough` / `regression` | **27/28, 14/15, 192/210** | 954 / 1,148 total across all upstream suites |
| Wasm32 & Native 4-Mode Smoke (`wasm_smoke`) | **PASS** | `native_dbg` / `native_rel` / `wasm_dbg` / `wasm_rel` all exit 0 with identical SHA-256 (incl. 50k `>` & 32k `- ` nesting, 0 Wasm32 `RangeError`) |

## Public API

```pion
import "markdown"

let html = markdown::to_html("# Hello **World**", markdown::Options::commonmark())

let gfm_html = markdown::to_html(
  "- [x] ~~old~~ **中文（测试）**文本",
  markdown::Options::{
    tables: true,
    strikethrough: true,
    tasklists: true,
    autolinks: true,
    smart_punctuation: false,
    cjk_friendly: true,
  },
)

// Flat event stream API
let events = markdown::parse(src, markdown::Options::gfm())
let rendered = markdown::render_html(events)

// v0.3.0 Structured Tree AST API (fully iterative, zero recursion)
let doc = markdown::parse_document(src, markdown::Options::gfm())
let ext_doc = markdown::parse_document_extended(src, markdown::ExtendedOptions::full())

// v0.3.0 Configurable Plain-Text Preview API (UTF-8 code-point safe truncation)
let preview = markdown::to_plain_text(
  src,
  markdown::Options::gfm(),
  markdown::PlainTextOptions::{
    image_placeholder: "[图片]",
    link_placeholder: "[链接]",
    code_block_placeholder: "[代码块]",
    math_placeholder: "[公式]",
    collapse_whitespace: true,
    max_chars: 120,
  },
)
let from_ast = doc.plain_text(markdown::PlainTextOptions::default())
```

- `Options` (`val struct`): `tables`, `strikethrough`, `tasklists`, `autolinks`, `smart_punctuation`, `cjk_friendly`, with `Options::commonmark()` and `Options::gfm()`.
- `ExtendedOptions` (`val struct`): wraps `base : Options` plus optional `footnotes`, `yaml_frontmatter`, `pluses_frontmatter`.
- `Event`, `OffsetEvent`, `Tag`, `TagEnd`, `Alignment`, `CodeBlockKind`, `LinkType`, `MetadataBlockKind`
- **Tree AST (`v0.3.0`)**: `Document`, `FrontMatter`, `Block`, `Inline`, `ListItem`, `TableCell`
  - `parse_document(src : String, opts : Options) -> Document`
  - `parse_document_extended(src : String, opts : ExtendedOptions) -> Document`
  - Note: `Inline::Math` and `PlainTextOptions.math_placeholder` are currently reserved for manually constructed or extension-transformed `Document` ASTs; the default CommonMark/GFM parser does not automatically parse `$...$` into `Inline::Math`.
- **Plain-Text Extraction (`v0.3.0`)**: `PlainTextOptions` (`PlainTextOptions::default()`)
  - `Document::plain_text(self : Document, pt_opts : PlainTextOptions) -> String`
  - `to_plain_text(src : String, opts : Options, pt_opts : PlainTextOptions) -> String`
  - `to_plain_text_extended(src : String, opts : ExtendedOptions, pt_opts : PlainTextOptions) -> String`
- `parse(src : String, opts : Options) -> Array[Event]`
- `parse_with_offsets(src : String, opts : Options) -> Array[OffsetEvent]` (source byte ranges `[start, end)` per event)
- `parse_extended(src : String, opts : ExtendedOptions) -> Array[Event]`
- `render_html(events : Array[Event]) -> String` (strict CommonMark 0.31.2 HTML)
- `render_html_pulldown(events : Array[Event]) -> String` (`pulldown-cmark::html::push_html` byte-for-byte formatting)
- `to_html(src : String, opts : Options) -> String` (direct zero-Event streaming HTML renderer)
- `to_html_pulldown(src : String, opts : Options) -> String` (direct zero-Event streaming `pulldown-cmark` HTML renderer)
- `to_html_extended(src : String, opts : ExtendedOptions) -> String` / `to_html_pulldown_extended(src : String, opts : ExtendedOptions) -> String`

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`, SHA-256 Verified)

Run via `scripts/bench_compare.py` with mandatory stdout SHA-256 byte-for-byte verification against Rust `pulldown-cmark 0.13.6` (`cargo build --release`, `opt-level = 3`, `lto = "thin"`), built with `pionc` (`AFK-surf/pion@a62689d5`).

### 1. CommonMark 0.31.2 `spec.txt` × 12 (`2,458,295 B` input → `2,690,436 B` HTML)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_pulldown_cmark`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_pulldown_cmark` | 16.869 | 15.778 | 18.345 | 145.73 | 13.03 MiB | 1.00x (baseline) |
| `pion_markdown` (`to_html_pulldown`) | 20.201 | 18.211 | 21.171 | 121.69 | 12.30 MiB | 0.84x |
| `pion_events` (`parse` + `render_html_pulldown`) | 23.980 | 22.771 | 25.473 | 102.52 | 19.31 MiB | 0.70x |

- SHA-256 (identical across all implementations and rounds): `a72cc1c4e54ce0990a10f277818f85a5e87db112e86b0bc84844b3c0ec54620a`

### 2. Mixed GFM Corpus (`2,503,227 B` input → `4,976,832 B` HTML)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_pulldown_cmark`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_pulldown_cmark` | 19.904 | 19.675 | 20.742 | 125.76 | 24.36 MiB | 1.00x (baseline) |
| `pion_markdown` (`to_html_pulldown`) | 23.326 | 22.677 | 23.943 | 107.31 | 18.44 MiB | 0.85x |
| `pion_events` (`parse` + `render_html_pulldown`) | 29.139 | 28.466 | 29.598 | 85.91 | 35.86 MiB | 0.68x |

- SHA-256 (identical across all implementations and rounds): `eb0ade9169dfd54fc25a08adb046413fa61bfb44182c6fd0a7310bb8aaf7eba3`

### 3. `v0.3.0` Tree AST & Plain-Text Throughput (Mixed GFM Corpus, `2,503,227 B`, `Darwin arm64`, `warmup=1`, `rounds=5`)

| Operation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| `to_html_pulldown` (regression check vs Rust `0.91x`, `21.543 ms`) | 23.704 | 21.792 | 24.299 | 105.60 | 18.44 MiB |
| `parse_document` (full tree `Document` AST) | 35.851 | 34.484 | 36.133 | 69.82 | 33.84 MiB |
| `to_plain_text` (full document, `collapse_whitespace: true`) | 41.174 | 39.394 | 43.375 | 60.80 | 34.88 MiB |
| `to_plain_text` (`max_chars: 120` preview with placeholders) | 34.076 | 30.610 | 36.293 | 73.46 | 33.86 MiB |

### 4. O(N²) DoS Elimination (`sh packages/markdown/audit/run_audit.sh`)

| Pathological input | v0.1.0 | P49 (current) | Interleaved vs `pulldown-cmark` |
| --- | ---: | ---: | ---: |
| `nested_strong_emph` (224 KB) | 6,019 ms | **8.4 ms** | **1.01x** (56 KB) |
| `smart_quotes_nested` (64 KB) | 1,039 ms | **5.7 ms** | 1.1x |
| `unclosed_comments` (64 KB) | 280 ms | **3.5 ms** | **1.04x** (128 KB) |

50k nested `>` blockquotes and 32k nested lists run with 0 SIGSEGV; 3-way differential across 85,152 cases has `0` `direct != events` divergences.

### Honest Bottleneck Analysis

With `StringBuilder::with_capacity` + `StringBuilder::write_substring` (`pion_strbuf_push_slice`), 4×-unrolled 256-byte LUT HTML escaping, zero-allocation `val struct LinkInfo` span links, zero-tuple ref-def/fence scanners, top-level block & simple inline fast paths, and reduced RC traffic in `scan_inlines_to_ctx` / `process_emphasis`, `pion_markdown` reaches **84%–85%** of Rust `pulldown-cmark --release` end-to-end (**121.7 MB/s** CommonMark, **107.3 MB/s** Mixed GFM; in-process compute `9.16 ms` vs Rust `5.82 ms` on CommonMark and `12.11 ms` vs Rust `9.01 ms` on Mixed GFM) while using **6%–24% less Peak RSS than Rust** (`12.30 MiB vs 13.03 MiB` on CommonMark, `18.44 MiB vs 24.36 MiB` on Mixed GFM).

The remaining **~3.1–3.3 ms** compute gap is attributable to two `pionc` / QBE codegen limits verified via ARM64 disassembly:
1. **Scalar QBE byte scanning vs NEON SIMD `memchr`**: Rust uses 16 B/cycle NEON `memchr` (~0.23 ms total across 7.5 MB of scans), whereas QBE compiles scalar loops (~1.0–1.3 ms per 2.5 MB pass across line-end scanning, inline trigger scanning, and HTML escaping).
2. **`[0, 255]` LUT BCE does not propagate across function parameters**: `FixedArray::make(256, ...)` created locally triggers LUT BCE, but `Array[Byte]` / `FixedArray[Byte]` passed as a parameter (even with `if tbl.length() != 256`) still emits `cmp; b.hs _pion_panic_oob` on every byte lookup in `write_html_escaped_span_lut` and `skip_plain_inline`.
