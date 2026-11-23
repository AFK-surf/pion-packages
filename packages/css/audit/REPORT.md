# Red-team audit: `packages/css` vs Rust `cssparser` / `lightningcss` and Node `css-tree`

Target: `packages/css` at `7d19ec4` (branch `feat/pkg-css`), Pion `pionc 0.1.0` (`AFK-surf/pion@81b8fb0`), Darwin arm64.

Oracles, pinned in `rust/Cargo.lock` and `node/package.json`:

| Oracle | Version | Used for |
|---|---|---|
| Rust `cssparser` | `=0.35.0` | token stream; a generic CSS Syntax 3 + Nesting AST built on `StyleSheetParser`/`RuleBodyParser` |
| Rust `cssparser-color` | `=0.3.0` (the `cssparser 0.35` line) | CSS Color 4 |
| Rust `lightningcss` | `=1.0.0-alpha.72` (`parcel_selectors`, a fork of Servo `selectors`) | specificity, media queries, semantic normal form for minify, full AST and real minifier timings |
| Node `css-tree` | `3.1.0` | second token oracle, AST timings |

Reproduce everything with one command (about 2 minutes). All build outputs go to `/private/tmp/redteam-css`, and `git status --porcelain --ignored` stays empty:

```sh
sh packages/css/audit/run_audit.sh            # QUICK=1 for a smaller run
```

| Part | Contents |
|---|---|
| `redteam_test.pion` | 34 tests: 3 `p0_`, 15 `p1_`, 9 `p2_` (each failure is evidence) and 7 `control_` tests that must pass |
| `probe/` | Pion batch probe (`tok`, `tokb`, `sheet`, `decls`, `min`, `css`, `spec`, `color`, `mq`, `one`), built in 4 modes |
| `rust/` | `oracle` binary: cssparser, cssparser-color and lightningcss, in the same dump format |
| `node/oracle.js` | css-tree token dump and timings |
| `scripts/tok_diff.py` | 17,904-case token differential (205 hand-written cases + grammar/byte fuzz), plus 2,014 raw-byte inputs |
| `scripts/struct_diff.py` | AST (3,076 sheets), declarations, specificity (93), color (79), MQ (49) |
| `scripts/minify_diff.py` | 2,114 inputs; checks `lightningcss(x) == lightningcss(pion_minify(x))` |
| `scripts/dos.py` | 20 crash and complexity probes at sizes N and 2N, under `/usr/bin/time -l` |
| `scripts/wasm4.py` | Native debug/release and Wasm32 debug/release, all executed under node, compared by SHA-256 |
| `scripts/perf.py` | 5 corpora × 12 implementation modes, interleaved rounds, median, peak RSS |

`pionc test --json -p css_audit packages/css/audit` gives `total=34 passed=7 failed=27`: all 27 p0/p1/p2 tests fail, which is the evidence, and all 7 controls pass. The package's own suite is untouched: `pionc test --json packages/css` still gives 27/27, and `fmt` and `check` are clean.

---

## P0: silent semantic corruption in the main outputs

### P0-1: CSS Nesting declaration order is lost in the AST, `to_css` and `minify`

`QualifiedRule`/`AtRule` store `declarations` and `nested_rules` in two separate arrays (`src/types.pion`). The order between them cannot be represented, so every serialization moves trailing declarations above every nested rule.

Browsers with nested-declarations rules (Chrome 130+, Firefox 132+, Safari 18.2+) and lightningcss keep trailing declarations in place. In the cascade they come after the nested rule.

| | Output |
|---|---|
| input | `.a{ @media (min-width:600px) { color: red } color: blue }` |
| lightningcss | `.a{@media (min-width:600px){color:red}color:#00f}` → blue on wide screens |
| Pion `minify` | `.a{color:blue;@media (min-width:600px){color:red}}` → **red** on wide screens |
| Pion `to_css` | same reordering (`p0_nesting_trailing_declaration_hoisted_by_to_css`) |

Tests: `p0_nesting_trailing_declaration_hoisted_by_minify`, `p0_nesting_trailing_declaration_hoisted_by_to_css`.

`minify_diff.py` shows this reordering is one of exactly two causes of every `to_css` semantic change (246/2,114). The other is P1-4.

### P0-2: `minify` deletes descendant combinators inside `:is()`, `:not()`, `:where()`, `:has()` and `@supports selector()`

`minify_prelude` treats `Colon` as tight whenever `paren_depth > 0` (`src/serialize.pion:125`/`135`). A space before `:` inside parentheses is a descendant combinator, and it gets deleted.

| Input | Pion output | Meaning before → after |
|---|---|---|
| `:is(div :hover)` | `:is(div:hover)` | any hovered element inside a div → a hovered div |
| `:where(.prose :first-child)` | `:where(.prose:first-child)` | |
| `:not(a :focus)` | `:not(a:focus)` | |
| `:has(a :hover)` | `:has(a:hover)` | |
| `@supports selector(a :hover)` | `@supports selector(a:hover)` | |

There is no error, and different elements match. This is the largest bucket of generated-corpus breaks: 346 of 735. Test: `p0_minify_drops_descendant_combinator_in_is_not_where_has`.

---

## P1

| # | Finding | Evidence (input → Pion; oracle) | Test |
|---|---|---|---|
| P1-1 | **minify glues tokens.** Comments are kept in the raw value, then dropped on re-tokenization with no separator. `+` is stripped from signed numbers without checking the previous token. | `margin:1px/**/2px` → `1px2px`; `font:12px/**/Arial` → `12pxArial`; `border:1px/*w*/solid/*s*/red` → `1pxsolidred`; `margin:1px+2px` → `1px2px`; `z-index:1+2` → `z-index:12`. lightningcss: `1px 2px` / `12px Arial` / `1px solid red`. | `p1_minify_comment_removal_glues_tokens`, `p1_minify_plus_sign_strip_glues_numbers` |
| P1-2 | **`0px` → `0` inside math functions that are not on the whitelist.** Only calc/min/max/clamp are recognized. A unit-less 0 in `<length> ± <number>` is a type error, so the declaration becomes invalid. | `round(0px + 10px, 1px)` → `round(0 + 10px,1px)` (lightningcss: `10px`); same for abs/mod/rem/sign/hypot/atan2, `-webkit-calc`, `-moz-calc` and `calc-size` (9/9 cases). 235 generated breaks. | `p1_minify_zero_unit_in_unlisted_math_functions` |
| P1-3 | **Escaped units are corrupted, and minify is not idempotent.** The numeric part is cut at `raw.length() - decoded_unit.length()`. | `width:1\70 x` (=1px) → `1\70px` (unit `ppx`), and a second pass gives `1\7ppx`. `1p\78` → `1p\px`. | `p1_minify_escaped_unit_corrupted` |
| P1-4 | **A custom property whose value contains a `{}` block becomes a nested rule.** The value and `!important` are lost. | `.a{--x:{a;b}; color:red}` → minify `.a{color:red;--x:{}}`. `--x:{a:b} !important` → `--x:{a:b}` (now a rule). cssparser and lightningcss: declaration `--x` = `{a;b}`. 184 generated breaks. | `p1_custom_property_block_value_becomes_nested_rule`, `p1_custom_property_block_value_loses_important` |
| P1-5 | **The `<unicode-range-token>` removed from CSS Syntax 3 in 2019 is still emitted.** This breaks `u+…` selectors. | `tokenize("u+a")` = `UnicodeRange(10,10)`; cssparser and css-tree give `u` `+` `a`. Specificity: `u+a` (0,0,0) vs (0,0,2); `.u+a` (0,0,0) vs (0,1,1); `u+b > i` (0,0,1) vs (0,0,3). 473 of the 550 token deviations found only in Pion. | `p1_unicode_range_token_breaks_u_plus_selectors` |
| P1-6 | **Top-level recovery is not CSS Syntax 3.** `;` and `}` do not end a qualified-rule prelude, so browsers drop the whole rule. Pion keeps a valid-looking rule. Top-level `@media` also accepts bare declarations. | `a; b{color:red}`: Pion rule `b`; cssparser prelude `a; b` (dropped by browsers). `}a{x:y}` → `a` vs `}a`. `@media screen{color:red;b{x:y}}` keeps `color:red`; cssparser yields one rule `color: red; b`. | `p1_top_level_semicolon_and_brace_recovery`, `p1_top_level_media_accepts_bare_declarations` |
| P1-7 | **Default limits reject entire real stylesheets with no partial result.** `max_tokens` = 2,000,000 counts whitespace tokens. `max_depth` = 256 counts `(`, `[` and functions anywhere in the sheet. | A 5.55 MB utility sheet (45k components, 90k rules) gets `ERR token limit exceeded` from parse, minify and tokenize; cssparser, lightningcss and css-tree all parse it. One 300-deep value causes `.ok{color:red}` to be lost too; the oracles keep 2 rules. | `p1_default_max_tokens_rejects_realistic_5mb_sheet`, `p1_default_max_depth_rejects_entire_sheet` |
| P1-8 | **Specificity APIs never reject an invalid selector** (only `""`). 23 of 93 selectors that lightningcss rejects get a value. | `a..b`=(0,1,1), `##a`=(1,0,0), `a,`=(0,0,1), `{`=(0,0,0), `:not()`=(0,0,0), `a::before.b`=(0,1,2), `a \|\| b`=(0,0,2) … | `p1_invalid_selectors_accepted` |
| P1-9 | **MQ4 grammar violations are accepted with a wrong meaning.** | `not (a) and (b)` → `Not(And(a,b))` (invalid in MQ4). `(100px < width > 50px)` and `(400px <= width >= 100px)` mix range directions. `screen and (a) or (b)` is accepted. `print,` → `[print, all]`, which matches every medium (lightningcss drops the empty query). | `p1_media_query_grammar_violations_accepted`, `p1_media_query_trailing_comma_matches_all` |
| P1-10 | **Legacy color syntax is too permissive.** | `rgb(255, 0%, 0)` mixes number and percentage; `hsl(0, 100, 50)` has unit-less S/L in comma syntax. Both are accepted; cssparser-color rejects them and browsers drop the declaration. | `p1_color_legacy_syntax_violations_accepted` |

## P2

| # | Finding | Test |
|---|---|---|
| P2-1 | Color 4 `none` is unsupported (`rgb(none 0 0)` → Err; cssparser-color → `0 0 0 1`). | `p2_color_none_keyword_unsupported` |
| P2-2 | An unclosed function is rejected, but EOF should close it (`rgb(1 2 3`). | `p2_color_unclosed_function_rejected` |
| P2-3 | `hwb()`, `lab()`, `lch()`, `oklab()`, `oklch()` and `color()` are not supported. All six parse in cssparser-color. | `p2_color4_spaces_unsupported` |
| P2-4 | Custom property values are not trimmed (`--x:  12px ;` → `"  12px "`; spec and cssparser give `12px`). Interior comments also stay in declaration values and `to_css` output, which is what feeds P1-1. | `p2_custom_property_whitespace_not_trimmed` |
| P2-5 | `<!--`/`-->` are skipped inside blocks, not only at the top level (`.a{<!-- color:red}` keeps `color:red`; cssparser drops it). | `p2_cdo_inside_block_skipped` |
| P2-6 | The sign of `-0` is lost (`0.0 - 0.0`). All 83 numeric token differences are this, and nothing else. | `p2_negative_zero_sign_lost` |
| P2-7 | `::slotted(.a)` ignores its argument: (0,0,1) instead of (0,1,1). | `p2_slotted_argument_specificity_ignored` |
| P2-8 | `tokenize_bytes` emits one U+FFFD per invalid byte, not per WHATWG maximal subpart (`E2 82` → 2× U+FFFD). Separately, `tokenize`, `parse_stylesheet` and `minify(String)` pass invalid UTF-8 through to token values and output (1,865 of 2,014 random byte inputs). | `p2_tokenize_bytes_not_maximal_subpart` |
| P2-9 | minify is not idempotent: 3 of 2,114 inputs (`12pxArial` → `12pxarial`, and the escaped-unit cases). | `p2_minify_not_idempotent` |
| P2-10 | Lower-impact points. Specificity is not capped (`.a`×2000 = (0,2000,0); parcel_selectors caps at 1023). Limit errors always report `line 1, col 1`. Inline-style `parse_declarations` silently drops at-rules and recovers differently from cssparser on `a:b}c:d` / `{x}a:b` (6/14 differ). The README's "100% iterative" claim does not cover `media.pion` (`parse_media_condition` is recursive, bounded by `max_depth`). | (struct_diff output) |
| P2-11 | **The README benchmarks are not like-for-like** (details in the Performance section). W1 times the zero-allocation `count_non_ws_tokens`, not `tokenize()`. W3's Rust "minifier" is a hand-written whitespace stripper (`bench/rust_bench`). The bench's Rust `tokenize` and `minify` modes recurse per block and abort on 50k nested `{` (`rust_css tokenize|minify <50k file> 1` → rc=134, "has overflowed its stack"). | perf.py, dos.py |

---

## Fairness: dimensions with no defect found, and places Pion beats the oracles

- **Tokenizer.**
  - 17,904 cases: Pion matches cssparser in **96.61%** and css-tree in 86.65%. cssparser and css-tree match each other only in 89.59%.
  - The 550 deviations found only in Pion are 473 unicode-range cases (P1-5), the `-0` sign (P2-6) and one hash-flag fold.
  - url / BadUrl recovery, escapes (EOF, newline, >0x10FFFF, surrogates, `\0`), `1e+` / `+.5` / `1.2.3`, CDO/CDC, unclosed comments and strings, and `\r\n` handling all agree.
  - **Pion is more correct than cssparser 0.35** on `-\` + newline, `@-\` + newline and `#-\` + newline. CSS Syntax 3 §4.3.9 says these are not ident starts. cssparser emits ident `-`, at-keyword `-` and id-hash; css-tree agrees with Pion. These are 21 cases (`control_escape_newline_not_ident_start`).
- **No crash at all, linear everywhere.** All 20 DoS probes at N and 2N show growth of 2.2× or less; there is no quadratic path. 50k nesting of `{`, `(`, `[`, `@media`, `:is(` and `calc(` returns a clean `LimitExceeded` in Pion. On the same inputs, **cssparser-based recursion and lightningcss abort with a Rust stack overflow (SIGABRT)**: nested `{` and `@media` crash both, and `:is(` and `calc(` crash lightningcss. Linear inputs include a 10 MB unclosed comment or string, a 1 MB escape run, 100k declarations, 50k-selector lists and 200k stray `}`.
- **Wasm32.** All 12 corpora, including every 50k stress input, give **byte-identical** output across Native debug, Native release, Wasm32 debug and Wasm32 release, with the wasm builds actually executed under node. There were no traps.
- **Strings, urls, calc and `!important`.**
  - `content:"/* x */"`, `url(http://a/*b*/)`, `calc(100% - 0px)` and `margin:10px -5px` survive minify unchanged.
  - `!/*c*/important`, `! important` and `!IMPORTANT` are recognized.
  - minify never produced CSS that lightningcss's strict parser rejects (0/2,114).
  - Apart from P0-1 and P1-4, `to_css` preserved meaning on every input.
- **Specificity where lightningcss is wrong.** Pion's `:has(> #x)` = (1,0,0) and `:host-context(#a)` = (1,1,0) follow Selectors 4. lightningcss alpha.72 returns (0,0,0) and (0,1,0). `:nth-child(2n+1 of #id.foo)` = (1,2,0) is correct in both.
- **Nesting-heavy parse speed.** Pion `parse_stylesheet` (171 ms) is **1.29× faster than lightningcss** (220.6 ms) on the nesting-heavy corpus, using 2.4× less RSS.

---

## Performance

`perf.py`: each process runs 3 repetitions; 5 interleaved rounds; median; Darwin arm64. "vs rust/sheet" is relative to cssparser building an owned generic AST with the same shape as Pion's `Stylesheet`.

| Corpus (MB) | Pion `count_tokens` | Pion `tokenize()` | cssparser token walk | Pion `parse` | cssparser AST | lightningcss parse | Pion `minify` | lightningcss minify | css-tree parse |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| design_system (2.09) | **18.0** | 48.6 | 26.2 | 105.0 | **41.5** | 76.6 | 187.6 | **93.0** | 306.5 |
| color_heavy (1.81) | **18.5** | 53.1 | 25.8 | 127.5 | **46.3** | 76.6 | 234.7 | **83.5** | 372.5 |
| selector_heavy (1.34) | **17.3** | 49.7 | 26.0 | 75.6 | **23.7** | 71.2 | 139.9 | **83.0** | 341.9 |
| nesting_heavy (1.74) | **20.3** | 64.0 | 30.0 | 171.0 | **71.0** | 220.6 | 335.6 | **264.0** | 468.5 |
| custom_props (2.04) | **18.8** | 51.7 | 24.9 | 92.8 | **51.8** | 131.6 | **98.0** | 138.2 | 325.2 |

All times are median ms.

- **README W1 vs the public `tokenize()`.** The 1.08× "Pion beats Rust" result times `count_non_ws_tokens`, which builds no tokens. The public `tokenize()` takes 48.6 ms versus 26.2 ms for a cssparser walk that produces full `Token` values, so it is **0.54× of cssparser**. Counting alone (18.0 ms) does beat cssparser; that part of the claim is honest, but it is not a tokenizer API.
- **Where Pion's parse time goes** (design_system):

  | Phase | Time | Share of parse |
  |---|---:|---:|
  | Scan | 18 ms | |
  | `Array[Token]` materialization | +30.6 ms | 29% |
  | AST build over the materialized tokens | +56.4 ms | 54% |
  | **parse total** | **105.0 ms** | |
  | minify: re-tokenizing every prelude and value string, plus output | +82.6 ms | 44% of minify's 187.6 ms |

  The cssparser AST with owned strings takes 41.5 ms, so Pion parse is 2.53× slower.
- **README W3 vs a real minifier.** The "0.20× Rust" baseline is a bespoke whitespace stripper. Against lightningcss, which parses into typed properties, optimizes shorthands and colors, and prints, **Pion's minify is still 2.0× slower** on design_system (187.6 vs 93.0 ms) and 2.8× slower on color_heavy. It is only ahead on custom_props (98.0 vs 138.2 ms), where both mostly copy verbatim.
- **Memory.**
  - Pion parse peaks at 47.8 MB on 2.09 MB of input, versus cssparser AST 18.0 MB and lightningcss 44.2 MB. On nesting_heavy it is 85.9 MB versus 34.0 MB.
  - It is 5–6× lower than css-tree throughout.
  - On the 5.5 MB sheet, Pion reaches 128.6 MB before failing at the token limit (P1-7); cssparser finishes in 73.2 MB.

## Suggested fix directions (not applied: audit only)

1. Store rule bodies as one ordered `Array[BodyItem]` (Decl | Rule). That fixes P0-1.
2. Serialize from tokens, emitting a separator between any pair of tokens that would re-tokenize differently (CSS Syntax 3 §9 table) instead of relying on raw-slice and whitespace heuristics. That fixes P0-2, P1-1 and P1-3. Only collapse `0<unit>` outside every function except a known safe allowlist (P1-2).
3. Implement "consume a declaration" per spec: `{}` is allowed in custom properties, and the parser falls back to a nested rule only for non-custom names (P1-4). Make the top-level and @media rule-list grammar spec-compliant (P1-6).
4. Drop the unicode-range token and parse `<urange>` on demand in `@font-face`, as cssparser does (P1-5).
5. Do not count whitespace toward `max_tokens` and raise the default, or stream. Make `max_depth` drop only the offending construct (P1-7).
6. Add a real Selectors 4 / MQ4 grammar validation pass (P1-8, P1-9).
