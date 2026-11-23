# RT-jq: red-team audit of `packages/jq`

- **Target**: `origin/feat/pkg-jq` @ `35ff1bb` (`packages/jq/src/*`, 7.4 kLoC Pion), toolchain `pionc` @ `AFK-surf/pion@79d1fbd`.
- **References**: Go `github.com/itchyny/gojq v0.12.17` (used as a library, `audit/diff/go`) and the system `jq 1.7.1` as the tie-breaker.
- **Machine**: Darwin arm64 (tokyo-mac-studio-0), node v24.22.2 for wasm32.
- **Scope rule**: this audit adds files under `packages/jq/audit/` only. `sh scripts/verify.sh packages/jq` still passes 38/38 (`jq`), 376/376 total, worktree clean.

## How to reproduce

```sh
sh packages/jq/audit/run_audit.sh            # all: build, tests, expect, diff, dos, wasm, bench
sh packages/jq/audit/run_audit.sh tests      # only the redteam_test.pion verdicts
AUDIT_OUT=/tmp/x sh packages/jq/audit/run_audit.sh diff
```

| Piece | What it does |
| --- | --- |
| `redteam_test.pion` (+ `pion.toml`) | 28 evidence tests `p0_*`/`p1_*`/`p2_*` (all FAIL on 35ff1bb) + 7 `control_*` tests (all PASS) |
| `diff/check_expectations.py` | Re-runs all 111 `expect()` calls of the test file on Pion, gojq and jq: every evidence expectation is met by gojq **and** jq and missed by Pion; every control is met by all three (0 violations) |
| `diff/gen_corpus.py` | Deterministic corpus, 9,021 cases: 72 builtins x 26 inputs, 99 parametrised builtins x 26 inputs, 387 syntax/stream/path vectors x 3 inputs, 82 regex/format filters x 16 strings, 26 number filters x 23 numbers, 1,500 seeded grammar-fuzz programs, 498 cases from gojq's own `cli/test.yaml` |
| `diff/pion_runner`, `diff/go` | Same-schema runners (one JSON line per case) for Pion and gojq; the Pion runner builds for native and wasm32 |
| `diff/run_diff.py` | 3-way verdicts (match / fmt / bug / gojq-only / split / errmsg), crash-restart, 4-mode consistency |
| `dos/run_dos.py` | 69 isolated DoS / complexity / bomb / deep-nesting cases, RSS-capped (3 GiB) and timed, any number of Pion modes vs gojq |
| `bench/run_blindspots.sh` | Slow paths missing from `bench/`, through `scripts/bench_compare.py` with SHA-256 checks |

## Summary

| Severity | Count | Theme |
| --- | ---: | --- |
| **P0** | 8 | regex anchors bypass validation; 64-bit IDs corrupted by `.`; wrong `%`; outputs lost on error/break; invalid UTF-8 output; `max_output_bytes` bypass (one process abort); quadratic `\|=`/`=`/`from_entries` (minutes of CPU under the default `JqLimits`); wasm32 stack trap at recursion depth ~80 |
| **P1** | 12 | path expressions through user `def`/slices/`first`/`getpath`/`//`/...; unknown functions are not compile errors; `. a` accepted; `try` precedence; `{k: a \| b}`; `sub`/`gsub` multi-output; `add`/`any`/`all`/`join` on objects; per-collection `max_outputs`; `parse_json` depth 128; missing core builtins |
| **P2** | 11 | `-0` stringification, stream ordering, `nan < nan`, null `has`/`indices`, binding edge cases, lexer coverage, `@sh`/`@csv` details, `tonumber`, `"s" * 0.5`, depth limit vs ordinary recursion, error-message wording |

Differential statistics on the 9,021-case corpus (`native_rel`, verdicts against gojq, jq as tie-breaker):

| Verdict | Cases | Meaning |
| --- | ---: | --- |
| match | 7,882 (87.4%) | identical output text, or both error |
| fmt | 70 | same JSON values, different number spelling (mostly big integers printed as `4.7e+21`) |
| errmsg | 32 | only the message inside `try ... catch .` differs |
| gojq-only | 328 | Pion differs from gojq but **agrees with jq 1.7.1** (not counted against Pion) |
| split | 51 | all three differ (e.g. `-0 \| tostring`: Pion `"-0.0"`, gojq `"0"`, jq `"-0"`) |
| **bug** | **652** (252 distinct queries) | Pion differs while gojq and jq agree |
| invalid_utf8 | 2 | Pion emitted bytes that are not UTF-8 (P0-5) |
| gojq-timeout | 4 | gojq did not finish in 3 s (Pion hit `max_outputs`) |

Of the 652 `bug` cases: 271 differ in value, 194 are "unknown function" (missing builtin), 85 are other runtime errors where gojq/jq produce a value, 69 are "invalid path expression", 31 syntax rejections, 2 limits.

4-mode consistency (`native_rel`, `native_dbg`, `wasm_dbg`, `wasm_rel`, same 9,021 cases): **0 crashes / 0 traps; 2 output mismatches**, both `@base64d` producing invalid UTF-8: native writes the raw bytes, the wasm runtime's `TextDecoder` replaces them with U+FFFD (P0-5). The deep-nesting battery, however, traps on wasm (P0-8).

---

## P0

### P0-1 Regex `^`/`$` are multi-line by default: anchored validation is bypassed
`src/builtins.pion:472` `compile_jq_regex` starts with `let mut multi_line = true`. jq (Oniguruma, Ruby syntax) and gojq (RE2) anchor `^`/`$` to the whole string unless a flag says otherwise.

| Query | Input | Pion | gojq / jq |
| --- | --- | --- | --- |
| `test("^[a-z]+$")` | `"ok\n; rm -rf /"` | `true` | `false` |
| `test("^line2")` | `"line1\nline2"` | `true` | `false` |
| `gsub("$"; "!")` | `"l1\nl2"` | `"l1!\nl2!"` | `"l1\nl2!"` |

Any allow-list check written as `select(.x \| test("^...$"))` accepts values with an embedded newline. The `p` flag sets the same thing (`multi_line = true`), and `m`/`s` are both mapped to dot-all. Test: `p0_regex_anchors_are_multiline_by_default_validation_bypass`.

### P0-2 Integers above 2^53 are corrupted, even by the identity filter
`json5::Json5Value::Number(Double)` is the only number representation. gojq keeps `int`/`*big.Int`, and jq 1.7 keeps the literal for unchanged values. As a result `jq .` changes 64-bit IDs:
`9007199254740993` → `9007199254740992`, `{"id":1234567890123456789}` → `1234567890123456800`, `12345678901234567890` → `12345678901234567000`. Knock-on effect: `range(9223372036854775700; 9223372036854775805; 10)` is empty, because both bounds round to 2^63. Test: `p0_large_integer_identity_corrupts_ids`.

### P0-3 `%` returns wrong results for large operands
`src/value.pion:719` `jq_mod` computes `xi - trunc(xi/yi)*yi` in Double, so the remainder is lost once |x| > 2^53/|y|. `1e17 % 7` gives `0` (gojq and jq give `5`). Test: `p0_modulo_wrong_for_large_operands`.

### P0-4 Outputs that were already produced are lost on a later `error` or `break`
`limit` (`src/eval.pion:2982`) collects its generator into a capped sink (`eval_collect_cap`) and only emits after the generator returns. An `error` or `break` in the generator throws away everything collected so far. The same collect-then-emit pattern is used across many builtins.

| Query | Pion | gojq / jq |
| --- | --- | --- |
| `[label $f \| limit(3; 1, break $f)]` | `[]` | `[1]` |
| `try limit(5; 1, 2, error("x")) catch .` | `"x"` | `1, 2, "x"` |
| `[range(3) \| label $out \| limit(3; 1, if . > 1 then break $out end, 2)]` | 6 values | 7 values (from gojq's own test suite) |

Test: `p0_limit_drops_outputs_already_emitted_on_error_or_break`.

### P0-5 Strings hold bytes that are not UTF-8; the output is not valid UTF-8 or JSON
- `bytes_to_string_lossy` (`src/builtins.pion:8`) is not lossy: it copies the raw bytes of `@base64d`.
- `implode` of a surrogate code point stores CESU bytes `ED A0 80`.

`serialize_jq_json` then writes these bytes unchanged. Effects:
- `"aaaa" | @base64d` emits `69 A6 9A` (gojq: `"i��"`, jq: raw U+FFFD).
- `[55296] | implode | @base64` gives `"7aCA"` (gojq/jq: `"77+9"`).
- Native and wasm32 give **different bytes** for the same query (the only two 4-mode mismatches).

Test: `p0_invalid_utf8_inside_strings_base64d_implode`. It re-parses the output with `json5::parse_bytes`, which reports `invalid UTF-8 lead byte`.

### P0-6 `max_output_bytes` is bypassed by shared-structure serialization, and one variant aborts the process
`[., .]` doubling builds a value of 2^n leaves in n steps, because the children are shared references. `tojson`, `tostring` and the public `to_json` expand it without consulting any limit (`src/value.pion:1188` `serialize_jq_json` takes no limits):

| Case (default limits) | Pion native | Pion wasm32 | gojq |
| --- | --- | --- | --- |
| `reduce range(40) as $i ([1]; [., .]) \| tojson \| length` | runs unbounded (timeout 30 s, 1.5 GiB) | timeout, 1.8 GiB | OOM |
| `reduce range(40) as $i ({}; {a: ., b: .}) \| tostring \| length` | **SIGABRT** `pion panic ... pion_rt.c:155: container length exceeds maximum` (rc -6) | OOM (3.1 GiB, killed) | OOM |
| `reduce range(26) as $i ([1]; [., .])` (a single output) | 11.6 s, 1.0 GiB of output | 23 s, 2.8 GiB | 2.6 s, 1.8 GiB |

A runtime panic is not a `JqError`: an embedder cannot catch it, and the whole host process dies. With `JqLimits(64, 100000, 1000, 4096)`, `reduce range(18) as $i ([1]; [., .]) | tojson` returns a 1 MiB string. Test: `p0_max_output_bytes_bypassed_by_shared_structure_serialization`.

### P0-7 Quadratic `|=`, `=`, `del`, `from_entries`: minutes of CPU inside the default `JqLimits`
For every path, `eval_update`/`eval_assign` (`src/eval.pion:1339`, `:1378`) call `jq_setpath` (`src/value.pion:878`), which copies the whole container. That makes `.[] |= f` O(n²). Objects are worse: their keys are found by linear scan. Steps are counted per evaluation node, not per copied element, so `max_steps` never fires. The cases below come from gojq's own "update performance" tests, run by `audit/dos` (gojq times include its process start):

| Case | Pion | gojq | Ratio |
| --- | ---: | ---: | ---: |
| `.[] \|= . + 1` on a 100k-element **input** array (588 KB input, default limits) | 50.1 s | 0.21 s | ~240x |
| `.[] = 0` on the same input | 45.6 s | 0.20 s | ~230x |
| `.[] \|= . + 1` on a 50k-key input object | 35.5 s | 0.06 s | ~600x |
| `[range(50000)] \| .[] \|= . * 2 \| add` | 12.5 s | 0.47 s | 26x |
| `... from_entries \| [.[] \|= . * 2 \| .[]] \| add` (50k) | > 20 s (timeout) | 0.23 s | > 85x |
| `to_entries \| from_entries` on 50k keys | 14.3 s | 0.19 s | 75x |
| `(.. \| numbers) \|= . + 1` on 50k | 13.7 s | 0.18 s | 77x |
| `"a" * 200000 \| indices("aa")` | 5.8 s | 0.06 s | ~100x |

Time grows with the square of the input, so a 1 MB document plus a 13-character query is enough to pin a core for minutes. This is a DoS that the advertised `JqLimits` does not prevent. Unit tests have no clock, so this finding has no `p0_*` test; it is evidenced by `dos/run_dos.py` and by `bench/run_blindspots.sh` B1–B5.

### P0-8 wasm32: native stack overflow at about 80 levels of jq recursion, far below `max_depth = 256`
On wasm32 the evaluator's native recursion overflows the V8 stack (`RangeError: Maximum call stack size exceeded`) long before `max_depth` trips. The instance traps and every later query in that instance is lost. Measured with `audit/dos` 4-mode and a manual bisection, Node 24:

| Case | native rel/dbg | wasm32 rel | wasm32 dbg |
| --- | --- | --- | --- |
| `def f: if . < N then . + 1 \| f else . end; 0 \| f` | N=250: `LimitExceeded` (clean) | **trap from N≈80** (N=70 ok) | trap from N≈90 |
| `reduce range(N) as $i (0; [.]) \| tojson` | ok at N=10,000 | **trap from N≈3,000** (ok at 2,000) | trap |
| `reduce range(10000) as $i (0; [.]) \| [..] \| length` | ok | trap | trap |
| `reduce range(5000) as $i (null; {a: .}) \| tojson` | ok | trap | trap |
| `[1,1,...x20000] \| length`, `1+1+...x20000` | `LimitExceeded` | trap | trap |
| `def r: ., (. + 1 \| r); [limit(1e8; 0 \| r)]` | `LimitExceeded` | trap | trap |

The `wasm_smoke` in `README.md` (6 fixed queries) does not reach any of these depths. To be safe on wasm32, `max_depth` would need to be ≤ ~60, or the evaluator and serializer would need explicit stacks.

## P1

| Id | Finding (root cause) | Evidence (Pion vs gojq = jq) | Test |
| --- | --- | --- | --- |
| P1-1 | Path mode (`eval_paths_inner`, `src/eval.pion:1071-1335`) does not resolve **user-defined functions** | `def f: .a; f \|= 1`: `invalid path expression: f` vs `{"a":1}`; `def f: .b[0]; del(f)` | `p1_path_through_user_defined_function` |
| P1-2 | No `Expr::Slice` in path mode | `.[1:3] \|= map(.*10)`, `.[1:] = []`, `del(.[1:])`, `path(.[1:2])` all error | `p1_slice_update_and_delete` |
| P1-3 | Path mode only knows `. .a .[i] .[] .. , \| select if` + type filters | `first(.b[]) \|= 9`, `getpath(["x"]) = 1`, `path(.a // .b)`, `path(foreach ...)`, `path(try .a catch .b)`, `path(.a as $x \| .b)`, `path(recurse)` | `p1_path_through_first_getpath_alt_reduce_try` |
| P1-4 | Function names are resolved at **run time** (`eval_call`, `src/eval.pion:1537`): `compile("nosuchfn")` succeeds and the `CompileError` is raised during evaluation, where `?`/`try` swallow it | `[paths(numbers)]?` → nothing (instead of the paths); `try ltrim catch .` → `"compile error: unknown function ltrim/0"` | `p1_unknown_function_is_not_a_compile_error` |
| P1-5 | The lexer emits `.` and the identifier as separate tokens, so whitespace between them is allowed (`src/parser.pion:640`) | `. a` evaluates as `.a` (`{"a":5}` → `5`); jq/gojq: syntax error | `p1_parser_accepts_space_between_dot_and_field` |
| P1-6 | `try` and `catch` bodies are parsed with `parse_alt` (`src/parser.pion:611`), not as a post-term | `1 + try 2 catch 3 + 4` → `3` vs `7`; `try error(0) // 1` → empty vs `1` | `p1_try_catch_precedence` |
| P1-7 | Object values do not accept a pipe (jq grammar `ObjVal: ExpD`) | `{x: -. \| abs}`, `{"bar": {"baz":.} \| select(.baz)}`: syntax error | `p1_object_value_pipe_without_parens` |
| P1-8 | `sub`/`gsub` evaluate the replacement once | `"abc" \| sub("a"; "1","2")` → `"1bc"` vs `"1bc","2bc"` | `p1_sub_gsub_multi_output_replacement` |
| P1-9 | `add`, `any`, `all`, `join`, `flatten`, `first`/`last`, `with_entries`, `combinations` require arrays | `{"a":1,"b":2} \| add` → error vs `3`; `{} \| add` → error vs `null` | `p1_collection_builtins_reject_objects_and_null` |
| P1-10 | Missing jq 1.7 builtins used daily: `paths(f)`, `while`, `until`, `repeat`, `walk`, `IN`, `tostream`/`fromstream`, `nth/1`, `pow`, `sqrt`, `getpath` in paths, `pick`, `splits/2`, `split/2`, `combinations/1`, `env`/`$ENV`, `builtins`, `halt_error`, `@base32`, dates, `ltrimstr`-family errors | 194 "unknown function" cases in the diff | `p1_missing_core_builtins` |
| P1-11 | `max_outputs` is checked per **collection sink** (`EvalCtx::emit`, `src/eval.pion:136`), not per query | Default limits: `[range(150000)] \| length` → `LimitExceeded`; `tojson`/`join`/`sort` of 200k-element arrays fail | `p1_default_max_outputs_rejects_ordinary_large_arrays` |
| P1-12 | `parse_json` uses `json5` strict options with a fixed `max_depth: 128` and ignores `JqLimits` | 200-deep input rejected (jq 1.7.1 allows 256, gojq 10,000); `reduce range(150) as $i (0;[.]) \| tojson \| fromjson` fails | `p1_parse_json_depth_128_ignores_limits` |

## P2

| Id | Finding | Test |
| --- | --- | --- |
| P2-1 | `-0 \| tostring` and `[-0] \| tojson` give `"-0.0"` (jq `"-0"`, gojq `"0"`) | `p2_negative_zero_tostring` |
| P2-2 | Interpolation `"\(1,2)-\(3,4)"` and index `.c[][.k[]]` enumerate in the wrong order. Binary operators also evaluate the LHS first, so `.[0] * empty` on a string errors instead of producing empty (seen in 85 fuzz/diff cases) | `p2_multi_output_ordering` |
| P2-3 | `nan < nan` is `false` (jq orders nan below every number) | `p2_nan_ordering` |
| P2-4 | `null \| has(k)` errors; `null \| indices(x)` returns `[]` instead of `null` | `p2_null_has_and_indices` |
| P2-5 | `def f($g;$g)` duplicates outputs; `{("a","b"):$v}` patterns bind only the first key; `?//` is unsupported; `.[[1]]` (array indices) is unsupported | `p2_binding_edge_cases` |
| P2-6 | Lexer: keyword field names (`.and`), `."a\(1)"`, `.a.[0]`, `5.`, `01000`, and `1e1000` are rejected | `p2_lexer_coverage` |
| P2-7 | `@sh` quotes `null`/`true`/numbers and accepts objects; `[nan] \| @csv` → `"null"` | `p2_format_strings` |
| P2-8 | `tonumber` rejects `"+4.2"`, `"05"`, `".5"` | `p2_tonumber_leniency` |
| P2-9 | `"ab" * 0.5` → `null` (jq 1.7.1 / gojq: `""`) | `p2_string_repeat_fraction` |
| P2-10 | `max_depth = 256` counts *evaluation* depth (≥2 per jq call), so ordinary recursion of depth 1,000 fails (gojq's own suite recurses 100,000 deep). Also 10k-long flat `\| . \| .` or `,` chains hit "max parse depth" | `p2_default_depth_limit_rejects_ordinary_recursion` |
| P2-11 | Error messages differ in wording (32 `errmsg` cases), e.g. `"cannot index string"` vs jq `"Cannot index string with number"` | (diff only) |

## Controls: what Pion gets right (all PASS, and all agree with gojq and jq)

- **Streams and backtracking**: Cartesian products in `+` and `{a:(1,2),b:(3,4)}`; multi-valued `if`/`elif` conditions; `and`/`or` with multiple values and short-circuiting; `//` over `false`/`null`/`empty`; `reduce`/`foreach` including `empty` updates; `label`/`break` outside `limit`; lexical closures, arity overloading and redefinition (`def x: 1; def y: x; def x: 2; y` → `1`).
- **Basic updates**: `.a.b.c |= 1` on `{}`, `|= empty` deletion, `+=` with multiple right-hand values, padding with `null` on out-of-range `setpath`, multi-index `del`.
- **Total order**: `sort` over all types and objects, stable `sort_by`, `group_by`.
- **Limits that work**: string/array repetition bombs, string doubling, `setpath([1e8]; 1)`, `.[1e9] = 1`, `range(1e9)`, a 1000x1000 Cartesian product, `combinations`, infinite recursion, `implode` of 1e7 elements and a 1e6-element `sort` all stop with `LimitExceeded` in about 0.1 s on native and wasm32 (except infinite stream recursion, which traps on wasm32, P0-8). **gojq OOMs (> 3 GiB) or hangs on 9 of the 69 cases**, including `reduce range(40) as $i ("x"; .+.)`, `[range(1e9)]`, infinite stream recursion, `[paths]` of a doubled array, and even `reduce range(20000) ... .["k\($i)"] = $i` (gojq 3.4 GiB, Pion 4.6 s / 8.5 MiB).
- **Regex**: no ReDoS (`(a+)+$`, `(a|a)*$`, `(.*a){10}` are linear). `gsub` on 100 kB is **239x faster than gojq** (26 ms vs 6.2 s; gojq uses 2.6 GiB). Named captures and `capture`/`scan`/`splits` all agree.
- **Wide collections**: `sort_by`, `split`, `ascii_downcase`, `group_by` and `unique` are within 1–3x of gojq or faster, with 1.3–3x lower RSS.
- **Correctness**: 87.4% exact match on a corpus that targets the weak spots; no native crash anywhere in the 9,021-case diff; native debug and release are byte-identical.

## Benchmark fairness (`packages/jq/bench/`)

The W1–W3 numbers in `README.md` reproduce: the stdout SHA-256 really is identical, and both sides compile once and parse the same file. They are fair for what they measure. They also contain no slow path, so they hide the one weakness that dominates real-world risk:

| Probe (`audit/bench/run_blindspots.sh`, warmup 1, 5 interleaved rounds, SHA-256 verified) | Pion median | gojq median | Pion vs gojq |
| --- | ---: | ---: | ---: |
| B0 startup floor (`.` on `null`) | 13.9 ms | 14.8 ms | 1.06x |
| B1 `[range(20000)] \| .[] \|= . * 2 \| add` | 3,110 ms | 22.6 ms | **0.007x** |
| B2 `[range(20000)] \| .[] = 1 \| add` | 2,064 ms | 16.4 ms | **0.008x** |
| B3 5k-key object `.[] \|= . + 1` | 716 ms | 26.9 ms | 0.04x |
| B4 `to_entries \| from_entries` on 20k keys | 3,101 ms | 26.3 ms | **0.008x** |
| B5 `"a" * 50000 \| indices("aa")` | 417 ms | 22.8 ms | 0.05x |
| B6 2k `has` lookups on a 20k-key object | 182 ms | 21.8 ms | 0.12x |
| B7 `"ab" * 50000 \| gsub("a"; "x")` | **25.9 ms** | 6,190 ms | **239x** |

- **W2** ("1.82x faster than gojq") updates a ~1.4k-node tree whose arrays have at most 4 children, so the O(n²) `|=` never shows. On a flat 20k array the same operator is 140x **slower**.
- W2 and W3 total 17–79 ms, against a startup floor of ~14 ms for both sides. The ratios are real, but startup is a large share of them.
- The README weakness notes for W1/W3 (materialisation, regex cache) are accurate but minor next to B1–B6.
- B7 shows a Pion strength that the shipped bench also leaves out.

## Proposals (for the owner to decide; this audit changes no code)

1. **P0-1**: default `multi_line` to false, and map jq flags as Oniguruma does (`s` single-line, `x` extended, `p` = `m`+`s`).
2. **P0-2 / P0-3**: carry integers that fit in i64 (or the original literal) next to the Double, as jq 1.7 does for unchanged literals. Implement `%` on i64.
3. **P0-4 / P1-8**: make `limit`/`first`/`sub` and friends stream through a sink callback instead of `eval_collect`.
4. **P0-5**: replace invalid sequences with U+FFFD in `bytes_to_string_lossy` and in `implode`.
5. **P0-6**: thread `max_output_bytes` through `serialize_jq_json`, `tostring` and `tojson`, and count it in the public `to_json`. Never let a container length reach the runtime panic.
6. **P0-7**: batch path updates (a copy-on-write path trie, or one rebuild per `|=`), and give objects an index (`json5::ObjectIndex` already exists).
7. **P0-8**: use an explicit stack in `eval`, `eval_paths` and the serializer, or derive a wasm32-safe default `max_depth`. Add the `audit/dos` stack cases to `wasm_smoke`.
8. **P1-1..3**: resolve user functions, slices and the remaining path-capable builtins in `eval_paths`.
9. **P1-4**: resolve function names at compile time.
10. **P1-11**: make `max_outputs` a per-query budget.
