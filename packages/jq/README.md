# `jq` (Pure Pion)

Pure Pion, zero-C-dependency, `World`-free, Native + Wasm32 dual-target **`jq` 1.7 / `gojq`** JSON query and transformation language engine.

Reuses in-repo packages [`packages/json5`](../json5), [`packages/regex`](../regex), [`packages/base64`](../base64), and [`packages/url`](../url).

## Features

- **Full `jq` Lexer & Parser** (`src/lexer.pion`, `src/parser.pion`, `src/ast.pion`):
  - Flat `Array[Expr]` arena AST with `max_depth` parse protection
  - Identity `.`, recursive descent `..`, field/index/slice/iterator chains (`.foo`, `."foo"`, `.[expr]`, `.[a:b]`, `.[]`, `?`)
  - Pipes `|`, multi-output streams `,`, arithmetic (`+ - * / %` with jq string/array/object/null semantics, shallow `+` and deep `*` object merge), strict jq total-order comparisons (`null < false < true < number < string < array < object`), `and`/`or`/`not`, alternative `//`
  - `if ... then ... elif ... else ... end` (multi-value conditions), `try ... catch ...`, nested string interpolation `"\(...)"`, `[...]`, `{...}` (shorthand, computed keys, Cartesian product)
  - Variable bindings `as $x` with array/object destructuring, `reduce`, `foreach` (2- and 3-arg), `def` (filter & value params, lexical closures, recursion), `label $out | ... break $out`
  - Path & update operators: `path(expr)`, `getpath`, `setpath`, `delpaths`, `del(expr)`, `|=`, `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `//=` (including `|= empty` deletion)
- **Standard Library Built-ins & Formatters** (`src/builtins.pion`, `src/eval.pion`):
  - Types & meta: `type`, `length`, `utf8bytelength`, `keys`, `keys_unsorted`, `values`, `has`, `in`, `contains`, `inside`, `empty`, `error`, `nan`, `infinite`, `isnan`, `isinfinite`, `isfinite`, `isnormal`, `not`, `floor`, `ceil`, `trunc`, `fabs`/`abs`
  - Collections & streams: `map`, `map_values`, `select`, `add`, `any`, `all`, `first`, `last`, `nth`, `limit`, `isempty`, `range`, `reverse`, `sort`, `sort_by`, `group_by`, `unique`, `unique_by`, `min`/`max`/`min_by`/`max_by`, `flatten`, `indices`/`index`/`rindex`, `transpose`, `combinations`, `to_entries`/`from_entries`/`with_entries`, `arrays`/`objects`/`iterables`/`booleans`/`numbers`/`strings`/`nulls`/`scalars`/`leaf_paths`/`paths`/`recurse`
  - Strings & regex: `tostring`, `tonumber`, `tojson`, `fromjson`, `ascii_downcase`, `ascii_upcase`, `ltrimstr`, `rtrimstr`, `startswith`, `endswith`, `split`, `join`, `explode`, `implode`, `test`, `match`, `capture`, `scan`, `splits`, `sub`, `gsub`
  - All 9 formatters: `@text`, `@json`, `@html`, `@uri`, `@csv`, `@tsv`, `@sh`, `@base64`, `@base64d`
- **DoS & Resource Safety (`JqLimits`)**:
  - Enforces `max_depth`, `max_steps`, `max_outputs`, and `max_output_bytes` across Native and Wasm32
  - `try ... catch ...` catches `RuntimeError` and `UserError` only; `LimitExceeded` and `InvalidLimits` always propagate

## Quick Example

```pion
import "jq"

let doc = "[{\"ns\":\"prod\",\"ms\":45,\"ok\":true},{\"ns\":\"prod\",\"ms\":15,\"ok\":true}]"
let q = "[.[] | select(.ok)] | group_by(.ns) | map({ns: .[0].ns, total: (map(.ms) | add)})"
let out = jq::eval_json(q, doc)
// Ok(["[{\"ns\":\"prod\",\"total\":60}]"])
```

## Verification

- `sh scripts/verify.sh packages/jq`: **38 / 38 tests PASS** (`jq_syntax_test.pion`, `jq_control_test.pion`, `jq_builtins_test.pion`, `jq_limits_test.pion`, `jq_edge_test.pion`).
- **4-Mode `wasm_smoke`** (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`, clean `PION_CACHE_DIR`): all 4 exit `0` with identical stdout SHA-256:
  `5eaaff3ac9da8e31981e51a9742ea4eb4c8b8998b79b7d062afe3c03fae52a00`.

## Head-to-Head Benchmarks vs Go `github.com/itchyny/gojq` (`v0.12.17`)

Run via `sh packages/jq/bench/run_bench.sh` (`Darwin arm64`, `warmup=1`, `rounds=5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification):

| Workload | `pion` Median (ms) | `gojq` Median (ms) | Speedup (vs `gojq`) | `pion` Peak RSS | `gojq` Peak RSS | Verified SHA-256 (prefix) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: 10k K8s/API events aggregation (`select`+`group_by`+`map`+`sort_by`, 5x) | **63.943** | 56.285 | **0.88x** | **16.25 MiB** | 23.20 MiB | `a8fb7ca11b5f520f` |
| **W2**: Deep nested tree extract + `\|=` path rewrite (10x) | **17.489** | 31.748 | **1.82x** | **4.91 MiB** | 13.30 MiB | `0e0ecf194f9eb7e3` |
| **W3**: End-to-end Compile + Eval (1,000 queries: `reduce`, `def`, interp, `@csv`, `test`) | **78.538** | 47.670 | **0.61x** | **4.34 MiB** | 13.84 MiB | `0856973c670c20d5` |

### Strengths & Weaknesses Analysis
- **Strengths**:
  - **W2 (`1.82x` faster than `gojq`)**: Flat `Array[Expr]` arena + direct structural `Json5Value` traversal/update avoids Go's `any` interface boxing and `map[string]any` rehashing during recursive descent and `|=` rewrites.
  - **Memory footprint**: `1.4x–3.2x` lower peak RSS than `gojq` across all three workloads (`4.34–16.25 MiB` vs `13.30–23.20 MiB`).
- **Weaknesses**:
  - **W1 (`0.88x`)**: `group_by`/`sort_by` currently materializes intermediate arrays per pipeline stage (`eval_collect`) and performs linear-scan object key lookup on small objects (`obj_get_last`), trailing `gojq`'s bytecode VM slightly on 10k-element array pipelines.
  - **W3 (`0.61x`)**: Each `test(...)` regex call currently compiles the pattern fresh via `packages/regex` without a cross-call regex cache, whereas `gojq` caches compiled regexes globally.
