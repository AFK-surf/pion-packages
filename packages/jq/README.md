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

## Formal Verification (Lean 4)

Production `#verify` kernels (1 type, 14 functions, 0 externals) across `src/types.pion`, `src/lexer.pion`, `src/value.pion`, and `src/json_parser.pion` are extracted via `pionc extract-lean` and formally verified in `packages/jq/proofs/` (**22 theorems**, 0 `sorry`, 0 `admit`, 0 custom axioms, 0 `bv_decide`, 0 `native_decide`):

- **`JqProofs/LexerAndUtf8.lean` (11 theorems)**: RFC 8259 §2 `is_json_ws` exact 4-byte whitespace spec, `is_json_str_fast_byte` exact spec & escape disjointness, `is_ascii_alpha`/`is_ascii_digit` disjointness, `is_ident_char` spec, `hex_val` range & exact nibble decoding, `sanitize_utf8_cp` RFC 3629 scalar-value safety & idempotence, UTF-16 `is_high_surrogate`/`is_low_surrogate` disjoint partition of `[0xD800, 0xDFFF]`, and `decode_surrogate_pair` exact supplementary scalar value (`[0x10000, 0x10FFFF]`), preservation under `sanitize_utf8_cp`, and injectivity.
- **`JqProofs/SliceAndLimits.lean` (11 theorems)**: `JqLimits::default` positivity & `jq_limits_is_valid` iff characterization, `clamp_slice_idx` total `[0, len]` bounds (including `I32.min`), identity on `[0, len]`, negative-offset resolution, underflow/overflow clamping, idempotence, non-negative monotonicity, and `clamp_slice_i64` full 64-bit overflow-free clamping into `[0, len]`.
- **Reproduce**: `packages/jq/proofs/run_proofs.sh` (verifies extraction, static scan, `lake build`, `CheckAxioms.lean` standard-axioms-only check, and 35-case Native Pion vs Lean `EvalDiff` `diff -u` cross-check).

## Head-to-Head Benchmarks vs Go `github.com/itchyny/gojq` (`v0.12.17`)

### Standard Workloads (`sh packages/jq/bench/run_bench.sh`)

`Linux x86_64`, `warmup=1`, `rounds=5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification:

| Workload | `pion` Median (ms) | `gojq` Median (ms) | Speedup (vs `gojq`) | Verified SHA-256 (prefix) |
| --- | ---: | ---: | ---: | --- |
| **W1**: 10k K8s/API events aggregation (`select`+`group_by`+`map`+`sort_by`, 5x) | **212.964** | 253.895 | **1.19x** | `a8fb7ca11b5f520f` |
| **W2**: Deep nested tree extract + `\|=` path rewrite (10x) | **46.185** | 140.291 | **3.04x** | `0e0ecf194f9eb7e3` |
| **W3**: End-to-end Compile + Eval (1,000 queries: `reduce`, `def`, interp, `@csv`, `test`) | **113.370** | 289.659 | **2.56x** | `0856973c670c20d5` |

### Red-Team Blindspot Slow Paths (`audit/bench/run_blindspots.sh`)

`Linux x86_64`, `warmup=1`, `rounds=5`, strictly interleaved, mandatory stdout SHA-256 verification:

| Probe | `pion` Median (ms) | `gojq` Median (ms) | Speedup (vs `gojq`) | Verified SHA-256 (prefix) |
| --- | ---: | ---: | ---: | --- |
| **B0**: Startup floor (`.` on `null`) | **11.338** | 22.062 | **1.95x** | `ba20c457b9f476ed` |
| **B1**: Wide array `\|=` (`[range(20000)] \| .[] \|= . * 2 \| add`) | **38.412** | 82.246 | **2.14x** | `67a670ba038aa058` |
| **B2**: Wide array `=` (`[range(20000)] \| .[] = 1 \| add`) | **25.048** | 66.405 | **2.65x** | `0eb4bfffcb8d8eae` |
| **B3**: 5k-key object `.[] \|= . + 1` | **40.761** | 77.601 | **1.90x** | `2a558e4d2c486388` |
| **B4**: `to_entries \| from_entries` on 20k keys | **107.889** | 123.410 | **1.14x** | `0eb4bfffcb8d8eae` |
| **B5**: `"a" * 50000 \| indices("aa")` (KMP linear) | **32.427** | 103.467 | **3.19x** | `2c10fe1df8ae7a2d` |
| **B6**: 2k `has` lookups on a 20k-key object | **107.278** | 122.666 | **1.14x** | `a0fd9d82673f5825` |
| **B7**: `"ab" * 50000 \| gsub("a"; "x")` | **47.044** | 28731.948 | **610.75x** | `2898ea78580f87fc` |

### Strengths & Weaknesses Analysis
- **Strengths**:
  - **All 11 / 11 workloads (W1–W3 `1.19x–3.04x`, B0–B7 `1.14x–610.75x`)**: Zero-allocation `eval_one` / `Identity` fast paths, direct `parse_json_to_json5` + scalar-inlined `from_json5`/`to_json5`, single-probe seeded `ObjHashIndex`, O(N) hash-bucket `group_by`, single-buffer iterative mergesort, zero-alloc scalar `jq_cmp`/`jq_eq`, structural single-pass `|=` / `=` updates, KMP `indices`, and the cross-call regex compile cache outperform `gojq` across every standard and red-team workload.
  - **DoS resilience**: Bounds shared-structure doubling, string/array bombs, sparse `setpath`, and deep recursion cleanly under `JqLimits` on both Native and Wasm32 (where `gojq` OOMs or hangs on 9/69 probes).
- **Remaining Trade-offs**:
  - Public `run` / `run_with_limits` API crosses the `json5::Json5Value` <-> `JqVal` boundary; `eval_json` avoids this conversion entirely when operating directly on JSON strings.
