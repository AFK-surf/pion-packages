# Red-team audit: `packages/promql` (`feat/pkg-promql` @ `3cd9f63`)

Reference implementation: Go `github.com/prometheus/prometheus` **v0.302.1** (Prometheus 3.2.1):
`promql/parser` (`ParseExpr`, `Expr.String()`, `Prettify`) for syntax and formatting, and
`promql.Engine` over an in-memory TSDB head (`util/teststorage`) for evaluation.
`parser.EnableExperimentalFunctions = true` in the oracle, because the package advertises
`limitk` / `limit_ratio` / `mad_over_time` / `double_exponential_smoothing`.

Reproduce everything (nothing is written into the worktree):

```sh
sh packages/promql/audit/run_audit.sh      # artifacts in /private/tmp/rt-promql-audit (override: AUDIT_OUT)
```

Each finding below maps to one or more `CHECK PASS|FAIL <id>` lines of the script; the script exits
non-zero while any check fails and is meant to be re-run unchanged on a fix branch.

| Severity | Findings | Meaning |
| --- | --- | --- |
| **P0** | 1 (F01) | crash (native SIGSEGV / Wasm32 `RangeError`) on small inputs under **default** limits |
| **P1** | 9 (F02–F10) | crash/hang when limits are raised or time params are hostile; wrong query results vs Prometheus 3.x; broken `format_expr` round-trip |
| **P2** | 9 (F11–F19) | static-validation gaps, compatibility, formatter parity, unimplemented functions, benchmark fairness |

## Suite layout (`packages/promql/audit/`)

| File | Role |
| --- | --- |
| `run_audit.sh` | one-shot runner: build (serial, 4 modes) → parse diff → eval diff → DoS → 4-mode consistency → bench fairness → summary / exit code |
| `go/` (`go.mod`, `go.sum` locked, `-mod=readonly`) | Go oracle: `parse`, `eval`, `w3engine` modes |
| `probe/` | Pion probe (`parse`, `eval`, `dos` modes), built native/wasm32 × debug/release |
| `cases/parse_corpus.txt` | 570 hand-written queries over every dimension of the audit brief |
| `gen_corpus.py` | + 2,000 deterministic mutants (fixed seed `20261123`) |
| `cases/eval_cases.txt`, `gen_eval.py` | 188 evaluation cases (series data + instant/range queries) |
| `cases/eval_groups.txt` | eval case ids per finding; all other cases are controls |
| `cases/dos_cases.txt`, `run_dos.py` | 11 crash/hang scenarios + 20 controls, each run in all 4 modes |
| `compare_parse.py`, `compare_eval.py` | comparators that print the `CHECK` lines |

## Measured summary (`sh packages/promql/audit/run_audit.sh`, Darwin arm64)

```
=== Summary ===
  P0: 3 failing checks (F01)
  P1: 16 failing checks (F02 F03 F04 F05 F06 F07 F08 F09 F10 F10b)
  P2: 9 failing checks (F11 F12 F13 F14 F15 F16 F17 F18 F19)
  total: 25 PASS, 28 FAIL
RESULT: FAIL (28 open checks)        exit 1, wall time 2 min 53 s
```

* Parse differential: 2,570 queries (570 hand-written + 2,000 mutants) — 52 over-accept, 36
  over-reject, 0 type mismatches, 106 `format_expr` mismatches, 27 round-trip failures, 258
  `prettify_expr` ≠ `Prettify`.
* Eval differential: 188 cases, 46 mismatches, all assigned to findings; 142/142 controls match.
* DoS: 11 scenarios fail (crash or hang), 20 controls pass, in all 4 modes.
* 4-mode: parse (2,570 lines) and eval (522 lines) outputs byte-identical across native/wasm32 ×
  debug/release; `wasm_smoke` prints `promql_wasm_smoke: OK checks=4`
  (`sha256:c4e142bf…239551`, matches the README) in all 4 modes.

---

## P0

### F01 — Stack overflow in the evaluator on left-associative operator chains under default limits

`CHECK F01.a/b/c`. Default `PromqlLimits` (`max_depth = 128`, `max_tokens = 65536`).

| Input (default limits) | native debug/release | wasm32 debug/release |
| --- | --- | --- |
| `1+1+…+1`, 600 terms (1.2 KB) | ok | **`RangeError: Maximum call stack size exceeded`** |
| `1+1+…+1`, 30,000 terms (60 KB, 59,999 tokens < `max_tokens`) | **SIGSEGV (139)** | **RangeError** |
| `foo and foo and …`, 20,000 terms | **SIGSEGV** | **RangeError** |

Go parses and evaluates all three (`String()` round-trips; the engine returns the result).

Root cause. `Parser::parse_expr_prec` (`src/parser.pion:1142-1215`) consumes a left-associative chain
in a `while` loop and only calls `enter_depth` around the **right** operand (`:1161-1172`), so a chain
of N operators yields a left-deep tree of depth N while the parser's depth counter never exceeds 2;
`max_depth` therefore never fires. `eval_node` → `eval_binary` (`src/eval.pion:1699`, `:1507-1523`)
then recurse once per tree level with large frames — 600 levels exhaust the default Node/V8 Wasm
stack, ~15,000 exhaust the 8 MB native stack. (Parsing, `format_expr` and `prettify_expr` of the same
trees survive at these sizes, but `write_expr_node` / `write_pretty_node` / `collect_selectors` in
`src/format.pion` are equally unbounded.) Alerting rules such as `a or b or c …` with a few hundred
alternatives are realistic, and the input is accepted as valid, so a server embedding the package is
killed by one query; on Wasm32 the trap escapes the `Result` API.

Fix direction: count depth for the accumulated left operand as well (each loop iteration that wraps
`lhs` in a new `BinaryExpr` is one level), or make evaluation/formatting iterative; give the whole
pipeline one depth budget that is proven stack-safe on Wasm32.

## P1

### F02 — `max_depth` is not a stack-safety guarantee once raised

`CHECK F02.a–d`. `validate_limits` (`src/ast.pion:101`) only requires `max_depth > 0`; nothing caps it to
what the recursive parser/formatter/evaluator can survive.

| Input | limits | native | wasm32 |
| --- | --- | --- | --- |
| `((((1))))` depth 1,000 | `max_depth = 1000` | ok | **RangeError** |
| `((((1))))` depth 20,000 | `max_depth = 20000` | **SIGSEGV** | **RangeError** |
| `sum(sum(…foo))` depth 20,000 | `max_depth = 20000` | **SIGSEGV** | **RangeError** |
| 20,000 × unary `-` | `max_depth = 20000` | **SIGSEGV** | **RangeError** |

On Wasm32 the safe ceiling is ≈ 300–500 nested parentheses; the default (128) is safe (`CTRL.02/03`).
The README promises the budgets "prevent stack overflow (SIGSEGV on Native / RangeError on Wasm32)".
Fix: clamp `max_depth` to a verified ceiling (or return `InvalidLimits`), or remove recursion.

### F03 — Unbounded evaluation loops (CPU DoS, Int64 wrap-around)

`CHECK F03.a–d` — every one times out (10 s) in all 4 modes with flat memory.

* `eval_range(foo, 0, 1e12, 1)` — `eval_range_impl` (`src/eval.pion:1823-1901`) loops once per step
  with no cap; Prometheus' HTTP API refuses more than 11,000 points per series (the oracle applies the
  same API-level checks: `end < start`, `step <= 0`, `> 11000` points). `max_samples` is only charged
  for selected samples, so an empty or absent series costs nothing and the loop never stops.
* `eval_range(foo, i64::MAX-807, i64::MAX, 600)` — `t = t + step_ms` (`:1892`) overflows to a negative
  value and the loop restarts forever.
* `max_over_time(foo[100y:1ms])` — the subquery loop (`:1725-1757`) runs 3.15 × 10¹² inner
  evaluations; `max_over_time(max_over_time(foo[1d:1s])[1d:1s])` 7.5 × 10⁹. No step or work budget
  exists for subqueries either.

### F04 — `rate` / `increase` / `delta` extrapolation uses the Prometheus 2.x order

`CHECK F04` (eval cases E001–E004, E013, E029).
`extrapolated_rate` (`src/eval.pion:627-685`) applies the "extrapolate to zero" clamp **before** the
`1.1 × average interval` threshold. Prometheus 3.x (`promql/functions.go:146-163` in v0.302.1)
first replaces a too-long `durationToStart` with `avg/2`, and only then clamps by `durationToZero`.
Whenever `avg/2 < durationToZero < 1.1·avg` and the series starts late in the window, results differ:

```
series http_requests_total{job="web"}  150s:10 200s:20 250s:30 300s:40
increase(http_requests_total{job="web"}[5m]) @300s   Go 35    Pion 40
rate(...)                                             Go 0.1167 Pion 0.1333
```

The bench W3 Go loop copies the same 2.x formula (see F19), so the W3 SHA-256 parity did not catch it.

### F05 — Lookback and subquery windows are left-closed (Prometheus 3.x: left-open)

`CHECK F05` (E030, E034, E036, E037, E046, E047).

* Instant selector: `eval_vector_selector` accepts `ts >= t - lookback` (`src/eval.pion:515-516`).
  3.x uses `(t - 5m, t]`: a sample exactly 5 m old is stale.
  `old` with one sample at 0 s, evaluated at 300 s: **Go: empty, Pion: 42**; range query 0..300 s
  returns 6 points instead of 5.
* Subqueries: the first step is `start` itself when aligned (`:1718-1721`), so
  `count_over_time(edge[5m:1m])` sees 6 points (Go 5); and for negative starts `start / step` truncates
  toward zero, so alignment is off by one step (`count_over_time(vector(1)[90s:1m])` at 0 s: Go 2,
  Pion 1; at 30 s: Go 1, Pion 2).

### F06 — Many-to-one matching without `group_left`/`group_right` silently returns data

`CHECK F06` (E060). `a{job="x",i="1"}`, `a{job="x",i="2"}` × `b{job="x"}`: `a * on(job) b` must fail
("multiple matches for labels: many-to-one matching must be explicit (group_left/group_right)"); Pion
returns three samples. The 1:1 branch of `eval_binary` (`src/eval.pion:1651-1691`) only checks that
each LHS element has at most one RHS partner; it never checks that two LHS elements share one
signature. (The mirrored case `b * on(job) a` correctly errors — control E061.)

### F07 — `topk` / `bottomk` treat NaN as the largest and the smallest value

`CHECK F07` (E095–E098). The insertion sorts (`src/eval.pion:945-1001`) compare with `<` / `>`, which
are false for NaN, so a NaN stays wherever it was inserted. Prometheus ranks NaN last in both
directions. `topk(1, n)` over {NaN, 5, 1, +Inf, -Inf}: **Go `+Inf`, Pion `NaN`**;
`bottomk(2, n{k=~"nan|five|one"})`: Go {1, 5}, Pion {NaN, 1}.

### F08 — Regex matchers do not use `(?s)`: `.` does not match `\n`

`CHECK F08` (E189–E191, E197). `compile_promql_regex` (`src/parser.pion:219-224`) anchors with
`^(?:…)$`; Prometheus uses `^(?s:…)$`. With label value `"line1\nline2"`:
`ml{v=~"line1.*"}` / `ml{v=~".*line2"}` select nothing (Go: the series), `!~` keeps it (Go: drops
it), and `label_replace(…, "(.*)")` silently does not rewrite it.

### F09 — `timestamp()` returns the evaluation time

`CHECK F09` (E041, E042). Selected samples are stored with `eval_ts_ms` instead of the sample's own
timestamp (`src/eval.pion:531`), and `timestamp` reads that field (`:1497`).
`timestamp(edge)` at 330 s with the last sample at 300 s: **Go 300, Pion 330**;
`timestamp(old @ 10)`: Go 0, Pion 300.

### F10 — Number literals are not correctly rounded; `format_expr` output does not re-parse

`CHECK F10` / `F10b` (27 corpus entries each).

* `parse_f64_str` (`src/lexer.pion:461-…`) accumulates mantissa digits into a `Double` and multiplies
  by a binary-powered `10^exp`, which is not correctly rounded: `1e300` → `1.0000000000000006e+300`,
  `1e-300` → `9.999999999999994e-301`, `2.2250738585072014e-308` → `2.2250738585072e-308`,
  `5e-324` → `0`, `123456789012345678901234567890` → `…566e+29` (Go `…568e+29`). The parsed value
  is wrong, and formatting it gives a different literal.
* `Inf` is formatted as `+Inf` (`format_number_lit`, `src/format.pion:50`), but the parser does not
  fold unary `+`/`-` into number literals as Go does (`parse_unary`, `src/parser.pion:1005-1049`), so
  `+Inf` re-parses as `UnaryExpr(+, Inf)` and formats as `++Inf`; `-Inf` → `-+Inf`, `1 + Inf` →
  `1 + +Inf` → `1 + ++Inf`. The README's "round-trip guarantee" does not hold for any expression that
  contains an infinite literal.

## P2

### F11 — Parser accepts PromQL that Go rejects (`CHECK F11`, 52 corpus entries)

| Input | Go v0.302.1 | Pion | Where |
| --- | --- | --- | --- |
| `foo{__name__="bar"}`, `foo{__name__="foo"}`, `foo{b="1",__name__="foo"}` | `metric name must not be set twice` | accepted (the first one can never match) | `parse_matchers_brace`, `src/parser.pion:381-397` |
| `foo offset 1m [5m]`, `foo @ 100 [5m]` | `no offset modifiers allowed before range` | accepted, modifiers moved after the range | `parse_postfix`, `:947-962` |
| `on`, `bool`, `ignoring`, `group_left`, `atan2`, `foo + atan2`, `nan{a="b"}`, `inf{a="b"}` | keyword / unexpected token | accepted as metric names | `parse_primary`, `:859-895` |
| `1__0`, `1_`, `1_0_`, `00_`, `0x__`, `1_000._000_000` | `bad number or duration syntax` | accepted | `tokenize` / `parse_f64_str`, `src/lexer.pion` |
| `1e309`, `1E900`, `.1e510`, `0xFFFFFFFFFFFFFFFF…` | value out of range / invalid syntax | `+Inf`, rounded float | lexer |
| `foo[293y]`, `foo[9223372036854775807ms]` | `duration out of range` (int64 ns ≈ 292 y) | accepted | `parse_duration_ms_impl` |
| `foo @ 1e300`, `foo @ 1e900` | `timestamp out of bounds for @ modifier` | silently saturated to `@ 9223372036854775.807` | `parse_at_value`, `src/parser.pion:431` |
| `foo offset 0s`, `{"foo"} offset 0m` | `duration must be greater than 0` | accepted | `parse_offset_value` |
| `holt_winters(foo[5m], 0.5, 0.5)` | unknown function (removed in 3.0) | accepted | `lookup_func_sig`, `:550` |
| `foo{a=~"x{1001}"}`, `x{9000}`, `a**` | RE2: invalid repeat count / nested repetition | accepted (Rust-style `packages/regex`) | `compile_promql_regex` |

### F12 — Parser rejects PromQL that Go accepts (`CHECK F12`, 36 corpus entries)

* Numbers as durations (3.x): `foo[5]`, `foo[300]`, `foo offset 5`, `predict_linear(foo[5], 3600)`.
* Quoted metric name only allowed as the first item: `{env="prod", "http.requests"}` and
  `{"foo", "bar"}` are valid in Go (`parse_matchers_brace`, `:314`).
* Duplicate labels in `by`/`without`/`on`/`ignoring`/`group_left(…)` are rejected
  (`parse_label_list`, `:285`); Go accepts them.
* Missing functions: `sort_by_label`, `sort_by_label_desc`, `histogram_stddev`, `histogram_stdvar`,
  `info`; `label_join` requires 4 arguments instead of 3 (`:593`).
* `label_replace(…, "(")`: Go validates the regex at evaluation time; Pion fails the parse.
* Regex dialect: RE2 reads `b{.*` and `x{100x}` as literals; `packages/regex` errors.

### F13 — `format_expr` differs from Go `Expr.String()` (`CHECK F13`, 106 corpus entries)

Only cases where Go's own output re-parses to itself are counted (6 Go formatter quirks such as
`on (a.b)` for UTF-8 label names are reported as `format_go_quirk(info)` and excluded).
Label matchers are not sorted (`foo{c="d",a="b"}`); `{__name__="foo"}` / `{"metric.name"}` are
rewritten to `foo` / `{"metric.name"}` (Go keeps `{__name__="…"}`); numbers use integer notation
(`1.5e10` → `15000000000`, Go `1.5e+10`; `1_000_000` → `1000000`, Go `1e+06`); durations keep
`y`/`w` (`1y2w3d…` vs Go `382d…`); `@ 1.0005` is truncated to `1.000` (Go rounds to `1.001`, and
the stored millisecond value differs too); unary signs on literals are not folded (`+1`, `--1`,
`-+1`); `sum by () (x)` and `x * ignoring() y` keep the empty clause; `\a`, `\x01`, `\x7f` are
emitted as raw control bytes (`quote_promql_string`, `src/format.pion:4`).

### F14 — `prettify_expr` is not `parser.Prettify` (`CHECK F14`, 258 corpus entries)

`write_pretty_node` (`src/format.pion:280`) always breaks binary operators and aggregations over
lines; Go `Prettify` keeps any node that fits in 100 columns on one line. `lib.pion` documents
`prettify_expr` as `parser.Prettify()`. Output size is also quadratic in nesting depth (1,000 nested
parentheses → 2 MB of indentation).

### F15 — Functions accepted by the parser but missing in the evaluator (`CHECK F15`)

`eval_call` (`src/eval.pion:1504`) returns `EvalError("function not supported")` for: `deriv`,
`predict_linear`, `holt_winters`, `double_exponential_smoothing`, `mad_over_time`, all
trigonometric functions (`sin`…`atanh`), `deg`, `rad`, `histogram_fraction`, `histogram_count`,
`histogram_sum`, `histogram_avg`, `day_of_month`, `day_of_week`, `day_of_year`, `days_in_month`,
`hour`, `minute`, `month`, `year` (cases E014, E015, E027, E058, E146–E149, E160–E162).

### F16 — Label-set semantics (`CHECK F16`)

`last_over_time` drops `__name__` (Go keeps it, E021); `absent_over_time(x{job="x"}[5m])` returns
`{}` instead of `{job="x"}` (E026); `absent(x{job="x",job="y"})` emits a label set with a duplicate
`job` (Go `{}`, E172); `label_replace` accepts `"1bad"` / `""` as destination and produces invalid
label names (Go errors, E181/E182); `count_values` renders values with `format_number_lit`
(`1e+21`, `0` for `-0`; Go `1000000000000000000000`, `-0`, E109); `label_join` with no source
labels (E187) and `label_replace` with an invalid regex (E185, error stage) — see F12.

### F17 — `histogram_quantile` does not merge buckets with the same upper bound (`CHECK F17`)

`le="1"` and `le="1.0"` are two buckets for Pion; Go coalesces them (sums counts) before
interpolating: `histogram_quantile(0.5, …{job="dup"})` Go `0.625`, Pion `1` (E050).

### F18 — Invalid `topk` / `limit_ratio` parameters accepted (`CHECK F18`)

`topk(1e300, x)`, `topk(NaN, x)` and `limit_ratio(NaN, x)` fail in Go ("Scalar value … overflows
int64" / "Ratio value is NaN"); Pion silently returns an empty vector (`param_num.to_int64()`
saturates/zeroes, `src/eval.pion:946`, `:1042`). No Wasm32 float→int trap was found: Pion's
`to_int64()` saturates in all 4 modes (`CTRL.04–15`).

### F19 — Benchmark fairness: W3 is not a head-to-head with Prometheus (`CHECK F19`)

Read-only review of `packages/promql/bench/` (not modified):

* **W1 (parse + `String()`) — fair.** Go runs the full `parser.ParseExpr` + `Expr.String()`;
  Pion `parse_expr` + `format_expr`; identical stdout hash, so the 10 production queries format the
  same. (The workload avoids every construct in F10/F13, so it says nothing about parity elsewhere.)
* **W2 (selector parse + matcher extraction) — fair.** Both parse completely (Go compiles regex
  matchers in `labels.NewMatcher`, Pion validates them with `packages/regex`) and hash the same
  matcher triples, range and offset.
* **W3 (in-memory eval) — not a head-to-head with Prometheus.** `bench/go_bench/main.go` does not
  import `promql`; it is a ~150-line loop over pre-built slices with no parsing, no selector
  matching, no label-set grouping, and it re-implements `extrapolatedRate` / `histogramQuantile`
  line by line **from Pion's code**, including the Prometheus 2.x extrapolation order (F04) and no
  bucket coalescing (F17). Matching SHA-256 therefore proves self-consistency, not upstream parity,
  and the column header `go_promql` / "Speedup vs go_promql" is misleading. Timing of the same
  workload (run_audit §5, 5-run medians): Pion bench 9.11 ms, Go hand loop 8.29 ms, real
  `promql.Engine` (audit `oracle w3engine 200`) 28.75 ms *including* TSDB open + 440 appends
  (≈ 20 ms with 0 iterations). Recommendation: drive W3 through `promql.Engine` (as
  `audit/go/main.go` `runW3Engine` does) and hash the engine's output.
* Methodology otherwise OK: `-mod=readonly`, `--warmup 1 --rounds 5`, interleaved, SHA-256 checked.

---

## Controls (attacks that did not find a defect)

* Default-limit nesting (`((…))`, `sum(sum(…))` up to 127 levels), right-associative `^` chains
  (`LimitExceeded`), 30,000-term `^` chain — all 4 modes.
* Float→int conversions with `1e300`, `-1e300`, `NaN`, `±Inf` in `@`, `topk`, `limitk`,
  `limit_ratio`, `quantile`, `count_values`, number formatting: no Wasm32 trap (`to_int64`
  saturates).
* Regex bombs: `(?:(?:x{1000}){1000}){1000}` is rejected by `packages/regex`'s size limit;
  `(a*)*(a|aa)*b` over a 50 KB value runs in linear time.
* 10,000-series `count by` / `* on(i)`: 0.07 s / 0.14 s.
* Duration overflow (`99999999999y`) → error; matrix/subquery ranges and steps `<= 0` rejected;
  `{}`, `{a=~".*"}`, `{a!="x"}`, `{__name__=~".*"}`, `{a=~"foo|"}` rejected; `bool` on non-comparison,
  `group_left` on set operators, scalar-scalar comparison without `bool` rejected; static type
  checks of every corpus entry agree with Go (`PARSE-TYPE`).
* 142 eval controls agree with Go: counter resets in `rate`/`increase`/`irate`/`resets`, all
  `*_over_time`, `histogram_quantile` with unsorted / missing `+Inf` / non-monotonic / zero / bad `le`
  buckets and `phi` ∉ [0,1] / NaN, group_left / group_right label copying, set operators, NaN
  comparisons, division by zero, `absent`, `label_replace` / `label_join`, `eval_range` argument
  validation (`step <= 0`, `start > end`).
* 4-mode consistency: parse and eval differential outputs and `wasm_smoke` are byte-identical across
  native/wasm32 × debug/release (`4MODE.*`).
