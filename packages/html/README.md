# `html` — Pure-Pion HTML5 Parser, CSS Selector Engine & XSS Sanitizer

Pure-Pion, zero-C-dependency, Native + Wasm32 compatible **WHATWG HTML5 parser**, **CSS Selectors query engine**, and **`ammonia`-grade whitelist HTML XSS sanitizer** (`v0.1.0`), benchmarked head-to-head against Rust `scraper` (`html5ever`) + `ammonia` and Go `golang.org/x/net/html`.

## Features

- **Fault-Tolerant WHATWG HTML5 Parser (`Document::parse`, `Document::parse_fragment`)**
  - All HTML5 void elements (`area`, `base`, `basefont`, `bgsound`, `br`, `col`, `embed`, `frame`, `hr`, `img`, `input`, `keygen`, `link`, `meta`, `param`, `source`, `track`, `wbr`).
  - RAWTEXT (`script` with WHATWG escaped & double-escaped states, `style`, `xmp`, `iframe`, `noembed`, `noframes`, `noscript`) and RCDATA (`title`, `textarea`, with leading LF stripping on `<textarea>`, `<pre>`, `<listing>`).
  - **Complete 2,231 / 2,231 WHATWG named character references** (all 2,125 semicolon-terminated entries including multi-codepoint entities + all 106 legacy no-semicolon entities with text vs attribute context rules), plus numeric character references, `U+0000` → `U+FFFD` (or dropped in HTML body text), surrogate/overflow → `U+FFFD`, and full Windows-1252 `0x80..0x9F` remapping.
  - Fault-tolerant WHATWG tree building: implicit `html`/`head`/`body` (with duplicate `<html>`/`<body>` attribute merging, after-head `<head>` insertion, `<frameset>`/`<frame>`, and after-body/after-html content kept inside `<body>`), foster parenting, active formatting element reconstruction with **Noah's Ark clause** (at most 3 identical entries) and **bounded 8×3 adoption agency algorithm** (furthest block), element scope checks (default/button/list-item/table), `<select>` and `<ruby>` rules, `</p>`/`</br>`/`<image>`/`<a>`/`<nobr>`/`<form>`/`<button>` special cases, and SVG/MathML foreign content case adjustment (`viewBox`, `foreignObject`, etc.).
  - End-tag attribute tokenization (quoted `>` does not terminate end tags), EOF-in-tag token dropping, `=`-prefixed attribute names, and O(1) open-tag refcount pruning for stray end tags.
  - Iterative serialization (`to_html`, `outer_html`, `inner_html`) and `text_content`.
- **CSS Selectors Query Engine (`Selector`, `select`, `select_first`, `matches`)**
  - Type (`div`), universal (`*`), namespace prefixes (`*|li`, `|li`), `#id`, `.class`, strict CSS identifier validation, full CSS hex escapes (`#\31 23`, `#\31\32\33`), and attribute selectors (`[a]`, `[a=v]`, `[a~=v]`, `[a|=v]`, `[a^=v]`, `[a$=v]`, `[a*=v]`, WHATWG HTML ASCII case-insensitive attribute list, plus explicit `i`/`s` flags).
  - Combinators: descendant (`A B`), child (`A > B`), adjacent sibling (`A + B`), general sibling (`A ~ B`), and comma-separated selector lists (deduplicated in document order).
  - Pseudo-classes: `:first-child`, `:last-child`, `:only-child`, `:nth-child`, `:nth-last-child`, `:nth-of-type`, `:nth-last-of-type`, `:first-of-type`, `:last-of-type`, `:only-of-type`, `:empty`, `:root`, `:scope`, `:not(...)`, `:is(...)`, `:where(...)`, and `:has(...)`.
  - **100% iterative right-to-left matcher** with Servo-style `NotMatchedGlobally` and sibling-exhaustion cut-offs (eliminates exponential backtracking and Wasm32 stack overflow on 12,000+ child combinators) plus lazy O(N) `:nth-child` / `:nth-last-child` indexing.
- **`ammonia`-Grade Whitelist HTML XSS Sanitizer (`sanitize`, `Sanitizer::clean`, `Sanitizer::try_clean`)**
  - Safe default tag/attribute whitelist; strips `<script>`, `<style>`, `<iframe>`, `<object>`, `<embed>`, `<svg>`, `<math>`, `<noscript>`, `<xmp>`, `<textarea>`, `<title>`, etc. and their entire subtrees; unwraps non-whitelisted ordinary tags.
  - `add_tags` does **not** bypass `clean_content_tags` (enabling a clean-content tag requires an explicit `rm_clean_content_tags` call).
  - Strips all `on*` event handler attributes (even if allow-listed) and HTML comments by default.
  - Strict URL scheme whitelist (`http`, `https`, `mailto`, relative paths) covering `href`, `src`, `cite`, `action`, `formaction`, `poster`, `data`, `xlink:href`, `background` with ASCII whitespace/control-character normalization to block obfuscated schemes.
  - `try_clean` returns `Result[String, HtmlError]` so callers can observe limit errors explicitly.
- **Red-Team Defenses & Zero `World` Dependency**
  - Flat-array arena DOM (`NodeData` / `AttrData` `val struct`s + zero-copy source spans) with zero recursion across parsing, serialization, text extraction, selector traversal, and sanitization.
  - Configurable `Limits` (`max_depth`, `max_nodes`, `max_attributes`) returning explicit `Err(HtmlError { kind: LimitExceeded, ... })`.

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

## Verification & Conformance

- **Unit, Compliance & Red-Team Tests**: `pionc test packages/html` — **29/29 passed** (`html5_parser_test.pion`, `selector_test.pion`, `sanitizer_test.pion`, `redteam_test.pion`).
- **Red-Team Audit Suite**: `pionc test -p html_audit packages/html/audit` — **36/37 passed** (**25/25 `p1_*`**, **8/8 `control_*`**, **3/4 `p2_*`**; the sole intentional difference is `p2_sanitizer_scheme_allowlist_narrower_than_ammonia`, as Pion defaults to 3 safe URL schemes `http`/`https`/`mailto` rather than `ammonia`'s 25 schemes including `tel:`/`ftp:`).
- **WHATWG Named Character References**: **2,231 / 2,231 (100.0%)** in both text and attribute contexts, with **0 / 36** legacy/numeric edge differences vs `html5ever`.
- **html5lib Tree-Construction Suite (`9329e64`, scripting-on)**: **1,147 / 1,578 (72.69%)** overall (up from 44.17%; **90.2%** of the 1,272 tests not requiring `<svg ...>`/`<math ...>` namespace prefixes or `<template> content` in the audit dumper), with 100% on `blocks.dat`, `comments01.dat`, `entities01.dat`, `entities02.dat`, `ruby.dat`, `scriptdata01.dat`, `adoption02.dat`, and 16/17 on `adoption01.dat`.
- **XSS / mXSS Round-Trip & Idempotence (`scripts/xss.py`)**: **0 / 20,137** round-trip unsafe outputs (re-parsed by `html5ever`) and **0 / 20,137** non-idempotent outputs across both default and keep-comments modes.
- **CSS Selector Differential (`scripts/css_diff.py`)**: **139 / 141** identical to Rust `scraper` (the 2 remaining diffs are unclosed `[lang` / `[lang=en` at EOF, which Pion intentionally rejects as `InvalidSelector`).
- **4-Mode Native + Wasm32 Parity**: `packages/html/wasm_smoke` and `scripts/wasm4.py` (including 12,000-compound child combinators) are 100% byte-identical with 0 traps across Native debug/release and Wasm32 debug/release executed under Node.js.

## Head-to-Head Benchmarks

Run via `sh packages/html/bench/run_bench.sh` using `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved rotation, mandatory stdout SHA-256 parity) on **Darwin arm64** against pinned baselines:
- Rust `scraper = "=0.22.0"` (`html5ever 0.29.1`) + `ammonia = "=4.0.0"` (`cargo build --release`, `opt-level = 3`, `lto = "thin"`)
- Go `golang.org/x/net v0.35.0` (`go 1.27.3`)

### Bench 1: HTML5 Document Parse + Text/Link Extraction (20 rounds, 1,377,460 B)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_scraper`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **31.347** | 29.814 | 32.733 | **43.94** | **2.91 MiB** | **1.14x** |
| `go_net_html` | **24.969** | 22.554 | 25.792 | **55.17** | 11.48 MiB | 1.43x |
| `rust_scraper` | 35.603 | 33.965 | 38.610 | 38.69 | 3.58 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `d288e1dc3c38f7787b4573bfc647fff56c5308b8c49d25e0f7fd58a35637f211`._

### Bench 2: CSS Selector Query on Large DOM (50 rounds × 5 complex selectors = 250 queries)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_scraper`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 18.284 | 17.862 | 19.226 | 73,135 | **3.09 MiB** | **0.91x** (up from 0.45x) |
| `rust_scraper` | **16.559** | 15.915 | 17.961 | **66,238** | 3.56 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `af4b62ca244afbee8b7a38bfc72531a5c2be6fd03f96d9da816e9124bbd224d8`._

### Bench 3: HTML XSS Sanitization Throughput (20 rounds, 2,451,400 B)

Note: `rust_ammonia` is configured with `.add_clean_content_tags(["iframe"])` so both sanitizers enforce identical `<iframe>` subtree stripping and produce byte-for-byte identical sanitized HTML (`fnv64` verified).

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_ammonia`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **51.752** | 51.282 | 54.927 | **47.37** | **3.44 MiB** | **1.37x** |
| `rust_ammonia` | 70.666 | 67.387 | 71.797 | 34.69 | 4.78 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `07a42875443631f00e8fa857076d34f1c34e6b9d962b017c7cbc93251871b6ff`._

### Un-Curated / Adversarial Benchmarks (`audit/scripts/adv_bench.py`)

Bench 1–3 use a curated synthetic corpus; on un-curated real-world / adversarial corpora (`scripts/adv_bench.py`):
- **All 2,125 WHATWG `;`-entities ×40**: Pion **22.9 ms** vs Rust `html5ever` **103.7 ms** (**4.53x**, `same_output=True`).
- **`li:nth-child(2n+1)` on 20k siblings**: Pion **15.2 ms** vs Rust `scraper` **18.3 ms** (**1.20x**, `same_output=True`, down from 770 ms).
- **`li:last-child` / `li:first-of-type` / `[data-k$='7']` on 20k siblings**: Pion **13.2–14.2 ms** vs Rust **16.9–18.9 ms** (**1.19–1.43x**, `same_output=True`).
- **`section > article p > span em` (30k nodes)**: Pion **11.0 ms** vs Rust **12.1 ms** (**1.11x**, `same_output=True`).
- **`div.a div.b em` (30k nodes)**: Pion **17.1 ms** vs Rust **13.9 ms** (**0.81x**, `same_output=True`).
- **Filtered html5lib messy corpus ×40**: parse Pion **277.9 ms** vs Rust **322.2 ms** (**1.16x**) vs Go **230.1 ms**; sanitize Pion **217.8 ms** vs `ammonia` **265.0 ms** (**1.22x**).

### Honest Performance & Design Notes

- **Bench 2 root cause & optimization**: The original `0.45x` gap was caused by per-node traversal overhead (multiple 80-byte `NodeData` copies per visited node, `Node` handle + `String` attribute materializations, and per-candidate backtrack stack allocations), not missing Bloom filters. Switching full-document queries without reparenting to a flat linear arena scan with inline tag-length/first-byte filtering, zero-copy attribute span matching, and reusable backtrack scratch stacks doubled Bench 2 speed (`0.45x` → `0.91x`) and put Pion ahead of `scraper` on 20k-sibling pseudo-class queries (`1.19–1.43x`).
- **Sanitizer defaults vs `ammonia`**: Pion is intentionally stricter than `ammonia` in default configuration: it allows 3 URL schemes (`http`, `https`, `mailto`) instead of `ammonia`'s 25 (e.g. `tel:`, `ftp:`, `sms:` require explicit `add_url_schemes`), URL-checks `cite` on `<blockquote>`/`<q>`/`<del>`/`<ins>`, never emits `on*` attributes even if allow-listed, and strips `<textarea>`/`<noembed>`/`<noframes>`/`<plaintext>` subtrees by default.

## Scope & Known Limitations

- Public `Node` API currently exposes element tag names without a separate namespace accessor; SVG/MathML elements are parsed with foreign-content case adjustment and integration-point rules internally.
- `<template>` contents are stored as direct element children rather than a separate `DocumentFragment` wrapper.
- Unclosed attribute selectors at EOF (e.g. `[lang`) return `Err(InvalidSelector)` rather than auto-closing.
