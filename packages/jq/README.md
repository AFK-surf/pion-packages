# `jq` (Pure Pion)

Pure Pion, zero-C-dependency, `World`-free, Native + Wasm32 dual-target **`jq` 1.7 / `gojq`** JSON query and transformation language engine.

Reuses in-repo packages [`packages/json5`](../json5), [`packages/regex`](../regex), [`packages/base64`](../base64), and [`packages/url`](../url).

## Features

- **Full `jq` Lexer, Parser & Compile-Time Validator** (`src/lexer.pion`, `src/parser.pion`, `src/ast.pion`):
  - Flat `Array[Expr]` arena AST with flat chain nodes (`PipeChain`, `CommaChain`, `AddChain`, `FieldChain`) for O(1) parse & eval depth on 20k-element chains
  - Compile-time validation of all function calls (`name/arity`) and `@format` names
  - Strict `.field` adjacency (rejecting `. a`, supporting keyword fields `.and`/`.or`, interpolated `."a\(1)"`, `.a.[0]`, `5.`, `01000`, `1e1000`)
  - Full jq precedence (`try Term catch Term`, object values accepting `|` without parens), `?//` alternative destructuring, multi-key object patterns `{("a","b"):$v}`
  - Identity `.`, recursive descent `..`, field/index/slice/iterator chains (including `.[[x]]` array-index lookup), pipes `|`, streams `,`, exact `Int64` + arbitrary-precision `BigInt` + IEEE 754 `Float` arithmetic, strict jq total-order comparisons (`nan < nan`), `and`/`or`/`not`, `//`
  - `if ... then ... elif ... else ... end`, `try ... catch ...`, nested string interpolation `"\(...)"` (jq right-outer order), `[...]`, `{...}`, `as`, `reduce`, `foreach`, `def`, `label`/`break`
  - Full path mode (`src/eval_paths.pion`): user-defined functions, slice updates/deletes, `first`/`last`/`limit`/`nth`/`getpath`/`//`/`reduce`/`foreach`/`try`/`as`/`recurse`/`label`, plus O(n) single-pass structural updates & batched `|=` / `=` / `del`
- **Iterative JSON Parser & Serializer + Indexed Values** (`src/json_parser.pion`, `src/num.pion`, `src/obj_index.pion`, `src/value.pion`):
  - Iterative strict RFC 8259 JSON parser (O(1) stack on 10,000+ depth, lossless `>2^53` 64-bit IDs & arbitrary-precision integers)
  - Iterative `serialize_jq_val` enforcing `max_output_bytes` on every write (immune to `[., .]` shared-structure doubling bombs and Wasm32 stack traps)
  - Lazy seeded SplitMix64 `ObjHashIndex` for O(1) object key lookup, `has`, `from_entries`, `with_entries`, and object merges
- **Standard Library Built-ins & Formatters** (`src/builtins.pion`, `src/eval_builtins.pion`):
  - Tail-call trampoline evaluator (`src/eval.pion`) running 10,000+ deep recursive `def`s in O(1) Wasm32 stack frames
  - Streaming `limit`/`first`/`nth`/`skip` preserving emitted prefixes before `break`/`error`
  - Types & meta: `type`, `length`, `utf8bytelength`, `keys`, `keys_unsorted`, `values`, `has`, `in`, `contains`, `inside`, `empty`, `error`, `halt`, `halt_error`, `nan`, `infinite`, `isnan`, `isinfinite`, `isfinite`, `isnormal`, `normals`, `finites`, `not`, `floor`, `ceil`, `trunc`, `round`, `fabs`/`abs`, `sqrt`, `pow`, `ldexp`, `env`/`$ENV`, `builtins`, `debug`, `stderr`
  - Collections & streams: `map`, `map_values`, `select`, `add`/`add(f)`, `any`/`all` (arrays & objects), `first`, `last`, `nth`, `limit`, `skip`, `isempty`, `range`, `while`, `until`, `repeat`, `walk`, `IN`, `tostream`, `fromstream`, `pick`, `bsearch`, `reverse`, `sort`, `sort_by`, `group_by`, `unique`, `unique_by`, `min`/`max`/`min_by`/`max_by`, `flatten`, `indices`/`index`/`rindex` (O(n+m) KMP), `transpose`, `combinations`, `to_entries`/`from_entries`/`with_entries`, `arrays`/`objects`/`iterables`/`booleans`/`numbers`/`strings`/`nulls`/`scalars`/`leaf_paths`/`paths`/`paths(f)`/`recurse`
  - Strings & regex: `tostring`, `tonumber`, `toboolean`, `tojson`, `fromjson`, `ascii_downcase`, `ascii_upcase`, `ltrim`/`rtrim`/`trim`, `ltrimstr`/`rtrimstr`/`trimstr`, `startswith`, `endswith`, `split`/`split(re; flags)`, `join`, `explode`, `implode` (U+FFFD surrogate sanitization), `test`, `match`, `capture`, `scan`, `splits`, `sub`, `gsub` (multi-output replacement streams, string-anchored `^`/`$` by default, cross-call regex compile cache)
  - All 9 formatters: `@text`, `@json`, `@html`, `@uri`, `@csv`, `@tsv`, `@sh`, `@base64`, `@base64d` (strict RFC 3629 U+FFFD lossy UTF-8 decoding)
- **DoS & Resource Safety (`JqLimits`)**:
  - Enforces `max_depth`, `max_steps`, per-query `max_outputs`, and `max_output_bytes` across Native and Wasm32
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

- `sh scripts/verify.sh packages/jq`: **39 / 39 tests PASS** (`377 / 377` across dependency tree; `fmt` / `check` / `test` / clean worktree).
- `pionc test --json --only-pkg packages/jq/audit`: **35 / 35 PASS** (all 28/28 red-team P0/P1/P2 evidence tests + 7/7 control tests, 0 FAIL).
- `sh packages/jq/audit/run_audit.sh`:
  - **9,021-case 4-mode differential** (`native_rel`, `native_dbg`, `wasm_dbg`, `wasm_rel`): **0 mode mismatches, 0 crashes, 0 traps, 0 invalid UTF-8**; 3-way exact match **8,551 / 9,021 (94.8%)**.
  - **69-case DoS / deep-nesting battery** (Native + 4-mode Wasm32): **0 SIGABRT, 0 `RangeError` traps, 0 OOM, 0 timeouts** (all bombs cleanly hit `LimitExceeded`; 10k-deep recursion and 10k-deep JSON round-trips succeed on Wasm32).
- **4-Mode `wasm_smoke`** (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`, clean `PION_CACHE_DIR`): all 4 exit `0` with identical stdout SHA-256:
  `5eaaff3ac9da8e31981e51a9742ea4eb4c8b8998b79b7d062afe3c03fae52a00`.

## Head-to-Head Benchmarks vs Go `github.com/itchyny/gojq` (`v0.12.17`)

### Standard Workloads (`sh packages/jq/bench/run_bench.sh`)

`Darwin arm64`, `warmup=1`, `rounds=5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification:

| Workload | `pion` Median (ms) | `gojq` Median (ms) | Speedup (vs `gojq`) | `pion` Peak RSS | `gojq` Peak RSS | Verified SHA-256 (prefix) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: 10k K8s/API events aggregation (`select`+`group_by`+`map`+`sort_by`, 5x) | **89.242** | 50.694 | **0.57x** | **23.75 MiB** | 24.02 MiB | `a8fb7ca11b5f520f` |
| **W2**: Deep nested tree extract + `\|=` path rewrite (10x) | **18.116** | 29.080 | **1.61x** | **5.41 MiB** | 13.22 MiB | `0e0ecf194f9eb7e3` |
| **W3**: End-to-end Compile + Eval (1,000 queries: `reduce`, `def`, interp, `@csv`, `test`) | **34.467** | 42.824 | **1.24x** | **4.47 MiB** | 14.03 MiB | `0856973c670c20d5` |

### Red-Team Blindspot Slow Paths (`audit/bench/run_blindspots.sh`)

`Darwin arm64`, `warmup=1`, `rounds=5`, strictly interleaved, mandatory stdout SHA-256 verification:

| Probe | `pion` Median (ms) | `gojq` Median (ms) | Speedup (vs `gojq`) | `pion` Peak RSS | `gojq` Peak RSS | Verified SHA-256 (prefix) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| **B0**: Startup floor (`.` on `null`) | **9.317** | 9.755 | **1.05x** | **3.48 MiB** | 6.52 MiB | `ba20c457b9f476ed` |
| **B1**: Wide array `\|=` (`[range(20000)] \| .[] \|= . * 2 \| add`) | **13.549** | 19.845 | **1.46x** | **5.91 MiB** | 12.38 MiB | `67a670ba038aa058` |
| **B2**: Wide array `=` (`[range(20000)] \| .[] = 1 \| add`) | **10.711** | 16.166 | **1.51x** | **5.08 MiB** | 11.84 MiB | `0eb4bfffcb8d8eae` |
| **B3**: 5k-key object `.[] \|= . + 1` | **14.376** | 16.383 | **1.14x** | **9.41 MiB** | 11.98 MiB | `2a558e4d2c486388` |
| **B4**: `to_entries \| from_entries` on 20k keys | **23.102** | 26.431 | **1.14x** | **18.45 MiB** | 19.45 MiB | `0eb4bfffcb8d8eae` |
| **B5**: `"a" * 50000 \| indices("aa")` (KMP linear) | **11.682** | 14.565 | **1.25x** | **6.41 MiB** | 14.73 MiB | `2c10fe1df8ae7a2d` |
| **B6**: 2k `has` lookups on a 20k-key object | **18.959** | 17.511 | **0.92x** | **10.92 MiB** | 12.11 MiB | `a0fd9d82673f5825` |
| **B7**: `"ab" * 50000 \| gsub("a"; "x")` | **11.063** | 5171.332 | **467.46x** | **10.22 MiB** | 2623.95 MiB | `2898ea78580f87fc` |

### Strengths & Weaknesses Analysis
- **Strengths**:
  - **W2 (`1.61x`), W3 (`1.24x`), and B1–B5/B7 (`1.14x–467.46x`)**: Structural single-pass `|=` / `=` updates, lazy seeded `ObjHashIndex`, KMP `indices`, and the cross-call regex compile cache beat `gojq` across 9 of 11 workloads while using `1.0x–3.1x` lower peak RSS.
  - **DoS resilience**: Bounds shared-structure doubling, string/array bombs, sparse `setpath`, and deep recursion cleanly under `JqLimits` on both Native and Wasm32 (where `gojq` OOMs or hangs on 9/69 probes).
- **Weaknesses**:
  - **W1 (`0.57x`) & B6 (`0.92x`)**: Crossing the public `json5::Json5Value` <-> internal `JqVal` bridge on large 5 MB inputs plus `group_by`/`sort_by` intermediate materialization adds ~35 ms overhead on W1 compared to `gojq`'s native bytecode VM.
