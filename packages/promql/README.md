# `promql` — Pure-Pion Prometheus PromQL Parser, Formatter & Evaluator

Pure-Pion implementation of **Prometheus PromQL**, targeting parity with Go's official `github.com/prometheus/prometheus/promql/parser` plus an in-memory instant & range time-series evaluation engine.

- **Zero C dependencies / No `World`**: Pure Pion (`packages/regex` for `=~` / `!~` & `label_replace`), runs identically on Native and `wasm32`.
- **Full Lexer, Duration & AST Parser (`src/lexer.pion`, `src/parser.pion`, `src/ast.pion`)**:
  - Comments (`# ...`), decimal/float/scientific/hex/`Inf`/`NaN` literals, double/single/backtick strings with full escape sequences.
  - Compound durations (`1y2w3d4h5m6s7ms`) with strictly descending unit validation and canonical formatting (`format_duration_ms`).
  - Instant Vector Selectors, Matrix Selectors (`[5m]`), Subqueries (`[1h:5m]`, `[1h:]`), `offset` (positive and negative), `@ <timestamp>` / `@ start()` / `@ end()`, UTF-8 quoted metric and label names (`{"http.requests", "k8s.pod"=~"web-.*"}`), and all 4 matchers (`=`, `!=`, `=~`, `!~`).
  - Full binary operator precedence & right-associative `^` (including `-2 ^ 2 == -(2 ^ 2)` and `2 ^ -3 == 2 ^ (-3)`), `bool`, `on`/`ignoring`, `group_left`/`group_right`, and set operators (`and`, `or`, `unless`).
  - All 14 PromQL aggregations (`sum`, `min`, `max`, `avg`, `group`, `stddev`, `stdvar`, `count`, `count_values`, `bottomk`, `topk`, `quantile`, `limitk`, `limit_ratio`) with prefix or suffix `by`/`without`.
  - Static semantic & type validation (non-empty matcher guard against `{job=~".*"}`, function arity & `ValueType` checking, `group_left`/`group_right` & `bool` constraints, parse-time regex validation).
- **Canonical Formatter & AST Inspection (`src/format.pion`)**:
  - `format_expr(expr)` (canonical single-line PromQL aligned with Go `parser.Expr.String()`), `prettify_expr(expr)` (multi-line indented formatting with round-trip guarantee), `extract_metric_names(expr)`, and `inspect_selectors(expr)`.
- **In-Memory Time-Series Evaluator (`src/eval.pion`)**:
  - `SeriesStore` with `eval_instant` and `eval_range`, supporting scalar/vector arithmetic & comparisons (`bool`), 1:1 and N:1 (`group_left`/`group_right`) matching, `and`/`or`/`unless`, all 14 aggregations, counter-reset-aware extrapolated `rate`/`increase`/`irate`, `delta`/`idelta`, `*_over_time`, `histogram_quantile`, `abs`/`ceil`/`floor`/`round`/`clamp*`/`absent`/`label_replace`/`label_join`/`sort`/`sort_desc`/`time`/`vector`/`scalar`.
- **Day-1 Safety Budgets (`PromqlLimits`)**:
  - `max_depth`, `max_tokens`, `max_nodes`, `max_series`, `max_samples` to prevent stack overflow (`SIGSEGV` on Native / `RangeError` on Wasm32) and memory exhaustion.

## Quick Start

```pion
import "promql"

let expr = match promql::parse_expr("histogram_quantile(0.95, sum by (le, job) (rate(http_request_duration_seconds_bucket[5m])))") {
  Ok(e) => e
  Err(err) => panic(err.to_string())
}

let canonical = promql::format_expr(expr)
let metrics = promql::extract_metric_names(expr) // ["http_request_duration_seconds_bucket"]
```

## Verification

```sh
sh scripts/verify.sh packages/promql
```

4-mode `wasm_smoke` (each with a clean `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/private/tmp/w14-promql-nd pionc run packages/promql/wasm_smoke
PION_CACHE_DIR=/private/tmp/w14-promql-nr pionc run --release packages/promql/wasm_smoke
PION_CACHE_DIR=/private/tmp/w14-promql-wd pionc run --target wasm32 packages/promql/wasm_smoke
PION_CACHE_DIR=/private/tmp/w14-promql-wr pionc run --target wasm32 --release packages/promql/wasm_smoke
```

All 4 modes exit `0` with byte-identical stdout:
`promql_wasm_smoke: OK checks=4` (`sha256:c4e142bf1f75557416da83cb340a7e2cb90a044dbb7da2d5bc7fecbc42239551`).

## Head-to-Head Benchmarks vs Go `prometheus/promql` (`v0.302.1`)

Run with:

```sh
sh packages/promql/bench/run_bench.sh
```

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, `-mod=readonly`, mandatory stdout SHA-256 verification across all rounds and implementations):

### W1: Production PromQL Parse + Canonical `String()` (`20,000` ops)

10 real alerting / Grafana dashboard queries (nested `histogram_quantile`, `rate`, `subquery`, `group_left`, `by`/`without`, regex matchers) parsed and canonically formatted 20,000 times.
SHA-256: `4468c0ee996b9e3b74716e749b56a5182b363c58bb46588c3916545e02dba783`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_promql`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 210.604 | 170.937 | 272.159 | 10530.20 | 2.98 MiB | **0.72x** |
| `go_promql` | 151.355 | 146.337 | 175.844 | 7567.73 | 30.53 MiB | 1.00x (baseline) |

### W2: Metric Selector Parse + Label Extraction (`50,000` ops)

5 complex metric selectors (multi-label matchers including `=~`/`!~`, duration ranges, `offset`/`@`) parsed with matcher/range/offset extraction 50,000 times.
SHA-256: `b30b421dfd79bb357f4833396984d7aa139d209a58dd7ebd77eb9323fd94a409`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_promql`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 357.538 | 351.256 | 366.687 | 7150.76 | 2.91 MiB | **0.40x** |
| `go_promql` | 143.705 | 140.104 | 150.897 | 2874.09 | 29.69 MiB | 1.00x (baseline) |

### W3: In-Memory Time-Series Eval (`200` iters, `5,600` points)

Pion `parse_expr` + `eval_instant` (`histogram_quantile(0.95, sum by (le, job) (rate(...[5m])))`) + `eval_range` (`sum by (job) (rate(...[5m]))` across 6 steps x 4 jobs) vs official Go `github.com/prometheus/prometheus/promql.Engine` over an in-memory TSDB head (`util/teststorage`).
SHA-256: `86a8fa5bef90340bc7ca17937f0a9c9e525f16cf33bee8dd1bc503a9b3786288`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_promql`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 17.750 | 17.107 | 18.222 | 3169.73 | 2.80 MiB | **2.64x** |
| `go_promql` | 46.888 | 41.993 | 47.584 | 8372.87 | 35.97 MiB | 1.00x (baseline) |

### Objective Performance Analysis

- **In-Memory Evaluation (W3, 2.64x)**: Against official Go `promql.Engine` (`v0.302.1`, including in-memory TSDB head setup via `util/teststorage`), Pion's `SeriesStore` + iterative AST evaluator runs **2.64x faster** (`17.75 ms` vs `46.89 ms`) with **12.8x lower Peak RSS** (`2.80 MiB` vs `35.97 MiB`). Note that Go's `teststorage` includes TSDB head initialization overhead (~20 ms) while Pion operates on a lightweight in-memory `SeriesStore`.
- **Parser & Regex Validation (W1 0.72x, W2 0.40x — Pion weakness)**: During parse-time semantic validation, `packages/promql` preprocesses RE2 syntax and compiles every `=~` / `!~` matcher with full NFA + LazyDFA construction in `packages/regex` to verify syntax and reject empty-matching selectors (`{job=~".*"}`). Go's `prometheus/promql/parser` uses `grafana/regexp` with fast literal/alternation analysis (`FastRegexMatcher`) that skips DFA construction for common patterns, giving Go an advantage on regex-heavy selector workloads (W2).
- **Memory Footprint**: `pion` runs in **2.80–2.98 MiB** Peak RSS across all 3 workloads vs Go's **29.69–35.97 MiB** (**10.2x–12.8x lower memory**, zero GC overhead, Wasm32-ready).
