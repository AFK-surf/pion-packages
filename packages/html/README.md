# `html` — Pure-Pion HTML5 Parser, CSS Selector Engine & XSS Sanitizer

Pure-Pion, zero-C-dependency, Native + Wasm32 compatible **WHATWG HTML5 parser**, **CSS Selectors query engine**, and **`ammonia`-grade whitelist HTML XSS sanitizer** (`v0.1.0`), benchmarked head-to-head against Rust `scraper` (`html5ever`) + `ammonia` and Go `golang.org/x/net/html`.

## Features

- **Fault-Tolerant WHATWG HTML5 Parser (`Document::parse`, `Document::parse_fragment`)**
  - All 14 HTML5 void elements (`area`, `base`, `br`, `col`, `embed`, `hr`, `img`, `input`, `link`, `meta`, `param`, `source`, `track`, `wbr`).
  - RAWTEXT (`script`, `style`, `xmp`, `iframe`, `noembed`, `noframes`, `noscript`) and RCDATA (`title`, `textarea`) tokenizer states.
  - Named & numeric HTML5 character references (decimal, hexadecimal, `U+0000` → `U+FFFD`, surrogate/overflow → `U+FFFD`, full Windows-1252 `0x80..0x9F` replacement table, and WHATWG legacy no-semicolon rules in text vs attribute context).
  - Fault-tolerant tree building: implicit `html`/`head`/`body` in document mode, auto-closing (`<p>`, `<li>`, `<dt>`/`<dd>`, `<option>`/`<optgroup>`, `<h1>`..`<h6>`), implicit `<tbody>`/`<tr>` and cell auto-closing in tables, formatting element adoption agency (`<b><i>1</b>2</i>` → `<b><i>1</i></b><i>2</i>`), abrupt comments (`<!-->`, `<!--->`), DOCTYPE, lowercase ASCII normalization, and first-wins duplicate attribute deduplication.
  - Iterative serialization (`to_html`, `outer_html`, `inner_html`) and `text_content`.
- **CSS Selectors Query Engine (`Selector`, `select`, `select_first`, `matches`)**
  - Type (`div`), universal (`*`), `#id`, `.class`, attribute selectors (`[a]`, `[a=v]`, `[a~=v]`, `[a|=v]`, `[a^=v]`, `[a$=v]`, `[a*=v]`, case-insensitivity flag `i`).
  - Combinators: descendant (`A B`), child (`A > B`), adjacent sibling (`A + B`), general sibling (`A ~ B`), and comma-separated selector lists (deduplicated in document order).
  - Pseudo-classes: `:first-child`, `:last-child`, `:only-child`, `:nth-child(an+b|odd|even)`, `:empty`, `:root`, `:first-of-type`, `:last-of-type`, and `:not(...)`.
- **`ammonia`-Grade Whitelist HTML XSS Sanitizer (`sanitize`, `Sanitizer`)**
  - Safe default tag/attribute whitelist; strips `<script>`, `<style>`, `<iframe>`, `<object>`, `<embed>`, `<svg>`, `<math>`, `<noscript>`, `<xmp>`, `<textarea>`, `<title>` and their entire subtrees; unwraps non-whitelisted ordinary tags.
  - Strips all `on*` event handler attributes and HTML comments by default.
  - URL scheme whitelist (`http`, `https`, `mailto`, relative paths) with ASCII whitespace/control-character normalization to block obfuscated payloads (`java&#x09;script:`, `&#106;avascript:`, `vbscript:`, `data:text/html`).
  - mXSS-hardened DOM-based serialization with automatic `rel="noopener noreferrer"` on links.
- **Day-1 Red-Team Defenses & Zero `World` Dependency**
  - Flat-array arena DOM (`NodeData` / `AttrData` `val struct`s + zero-copy source spans) with zero recursion across parsing, serialization, text extraction, selector traversal, and sanitization (**50,000 nested `<div>`s parse and serialize with 0 SIGSEGV**).
  - Configurable `Limits` (`max_depth`, `max_nodes`, `max_attributes`) returning explicit `Err(HtmlError { kind: LimitExceeded, ... })`.
  - Linear `O(N)` scaling on 50k attributes (automatic linear→`Map` dedup promotion at >16 attrs) and 50k alternating text/entity runs (single `StringBuilder` text merging).

## Quick Start

```pion
import "html"

pub fn example() -> Unit {
  let doc = match html::Document::parse("<!DOCTYPE html><body><main id=\"app\"><p class=\"lead\">Hello &amp; <b>Pion</b></p></main></body>") {
    Ok(d) => d
    Err(_) => return ()
  }
  let leads = match doc.select("main#app > p.lead") {
    Ok(v) => v
    Err(_) => []
  }
  let _ = leads[0].text_content() // "Hello & Pion"

  let safe = html::sanitize("<p onclick=\"alert(1)\">Hi <a href=\"javascript:alert(1)\">bad</a> <a href=\"https://example.com\">ok</a></p><script>evil()</script>")
  let _ = safe // "<p>Hi <a rel=\"noopener noreferrer\">bad</a> <a href=\"https://example.com\" rel=\"noopener noreferrer\">ok</a></p>"
}
```

## Verification

- **Unit, Compliance & Red-Team Tests**: `pionc test packages/html` — **29/29 passed** (`html5_parser_test.pion`, `selector_test.pion`, `sanitizer_test.pion`, `redteam_test.pion`).
- **Formatting & Typecheck**: `pionc fmt --check packages/html` and `pionc check --json packages/html` — 0 warnings, 0 errors.
- **4-Mode `wasm_smoke`**: `packages/html/wasm_smoke` builds and exits `0` across Native debug, Native release, Wasm32 debug, and Wasm32 release.

## Head-to-Head Benchmarks

Run via `sh packages/html/bench/run_bench.sh` using `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved rotation, mandatory stdout SHA-256 byte-for-byte parity) on **Darwin arm64** against pinned baselines:
- Rust `scraper = "=0.22.0"` (`html5ever 0.29.1`) + `ammonia = "=4.0.0"` (`cargo build --release`, `opt-level = 3`, `lto = "thin"`)
- Go `golang.org/x/net v0.35.0` (`go 1.27.3`)

### Bench 1: HTML5 Document Parse + Text/Link Extraction (20 rounds, 1,377,460 B)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_scraper`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **22.522** | 20.877 | 24.404 | **61.16** | **2.67 MiB** | **1.44x** |
| `go_net_html` | 23.388 | 22.726 | 23.992 | 58.90 | 11.50 MiB | 1.39x |
| `rust_scraper` | 32.428 | 32.305 | 34.827 | 42.48 | 3.58 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `d288e1dc3c38f7787b4573bfc647fff56c5308b8c49d25e0f7fd58a35637f211`._

### Bench 2: CSS Selector Query on Large DOM (50 rounds × 5 complex selectors = 250 queries)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_scraper`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 38.175 | 36.297 | 43.233 | 152,701.33 | **2.75 MiB** | **0.45x** |
| `rust_scraper` | **17.147** | 16.075 | 17.961 | **68,587.84** | 3.56 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `af4b62ca244afbee8b7a38bfc72531a5c2be6fd03f96d9da816e9124bbd224d8`._

### Bench 3: HTML XSS Sanitization Throughput (20 rounds, 2,451,400 B)

Note: `rust_ammonia` is configured with `.add_clean_content_tags(["iframe"])` so both sanitizers enforce identical `<iframe>` subtree stripping and produce byte-for-byte identical sanitized HTML (`fnv64` verified).

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_ammonia`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **34.302** | 30.910 | 36.100 | **71.47** | **3.22 MiB** | **2.02x** |
| `rust_ammonia` | 69.432 | 62.439 | 77.543 | 35.31 | 4.78 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `07a42875443631f00e8fa857076d34f1c34e6b9d962b017c7cbc93251871b6ff`._

### Honest Performance Analysis

- **Where Pion leads**:
  - **HTML5 Parsing (`1.44x` vs Rust `scraper`/`html5ever`, faster than Go `x/net/html` with `4.3x` lower RSS)**: flat-array `NodeData`/`AttrData` arena with zero-copy source spans eliminates per-node heap allocations, `Tendril` reference-counting overhead, and `string_cache` atom locking.
  - **XSS Sanitization (`2.02x` vs Rust `ammonia`)**: single-pass iterative DOM walk directly over the flat arena into one pre-sized `StringBuilder`, avoiding `ammonia`'s `rcdom` `Rc<RefCell<Node>>` tree mutations and secondary `html5ever` serialization pass.
- **Where Rust `scraper` leads**:
  - **Complex CSS Selector Queries (`0.45x` vs Rust `scraper`)**: `scraper` builds on Servo's `selectors` crate, which interns tag/class/attribute names as `LocalName` atoms (pointer-equality checks) and pre-filters ancestor chains with 64-bit Bloom filters. Pion `html` currently evaluates tag/attribute/class slices directly per visited element without atom interning or ancestor Bloom filters. Adding a flat tag-bucket index or ancestor Bloom filter is the primary optimization opportunity for `v0.2.0`.

## Scope & Known Limitations

- Named character references cover the high-frequency HTML5 entity set (160+ entities including Latin-1, Greek, math, arrows, punctuation, and all legacy no-semicolon entities) plus full numeric/Windows-1252 decoding; the full 2,125-entry WHATWG trie is deferred to `v0.2.0`.
- Foreign content integration points (SVG/MathML camelCase attribute/tag fixups) are not yet modeled separately from HTML elements.
- CSS Selectors cover CSS Selectors Level 3/4 core combinators, attribute operators (`i`/`s` flags), and structural/logical pseudo-classes (`:first-child`, `:last-child`, `:only-child`, `:nth-child`, `:empty`, `:root`, `:first-of-type`, `:last-of-type`, `:not(...)`); `:has()`, `:is()`, `:where()`, and `:nth-of-type()` are planned for `v0.2.0`.
