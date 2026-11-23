# Red-team audit: `packages/cel` vs Go `google/cel-go v0.24.1`

Target: `origin/feat/pkg-cel` @ `a34957e` (`packages/cel/src/**`, 4,448 lines read in full).
Reference: Go `github.com/google/cel-go v0.24.1` with a default `cel.NewEnv()` (same pin as
`bench/go_bench`), `cel-spec` where cel-go is silent. Toolchain: `pionc 0.1.0`, `go1.27.3`,
Darwin arm64 (M-series, shared machine, load average 29–51 during the runs).

Everything here is reproducible with one command (artifacts go to `/private/tmp/rt-cel-audit`,
the git worktree stays clean):

```sh
sh packages/cel/audit/run_audit.sh          # full run
sh packages/cel/audit/run_audit.sh --quick  # smaller fuzz / DoS subset
pionc test --json -p cel_audit packages/cel/audit   # just the red/control tests
```

| Layout | Purpose |
| --- | --- |
| `redteam_test.pion` | 24 `p0_*`/`p1_*`/`p2_*` tests asserting the correct behaviour — **all FAIL today** (evidence) |
| `control_test.pion` | 6 `control_*` tests pinning what Pion already gets right — **all PASS** |
| `diff/` | Pion driver + Go cel-go oracle (same case file → same canonical transcript), case generator, diff runner, root-cause classifier, 4-mode build comparison |
| `dos/` | DoS / limit-bypass probes, Pion and cel-go, one probe per process (`/usr/bin/time -l`) |

## Summary

| Severity | Count | Findings |
| --- | ---: | --- |
| **P0** | 3 | P0-1 unbounded checker recursion → `compile()` crashes (native SIGSEGV at ~19.4k terms, **wasm32 stack overflow at 331 terms / ~660 bytes**); P0-2 `max_output_bytes` is per value, not per result (1 GiB result under a 1 MiB limit); P0-3 `max_cost` charges O(n) scans as O(1) (1.7e10 comparisons = 80 s wall / 51 s CPU in one eval under default limits) |
| **P1** | 11 | double literal rounding (DBL_MAX → +Inf), silent int64 wrap in `duration()`, no CEL duration range, wrong timestamp range (rejects `9999-12-31T23:59:59Z`), duplicate map keys kept (first wins), `matches()` is Rust-regex not RE2, no IANA time zones, `duration.getMilliseconds()` semantics, `string(double)` format, flat `\|\|`/`+` chains > 63 rejected; plus perf cliffs (O(n) map lookup and Activation) |
| **P2** | 9 | reserved words accepted, grammar leniency, non-bool absorption, NaN ordering, lenient checker, conversion gaps, RFC 3339 strictness, invalid map key types, `-0.0` sign lost |
| Red tests | 24 | 24 FAIL / 0 pass |
| Control tests | 6 | 6 / 6 PASS |
| Differential | 11,138 cases | curated 1,138 (569 expressions × E/C): 947 match / 191 diff; fuzz 10,000: 9,422 match / 578 diff — `diff/classify.py` assigns every one of the 769 diffs to a finding below, 0 unclassified (330 fuzz + 9 curated diffs are the checker's deliberate cross-type numeric acceptance, 12 are cel-go's lossy int→double comparison) |
| 4 build modes | 11,138 cases | native debug = native `--release` = wasm32 debug = wasm32 `--release`: **byte-identical, 0 diff lines, 0 traps** |
| Original suite | 14 / 14 | `pionc test -p cel packages/cel` unchanged |

The defects cluster in three places: **resource limits** (`EvalLimits` does not bound what it
promises, and the checker has no limit at all), **numeric/text conversion** (`parse_double_str`,
`string(double)`, duration/timestamp ranges delegated to the `time` package without CEL bounds),
and **library semantics** borrowed from neighbouring packages (`regex` = Rust dialect, `time` =
jiff range). The core evaluator — error absorption, int64 edge cases, exact cross-type comparison,
lexer escapes, macro scoping — is solid and in places more correct than cel-go (see Fairness).

---

## P0

### P0-1 `compile()`/`check()` recurse without any depth guard → process crash (native and wasm32)

`Parser::enter` counts only `(`, `?:` and unary operators; binary chains (`parse_or` …
`parse_mul`) and member/index chains (`parse_member`) are loops, so a flat `1+1+…+1` or
`x.a.a.a…` parses with depth 1 but produces a left-nested tree of the full length.
`TypeChecker::check_node` (`src/checker.pion`) then recurses once per level with no limit.
Evaluation is protected (`EvalCtx::eval_node` checks `max_depth`), the checker is not.

| Build | `1+1+…` (N terms) | `dyn({'a':1}).a.a…` | `dyn([0])[0][0]…` |
| --- | --- | --- | --- |
| native debug / `--release` | OK @ 19,367 · **SIGSEGV (rc 139) @ 19,379** (≈39 KB source) | OK @ 19,354 · SIGSEGV @ 19,367 | OK @ 19,354 · SIGSEGV @ 19,367 |
| wasm32 debug / `--release` | OK @ 327 · **`RangeError: Maximum call stack size exceeded` @ 331** (≈660 B source) | OK @ 323 · crash @ 327 | OK @ 323 · crash @ 327 |
| cel-go v0.24.1 | `ERROR: max recursion depth exceeded` (clean error, limit 250) for 330 and 20,000 | same | same |

(bisected with `dos/pion_dos check_* N`; the crash takes the whole host process down — a
multi-tenant policy service that compiles user-supplied CEL can be killed with one 660-byte
request when running on wasm32.) `p0_1_*` assert that a 2,000-deep chain is rejected with
`LimitExceeded` before the checker recurses; today `compile()` returns `Ok`.

Fix direction: count depth for every left-nesting step in the parser (or balance `||`/`&&` like
cel-go and give `+`/`.`/`[]` chains a nesting count), and add the same guard to `check_node` /
`build_regex_cache`-style walkers; also cap source length (cel-go: 100k code points).

### P0-2 `max_output_bytes` bounds single values, not the result

The limit is only checked inside one `+` (string/bytes/list) and one list/map literal. A
comprehension can return any number of values that are each ≤ the limit:

```cel
['0123456789abcdef'].map(s, s + s) … (15×)  // s = 512 KiB
[s].map(s, [<2^k zeros>].map(l, l.map(i, s + s)))   // 2^k fresh 1 MiB strings
```

| probe (`dos/`, default `EvalLimits`: 1 MiB, cost 1e6) | Pion result | Pion RSS | cel-go unlimited | cel-go `CostLimit(1e6)` |
| --- | --- | --- | --- | --- |
| `mem_amp 8` (256 × 1 MiB) | **OK, 268,435,456 B** in 0.02–0.24 s | 278 MB | OK, 284 MB | **`actual cost limit exceeded`**, 25 MB |
| `mem_amp 10` (1,024 × 1 MiB) | **OK, 1,073,741,824 B** in 0.09 s | 1.10 GB | OK, 1.09 GB | rejected |

Each list may hold 131,072 elements (`len*8 ≤ 1 MiB`), so under the default budget the same
shape reaches 128 GiB → OOM kill. The limit is named and documented as an output bound but does
not bound output; cel-go's cost model charges string concat by produced size, which is why its
cost limit catches this. `p0_2_max_output_bytes_not_cumulative` uses a 4 KiB limit: the
result holds 262,144 bytes.

### P0-3 `max_cost` charges O(n) operations as one unit

`EvalCtx::eval_node` adds 1 per node and comprehensions add 1 per iteration; `in`, `==`/`!=` on
lists/maps/strings/bytes, map index (`O(n)` scan), list concat copies, `size(string)` (UTF-8
scan), `contains`/`startsWith`/`matches` and regex compilation of non-literal patterns are free.

| probe | work | Pion (default limits) | cel-go unlimited | cel-go `CostLimit(1e6)` |
| --- | --- | --- | --- | --- |
| `cpu_in 12` (`L.map(i, 1 in L)`, \|L\| = 4,096) | 1.7e7 compares | OK 0.26 s | — | — |
| `cpu_in 15` (32,768) | 1.1e9 | **OK 2.84 s** | OK 14.6 s | **rejected in 0.02 s** |
| `cpu_in 16` (65,536) | 4.3e9 | **OK 21.3 s wall / 12.7 s CPU** | — | rejected |
| `cpu_in 17` (131,072, max list size) | 1.7e10 | **OK 80.4 s wall / 51.3 s CPU, one eval** | — | rejected |
| `cpu_size 12` (4,096 × `size(<1 MiB>)`) | 4 GiB scanned | OK 1.21 s | OK 1.11 s | OK 1.12 s (cost 267,888: cel-go also treats `size` as O(1)) |

`p0_3_max_cost_ignores_linear_scans` (max_cost = 100,000; 16.8 M comparisons) and
`p0_3_max_cost_ignores_string_equality` (max_cost = 50,000; 64 MiB compared) both return `Ok`.
The `size()` row is reported for fairness: there cel-go has the same blind spot.

---

## P1

| id | finding | evidence (Pion → cel-go) | test |
| --- | --- | --- | --- |
| P1-1 | `parse_double_str` is not correctly rounded (digit accumulation in a `Double`, power-of-ten by repeated squaring) — used for literals **and** `double(string)` | `1.7976931348623157e308` → **+Inf** (`7ff0…`) vs DBL_MAX; `5e-324`, `4.9e-324` → 0 vs min subnormal; `2.2250738585072014e-308` → `000ffffffffffffd` vs `0010000000000000`; `1e308` off by 3 ulp; `uint(18446744073709549568.0)` → 18446744073709547520. 158 fuzz diffs. | `p1_1` |
| P1-2 | silent int64 wrap in `parse_cel_duration` (unchecked `total_secs + …` in the sub-second branch and the nanos carry) | `duration('9223372036854775807s1000000000ns')` → **−9223372036854775808 s** (a huge positive duration becomes negative, `< duration('0s')` is `true`); cel-go: error | `p1_2` |
| P1-3 | no CEL duration range (cel-go: int64 ns ≈ ±292 y) and range-unchecked `timestamp − timestamp` | `duration('2562048h')` OK; `duration('2562047h') + duration('2562047h')` OK; `ts('2020') − ts('1700')` OK (cel-go: overflow errors) | `p1_3` |
| P1-4 | timestamp range is the `time` package's (jiff: `-9999 … 9999-12-30T22:00:00Z`), not CEL's `0001-01-01 … 9999-12-31T23:59:59.999999999Z` | **`timestamp('9999-12-31T23:59:59Z')` (the usual "never expires" sentinel) is rejected**, so are `timestamp(253402300799)` and `9999-12-31T00:00:00Z`; year 0 / `timestamp(-62135596801)` / `ts('0001-01-01') − 1s` accepted | `p1_4` |
| P1-5 | map literals keep duplicate keys | `{'role':'viewer','role':'admin'}.role` → **`viewer`** (cel-go `admin`); `{'a':1,'a':2}.size()` → 2 (cel-go 1); `{'a':1,'a':2} == {'a':2}` → false (cel-go true). cel-spec: duplicate key is an error. | `p1_5` |
| P1-6 | `matches()` uses `packages/regex` (Rust `regex` dialect), not RE2 | `'١٢٣'.matches('^\\d+$')` → **true** (RE2 `\d` is ASCII); `\w`, `\s`, `\b` Unicode; `[a&&b]` / `[a--b]` set ops; `a{1001}` accepted; `\Q` rejected (RE2 accepts) | `p1_6` |
| P1-7 | only fixed `±HH:MM` offsets for timestamp accessors | `getHours('America/New_York')`, `'Asia/Kolkata'`, `'05:30'` → error (cel-go 19 / 6 / 6) | `p1_7` |
| P1-8 | `duration.getMilliseconds()` returns the sub-second part | `duration('1.5s').getMilliseconds()` → 500 (cel-go 1500), `'61.5s'` → 500 (61500) | `p1_8` |
| P1-9 | `string(double)` ≠ Go `FormatFloat(f,'g',-1,64)` | `string(1e6)` `1000000` vs `1e+06`; `string(123456789.0)` vs `1.23456789e+08`; `string(-0.0)` `0` vs `-0`; `inf`/`nan` vs `+Inf`/`NaN` | `p1_9` |
| P1-10 | `max_depth` = evaluation recursion depth on left-nested chains ⇒ ordinary flat expressions with > 63 operators are rejected | 70-clause `x == 0 \|\| … \|\| x == 69` → `LimitExceeded: evaluation depth exceeds limit (64)`; `1 + 1 + … (70)` same. cel-go: 70 and 1,000 clauses OK (it balances logical chains; its 250 limit applies to `+` chains) | `p1_10` |
| P1-11 | linear-complexity cliffs (no test: perf) | map index is a linear scan: 16,384 lookups in a 16,384-key map **0.62 s vs cel-go 0.01 s** (`map_lookup 14`), 65,536 → **13.2 s vs 0.06 s (220×)** (`map_lookup 16`, O(n²)); `Activation`/`Env` are association lists: 100,000 evals of the last of 512 vars 0.23 s vs 0.01 s, of 2,048 vars **1.01 s vs 0.02 s** (`act_lookup`) | `dos/` |

## P2

| id | finding | evidence | test |
| --- | --- | --- | --- |
| P2-1 | reserved words (`as break const continue else for function if import let loop package namespace return var void while`) accepted as identifiers / macro variables | `[1].map(let, let)` → `[1]`; cel-go: `reserved identifier: let` | `p2_1` |
| P2-2 | grammar leniency | `rb'\x80'` accepted (cel-go lexes only `br`); `true ? false ? 1 : 2 : 3` accepted (cel-go grammar: then-branch is `conditionalOr`) | `p2_2` |
| P2-3 | non-bool `\|\|`/`&&` operands are not absorbed | `dyn('a') \|\| true` → error (cel-go `true`), `dyn(1) && false` → error (`false`) | `p2_3` |
| P2-4 | ordering against NaN returns `false` | `0.0/0.0 < 1.0` → false; cel-go: `NaN values cannot be ordered` (27 diffs) | `p2_4` |
| P2-5 | checker accepts what cel-go's checker rejects (type confusion deferred to runtime) | `1 == 'a'`, `true ? 1 : 'a'`, `[1] + ['a']`, `-duration('1s')`, `{1:'a'}['x']` all compile | `p2_5` |
| P2-6 | conversion / indexing gaps | `[1,2][1.0]` error (cel-go 2); `int(duration)` missing; `double('infinity')`, `'INF'`, `'1_000'`, `'0x1p-2'` rejected; `string(timestamp('…+08:00'))` drops the offset | `p2_6` |
| P2-7 | RFC 3339 parsing both laxer and stricter than cel-go | accepts lowercase `t`/`z`, space separator, leap second `23:59:60`; rejects > 9 fractional digits | `p2_7` |
| P2-8 | invalid map key types accepted | `{1.0: 'a'}[1]` → `'a'`, `{b'a': 1}` accepted (cel-go: error) | `p2_8` |
| P2-9 | unary minus on double is `0.0 - d` (also in the literal parser) → sign of zero lost | `-0.0` is +0.0, `1.0 / -0.0` → +Inf (cel-go −Inf); 40 fuzz diffs | `p2_9` |

---

## Fairness — what Pion gets right (or better than cel-go)

* **Commutative error absorption** is implemented exactly: `true || err`, `err || true`,
  `false && err`, `err && false`, `all`/`exists` keep the first error but let a later decisive
  element win, `exists_one`/`map`/`filter` stay strict — all identical to cel-go
  (`control_commutative_error_absorption`). `LimitExceeded` is deliberately *not* absorbed — good.
* **int64/uint64 edge cases never trap**: `INT64_MIN / -1`, `% -1`, `-INT64_MIN`, `MIN * -1`,
  `-1 * MIN`, uint wrap, `int(±2^63 doubles)`, `int(NaN/Inf)`, `uint(-1.0)` all return
  `Overflow`/`DivisionByZero` errors on all 4 build modes (`control_int64_edges_no_trap`).
* **Exact cross-type numeric comparison** (cel-spec "as if on the continuous number line"):
  `9007199254740993 > 9007199254740992.0` is `true` in Pion; cel-go converts the int to
  double and answers `==` (12 curated diffs are cel-go being lossy, not Pion).
* Pion's checker accepts `1 == 1u`, `1 < 2.0` etc. (the newer cel-spec heterogeneous rules /
  cel-go's `CrossTypeNumericComparisons` option). This is the source of 330 of the 578 fuzz
  diffs; it is a design choice, not counted as a defect (the *non-numeric* leniency is P2-5).
* Lexer: surrogate `\uD800`, `\400`, newline in `'…'`, `\u` in bytes all rejected; octal/hex
  escapes, triple quotes, raw strings, `-9223372036854775808` literal correct.
* `max_depth` protects the parser and evaluator against deep `(((…)))` and `!!!!…` (100,000
  levels → clean `LimitExceeded`), and nested comprehension fuel bombs hit `max_cost`
  (`control_depth_and_fuel_limits`).
* `matches()` is linear-time (no ReDoS) and constant patterns are precompiled per `Program`.
* `1 in L` over 32,768 × 32,768 is **5× faster than cel-go** (2.84 s vs 14.6 s); cel-go folds
  `!!x` to `x` at parse time (`!!dyn(1)` → 1) where Pion strictly reports `'!' requires bool`.
* **Native ↔ wasm32 determinism is perfect**: 11,138 transcripts byte-identical across
  native debug / native `--release` / wasm32 debug / wasm32 `--release`, 0 traps.

## Benchmark fairness (`bench/`)

Re-run of `sh packages/cel/bench/run_bench.sh` on the same machine (load ≈ 30–37), plus the
same binaries with 25× the iterations to amortise process start-up:

| workload | README claim | re-run, published size | re-run, 25× ops (steady state) |
| --- | --- | --- | --- |
| W1 compiled IAM/K8s rules (80 k ops) | Pion **1.11×** faster | Pion 38.99 ms vs Go 23.25 ms → **0.60×** | 2 M ops: Pion 1,231 ms vs Go 262 ms → **0.21×**; repeat (7 rounds): 826 vs 285 ms → **0.35×** |
| W2 macros + regex + timestamps (20 k ops) | 2.50× | 3.87× | 3.24× |
| W3 compile + eval (2 k ops) | — | 6.62× | 20.68× (cel-go's ANTLR parse+check dominates) |

* **W1's "Pion is faster" is not reproducible.** At 80 k ops the run lasts ~25–50 ms, so both
  sides are dominated by process start-up and environment construction (Go runtime init +
  `cel.NewEnv`), which is noise; at steady state cel-go is **2.9–4.7× faster per eval** on the
  most common workload (simple compiled rules). The README must report W1 at a size where
  evaluation dominates, and list it as a Pion weakness.
* W1 uses 11 variables, not "20+": the linear `Activation` lookup is under-exercised;
  `dos/act_lookup` shows it at 512 vars (0.23 s vs 0.01 s / 100 k evals).
* No workload covers large maps or lists from the activation (P1-11: O(n²) map lookup),
  long rule chains (P1-10 rejects them), or limits enabled on both sides (cel-go without
  `CostLimit` vs Pion with `EvalLimits::default()` is not the same work). The W2/W3 wins are
  genuine (cel-go's interpretive overhead for macros and its expensive compile).

## Full DoS table (`run_audit.sh` step 5, one probe per process)

Native = `--release`; cel-go "cost" rows run with `cel.CostLimit(1000000)` + `OptTrackCost`;
Pion always runs with `EvalLimits::default()` (depth 64, cost 1e6, 1 MiB).

| impl | probe | n | wall s | RSS MiB | result |
|---|---|---:|---:|---:|---|
| pion | check_chain | 19000 | 0.02 | 14.4 | OK |
| pion | check_chain | 20000 | 0.01 | 14.5 | **CRASH SIGSEGV** |
| pion | check_member / check_index | 20000 | 0.03 | 14.4 | **CRASH SIGSEGV** |
| wasm32 dbg / rel | check_chain | 300 | 0.8 | 104 | OK |
| wasm32 dbg / rel | check_chain / check_member / check_index | 340 | 0.2 | 76 | **CRASH RangeError: Maximum call stack size exceeded** |
| go | check_chain / check_member | 300 / 20000 | 0.1–0.4 | 10–43 | clean error `max recursion depth exceeded` |
| pion | or_chain | 63 / 70 / 1000 | 0.01–0.03 | 3 | OK / **LimitExceeded** / **LimitExceeded** |
| go | or_chain | 63 / 70 / 1000 | 0.02–0.21 | 11–21 | OK / OK / OK |
| pion | mem_amp (1 MiB limit) | 6 / 8 / 10 | 0.02 / 0.14 / 0.59 | 69 / 265 / **1049** | OK, 64 MiB / 256 MiB / **1 GiB** |
| go | mem_amp | 6 / 8 / 10 | 0.04 / 0.17 / 0.42 | 78 / 272 / 1041 | OK (no limit configured) |
| go cost | mem_amp | 6 / 8 / 10 | 0.01–0.02 | 24 | **actual cost limit exceeded** |
| pion | cpu_in | 12 / 14 / 15 / 16 | 0.06 / 0.89 / 3.14 / 11.81 | 3–5 | OK (17: 80.4 s, measured separately) |
| go | cpu_in | 12 / 14 / 15 | 0.32 / 4.46 / 15.70 | 14–17 | OK (no limit configured) |
| go cost | cpu_in | 12 – 16 | 0.02–0.06 | 12 | **actual cost limit exceeded** |
| pion / go / go cost | cpu_size | 12 | 1.31 / 1.17 / 1.20 | 5 / 16 / 17 | OK / OK / OK (cost 267,888) |
| pion / go | map_lookup | 12 / 14 / 16 | 0.04 / 0.74 / **13.93** vs 0.03 / 0.01 / 0.13 | | O(n²) vs O(n) |
| pion / go | act_lookup (100k evals) | 16 / 512 / 2048 | 0.03 / 0.24 / 0.97 vs 0.02 / 0.02 / 0.00 | | linear vs hashed |

## Method

1. Read all of `src/{lib,ast,types,lexer,parser,checker,eval,numeric}.pion`, and the parts of
   `packages/time` (range, `parse_rfc3339`) and `packages/regex` (dialect) that `cel` delegates to.
2. Differential: `diff/gen_cases.py curated` (569 hand-written red-team expressions in 7 groups
   × E/C modes) and `fuzz 1 5000` (random typed int/uint/double/bool/string expressions with
   macros, `in`, conversions). Both sides print `OK <canonical value>` (doubles as IEEE bits,
   strings/bytes hex, maps sorted, timestamps/durations as secs.nanos) or `PERR/CERR/EERR`;
   two errors in any phase count as a match. `diff/classify.py` buckets the mismatches.
3. Build modes: `diff/cmp_builds.py` runs the same driver natively (debug, `--release`) and
   via `pionc run --target wasm32` (debug, `--release`, own `PION_CACHE_DIR`) and compares
   SHA-256 / lines with native debug.
4. DoS: `dos/pion_dos` and `dos/go_dos` run identical expressions one probe per process under
   `/usr/bin/time -l`; crash points bisected per build mode.
5. Every red test's expected value was read from cel-go through `diff/go_oracle`; the resource
   tests (P0-2/P0-3) assert the documented meaning of `EvalLimits`.
