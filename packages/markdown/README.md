# `markdown` — Pure Pion CommonMark 0.31.2 + GFM + CJK-Friendly Markdown Parser & HTML Renderer

Idiomatic pure Pion port of Rust [`pulldown-cmark`](https://github.com/pulldown-cmark/pulldown-cmark) (`v0.13.1`, MIT License), targeting both **Native** (`arm64_apple`, `amd64_*`, etc.) and **WebAssembly (`wasm32`)** with zero C glue and zero `World` dependency.

## Upstream Reference & License

- **Upstream**: [`pulldown-cmark/pulldown-cmark`](https://github.com/pulldown-cmark/pulldown-cmark) `v0.13.1` (MIT)
- **Specification**: [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) + GitHub Flavored Markdown (GFM) Tables, Strikethrough, Task Lists, Autolink Literals + CommonMark CJK-friendly emphasis amendments (Unicode 17)

## Compliance & Test Coverage (`702 / 702` PASS)

| Suite | Passed | Notes |
| --- | ---: | --- |
| CommonMark 0.31.2 official `spec.txt` | **652 / 652** | 100% byte-for-byte HTML parity |
| GFM Tables (`gfm_table.rs`) | **9 / 9** | Column alignment, escaped pipes, paragraph interruption |
| GFM Strikethrough (`gfm_strikethrough.rs`) | **3 / 3** | Single `~` and double `~~` delimiters |
| GFM Task Lists (`gfm_tasklist.rs`) | **2 / 2** | Checked/unchecked checkboxes, nested lists |
| GFM Autolink Literals | **8 / 8** | `www.*`, `http(s)://*`, emails, trailing punctuation & parens |
| Smart Punctuation (`smart_punct.rs`) | **16 / 16** | Curly quotes, em/en dashes, ellipses |
| CJK-Friendly Emphasis (`cjk_friendly_emphasis.rs` + toggle) | **11 / 11** | Full Unicode 17 CJK ranges, IVS & variation selectors |
| Pathological 10k linear-time stress test | **1 / 1** | 10,000 `[` / `*a ` / `_a ` without quadratic blowup |
| Wasm32 Smoke (`wasm_smoke`) | **PASS** | `pionc build --target wasm32` + Node.js execution verified |

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
```

- `Options` (`val struct`): `tables`, `strikethrough`, `tasklists`, `autolinks`, `smart_punctuation`, `cjk_friendly`, with `Options::commonmark()` and `Options::gfm()`.
- `Event`, `Tag`, `TagEnd`, `Alignment`, `CodeBlockKind`, `LinkType`
- `parse(src : String, opts : Options) -> Array[Event]`
- `render_html(events : Array[Event]) -> String` (strict CommonMark 0.31.2 HTML)
- `render_html_pulldown(events : Array[Event]) -> String` (`pulldown-cmark::html::push_html` byte-for-byte formatting)
- `to_html(src : String, opts : Options) -> String`

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`, SHA-256 Verified)

Run via `scripts/bench_compare.py` with mandatory stdout SHA-256 byte-for-byte verification against Rust `pulldown-cmark 0.13.1` (`cargo build --release`, `opt-level = 3`, `lto = "thin"`).

### 1. CommonMark 0.31.2 `spec.txt` × 12 (`2,460,323 B` input → `2,692,692 B` HTML)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_pulldown_cmark`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_pulldown_cmark` | 16.917 | 15.885 | 17.440 | 145.43 | 13.06 MiB | 1.00x (baseline) |
| `pion_markdown` | 36.899 | 36.655 | 40.525 | 66.68 | 32.11 MiB | 0.46x |

- SHA-256 (identical across all implementations and rounds): `110321ab0d170585d613698c00eecaf17192fdbedff9f9585e887800d6da64d4`

### 2. Mixed GFM Corpus (`2,503,227 B` input → `4,976,832 B` HTML)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_pulldown_cmark`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_pulldown_cmark` | 22.699 | 20.658 | 23.618 | 110.28 | 25.81 MiB | 1.00x (baseline) |
| `pion_markdown` | 51.712 | 49.845 | 56.385 | 48.41 | 55.31 MiB | 0.44x |

- SHA-256 (identical across all implementations and rounds): `eb0ade9169dfd54fc25a08adb046413fa61bfb44182c6fd0a7310bb8aaf7eba3`

### Honest Bottleneck Analysis

`pion_markdown` achieves **44%–46%** of Rust `pulldown-cmark`'s throughput (~48–67 MB/s) on Apple Silicon with ~2.1–2.5× peak RSS. The remaining gap comes from three clear architectural factors:
1. **Materialized `Array[Event]` + `String` slices vs zero-copy streaming `CowStr<'a>`**: `parse()` materializes all `Event` objects and owned `PionString` slices (RC-allocated copies) in memory before `render_html()`, whereas Rust `pulldown-cmark` streams borrowed `&'a str` slices directly into `html::push_html` without intermediate event buffering.
2. **Backend codegen & SIMD**: Rust uses LLVM `-O3` + thin LTO + `memchr` NEON SIMD scanning for delimiter/escape searches, while `pionc` uses QBE scalar loops without SIMD intrinsics.
3. **Line-slice copying in Phase 1**: `BlockNode.lines` stores owned `String` slices per line; switching to `(start, end)` byte-offset spans referencing the normalized input string would eliminate most per-line allocations and roughly halve peak RSS.
