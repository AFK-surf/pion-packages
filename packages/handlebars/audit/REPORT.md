# Red-team audit: `packages/handlebars` v0.1.0

| | |
| --- | --- |
| Target | `origin/feat/pkg-handlebars` @ `4ab06f4` (Handlebars 4.x + Mustache 1.4.2 engine, pure Pion) |
| References | **Handlebars.js 4.7.8** (the reference implementation; npm), **Rust `handlebars` =6.4.4** (the benchmark baseline; `Cargo.lock`, `--locked`), **Mustache Spec v1.4.2** core vectors (SHA-256 pinned in `run_audit.sh`) |
| Toolchain | `pionc` from `AFK-surf/pion@66d2b4b`, node v24, rustc stable, Darwin arm64 (M-series) |
| Reproduce | `sh packages/handlebars/audit/run_audit.sh` (~7 min; exit 1 while any graded check fails) |

## Summary

| ID | Sev | Finding | Evidence |
| --- | --- | --- | --- |
| P0-1 | **P0** | `{{> @partial-block}}` inside a partial-block body recurses forever: **SIGSEGV natively, `RangeError` trap on Wasm32**, with default limits; one 80-byte untrusted template string is enough | unit `p0_…`, diff `sem/partial/block_self_reference*`, DoS `dos/partial_block_*` |
| P1-1 | P1 | Block-helper string results are HTML-escaped again: the canonical `"<b>" + options.fn(this) + "</b>"` helper renders `&lt;b&gt;&amp;lt;i&amp;gt;…` | `p1_block_helper_…`, `sem/esc/block_helper_*` |
| P1-2 | P1 | `{{~{x}~}}` (the Handlebars.js/Rust whitespace-control form of `{{{x}}}`) parses as a path named `{x}`: the value vanishes (`{{~{x}}}` even leaks a stray `}`) | `p1_tilde_triple_…`, `sem/esc/tilde_triple_stash*` |
| P1-3 | P1 | Calling an unregistered helper with arguments silently evaluates the helper name as a data path: `{{#unless (isBanned user)}}secret{{/unless}}` **fails open**, `{{nohelper 1}}` prints the `nohelper` field. `ErrorKind::HelperNotFound` is never produced | `p1_unknown_helper_…`, `sem/helper/missing_*` |
| P1-4 | P1 | A section over a truthy scalar does not push it as context: `{{#foo}}{{.}}{{/foo}}` prints `[object Object]`. Fails Mustache Spec *Variable test* and *Deeply Nested Contexts* | `p1_section_over_scalar_…`, `spec/sections/*`, `sem/sect/*_pushes_context` |
| P1-5 | P1 | Object lookups are a linear scan and are not counted by `max_steps`: a benign `{{#each rows}}{{@root.title}}{{/each}}` over 2.3 MB of attacker-sized JSON runs **35 s** (Rust 0.05 s, Handlebars.js 0.11 s) | DoS `dos/wide_root_lookup_100000x100000`, bench B1 |
| P1-6 | P1 | Inline partials declared inside a partial-block body are invisible to the layout (`{{#> layout}}{{#*inline "slot"}}…{{/inline}}{{/layout}}`, the documented Handlebars layout pattern): renders empty | `p1_inline_partial_in_partial_block_…`, `sem/partial/inline_in_partial_block` |
| P2-1 | P2 | Standalone-partial indentation is applied to rendered output, not to the partial's lines: data newlines get indented (spec *Standalone Indentation* fails) and empty partial lines are not indented | `p2_partial_indentation_…`, `spec/partials/Standalone Indentation`, `sem/ws/partial_indent_empty_line` |
| P2-2 | P2 | Inline partials leak out of the block that declares them (`{{#if}}{{#*inline}}…{{/if}}{{> p}}`) and are not hoisted | `p2_inline_partial_scoping_…`, `sem/partial/inline_*` |
| P2-3 | P2 | `@partial-block` is lost inside partials that a layout calls (renders `[]`, no error) | `p2_partial_block_reaches_…`, `sem/partial/block_in_nested_partial` |
| P2-4 | P2 | Strict mode also rejects the value tested by `{{#if}}`/`{{#unless}}`, so `{{#if x}}{{x}}{{/if}}` guards cannot be written | `p2_strict_mode_…`, `sem/path/strict_if_guard` |
| P2-5 | P2 | Raw blocks `{{{{helper}}}}…{{{{/helper}}}}` never call their helper | `p2_raw_block_…`, `sem/helper/raw_block_calls_helper` |
| P2-6 | P2 | `Double` formatting follows neither JS nor Rust: `1e-07`, `1e-06`, `4.94065645841247e-324` (both references: `1e-7`, `5e-324`) | `p2_float_…`, `sem/num/shortest_round_trip` |
| P2-7 | P2 | No stack ceiling independent of the configurable limits: an embedder raising `max_depth`/`max_partial_depth` crashes the process (Wasm32 already at ~500 nested blocks, native at ~10,000) | DoS `dos/*_lifted`, `dos/partial_self_partial_depth_*` |
| P2-8 | P2 | Array indices wrap: `{{lookup a '4294967296'}}` returns `a[0]`, `'18446744073709551617'` returns `a[1]`; integer literals wrap silently | `p2_out_of_range_index_…`, `sem/helper/lookup_index_wraparound` |

Measured on `4ab06f4`: 13 of 17 red-team unit tests fail (all 13 p*-tests; the 4 controls pass), 21 of 83 graded
adversarial differential cases and 3 of 136 Mustache spec vectors fail, 4-mode output is byte-identical
(234 cases, SHA-256 `22051323…`), 12 of 41 DoS probes fail.

**What holds up well** (details in [Robust](#robust-what-the-attacks-did-not-break)): HTML escaping is correct in every
escaped position we could reach (all 7 characters, helper results, subexpressions, `lookup`, partial hash/context
params, `@key`, array-to-string), SafeString / `{{{ }}}` / `{{& }}` / `no_escape` boundaries behave like
Handlebars.js, UTF-8/NUL survive byte-for-byte, every limit fails closed at 0/negative values, recursive and
exponential partial bombs stop cleanly (where Rust aborts on a 2-partial cycle and both references run >20 s on
2^30), the deepest nesting the default limits allow renders in all four modes, and the Mustache spec pass rate is
133/136 (Handlebars.js 116, Rust 52).

## Method

* `audit/redteam_test.pion` – one Pion unit test per finding (`p0_`/`p1_`/`p2_`, each asserting the reference
  behaviour) plus `control_` tests for attacks that failed. Run by `pionc test --json audit`.
* `audit/diff/` – JSONL differential harness. The same case file is fed to the Pion probe (`audit/probe`), the Rust
  oracle (`audit/oracle/rust`, `handlebars =6.4.4`, `serde_json` with `preserve_order` so that object iteration order
  is not an artefact) and the Handlebars.js oracle (`audit/oracle/hbsjs/oracle.js`). All three register the same
  three helpers (`wrap` block helper, `echo`, `safe`).
  * `cases.py` – 98 hand-written adversarial cases. **Expectations live in the case file**, decided per case from
    Handlebars.js + Rust (+ spec); cases where the references disagree with each other and Pion's choice is
    defensible are left ungraded (`expect: None`, listed under *Accepted divergences*), so a fix branch is never
    asked to do two contradictory things. Where Pion's documented "missing partial renders empty" rule makes an
    empty rendering as acceptable as the reference's error, the case accepts either (`one_of`, `graceful`).
  * `spec_cases.py` – the 136 core vectors of Mustache Spec v1.4.2 (`comments`, `delimiters`, `interpolation`,
    `inverted`, `partials`, `sections`; the optional `~lambdas`/`~inheritance`/`~dynamic-names` are out of the
    package's scope).
  * `runner.py` – a crashing batch falls back to one process per case so a SIGSEGV is attributed to its case.
* `audit/diff/fourmode.py` – the whole corpus through `native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel`.
* `audit/diff/gen_dos.py` + `dos.py` – 41 DoS / stack / complexity probes, each in its own process per mode, with a
  wall-clock budget and peak RSS; Rust and Handlebars.js run the same probe for comparison.
* `audit/bench/` – benchmark fairness variants (Rust with a prebuilt `Context`) and three blind-spot workloads, run
  through the repository's `scripts/bench_compare.py` (SHA-256 identity enforced).

## Findings

Line numbers refer to `packages/handlebars/src/*.pion` at `4ab06f4`.

### P0-1 `@partial-block` self-reference: unbounded recursion, native SIGSEGV / Wasm32 trap

```handlebars
{{#*inline "l"}}<{{> @partial-block}}>{{/inline}}{{#> l}}{{> @partial-block}}{{/l}}
```

Rendered with `handlebars::render(…)` and **default limits** this kills the process: `SIGSEGV` (rc −11) in
`native_dbg`/`native_rel`, `RangeError: Maximum call stack size exceeded` in `wasm_dbg`/`wasm_rel`. No partial or
helper has to be registered; the variant with a registered layout `{{> @partial-block}}` behaves the same. Any
service rendering user-supplied templates (the README's "Untrusted Templates with Tight Limits" use case) can be
crashed with one request. Handlebars.js: `The partial @partial-block could not be found`; Rust: `Partial block cound
not be found`.

The README's tight limits do not help on Wasm32: even `max_steps = 1000` traps there (natively a `max_steps`
around 10,000 stops it before the 8 MiB stack is exhausted; the default 10,000,000 does not).

Root cause – `eval.pion:853-868`: the `@partial-block` branch returns before the `partial_depth` accounting at
`:870-883`, and evaluates the block body while the **same** entry is still on top of `partial_block_stack`
(pushed at `:908-912`), so a `{{> @partial-block}}` in the body resolves to itself. Each round only `tick()`s
(`:838`), and the native/Wasm stack runs out long before 10M steps.

Fix direction: while evaluating a partial-block body, expose the *enclosing* partial block (pop or mark the entry,
as Handlebars.js does by running the body with the caller's `data['partial-block']`), and count the evaluation
against `max_partial_depth`.

### P1-1 Block-helper output escaped twice

`{{#wrap}}{{x}}{{/wrap}}` with the canonical helper (`Ok(Value::string("<b>" + h.fn_render(h.this_val) + "</b>"))`,
x = `<i>`) renders `&lt;b&gt;&amp;lt;i&amp;gt;&lt;/b&gt;`; Handlebars.js and Rust render `<b>&lt;i&gt;</b>`. In
Handlebars the result of a *block* helper is written unescaped (the body is already escaped by `fn`); only inline
helper results are escaped. Every ported block helper either destroys its markup or has to wrap its result in
`Value::safe_string`, which the README does not mention.

Root cause – `eval.pion:578-583`: `Ok(v) => self.write_escaped(value_to_string(v), …)` for block helpers.
Not an XSS (it fails safe), but it is a silent output corruption of every block helper.

### P1-2 `{{~{x}~}}` loses the value

Handlebars.js lexes `"{{" "~"? "{"` as `OPEN_UNESCAPED` and `"}" "~"? "}}"` as `CLOSE_UNESCAPED`; Rust accepts the
same spelling. Pion only recognises a triple-stash when `{` immediately follows `{{` (`parser.pion:351-352`); for
`{{~{` the `~` is consumed first (`:402-409`) and `{x}` becomes the escaped path segment `{x}` (`:587-606`), which
is undefined. `a {{~{x}~}} b` → `ab` (references `a<i>b`); `a {{~{x}}} b` → `a} b`. The README's own spelling
`{{{~x~}}}` works in Pion and Rust but is a parse error in Handlebars.js (left ungraded).

### P1-3 Unknown helpers with arguments: silent data lookup, fail-open conditions

| Template | Pion | Handlebars.js | Rust |
| --- | --- | --- | --- |
| `{{nohelper 1}}` with `{"nohelper":"LEAK"}` | `LEAK` | Missing helper | Helper not found |
| `{{#unless (isBanned u)}}secret{{/unless}}` | `secret` | Missing helper: "isBanned" | Helper not found |
| `{{#nohelper 1}}x{{/nohelper}}` | `x` | Missing helper | Helper not found |

A typo, a helper that failed to register, or a template written for Rust (which ships `eq`, `ne`, `and`, `or`,
`not`, `len`… built in) silently evaluates to `null`, so `{{#if (isAdmin u)}}` is always false and
`{{#unless (isBanned u)}}` / `{{#if (not …)}}` always true.

Root cause – `eval.pion:447-505`: when no registered helper matches and the name is not `lookup`/`log`, the call
falls through to `self.eval_expr(call.head, …)` and discards `call.params`/`call.hash`; the block path
(`eval.pion:728-732`) does the same. `ErrorKind::HelperNotFound` (`types.pion`) is never constructed. Expected:
`HelperNotFound` whenever a simple name with params or hash arguments is neither a helper nor a built-in.

### P1-4 Sections over scalars keep the outer context

`{{#foo}}{{.}} is {{foo}}{{/foo}}`, foo = `"bar"` → `[object Object] is bar`; Mustache Spec (*Variable test*) and
Handlebars.js: `bar is bar`. Also `{{#n}}[{{this}}]{{/n}}` with n = 5 → `[[object Object]]` (Handlebars.js `[5]`),
and spec *Deeply Nested Contexts* fails on `{{#five}}…{{.}}…{{/five}}`. Root cause – `eval.pion:775-780`: the
fallback branch renders the body without pushing `sval` (only `Array` and `Object` push). `true` must still not
push (spec *Truthy*, Handlebars.js `fn(this)`), which `sem/sect/true_keeps_context` keeps graded.

### P1-5 Wide objects: O(N·K) CPU that `max_steps` does not see

`Value::Object` is an insertion-ordered array and every key lookup scans it from the end (`eval.pion:125-135`,
reached from `value_get_prop` `:137-159`; Mustache-style resolution may scan every frame of the context stack,
`:242-249`). `tick()` is charged once per node/iteration (`:41-59`, `:648`), not per key compared, so the cost of a
render is unbounded by `max_steps` and grows with *data* size squared:

| Probe (template, data) | Pion native | Rust | Handlebars.js |
| --- | ---: | ---: | ---: |
| `{{#each rows}}{{@root.title}}{{/each}}`, root with 10,000 keys + 10,000 rows | 0.47 s | 0.01 s | 0.06 s |
| same, 100,000 + 100,000 (2.3 MB JSON) | **35 s** (killed at the 10 s budget in the audit) | 0.05 s | 0.11 s |
| `{{#each o}}{{lookup ../o @key}}{{/each}}`, 20,000 keys | 0.86 s | 0.02 s | 0.07 s |
| Bench B1: 2,000 `@root` lookups in a 5,002-key root, ×20 renders | 856 ms | 30 ms | – |

The template is benign; only the data is attacker-sized, which is the common deployment (trusted template,
untrusted JSON). The README mentions "O(K) for very wide objects" but not that the 16 MiB / 10M-step limits do not
bound it. Fix direction: index objects above a small size (hash or sorted index built once in `Value::from_json5` /
`Value::object`), and/or charge `tick()` proportionally to the keys scanned.

### P1-6 Inline partials inside a partial block are invisible to the layout

```handlebars
{{#> layout}}{{#*inline "slot"}}S{{/inline}}{{/layout}}      layout = "[{{> slot}}]"
```

Pion `[]`, Handlebars.js and Rust `[S]`. This is the layout/slot pattern of the Handlebars documentation ("inline
partials … partial blocks"). Root cause – `eval.pion:906-913`: when the layout exists, the fallback body is only
stored for `@partial-block`; its `InlinePartial` nodes are registered (`:1003-1008`) only if and when the body is
rendered, and then into a frame the layout cannot see. They must be registered in the layout's frame before the
layout runs.

### P2-1 Partial indentation applied to output

`indent_partial_output` (`eval.pion:811-832`, used at `:914-931`) indents every non-empty line of the *rendered*
partial. (a) Interpolated data that contains newlines is indented too: spec *Standalone Indentation* expects
`"\\\n |\n <\n->\n |\n/\n"`, Pion produces ` ->` (Handlebars.js and Rust share this deviation, so the related
`sem/ws/partial_indent_data_newlines` is ungraded). (b) Empty lines of the partial are not indented, while
Handlebars.js and Rust both produce `"  x\n  \n  y\n"`. Indenting the partial's template lines at compile/call
time satisfies the spec and both references.

### P2-2 Inline-partial scope and hoisting

Inline partials are pushed into the innermost *partial* frame (`eval.pion:1003-1008`; frames are only created by
partial calls, `:913`), so `{{#if t}}{{#*inline "p"}}IN{{/inline}}{{/if}}[{{> p}}]` renders `[IN]` (Handlebars.js:
not found; an empty `[]`, Pion's missing-partial behaviour, is accepted), and registration happens in source order,
so `[{{> p}}]{{#*inline "p"}}IN{{/inline}}` renders `[]` (Handlebars.js hoists decorators: `[IN]`). Rust leaks like
Pion and does not hoist; Handlebars.js is the reference here.

### P2-3 `@partial-block` lost in nested partials

Layout `{{> inner}}`, inner `[{{> @partial-block}}]`: Pion `[]`, Handlebars.js `[PB]`, Rust errors. Every partial
call pushes its own `None` entry (`eval.pion:908-912`), shadowing the layout's block; the empty rendering hides the
mistake.

### P2-4 Strict mode forbids `{{#if}}` guards

`eval_params_and_hash` evaluates every helper parameter with `self.reg.strict_mode` (`eval.pion:387,397`), including
the built-in `if`/`unless` (`:592-596`). Handlebars.js and Rust strict modes render `{{#if nope}}x{{/if}}` as empty
and still reject `{{nope}}`. With Pion's strict mode an optional field cannot be tested at all.

### P2-5 Raw blocks never call their helper

`{{{{wrap}}}}{{x}}{{{{/wrap}}}}`: Handlebars.js and Rust `<b>{{x}}</b>`, Pion `{{x}}`. The tokenizer keeps only the
body (`parser.pion:274-341`, `RawTokKind::RawBlock`) and the parser emits it as `Node::Text` (`:1307-1312`); the
helper name is dropped.

### P2-6 Float formatting

`Value::Float(f) => f.to_string()` (`eval.pion:278`) prints `1e-07`, `1e-06`, `2.5e-05`, `1.2345678901234568e+20`,
`4.94065645841247e-324` (the last is not even the shortest round-trip form). Handlebars.js prints `1e-7`,
`0.000001`, `0.000025`, `123456789012345680000`, `5e-324`; Rust prints `1e-7`, `1e-6`, `0.000025`,
`1.2345678901234567e20`, `5e-324`. Only the values both references agree on are graded. Positive: the output is
identical in all four modes (no Native/Wasm32 drift).

### P2-7 No absolute stack ceiling (lifted limits, Wasm32)

`max_depth`/`max_partial_depth` are plain user settings and recursion depth (parser `parse_block_body` /
`parse_block_node` / `parse_expr`, evaluator `eval_block` / `eval_expr` / `eval_partial`) is only bounded by them:

| Probe (limits lifted) | native | Wasm32 (node default stack) | Rust | Handlebars.js |
| --- | --- | --- | --- | --- |
| 1,000 nested `{{#if}}` / subexpressions | OK | **RangeError** | OK | OK |
| 10,000 nested `{{#if}}` | **SIGSEGV** | RangeError | OK (1.8 s) | RangeError (caught) |
| 100,000 nested subexpressions | SIGSEGV | RangeError | parse error | >20 s |
| `{{> self}}` with `max_partial_depth` 1,000 / 100,000 | OK / **SIGSEGV** | RangeError / RangeError | error | error |

Wasm32 traps between 300 and 500 nested blocks. The defaults (64 / 32) are safe in all modes (`dos/legal_*`), but
the README offers the limits as knobs without saying that values above a few hundred crash Wasm32 hosts. Either
clamp internally to a per-target safe ceiling (returning `DepthLimitExceeded`) or document the ceiling. Related
usability note: chained `{{else if}}` branches count as nesting (`parser.pion:1570-1577`), so a 64-branch
`else if` chain is rejected with the default limits (Handlebars.js and Rust accept 10,000).

### P2-8 Index wrap-around

`parse_i64_decimal` (`parser.pion:934-958`) accumulates in a wrapping `Int64` and `value_get_prop` truncates with
`idx.to_int()` (`eval.pion:141-149`): `{{lookup a '4294967296'}}` → `a[0]`, `{{lookup a '18446744073709551617'}}` →
`a[1]`, `{{a.[4294967296]}}` → `a[0]` (references: empty). Integer literals wrap the same way
(`{{echo 99999999999999999999}}` → `7766279631452241919`). Low impact, but it defeats any "out of range → empty"
expectation on attacker-chosen indices.

## Robust: what the attacks did not break

* **Escaping (all P0 XSS attempts failed).** The 7 Handlebars.js characters are escaped (`escape.pion`) in plain
  mustaches, inline-helper results, subexpressions, `lookup`, partial hash and context parameters, `@key`, block
  parameters and array-to-string; unquoted-attribute, back-tick and `</script>` payloads stay inert. `{{{x}}}`,
  `{{& x}}`, `Value::safe_string`, `safe`-helper results and `set_no_escape(true)` are the only raw paths, exactly
  as in Handlebars.js. No path produced double escaping except P1-1. UTF-8 (CJK, Latin-1), NUL and C0 controls
  survive escaping, partial indentation, string literals and bracket segments byte-for-byte.
* **Limits fail closed.** `max_output_bytes` 0/−1, `max_steps` 0/−1, `max_template_bytes` −1, `max_depth` −1,
  `max_partial_depth` 0 all reject instead of disabling the limit. The 6× escape expansion is accounted before
  writing (`escaped_html_len`), so a 3.3 MB string of `"` stops at 16 MiB instead of producing 20 MB.
* **Recursion and amplification.** `{{> self}}`, `A → B → A` and inline self-recursion stop with
  `PartialDepthLimitExceeded` in all four modes (Rust *aborts* with a stack overflow on the 2-partial cycle and on
  inline self-recursion). A 2^20 partial fan-out renders its 1 MiB in 0.21 s; 2^30 stops at the step limit in
  0.97 s (Rust and Handlebars.js run past 20 s). Nested `{{#if}}`, subexpressions and `else if` chains of
  1,000–10,000 are rejected at compile time in ≤0.01 s (at 10,000, Handlebars.js spends 12–19 s and 365–450 MiB before failing).
* **Maximum legal nesting renders everywhere.** 63 nested `if`, 63 nested subexpressions, 63 nested `each`, and a
  31-partial chain ending in 60 `if` + 63 subexpressions all render in all four modes.
* **Large templates.** A 4 MiB template of 838,860 tags compiles and renders in 0.30 s native / 0.70 s Wasm32
  (Rust: >20 s, Handlebars.js: aborts after 4.2 GB). Peak RSS is high – 503 MiB native, 737 MiB Wasm32, ~120× the
  template – worth knowing when sizing `max_template_bytes` for multi-tenant hosts. `max_template_bytes + 1` is
  rejected before lexing.
* **Semantics.** Mustache Spec v1.4.2 core: 133/136 (Handlebars.js 116, Rust 52). Handlebars.js truthiness
  (`{}` truthy, `[]`/`0`/`""` falsy, `includeZero`), `@index/@first/@last/@key`, `@../index`, `@root`, `../../`,
  `./x` and `this.x` blocking the context walk, `[a.b]` literal segments, block-parameter shadowing and release,
  `\{{`/`\\{{`, delimiter switching scoped to its template, CRLF standalone lines and `~` stripping all match.
* **4-mode identity.** All 234 corpus cases produce byte-identical results in `native_dbg`, `native_rel`, `wasm_dbg`,
  `wasm_rel` (SHA-256 `22051323833cd548538b4a841613e986924ab0e8bd9fc511eef50ced46f21b9f` of the canonical result list);
  every non-crashing DoS probe also hashes identically across modes. The only mode differences are stack depth
  (P0-1 with small `max_steps`, P2-7).

## Accepted divergences (reported, not graded)

| Case | Pion | Handlebars.js | Rust | Note |
| --- | --- | --- | --- | --- |
| `{{#with a}}{{t}}{{/with}}`, `t` only at root | `T` | `` | `` | Mustache context walk; Handlebars needs `compat: true`. Templates relying on Handlebars' scoping can read outer data – document it, consider an opt-out |
| `{{> missing}}` | `` | error | error | Mustache spec *Failed Lookup*; `ErrorKind::PartialNotFound` is never produced, not even in strict mode |
| `{{#each arr}}{{@key}}` | `` | index | `` | |
| `{{#with 0}}` | inverse | body | inverse | |
| `{{#s}}…{{/s}}`, s = `""` | inverse | body | – | Mustache falsey |
| block params inside a partial | visible | not visible | visible | |
| partial-block context | caller's | call site's (`{{#with}}` around `{{> @partial-block}}`) | caller's | |
| object iteration order `{"b","2","1"}` | insertion | JS (`1,2,b`) | insertion (`preserve_order`) | |
| `a.0`, `a.length` | element, length | parse error | error | |
| `{{{~x~}}}` | raw | parse error | raw | README spelling |
| raw block without helper | body | `` | body | |
| integers > 2^53, `1.0` | binary64, `1` | binary64, `1` | exact, `1.0` | |
| NUL in template text | kept | lexer error | kept | |

## Benchmark review (`packages/handlebars/bench/`)

Same machine, `scripts/bench_compare.py --warmup 1 --rounds 5`, SHA-256 identical in every table.

| Workload | pion | rust (official harness) | rust, `Context` built once | pion vs fair rust |
| --- | ---: | ---: | ---: | ---: |
| W1 page SSR, 1,000 renders | 153 ms | 272 ms (README: 1.73×) | 246 ms | **1.60×** |
| W2 compile + render, 2,000 | 35 ms | 93 ms | (unchanged) | 2.65× |
| W3 escape-heavy table, 200 | 123 ms | 176 ms (README: 1.35×) | 150 ms | **1.22×** |
| B1 wide-object lookups (blind spot) | 856 ms | – | 30 ms | **0.04× (28× slower)** |
| B2 4,096-leaf partial fan-out ×50 | 75 ms | – | 123 ms | 1.63× |
| B3 64 KiB template compile ×10 | 38 ms | – | 3,657 ms | 97× |

* **Symmetry.** Data, templates, escaping and partial lookups are the same on both sides; W2 registers `eq` as a Pion
  closure where Rust uses its built-in (comparable), both compile per iteration, and output identity is enforced.
* **Rust harness overhead.** `Handlebars::render(name, &data)` re-serialises the whole `serde_json::Value` tree into a
  new `Context` on every call (`Context::wraps` → `to_value`); a server keeps the `Context` and calls
  `render_with_context`. With that, Pion's lead shrinks from 1.78× to 1.60× (W1) and 1.43× to 1.22× (W3). The
  README's numbers are reproducible within noise but overstate the gap by ~10–15 %.
* **Untested weak spot.** All three official workloads use objects with ≤ 8 keys. With a realistic configuration
  object (5,000 keys) Pion is 28× slower than Rust (B1, P1-5); this should be in the published table.
* **Untested strengths.** Partial reuse (B2, 1.63×) and large-template compilation (B3: Rust's compile time is
  superlinear – 0.35 s for 64 KiB, ~5 s for 256 KiB) favour Pion and are not shown either.
* Minor: `bench/rust_bench/Cargo.toml` asks for `handlebars = "6.3.2"` while the lock and README say 6.4.4 (correct
  under `--locked`, but `=6.4.4` would make the claim explicit); the Pion checksum walks bytes (`code_unit_at`), which
  matches Rust's `as_bytes()` only because Pion strings are UTF-8.

## Files

```
audit/REPORT.md               this report
audit/run_audit.sh            one-shot reproduction (STEPS="unit diff fourmode dos bench")
audit/pion.toml               package `handlebars_audit` (red-team unit tests)
audit/redteam_test.pion       p0_/p1_/p2_ findings + control_ tests
audit/probe/                  Pion JSONL probe (4 modes)
audit/oracle/rust/            Rust handlebars =6.4.4 oracle (Cargo.lock, --locked)
audit/oracle/hbsjs/oracle.js  Handlebars.js 4.7.8 oracle (installed into $AUDIT_OUT by run_audit.sh)
audit/diff/                   cases.py, spec_cases.py, runner.py, diff.py, fourmode.py, gen_dos.py, dos.py
audit/bench/                  rust_fair (Context-reusing W1/W3 + B1-B3), pion_blind (B1-B3), gen_blind.py
```

All builds, downloads and logs go to `$AUDIT_OUT` (default `/private/tmp/rt-handlebars-audit`); the worktree stays
clean. `run_audit.sh` exits 1 while any finding reproduces and 0 once all graded checks pass; it needs no edit for a
fix branch.
