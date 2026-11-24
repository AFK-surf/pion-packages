# Red-team audit: `packages/template` vs Rust `minijinja =3.1.0`

Branch `audit/redteam-template`, forked from `origin/feat/pkg-template` @ `e7d8411`. Only
`packages/template/audit/**` is added; the package source is untouched.

Machine: Apple M5 Max (Darwin arm64), `pionc 0.1.0`, rustc stable, node (wasm32 runner
`~/.pion/share/pion/pion_wasm_rt.mjs`). Reference: `minijinja = "=3.1.0"` with features
`builtins json preserve_order urlencode loop_controls fuel` (`audit/diff/rust`).

## How to reproduce

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
sh packages/template/audit/run_audit.sh            # everything (≈15 min, most of it the DoS watchdogs)
sh packages/template/audit/run_audit.sh tests      # 29 red-team unit tests
sh packages/template/audit/run_audit.sh diff       # 283-case differential vs minijinja 3.1.0
sh packages/template/audit/run_audit.sh wasm       # wasm32 vs native, one process per case
sh packages/template/audit/run_audit.sh dos        # 62 DoS cases × {pion native, pion wasm32, rust}
sh packages/template/audit/run_audit.sh bench      # 8 adversarial head-to-head benchmarks
```

Artefacts go to `$AUDIT_OUT` (default `/private/tmp/pion-template-audit`). After the run,
`git status --porcelain --ignored` is clean apart from the committed `audit/` files.

| Piece | Path |
| --- | --- |
| Red-team unit tests (FAIL = defect, `control_*` must PASS) | `audit/tests/redteam_test.pion` |
| Pion probe (`diff <corpus>` / `one <corpus> <case>`) | `audit/probe/src/main.pion` |
| Rust minijinja 3.1.0 mirror (same corpus format and context) | `audit/diff/rust/src/main.rs` |
| Corpus generator (semantic, DoS, bench) | `audit/diff/gen_corpus.py` |
| Comparator (pion vs rust, native vs wasm32) | `audit/diff/compare.py` |
| Process-isolated runner (timeout + RSS watchdog, crash/trap capture) | `audit/diff/run_isolated.py` |

Both engines render every case with the same fixed context (`xss`, `close`, `attr`, `uni`,
`imax`/`imin`, `users`, `m`, `safe_html` …) in an `Environment` configured from the case
flags. A case agrees when both return OK with byte-identical output, or both return an error.

## Results at a glance

| Check | Result |
| --- | --- |
| Red-team unit tests | **24 / 29 FAIL** (5 controls pass) |
| Differential vs minijinja 3.1.0 | **126 / 283 differ** (157 agree) |
| wasm32 vs native, same corpus | 280 / 283 identical; **3 cases trap the wasm instance**, so the whole-corpus run aborts on case 1 of them |
| DoS cases (62, default limits) | pion native: **SIGSEGV ×1, SIGABRT ×1, RSS > 3 GiB ×3, >10 s ×3**; pion wasm32: **16 traps** (stack overflow, memory.grow, DataView, float→int), RSS ×1, >10 s ×3; minijinja (no limits configured): SIGABRT ×1, RSS ×4, >10 s ×3 |
| Adversarial benchmarks (8) | Pion slower in 6/8; `|sort` **184× slower**, `|unique` **39× slower** (O(n²)) |
| Original `bench/` | reproduced (0.83× / 1.54× / 1.72×); SHA identity holds only because inputs avoid the divergences below |

---

## P0 — security / sandbox

### P0-1 `|tojson` is not HTML-safe yet is marked safe → `</script>` breakout (XSS)

`filters.pion:1400` serializes with `write_json_string` (`escape.pion:91`), which only
escapes `"`, `\` and control characters, then returns `Value::safe(...)`. minijinja 3.1.0
(`json.rs`, `html_safe = true`) additionally escapes `<` `>` `&` `'` to
`<` `>` `&` `'`, precisely so the result can be dropped into `<script>`
or a single-quoted attribute under HTML auto-escape.

```
{{ close|tojson }}   (close = "</script><script>alert(1)</script>", AutoEscape::Html)
pion: <script>var x = "</script><script>alert(1)</script>";</script>        ← executes alert(1)
rust: <script>var x = "</script><script>alert(1)</script>";</script>
```

Same for `<div data-x='{{ v|tojson }}'>` with `'` in `v` (attribute breakout). Cases
`xss_tojson_*` (9 diffs); tests `p0_tojson_script_breakout`, `p0_tojson_attr_breakout`.
This is the only *under*-escaping found: every plain `{{ … }}` / attribute / `|e` case agrees.
Note Bench 2 (`tojson(indent=2)`) skips this escaping pass that Rust pays for.

### P0-2 Template-only traps kill the wasm32 instance

Integer/float instructions that silently wrap on arm64 trap in wasm32; no context needed:

| Template | native | wasm32 | minijinja |
| --- | --- | --- | --- |
| `{{ (-9223372036854775807 - 1) // -1 }}` | `-9223372036854775808` (wrong) | **TRAP** divide result unrepresentable | `9223372036854775808` |
| `{{ imin // -1 }}` | `-9223372036854775808` | **TRAP** | `9223372036854775808` |
| `{{ 1.5\|round(1000000) }}` | `0.0` (wrong) | **TRAP** float unrepresentable in integer range | `1.5` |

A trap is uncatchable from Pion: one untrusted template takes down the host instance and every
other render in it (the whole-corpus wasm run aborts at the first of these).
`run_audit.sh wasm`; test `p1_int_overflow_no_silent_wrap`.

### P0-3 `max_depth` does not bound expression chains → SIGSEGV (native), stack overflow (wasm32)

`max_depth` is charged on nesting (parens, lists, `if`/`for`), all correctly rejected
(`dos_parens_*`, `dos_if_5000`, … → `RecursionLimit`). Left-associative operator chains,
filter chains, attribute chains and `not`/unary chains are parsed iteratively into an
arbitrarily deep AST that the evaluator then recurses into:

| Case (template size) | pion native | pion wasm32 | minijinja |
| --- | --- | --- | --- |
| `1 + 1 + …` ×10 000 (40 KB) | OK | **TRAP** max call stack | OK |
| `'a' ~ …`, `true and …`, `not …`, `-…`, `\|upper` ×10 000, `.a` ×10 000, `**` ×5 000 | OK | **TRAP** ×7 | OK |
| `1 + 1 + …` ×100 000 (400 KB) | **SIGSEGV** | **TRAP** | SIGABRT (stack overflow) |
| 5 000-deep list built at runtime, then printed / `==` / `\|sort` | OK (print truncated) | **TRAP** ×3 | OK |

The README promises "`max_depth` protection against … deeply nested blocks/expressions".
minijinja also overflows at 100 000 terms, but survives every 10 000 case that kills Pion's
wasm32 build. Test `p0_binop_chain_bypasses_max_depth` (2 001 terms render under `max_depth=64`).

### P0-4 `max_output_bytes` bypassed by intermediate values → OOM abort

The limit is checked on output writes, `~`, string `+` and `*` repetition, but not on
`|replace`, list `+`, `|batch` fill, `|slice` fill or `|indent`:

| Case | pion native | pion wasm32 | note |
| --- | --- | --- | --- |
| `'aaaaaaaaaa'\|replace('a','aaaaaaaaaa')` ×9 `\|length` | **SIGABRT** at 2 GiB | **TRAP** memory.grow | 10 B → 10 GB |
| `{% set ns.l = ns.l + ns.l %}` ×40 | **RSS-KILL** 3.2 GiB | **TRAP** memory.grow | list `+` has no check (`eval.pion` `BinOp::Add` Seq) |
| `[1, 2]\|batch(1000000000, 0)` | **RSS-KILL** 3.1 GiB | **TRAP** | fill loop unbounded |
| `[1, 2]\|slice(1000000000)` | **RSS-KILL** 3.8 GiB | RSS-KILL | (minijinja too) |
| `multi\|indent(100000000)` | ERR, but only after allocating 398 MiB | 693 MiB | string built before the check |

With the default `Environment` (16 MiB output, 10 M fuel). minijinja makes no such promise
and also blows up on most of these; the finding is against Pion's own README contract.
Tests `p0_replace_chain_bypasses_max_output_bytes`, `p0_list_doubling_bypasses_max_output_bytes`.

### P0-5 O(n²) `|sort` / `|unique` charge no fuel → CPU DoS

`|sort` is an insertion sort (`filters.pion:948`), `|unique` a linear-scan dedupe
(`filters.pion:996`); neither consumes fuel, so the fuel budget does not stop them:

| Case | pion native | minijinja |
| --- | --- | --- |
| `(range(100000)\|reverse\|list)\|sort\|first` | **>10 s (killed)** | 16 ms |
| `(range(100000)\|list)\|unique\|list\|length` | **>10 s (killed)** | 91 ms |
| 20 000 dicts `\|sort(attribute='k')` | 3 662 ms | 787 ms |

`range()` lists are capped at 100 000, but there is no cap for `Seq` inputs. Test
`p0_unique_quadratic_not_fueled` (20 000 items render under `fuel=100000`).

---

## P1 — semantics that silently produce wrong output

| # | Finding | Example (pion → minijinja 3.1.0) | Cases / tests |
| --- | --- | --- | --- |
| P1-1 | Integer overflow wraps silently (no i128 promotion / error); big literals wrap | `imax + 1` → `-9223372036854775808` vs `9223372036854775808`; `99999999999999999999` → `7766279631452241919` | `arith_*_overflow`, `lit_big_int`; `p1_int_overflow_no_silent_wrap` |
| P1-2 | Chained comparisons evaluated as `(1 < 2) < 3`; incomparable types compare as `false` | `1 < 2 < 3` → `false` vs `True` | `cmp_chain`, `cmp_order_mixed`; `p1_chained_comparison` |
| P1-3 | Booleans/none print as `true/false/none`; 3.x prints `True/False/None` (Python style) — touches every bool/none output, list/map repr | `{{ true }}` → `true` vs `True` | 30+ diffs; `p1_bool_none_display` |
| P1-4 | Strings are byte arrays: `length`, indexing, slicing, `reverse`, `list` split UTF-8 → invalid UTF-8 output; `upper/lower/title` ASCII-only | `uni[::-1]` → `��� dlr��w` ; `uni\|length` 17 vs 13 | `slice_unicode`, `upper_unicode`, `flt_lower_upper`; `p1_unicode_strings_are_bytes` |
| P1-5 | Safe-string taint dropped by `~`, `+`, `upper`, `replace`, `join`, filter blocks, filters on macro / `set`-block results → **double escaping** in HTML mode | `{% filter upper %}<b>{{ amp }}</b>{% endfilter %}` → `&lt;B&gt;A&amp;AMP;B…` vs `<B>A&AMP;B</B>` | 9 `xss_*` diffs; `p1_filter_block_double_escapes`, `p1_set_block_capture_is_safe`, `p1_macro_output_filter_double_escapes`, `p1_safe_preserving_ops` |
| P1-6 | Tests with a bare argument are a syntax error | `{{ 9 is divisibleby 3 }}` → SyntaxError | `tests_basic/more/cmp`; `p1_test_with_bare_argument` |
| P1-7 | Conditional `extends` ignored | `{% if t %}{% extends 'a' %}…` → `X` vs `AX` | `inh_cond_extends`; `p1_conditional_extends` |
| P1-8 | Child top-level `{% set %}` invisible in blocks; `import` does not export variables | `[{{ g }}]` → `[]` vs `[G]`; `l.x` → `` vs `42` | `inh_set_in_child_top`, `import_var`; 2 tests |
| P1-9 | Filter arguments silently ignored → wrong numbers | `users\|sum(attribute='age')` → `0` vs `90`; `sum(start=)`, `join(attribute=)`, `unique(attribute=)`, `split(maxsplit)`, `round(method=)`, `int(default)` | `flt_*`; `p1_filter_kwargs_ignored` |
| P1-10 | `|sort` is case-sensitive by default and does not order mixed types; `|round` is half-away-from-zero and turns ints into floats | `['b','a','C']\|sort` → `["C","a","b"]` vs `['a','b','C']`; `2.5\|round` → `3.0` vs `2.0` | `flt_sort*`, `flt_round*`; `p1_sort_semantics`, `p1_round_half_even` |
| P1-11 | `loop.depth` of a nested non-recursive loop is 2 (should be 1) | | `loop_depth_nested`; `p1_loop_depth_non_recursive` |
| P1-12 | Errors swallowed: too many macro args, unknown kwargs, unpack length mismatch, duplicate block names all render | `m(1, 2)` → `1` vs TooManyArguments | `macro_too_many`, `macro_unknown_kw`, `loop_unpack_mismatch`, `inh_block_twice`; `p1_arg_count_errors` |
| P1-13 | `\uXXXX` string escapes unsupported (`'é'` → `u00e9`); unknown escapes drop the backslash | | `lit_str_esc`, `lit_str_bad_esc`; `p1_string_unicode_escape` |

## P2 — missing features / formatting divergences (render error or different text)

- **Missing built-ins**: filters `dictsort`, `format`, `min`, `max`, `pprint`; tests `filter`, `test`; `loop.changed()`, `recursive` loops / `loop()`, `{% break %}`/`{% continue %}` (minijinja `loop_controls`), `self.<block>()`, tuple literals `(1, 2)`, `{% set a, b = … %}`, `{%+`/`+%}`, include of a template list, `users.0.name`, macro `.name`/`.arguments`, `debug` global.
- **repr / number formatting**: strings in list/map repr use `"…"` (minijinja `'…'`); `|items` yields lists not tuples; float formatting `1e+20` / `1.5e-07` (minijinja `100000000000000000000.0` / `0.00000015`); `-0.0` printed as `0.0`; `|tojson` default is compact (`{"a":1}`) vs minijinja's spaced default (`{"a": 1}`) — documented in README but still a byte-level divergence.
- **Operators**: float `%` and float `**` are `InvalidOperation` (`7.5 % 2`, `2.0 ** 0.5`); `2 ** 63` errors instead of promoting; bool arithmetic rejected; `-2 ** 2` = `-4` and `2 ** 3 ** 2` = `512` (Python) vs minijinja `4` / `64`; `1 + 2 ~ 3` precedence follows Jinja2 (`33`) while minijinja errors.
- **Other**: `|urlencode` on a map encodes its JSON instead of a query string; `|title` word boundaries differ; JSON auto-escape mode quotes `Value::safe` strings; `safe_html[0:3]` is "not sliceable"; `dict(m, c=3)` drops `m`; whitespace control on `{% raw %}` and `trim_blocks` after `{% endraw %}` ignored; Unicode identifiers accepted; `range(10**18)|length` accepted (minijinja rejects > 100 000); `tojson` rejects > 64 levels where minijinja serializes 200; import cycles are not detected (terminates only because imports are not executed transitively).

Full list with both outputs: `$AUDIT_OUT/diff.md` (`run_audit.sh diff`).

## Controls that held (no defect found)

HTML escaping of `& < > " ' /` in text and attributes, `|e` idempotence, `|safe`,
`{% autoescape %}` blocks, include inherits auto-escape; Python floor `//` and `%` on negative
ints; `and`/`or` return operands and short-circuit (`0 and 1/0`); `for`-block scoping of
`set`; `namespace`; `with`; strict-undefined errors; `extends`/`include` cycle detection;
macro recursion limit; deep nesting of parens / lists / dicts / `if` / `for` / ternaries
(`RecursionLimit` on both targets); string `*` repetition, `range()` materialization,
`join`, nested loops (`FuelExhausted` at 10 M steps where minijinja runs 3.8 s), wide macro
recursion, include fan-out (10 MB), 10 MB literal text.

## Performance

### Original `bench/` (re-run, same machine)

| Bench | pion median | rust median | pion vs rust |
| --- | ---: | ---: | ---: |
| 1 HTML SSR | 162.1 ms | 133.8 ms | 0.83× |
| 2 Prompt (`tojson(indent=2)`) | 66.7 ms | 102.5 ms | 1.54× |
| 3 compile + render | 28.6 ms | 49.1 ms | 1.72× |

Reproduces the README within noise; SHA-256 identical. Fairness notes:

- The inputs avoid every divergence above (no booleans/none printed, no `<>&'` inside `tojson`,
  ASCII only). Bench 2's lead partly comes from skipping the HTML-safe `<…` pass that is
  the P0-1 bug.
- The Rust side is built without minijinja's `speedups` feature (SIMD `v_htmlescape`), which
  understates Rust on Bench 1 — the 0.83× gap is a lower bound.

### Adversarial head-to-head (`run_audit.sh bench`, `scripts/bench_compare.py --warmup 1 --rounds 5`, SHA-256 verified; one process per run including compile)

| Workload | pion median | rust median | pion vs rust |
| --- | ---: | ---: | ---: |
| `bench_sort_20k` reversed `\|sort` | 1 757.8 ms | 9.5 ms | **0.005×** (O(n²) insertion sort) |
| `bench_unique_20k` | 738.4 ms | 19.0 ms | **0.026×** (O(n²) scan) |
| `bench_attr_lookup_100k` `users[i % 3].name` | 54.0 ms | 29.0 ms | 0.54× |
| `bench_loop_200k` nested `for` | 35.3 ms | 24.5 ms | 0.69× |
| `bench_html_escape_50k` | 29.4 ms | 24.4 ms | 0.83× |
| `bench_filters_50k` `upper\|replace\|trim\|title`, `join` | 45.9 ms | 41.6 ms | 0.91× |
| `bench_macro_50k` | 29.4 ms | 29.8 ms | 1.02× |
| `bench_set_concat_20k` `ns.s ~ 'x'` | 22.1 ms | 70.2 ms | 3.18× |

Hot-path observations (source): filters are dispatched through a chain of ~50 string
comparisons (`eval_filter`, `filters.pion:748+`) after a linear scan of custom filters;
`Environment` lookups (templates, globals, filters) are linear arrays; `value_to_items`
copies the whole sequence for every list filter.

## Suggested fix order

1. P0-1: escape `< > & '` in `write_json_string` when called from `|tojson`.
2. P0-2 / P1-1: checked i64 arithmetic everywhere (`//`, `%`, `+`, `-`, `*`, unary `-`,
   literals) → error or wider int; clamp `round` digits before converting to an integer.
3. P0-3: charge `max_depth` per AST node depth (or evaluate binary chains iteratively), and
   bound recursion in `equals` / `compare` / repr on runtime values.
4. P0-4 / P0-5: charge every allocation-producing filter and list `+` against
   `max_output_bytes`; charge fuel per element in `sort`/`unique`/`batch`/`slice`; use an
   O(n log n) stable sort.
5. P1 semantic items, then P2 feature gaps, re-running `run_audit.sh diff` until it converges.

## Appendix: DoS matrix (`run_audit.sh dos`, status / wall time / peak RSS)

| case | pion_native | pion_wasm32 | rust_minijinja |
|---|---|---|---|
| `dos_parens_10000` | ERR(RecursionLimit) 68ms 34MiB | ERR(RecursionLimit) 164ms 101MiB | ERR(SyntaxError) 24ms 15MiB |
| `dos_parens_1000` | ERR(RecursionLimit) 23ms 34MiB | ERR(RecursionLimit) 83ms 100MiB | ERR(SyntaxError) 43ms 14MiB |
| `dos_parens_200` | ERR(RecursionLimit) 63ms 34MiB | ERR(RecursionLimit) 127ms 99MiB | ERR(SyntaxError) 97ms 14MiB |
| `dos_lists_5000` | ERR(RecursionLimit) 95ms 34MiB | ERR(RecursionLimit) 94ms 101MiB | ERR(SyntaxError) 23ms 15MiB |
| `dos_dicts_2000` | ERR(RecursionLimit) 88ms 34MiB | ERR(RecursionLimit) 110ms 99MiB | ERR(SyntaxError) 19ms 15MiB |
| `dos_if_5000` | ERR(RecursionLimit) 21ms 34MiB | ERR(RecursionLimit) 95ms 127MiB | ERR(SyntaxError) 72ms 15MiB |
| `dos_for_3000` | ERR(RecursionLimit) 76ms 34MiB | ERR(RecursionLimit) 100ms 115MiB | ERR(SyntaxError) 36ms 15MiB |
| `dos_add_chain_10000` | OK(5B) 95ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 136ms 108MiB | OK(5B) 89ms 20MiB |
| `dos_add_chain_100000` | CRASH(SIGSEGV) 41ms 46MiB | TRAP(RangeError: Maximum call stack size exceeded) 202ms 142MiB | CRASH(SIGABRT) 92ms 33MiB |
| `dos_tilde_chain_10000` | OK(10000B) 91ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 155ms 109MiB | OK(10000B) 1756ms 22MiB |
| `dos_and_chain_10000` | OK(4B) 81ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 154ms 119MiB | OK(4B) 19ms 20MiB |
| `dos_not_10000` | OK(4B) 86ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 67ms 100MiB | OK(4B) 64ms 20MiB |
| `dos_neg_10000` | OK(1B) 95ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 109ms 100MiB | OK(1B) 46ms 20MiB |
| `dos_filter_chain_10000` | OK(1B) 44ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 118ms 113MiB | OK(1B) 86ms 18MiB |
| `dos_attr_chain_10000` | OK(0B) 36ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 107ms 114MiB | ERR(UndefinedError) 25ms 18MiB |
| `dos_pow_chain_5000` | OK(1B) 28ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 133ms 99MiB | OK(1B) 82ms 17MiB |
| `dos_ternary_5000` | ERR(RecursionLimit) 23ms 34MiB | ERR(RecursionLimit) 82ms 101MiB | ERR(SyntaxError) 43ms 15MiB |
| `dos_str_mul_1e8` | ERR(OutputLimitExceeded) 88ms 34MiB | ERR(OutputLimitExceeded) 107ms 109MiB | OK(100000000B) 175ms 205MiB |
| `dos_str_mul_1e12` | ERR(OutputLimitExceeded) 17ms 34MiB | ERR(OutputLimitExceeded) 126ms 109MiB | ERR(InvalidOperation) 35ms 15MiB |
| `dos_list_mul_1e8` | ERR(OutputLimitExceeded) 20ms 34MiB | ERR(OutputLimitExceeded) 157ms 109MiB | OK(9B) 31ms 15MiB |
| `dos_list_mul_print` | ERR(OutputLimitExceeded) 76ms 34MiB | ERR(OutputLimitExceeded) 163ms 109MiB | OK(300000000B) 5719ms 582MiB |
| `dos_list_mul_nested` | OK(5B) 24ms 34MiB | OK(5B) 123ms 129MiB | OK(5B) 52ms 15MiB |
| `dos_list_add_doubling` | RSS-KILL 3556ms 3246MiB | TRAP(RangeError: WebAssembly.Memory.grow(): Unable to grow instance memory) 816ms 2161MiB | TIMEOUT 10087ms 811MiB |
| `dos_str_doubling` | ERR(OutputLimitExceeded) 89ms 41MiB | ERR(OutputLimitExceeded) 128ms 144MiB | RSS-KILL 886ms 3883MiB |
| `dos_replace_empty` | OK(7B) 17ms 34MiB | OK(7B) 123ms 125MiB | OK(8B) 51ms 40MiB |
| `dos_replace_chain` | CRASH(SIGABRT) 1372ms 2067MiB | TRAP(RangeError: WebAssembly.Memory.grow(): Unable to grow instance memory) 655ms 2664MiB | RSS-KILL 2200ms 3113MiB |
| `dos_range_list_1e8` | ERR(OutputLimitExceeded) 19ms 34MiB | ERR(OutputLimitExceeded) 77ms 123MiB | ERR(InvalidOperation) 59ms 15MiB |
| `dos_range_sum_1e8` | ERR(OutputLimitExceeded) 49ms 34MiB | ERR(OutputLimitExceeded) 86ms 123MiB | ERR(InvalidOperation) 76ms 15MiB |
| `dos_range_length_1e18` | OK(19B) 82ms 34MiB | OK(19B) 86ms 123MiB | ERR(InvalidOperation) 75ms 15MiB |
| `dos_pow_1e6` | ERR(InvalidOperation) 79ms 34MiB | ERR(InvalidOperation) 92ms 109MiB | ERR(InvalidOperation) 37ms 15MiB |
| `dos_pow_float_big` | ERR(InvalidOperation) 82ms 34MiB | ERR(InvalidOperation) 74ms 109MiB | OK(3B) 17ms 15MiB |
| `dos_indent_huge` | ERR(OutputLimitExceeded) 385ms 398MiB | ERR(OutputLimitExceeded) 398ms 692MiB | OK(200000018B) 245ms 492MiB |
| `dos_center_huge` | ERR(UnknownFilter) 50ms 34MiB | ERR(UnknownFilter) 94ms 123MiB | ERR(UnknownFilter) 78ms 15MiB |
| `dos_join_big` | ERR(OutputLimitExceeded) 82ms 34MiB | ERR(OutputLimitExceeded) 73ms 123MiB | ERR(InvalidOperation) 57ms 15MiB |
| `dos_sort_1e6` | ERR(OutputLimitExceeded) 33ms 34MiB | ERR(OutputLimitExceeded) 90ms 123MiB | ERR(InvalidOperation) 88ms 15MiB |
| `dos_sort_1e5_rev` | TIMEOUT 10046ms 34MiB | TIMEOUT 10084ms 141MiB | OK(1B) 16ms 21MiB |
| `dos_sort_attr_2e4` | OK(1B) 3662ms 34MiB | OK(1B) 7549ms 135MiB | OK(1B) 787ms 21MiB |
| `dos_batch_fill_huge` | RSS-KILL 1020ms 3124MiB | TRAP(RangeError: Offset is outside the bounds of the DataView) 766ms 2165MiB | RSS-KILL 512ms 3479MiB |
| `dos_unique_1e5` | TIMEOUT 10037ms 34MiB | TIMEOUT 10019ms 141MiB | OK(6B) 91ms 26MiB |
| `dos_unique_strs_1e5` | TIMEOUT 10046ms 34MiB | TIMEOUT 10033ms 135MiB | TIMEOUT 10033ms 22MiB |
| `dos_list_append_quadratic` | OK(5B) 881ms 34MiB | OK(5B) 759ms 126MiB | OK(5B) 788ms 16MiB |
| `dos_nested_loops_1e8` | ERR(FuelExhausted) 540ms 34MiB | ERR(FuelExhausted) 1024ms 127MiB | OK(2B) 3516ms 15MiB |
| `dos_while_like_recursion` | ERR(RecursionLimit) 70ms 34MiB | ERR(RecursionLimit) 131ms 127MiB | ERR(InvalidOperation) 23ms 16MiB |
| `dos_macro_recursion_wide` | ERR(FuelExhausted) 812ms 34MiB | ERR(FuelExhausted) 1842ms 127MiB | TIMEOUT 10045ms 15MiB |
| `dos_extends_cycle` | ERR(RecursionLimit) 71ms 34MiB | ERR(RecursionLimit) 117ms 125MiB | ERR(InvalidOperation) 16ms 15MiB |
| `dos_extends_self` | ERR(RecursionLimit) 51ms 34MiB | ERR(RecursionLimit) 82ms 125MiB | ERR(InvalidOperation) 85ms 15MiB |
| `dos_include_cycle` | ERR(RecursionLimit) 25ms 34MiB | ERR(RecursionLimit) 115ms 125MiB | ERR(BadInclude) 31ms 15MiB |
| `dos_include_self` | ERR(RecursionLimit) 20ms 34MiB | ERR(RecursionLimit) 92ms 125MiB | ERR(BadInclude) 18ms 15MiB |
| `dos_import_cycle` | OK(2B) 24ms 34MiB | OK(2B) 208ms 125MiB | ERR(BadInclude) 92ms 15MiB |
| `dos_include_fanout` | OK(10000000B) 130ms 36MiB | OK(10000000B) 315ms 163MiB | OK(10000000B) 129ms 35MiB |
| `dos_recursive_loop` | ERR(SyntaxError) 87ms 34MiB | ERR(SyntaxError) 88ms 123MiB | ERR(InvalidOperation) 86ms 15MiB |
| `dos_tojson_deep` | ERR(RecursionLimit) 35ms 34MiB | ERR(RecursionLimit) 94ms 134MiB | OK(3B) 73ms 15MiB |
| `dos_deep_list_print` | OK(134B) 84ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 141ms 136MiB | OK(10002B) 40ms 17MiB |
| `dos_deep_list_eq` | OK(4B) 32ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 127ms 131MiB | OK(4B) 71ms 18MiB |
| `dos_deep_list_sort` | OK(1B) 22ms 34MiB | TRAP(RangeError: Maximum call stack size exceeded) 94ms 138MiB | OK(1B) 40ms 16MiB |
| `dos_long_text_10mb` | OK(10000000B) 46ms 44MiB | OK(10000000B) 123ms 126MiB | OK(10000000B) 28ms 43MiB |
| `dos_many_vars` | OK(400000B) 86ms 67MiB | OK(400000B) 239ms 175MiB | OK(400000B) 60ms 46MiB |
| `dos_slice_huge_step` | ERR(InvalidOperation) 82ms 34MiB | ERR(InvalidOperation) 73ms 109MiB | ERR(InvalidOperation) 47ms 15MiB |
| `dos_batch_huge` | OK(1B) 57ms 34MiB | OK(1B) 91ms 123MiB | OK(1B) 77ms 15MiB |
| `dos_slice_filter_huge` | RSS-KILL 494ms 3780MiB | RSS-KILL 619ms 3466MiB | RSS-KILL 666ms 3256MiB |
| `dos_round_huge` | OK(3B) 93ms 34MiB | TRAP(RuntimeError: float unrepresentable in integer range) 143ms 129MiB | OK(3B) 32ms 15MiB |
| `dos_wordcount_big` | OK(7B) 99ms 35MiB | OK(7B) 115ms 123MiB | ERR(UnknownFilter) 80ms 34MiB |
