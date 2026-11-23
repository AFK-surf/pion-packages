# Red-team audit: `packages/html` (Wave 7) vs html5ever / ammonia / Go x/net/html

- Target: `origin/feat/pkg-html` @ `0df3d6c` (html src last changed in `a1f4d91`), Pion `bee7628`, Darwin arm64.
- References: Rust `scraper =0.22.0` (`html5ever 0.29.1`, `selectors 0.26`), `ammonia =4.0.0`, Go `golang.org/x/net v0.35.0`, html5lib-tests `9329e64` (last commit with `tree-construction/`), WHATWG entity table (2,231 entries, from `markup5ever 0.14.1`).
- Reproduce everything: `sh packages/html/audit/run_audit.sh` (`QUICK=1` for a short run). Artifacts go to `/private/tmp/redteam-html`; nothing is written into the repo.
- Unit evidence: `pionc test -p html_audit packages/html/audit` → **37 tests, 29 FAIL (`p1_`/`p2_`, each asserting the oracle's output), 8 `control_` PASS**.

## Verdict

| Area | Result |
|---|---|
| P0 XSS / mXSS (default `sanitize`, and `set_strip_comments(false)`) | **No bypass found.** 137 hand vectors + 20,000 grammar-fuzz inputs; every output re-parsed by real html5ever: 0 scripts / foreign elements / `on*` / `javascript:`·`vbscript:`·`data:` URLs. Design is safe-by-construction (all text escaped, only allow-listed tags/attrs emitted, URL check on the decoded value, output re-escapes `&`). |
| P1 sanitizer config | `add_tags(["script"])` / `add_tags(["style"])` silently yields live `<script>`/`<style>` (ammonia refuses this config). |
| P1 DoS | Exponential selector backtracking (308-byte doc → 1.3 s, 608-byte doc → >60 s, 14 KB sibling list → >60 s; scraper ≤ 25 ms). Adoption-agency clone amplification (5 KB → 251,004 nodes / 1.76 MB sanitized; 8 KB → `sanitize()` returns `""`). `:nth-child` O(n²) (~40× slower than scraper on 20k siblings). |
| P1 spec conformance | html5lib tree-construction **44.17 %** (697/1578) vs html5ever 92.46 % vs Go 96.20 %. 87.6 % of WHATWG named references not decoded. 22/141 selector differences vs scraper. Several tokenizer differentials make Pion's DOM show elements a browser never builds. |
| Wasm32 4 modes | All corpora byte-identical across native debug/release and wasm32 debug/release, **executed** under node, no trap — except a wasm-only `RangeError` (stack) on a 12,000-compound child selector (native fine). |
| Benchmarks | Bench 1/3 inputs are curated to the subset Pion implements; on un-curated input outputs diverge from html5ever/ammonia, so the SHA-parity claims do not generalise. README's root-cause for Bench 2 (`0.45x`) is wrong: Pion is ~4× slower even for a selector that matches nothing. |

Where Pion is **better** than the references is listed at the end (it is real and worth keeping).

---

## P0 — XSS / mXSS on `sanitize` / `Sanitizer` (no finding)

Method (`scripts/xss.py`): Pion `sanitize` → output re-parsed by html5ever as a `<body>` fragment → flag any `script/iframe/svg/math/style/object/embed/form/…`, any non-HTML namespace, any `on*`/`style`/`srcdoc` attribute, any URL attribute whose WHATWG-parsed scheme is not http/https/mailto. Also checks idempotence and the keep-comments configuration.

| Corpus | Pion round-trip unsafe | ammonia round-trip unsafe |
|---|---:|---:|
| 137 vectors (mXSS classics from the brief, `noscript`/`textarea`/`title`/`xmp`/`template`/`iframe srcdoc`, CDATA in SVG, `--!>`, abrupt comments, 40+ URL obfuscations incl. `&#x09;`, `&#0000106;`, `&colon;`, NBSP/ZWSP/BOM/NUL prefixes, duplicate `href`, `REL` case, `srcset`/`formaction`/`poster`/`cite`) | **0** | 5 (`cite="javascript:…"` kept on blockquote/q/del/ins — ammonia does not URL-check `cite`; `ftp:`/`tel:` allowed by its scheme list) |
| 20,000 fuzz (seed 1337) | **0** | – |
| same, `set_strip_comments(false)` | **0** | – |

Why it holds: `Sanitizer::clean` (`src/sanitizer.pion:384`) re-serializes from Pion's own tree, escapes *all* text (even inside raw-text parents), emits only allow-listed tag/attribute names, and checks URLs on the decoded value while re-escaping `&` on output, so a parser differential cannot turn into an executable construct. Comment data can never contain `-->`/`--!>` (`src/parser.pion:1040`), so keep-comments is also safe.

Non-security observations from the same run:
- 6/20,137 outputs are **not idempotent** (`sanitize(sanitize(x)) != sanitize(x)`): e.g. `<table><desc>…<td>` emits `<table>…<td>` with no `<tbody><tr>`, which the next pass repairs. Cause: implicit `tbody/tr` only inserted when `<table>` is the current node.
- 34/137 vector outputs differ from ammonia (data loss on `<textarea>`/`<plaintext>`/`<noembed>`/`<noframes>`/SVG text that ammonia keeps escaped; raw NUL kept, see P2-3).

## P1 findings

### F-1 Sanitizer config footgun: one `add_tags` call enables live `<script>` / `<style>`
`Sanitizer::add_tags` (`src/sanitizer.pion:184`) also sets the tag to `false` in `clean_content_tags`. `Sanitizer::default().add_tags(["script"]).clean("<script>alert(document.cookie)</script>")` returns the script verbatim (text inside is not executable-escaped because JS needs no `<>&`). ammonia 4.0.0 asserts that no clean-content tag is also allowed (`lib.rs:1790`) — enabling script requires an explicit `rm_clean_content_tags`. Same with `style` (CSS injection). Tests: `p1_add_tags_script_yields_executable_script`, `p1_add_tags_style_yields_css_injection`.

### F-2 Adoption-agency clone amplification (memory / output DoS)
`handle_end_tag` (`src/parser.pion:813`) re-opens *every* formatting element above the matched one, with no Noah's-Ark clause and no 8-outer/3-inner loop bounds. `"<i>"*M + "<b>"*N + "</i>"*M` costs M·N nodes.

| 5,000-byte input (M=N=500) | nodes | peak RSS | sanitize output |
|---|---:|---:|---:|
| Pion | **251,004** | 31 MB | **1,757,000 B (351×)** |
| html5ever / ammonia | 1,004 | 3 MB | 7,000 B |

At M=N=1000 (8 KB) Pion exceeds `max_nodes` and `sanitize()` returns `""` for the whole document (see P2-1). Tests: `p1_adoption_agency_*`.

### F-3 Tokenizer differentials (Pion's DOM ≠ browser DOM for the same bytes)
- End tags are scanned to the first `>` (`src/parser.pion:1154`) instead of tokenizing attributes: `</div title="><img src=x>">` → Pion builds an `<img>`, browsers/html5ever build nothing.
- No script-data (double-)escaped states (`scan_raw_or_rcdata`, `src/parser.pion:864`): `<script><!--<script></script><img src=x>--></script>` → Pion ends the script early and builds `<img>`; html5ever keeps all of it inside the script. Also makes Pion's own `to_html()` not round-trip in a browser.
- EOF inside a tag emits the element (`<img src=x onerror=alert(1)//` → `<img src="x">`); WHATWG drops the token.
- Attribute name starting with `=` is skipped, CR/LF not normalised inside RAWTEXT, NUL not dropped/replaced.

Not XSS through `sanitize` (see P0), but any consumer that uses Pion's DOM to *decide* things about HTML a browser will render (link extraction, "contains no images" checks, scraping) sees elements that do not exist. Tests: `p1_end_tag_attributes_hide_markup`, `p1_script_double_escaped_state_missing`, `p1_eof_in_tag_drops_token`.

### F-4 Tree construction: 44.17 % of html5lib-tests
`scripts/html5lib_suite.py` (scripting-on, document tests + `body`-context fragment tests, verbatim html5lib dump):

| Implementation | passed / 1578 |
|---|---:|
| **Pion** | **697 (44.17 %)** |
| html5ever 0.29.1 (scraper) | 1459 (92.46 %) |
| Go x/net/html | 1518 (96.20 %) |

Files at 0 %: `tests8/9/10/11/12/22/23/24`, `tricky01`, `adoption02`, `tests_innerHTML_1`, `plain-text-unsafe`, `namespace-sensitivity`. Missing algorithms: foster parenting, active-formatting reconstruction, real adoption agency (furthest block), element-in-scope checks for end tags (`</div>` closes through `<td>`), `</p>`/`</br>` special cases, `<image>`, nested `<a>`/`<nobr>`/`<form>`/`<button>`, "after body"/"after after body" modes (content after `</html>` is appended **after the root element** and serialised outside `<html>`), head-after-head, `<body>`/`<html>` attribute merging, frameset, `<textarea>`/`<pre>` leading newline, template contents, foreign content (SVG/MathML case fix-ups, `viewBox` → `viewbox`). One `p1_tree_*` test per item.

### F-5 Named character references: 1,955 / 2,231 missing (87.6 %)
`scripts/entities.py` feeds every WHATWG entry in text and in attribute values: Pion decodes 276; html5ever decodes all. Includes common ones (`&rarr;` `&check;` `&Abreve;` …), legacy no-semicolon forms such as `&Aacute`, and all multi-code-point references (`&NotEqualTilde;`, `&fjlig;`, `&bne;`, `&ThickSpace;`). The legacy attribute rule (`&copy=1`, `&notit;`) and numeric edge cases do match html5ever (control test). README documents the gap ("deferred to v0.2.0"); recorded here for the numbers.

### F-6 CSS selector differential (22 / 141 vs scraper, identical trees)
`scripts/css_diff.py`:
- CSS hex escapes are wrong: `#\31 23` / `#\31\32\33` match nothing (parser copies the next byte instead of decoding hex, `src/selector.pion:44`).
- Invalid selectors accepted: `#123`, `.1a`, `#-`, `123` (scraper: parse error).
- HTML's case-insensitive attribute list not applied: `[lang|=EN]`, `[type=text]` vs `type="TEXT"` (scraper matches).
- Unsupported (error): `:nth-last-child`, `:nth-of-type`, `:nth-last-of-type`, `:only-of-type` (README does not list these as gaps), `:is` / `:where` / `:has` (listed), `:scope`, `*|li`.
- `[lang` / `[lang=en` without `]` rejected (cssparser closes at EOF) — minor.

### F-7 Exponential selector backtracking (CPU DoS)
`match_complex_at` (`src/selector.pion:940`) retries every ancestor / previous sibling for every compound with no "not matched globally" cut-off (Servo `selectors` has one). Measured (`scripts/dos.py`):

| Input | Pion | scraper |
|---|---:|---:|
| 308 B (60 nested divs + `<p>`), `section div div div div div p` | 1.26 s | 0.008 s |
| 608 B (120 nested), same selector | **> 60 s (killed)** | 0.012 s |
| 22 KB (50 × 40 nested), `section div div div div p` | 0.91 s; 44 KB: 26.3 s | 0.007 s / 0.013 s |
| 14 KB (`<p>` × 2000), `h1 ~ p ~ p ~ p` | **> 60 s** | 0.025 s |

### F-8 `:nth-child` is O(siblings) per element → O(n²)
`elem_child_index_1based` walks all previous siblings for every candidate. `li:nth-child(2n+1)` over 20,000 `<li>`: **Pion 770 ms vs scraper 19.4 ms (0.03×)** (parse excluded); `:last-child`/`:first-of-type` on the same doc are fine (1.5–1.6× faster than scraper).

### F-9 Quadratic end-tag / p-scope scans (parity with references, but slower)
Every start tag that closes `<p>` scans the whole open stack and every end tag scans to `html`/`body` (`src/parser.pion:510`, `:794`). All three engines are quadratic on these shapes, Pion is just the slowest on stray end tags:

| Input | Pion | html5ever | Go |
|---|---:|---:|---:|
| 50k nested `<div>` (550 KB) | 4.41 s (×2: 8.4 s) | 1.99 s (×2: 13.5 s) | 9.74 s (×2: 42.5 s) |
| 25k `<div>` + 25k `</span>` (300 KB) | 2.78 s (×2: 15.0 s) | 0.57 s (×2: 2.8 s) | 2.65 s (×2: 10.7 s) |
| sanitize, 25k `<div>` + 25k `</span>` | 2.21 s (×2: 13.2 s) | 0.65 s (×2: 2.5 s) | – |

## P2 findings

1. **Silent data loss on limits** (`p2_sanitize_silently_empties_on_limit`): `Sanitizer::clean` returns `""` on any `HtmlError` (`src/sanitizer.pion:385`). 250 KB of `<table><tr><td>` (4 open elements per repetition → `max_depth` 65,536) wipes the whole document; html5ever/ammonia process it fine. There is no API to learn that this happened.
2. **Wasm32-only trap**: `match_complex_at` is recursive (README claims "zero recursion … selector traversal"). A 72 KB child-combinator chain (`div > div > …`, 12,000 compounds) traps with `RangeError: Maximum call stack size exceeded` on wasm32 debug and release while native returns `ok 1` (native survives 50,000; scraper native aborts at 50,000). Only relevant when selectors are attacker-supplied.
3. **Raw NUL in output**: text and attribute NULs are kept and emitted by `sanitize`/`to_html`; WHATWG replaces them with U+FFFD (attributes) or drops them (body text). ammonia emits U+FFFD.
4. **"ammonia-grade" defaults differ** from ammonia: 3 URL schemes vs ammonia's 25 (`tel:`, `ftp:`, `sms:`, `xmpp:` … dropped), no `align`/`char`/`charoff`/`hr size` attributes, `details open` allowed (ammonia drops), many more clean-content tags (Pion drops `textarea`/`noembed`/`plaintext` content that ammonia keeps escaped). Stricter is fine for safety; it is not drop-in.
5. Non-idempotent sanitize output for tables (see P0 section).

## Wasm32 4-mode run (executed, not just compiled)

`scripts/wasm4.py` builds `audit/probe` four ways and runs the wasm builds with `node ~/.pion/share/pion/pion_wasm_rt.mjs`:

| Corpus | records | 4-mode identical |
|---|---:|:---:|
| html5lib `#data` → tree dump (document) | 1792 | yes |
| html5lib `#data` → tree dump (fragment) | 1792 | yes |
| html5lib `#data` → `to_html` | 1792 | yes |
| XSS vectors + 3k fuzz → `sanitize` | 3137 | yes |
| same → keep-comments sanitize | 3137 | yes |
| 141 selectors × doc | 282 | yes |
| stress (5k nesting, adoption 200×200, 20k entities, 50k `&`, 3k attrs, 3k tables, U+0001..U+1FFF) → tree / sanitize | 7 + 7 | yes |
| 50k nested `<div>` parse & sanitize | – | yes (no trap) |
| 12,000-compound child selector | – | **no: wasm `RangeError`, native ok** (P2-2) |

## Benchmark fairness (`packages/html/bench`)

1. **Bench 2 root cause is mis-stated.** README attributes the `0.45x` to missing atom interning / Bloom filters. Per-query cost on the Bench 2 document (parse excluded, 2,000 reps):

   | selector | Pion | scraper |
   |---|---:|---:|
   | `zz` (matches nothing) | 67.7 µs | 16.7 µs |
   | `*` | 69.8 µs | 15.8 µs |
   | `td` | 66.6 µs | 17.2 µs |
   | `.summary` | 98.8 µs | 19.1 µs |

   A selector that fails on the first tag compare is already 4× slower, so the gap is per-node traversal overhead in `select_descendants` → `selector_matches_id` → `match_complex` → `match_compound` (three 80-byte `NodeData` copies per visited node, `Node` handle + attribute `String` materialisation in `match_attr`), not matching sophistication. A Bloom filter would not close it. (`:nth-child` adds F-8 on wide lists.)
2. **Bench 1 / Bench 3 corpora are curated to the implemented subset.** `gen_data.py` only uses entities Pion has (`&mdash; &ldquo; &copy; &bull;`), no misnesting, no foster-parented text, no `tel:`/`align`, and Bench 3 adds `iframe` to ammonia's clean-content set so outputs coincide. Bench 1 only checks aggregate counters. On un-curated input (`scripts/adv_bench.py`) outputs diverge: filtered html5lib corpus ×40 → Pion 418,812 nodes vs html5ever 396,603; sanitize → Pion 1,907,280 B vs ammonia 3,250,596 B. Part of Pion's parse/sanitize speed-up comes from not running the algorithms html5ever runs (active formatting list, scope checks, foster parenting, `Url::parse` in ammonia).
3. Un-curated timings for the record (median of 5, interleaved): parse messy corpus Pion 76.0 ms vs html5ever 299.4 ms vs Go 216.2 ms; 2,125 entities ×40 Pion 51.5 ms vs 116.4 ms vs Go 18.5 ms (Pion mostly skips them: 92 % are not decoded); sanitize Pion 102.2 ms vs ammonia 300.6 ms.

## Where Pion beats the references (controls, must keep passing)

- Sanitizer is stricter than ammonia: URL-checks `cite` (ammonia keeps `cite="javascript:…"`), never emits `on*` even if allow-listed, blocks NUL/C0-obfuscated schemes.
- 20,000 nested `:not(` → clean `InvalidSelector` error; scraper/selectors **aborts the process** (stack overflow). 50,000-compound child chain on native: Pion fine, scraper aborts.
- 50k distinct attributes: Pion 10 ms, html5ever 373 ms (×2 size: 1.78 s, quadratic dedup).
- 50k nested `<div>` at ×2 size: Pion 8.4 s vs html5ever 13.5 s vs Go 42.5 s (Pion grows ~linearly here, the others quadratically).
- 10 MB comment: Pion 14 ms / 21 MB vs html5ever 115 ms / 42 MB vs Go 38 ms / 60 MB.
- Raw text (`script`/`style`) serialised verbatim, void elements without end tags, legacy attribute entity rule (`&copy=1`) correct.

## Files

```
audit/pion.toml, redteam_test.pion   html_audit package: 29 failing p1_/p2_ evidence tests + 8 control_ tests
audit/probe/                         Pion length-framed batch probe (tree/html/san/sanc/sel/one)
audit/rust/                          oracle: scraper 0.22.0 + ammonia 4.0.0 + html5ever re-parse checker
audit/go/                            oracle: golang.org/x/net/html v0.35.0
audit/scripts/html5lib_suite.py      html5lib tree-construction scoring (3 engines)
audit/scripts/xss.py                 P0 vectors + fuzz + html5ever round-trip + idempotence
audit/scripts/entities.py            2,231 WHATWG references, text + attribute
audit/scripts/css_diff.py            141 selectors vs scraper
audit/scripts/dos.py                 DoS / complexity probes (x1/x2 growth, RSS, timeouts kill the process group)
audit/scripts/wasm4.py               native debug/release vs wasm32 debug/release parity (executed)
audit/scripts/adv_bench.py           un-curated head-to-head timings
audit/run_audit.sh                   runs all of the above
```
