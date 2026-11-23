# `packages/jsonpath` red-team audit

- **Target**: `packages/jsonpath` at `origin/feat/pkg-jsonpath` @ `2cadac9856c1dabe3d0ae4dfb5cc97218887b9a8`
- **Toolchain**: `pionc 0.1.0 (arm64_apple, self-hosted)`, Node.js wasm runtime `~/.pion/share/pion/pion_wasm_rt.mjs`, Darwin arm64
- **Oracles**: official [`jsonpath-compliance-test-suite`](https://github.com/jsonpath-standard/jsonpath-compliance-test-suite) `cts.json` vendored at commit `20ebdcce5008c8a777ee9c80ad853ecf606950b5` (sha256 `f4ab5e3d…1d36`, 715 cases); Rust `serde_json_path 0.7.2` + `json-patch 4.2.0` + `jsonptr 0.7.1` + `serde_json 1.0.154` (`preserve_order`), locked by `audit/rust_oracle/Cargo.lock` and built with `--locked`.
- **Reproduce**: `sh packages/jsonpath/audit/run_audit.sh` (add `--bench` for the benchmark fairness split). Artifacts go to `/private/tmp/rt-jsonpath-audit`. The script exits non-zero while any finding below is unfixed. A fix branch should pass with exit 0 without changing anything under `audit/`.

Expectations come from the RFC text and the official CTS. Neither implementation is the reference. Rust oracle results are printed next to every check (`INFO … rust_reference`), and the places where Rust itself breaks the RFC are listed in §5.

## 1. Summary

| | Result |
| --- | --- |
| Official CTS (715 cases, values + Normalized Paths, `results` alternatives honoured) | **Pion 713/715 (99.72%)**; Rust `serde_json_path` 699/715 (97.76%). All 16 Rust failures are Normalized-Path escaping |
| Hand-written RFC 9535/9485/8259/6901/6902/7396 cases (`audit/cases.py`, 194 cases) | Pion 186/194 pass (8 failures, all mapped to findings below); Rust reference 179/194 |
| Rust `json-patch` applying Pion's `diff_patch` output (11 diffs: special keys `/`, `~`, `""`, nested array insert/remove/rotate) | 11/11 reach `after` |
| 4-mode driver stdout SHA-256 (`native_dbg` / `native_rel` / `wasm_dbg` / `wasm_rel`) on all 909 differential cases | identical in all 4 modes |
| DoS / stack-safety probes (15 probes × 4 modes) | **2 × P0, 1 × P1, 2 × P2 reproduce** (native SIGSEGV, wasm32 `RangeError`, SIGABRT/OOM, hangs) |

Severity scale used here:
- **P0**: crash, trap, OOM, or unbounded hang caused by untrusted input under **default** limits.
- **P1**: a wrong result on official CTS/RFC cases, or a super-linear CPU DoS from small input under default limits.
- **P2**: an RFC/consistency defect in edge semantics, or a resource blow-up that needs raised limits or uncommon input.

| ID | Sev | Title | Gating checks |
| --- | --- | --- | --- |
| P0-1 | P0 | Recursive Copy-on-Write pointer ops overflow the stack (native SIGSEGV, wasm32 `RangeError`) under default limits | `probe.deep_via_copy(20|1000).*`, `probe.deep_object(20000).wasm_*` |
| P0-2 | P0 | RFC 6902 `copy` amplification ("billion laughs"): 64 ops produce a 2^64-node document, so any later traversal OOMs or hangs | `probe.copy_bomb(64).*`, `probe.copy_bomb_test(30).*` |
| P1-1 | P1 | `json_value_eq` and `diff_patch` are O(n²) in object width, so `test` ops, filter `==` and diffs become a CPU DoS | `probe.wide_eq / wide_test_op / wide_diff (100000).*` |
| P1-2 | P1 | I-Regexp `^` / `$` are escaped to literals, which fails 2 official CTS cases | `cts.pion[516]`, `cts.pion[517]` |
| P2-1 | P2 | `merge_patch` silently returns the patch verbatim (nulls included) when nesting > 512 | `probe.deep_object(*).merge_patch_default_null_leaf` |
| P2-2 | P2 | Duplicate member names: `$.a` is last-wins but `*` / `..` / filters / `length()` / serializer see every duplicate, producing two nodes with the same Normalized Path | `rfc.jp.dupkey.*`, `rfc.json.dupkey_serialize` |
| P2-3 | P2 | Integers outside Int64 collapse to Double: lossy round-trip and a false-positive `test` op | `rfc.json.u64_max`, `rfc.patch.test_u64_distinct`, `rfc.eq.u64_distinct` |
| P2-4 | P2 | `apply_patch` costs O(ops × container size), because each op copies the whole parent container | `probe.wide_apply(100000).*` |
| P2-5 | P2 | `query_with_paths` memory is quadratic in depth: 1.1 GiB peak RSS for a 120 KB input | `probe.deep_paths(20000).*` (4 modes) |

Count: **P0 = 2, P1 = 2, P2 = 5** (9 findings, 53 gating FAIL checks; latest run: 243 PASS / 53 FAIL / 36 INFO, 7 min 51 s with `--bench`).

## 2. P0 findings

### P0-1 Stack overflow in recursive Copy-on-Write pointer ops (native SIGSEGV / wasm32 RangeError), default limits

**Root cause.**
- `cow_replace`, `cow_add` and `cow_remove` in `src/pointer.pion` (lines 202 / 289 / 433) recurse once per pointer token.
- `apply_patch_impl` (`src/patch.pion:216`) checks the pointer length against `limits.max_depth` for `add` only. `remove`, `replace`, `move` (both pointers), `copy` and `JsonPointer::resolve_mut` have no depth check.
- `copy` puts no bound on the depth of the document it produces. `copy` from `""` to a 126-token path nests the whole document about 125 levels deeper, and every pointer in it stays inside `max_depth = 128`.

**Minimal reproduction** (default `apply_patch`, input built with default `parse_json`):
1. Start from `doc = {"a":{"a":…1…}}` (126 levels).
2. Apply k ops of `{"op":"copy","from":"","path":"/a/a/…(126×)"}`.
3. Apply `{"op":"remove","path":"/a/a/…(126+125k−1 tokens)"}`.

| Mode | k | Result |
| --- | ---: | --- |
| `native_dbg` / `native_rel` | 1000 (depth ≈ 125 126) | **SIGSEGV** (exit 139) |
| `wasm_dbg` / `wasm_rel` | 20 (depth ≈ 2 626, pointer ≈ 5 KB) | **`RangeError: Maximum call stack size exceeded`** |
| `wasm_*` | `deep_object 20000` with raised limits, `JsonPointer::resolve_mut` | `RangeError` |

**Expected**: every op either succeeds or returns `Err(LimitExceeded)`. No call may trap. RFC 6902 allows copying into a child of the source; the problem is the unbounded recursion that follows.

**Fix direction**:
- Make `cow_*` iterative: walk the path down, then rebuild bottom-up from an explicit stack.
- Enforce `max_depth` on every pointer, and on the depth of the result for `copy` and `add`.

### P0-2 `copy` amplification bomb (OOM / hang), default limits

**Root cause.** `PatchOp::Copy` (`src/patch.pion:278`) shares the source subtree structurally, so apply time stays linear. The logical document still doubles with every `copy /a → /a/-`. `apply_patch_with_limits` has no node or size budget for its result: `max_nodes_visited` is not consulted and `max_patch_ops` (100 000) is far above the ~64 ops needed. Every consumer of the result then walks 2^k nodes:
- `to_json_string`,
- `json_value_eq` (and therefore `test` ops),
- `diff_patch`,
- `merge_patch`.

**Minimal reproduction**: `doc = {"a":[1]}` with 64 × `{"op":"copy","from":"/a","path":"/a/-"}`, a patch of about 3 KB.

| Probe | Mode | Result |
| --- | --- | --- |
| `copy_bomb(64)`: apply returns `Ok` in µs; `to_json_string(result)` runs next | `native_rel` | 2 GiB RSS, then **SIGABRT** after ~17 s |
| | `native_dbg` | timeout |
| | `wasm_*` | `RangeError: Offset is outside the bounds of the DataView` (wasm linear-memory exhaustion) after ~27 s |
| `copy_bomb_test(30)`: `json_value_eq(result, result)` / `diff_patch(result, result)` | all modes | timeout (2^30 nodes) |

`copy_bomb_test(26)` alone takes 7.7 s on native.

**Expected**: `apply_patch` returns `Err(LimitExceeded)` once the materialised size of the result exceeds a budget (for example `max_nodes_visited`), or the result is otherwise bounded. Rust `json-patch` deep-clones on `copy`, so it fails while applying the patch; this cannot be "fixed by matching Rust".

## 3. P1 findings

### P1-1 Quadratic object equality and diff (CPU DoS through `test`, filter `==`, `diff_patch`)

**Root cause.**
- `json_value_eq_impl` (`src/value.pion:137`): for each key of A it scans the rest of A for a shadowing duplicate (line 198), then scans B linearly (line 210). It repeats the same O(n²) shadow scan for B (line 232).
- `diff_recurse` (`src/patch.pion:360/370`) calls the linear `json_object_get` once per key, in both directions.

| Keys | `json_value_eq` | `test` op | `diff_patch` |
| ---: | ---: | ---: | ---: |
| 5 000 | 0.15 s | 0.19 s | 0.29 s |
| 20 000 (≈ 280 KB JSON) | 3.3 s | 3.8 s | 4.5 s |
| 100 000 (`probe.wide_*`) | > 10 s native / > 20 s wasm (timeout) | timeout | timeout |

A 100 000-key object parses in 0.02 s, so the input itself is cheap; the cost is entirely in the comparison. Any `test` op or filter equality (`$[?@ == $.x]`) on attacker-sized objects hits this.

**Expected**: about linear time. Use hash or sorted-key comparison, plus a last-wins index for duplicates. The probes allow 10 s native / 20 s wasm for 100 000 keys.

### P1-2 I-Regexp `^` / `$` handled as literals: 2 official CTS failures

**Root cause.** `iregexp_translate` (`src/iregexp.pion:113`) rewrites `^` and `$` outside classes to `\^` / `\$`.

**Failing CTS cases** (official `jsonpath-compliance-test-suite`, test file `tests/functions/match.json`):

| CTS case | Selector | Document | Expected | Pion |
| --- | --- | --- | --- | --- |
| 516 `functions, match, explicit caret` | `$[?match(@, '^ab.*')]` | `["abc","axc","ab","xab"]` | `["abc","ab"]` | `[]` |
| 517 `functions, match, explicit dollar` | `$[?match(@, '.*bc$')]` | `["abc","axc","ab","abcx"]` | `["abc"]` | `[]` |

Rust passes both.

The README presents this as a deliberate reading of the RFC 9485 ABNF, in which `^` and `$` are NormalChars. The CTS instead follows the RFC 9485 §5 mapping: when the pattern is wrapped as `^(?:…)$`, explicit anchors at the edges are redundant and harmless. The CTS is authoritative for this audit.

**Fix**: emit `^` / `$` as anchors (`\A` / `\z` in `search()` too, or leave them unescaped in non-multiline mode).

## 4. P2 findings

### P2-1 `merge_patch` silently returns the patch at depth > 512
`merge_patch_impl` (`src/patch.pion:537`) runs `merge_patch_recurse(…, 512)` and maps `Err(_) => patch`. With a 1 000-deep patch whose leaf is `null`, the "merged" result is the patch itself, `null` leaf included, where RFC 7396 requires the member to be deleted. The API returns no error and the data is corrupted. Reproduced in all 4 modes (`merge_patch_default_null_leaf = RETURNED_PATCH_VERBATIM`).

**Fix**: implement merge iteratively (it is a pure structural walk), or change the API so the failure is reported.

### P2-2 Inconsistent duplicate-member semantics; duplicate Normalized Paths
`parse_json` keeps every duplicate. `json_object_get` (used by `$.a`, pointers and patches) is last-wins, but wildcard, descendant, filter iteration, `length()` and `to_json_string` all see the duplicates.

| Query on `{"a":1,"a":2}` | Pion | Expected |
| --- | --- | --- |
| `$.*` | `[1,2]` with paths `["$['a']","$['a']"]` (two nodes, one path) | `[2]` |
| `$[?@ == 1]` | `[1]` | `[]` |

- `$[?length(@)==1]` on `[{"a":1,"a":2}]` returns `[]`, because the duplicate counts toward the length.
- The serializer emits `{"a":1,"a":2}`.

RFC 9535 §2.7 says a Normalized Path identifies exactly one node. RFC 8259 leaves duplicates undefined, but the library must apply one rule throughout; `serde_json` collapses to last-wins. 5 checks.

### P2-3 Integers outside the Int64 range become Double
In `parse_json_number` (`src/value.pion:581-610`), anything above 19 digits or beyond Int64 falls back to `to_double()`:
- `18446744073709551615` serializes as `1.8446744073709552e+19`.
- `{"op":"test","path":"/a","value":18446744073709551614}` **succeeds** against `18446744073709551615`. RFC 6902 §4.6 requires numeric equality, and these are different numbers.
- `json_value_eq(18446744073709551615, 18446744073709551614)` returns `true`.

`serde_json` keeps the full u64 range exact.

**Fix**: keep exact big integers (a `BigInt`/u64 arm, or the raw decimal text for comparison), or reject them with an error.

### P2-4 `apply_patch` is O(ops × container size)
Every `cow_add`, `cow_remove` and `cow_replace` copies the full parent `Array` / entry list. 20 000 `add`s into one object take 1.74 s; 100 000 take > 10 s (`probe.wide_apply`, timeout). `json-patch` mutates in place in O(1) amortized. **Fix**: a persistent map/vector, or in-place mutation on a private copy taken once per apply.

### P2-5 Quadratic memory in `query_with_paths` on deep documents
Every node pushed by the descendant walk carries its full Normalized Path string. `format_norm_name` (`src/eval.pion:14`) copies the parent path, so `$..*` on a 20 000-deep object (120 KB input, `max_depth` raised to 20 008) reaches a **1.1 GiB peak RSS** natively and 1.17 GiB under wasm. `max_results` and `max_nodes_visited` do not bound bytes. **Fix**: store a parent-pointer path chain and format only the emitted results, or add a byte budget.

## 5. Areas audited with no defect found (regression guards in the suite)

- **RFC 9535 grammar and §2.4 static typing**: whitespace rules; `!`/paren comparison bans; ValueType/LogicalType/NodesType checks on nested functions; singular-query enforcement.
- **String literals**: `\'`, `\"`, `\/` and `\uXXXX`, including astral pairs; lone or mismatched surrogates and raw control characters are rejected.
- **Integers and slices**: I-JSON integer range; `-0` and leading-zero rejection; slices with ±(2^53−1) bounds and steps, without Int64 overflow; `[-9223372036854775808:0:-1]` is rejected as a `ParseError`.
- **Filter comparisons**:
  - `Nothing == Nothing` is true;
  - `Nothing == null` is false;
  - `Nothing <= Nothing` is true. Rust gets this one wrong.
  - Deep, order-free object equality.
  - Exact Int64 vs Double comparison: `9007199254740993 ≠ 9007199254740992`, `> 1.5`, `< -1.5`.
- **`length()` and Normalized Paths**: `length()` counts Unicode scalar values; Normalized Path escaping (`\b \f \n \r \t \' \\`, lowercase `\u00xx`; DEL and U+2028 left unescaped).
- **I-Regexp** (besides P1-2):
  - `.` excludes `\r`/`\n` but matches astral characters and U+2028;
  - multibyte quantifiers and classes;
  - `\p{Lu}` / `\P{L}`;
  - invalid patterns (`\p{IsGreek}`, `\p{Cs}`, `\d`, back-references, lazy quantifiers, lookaround, `{2,1}`, dynamic invalid patterns) return `false`. Rust returns `true` for `\d`, `\p{IsGreek}` and `*?`.
- **RFC 8259 numbers and text**:
  - Int64::MIN/MAX exact;
  - `-0` sign preserved;
  - `1e400` rejected;
  - correctly rounded halfway inputs (ties-to-even, subnormal boundary);
  - 1 999 seeded random doubles round-trip bit-exact. `serde_json` without `float_roundtrip` is not correctly rounded and fails 3 halfway cases.
  - Lone surrogates, BOM, NBSP, trailing garbage and trailing commas are rejected; the depth-128 boundary is enforced.
- **RFC 6901 JSON Pointer**: all §5 examples; `~01` resolves to `~1`; `~2`, a trailing `~` and a missing leading `/` are rejected; `01`, `-`, `-0`, `+1`, `1e0` and 2^31/2^32/2^64 indices resolve to not-found, with no overflow on 32-bit wasm.
- **RFC 6902 JSON Patch**:
  - every op; `-` handling; root `""` add and replace;
  - `move` into its own child is rejected (prefix check on tokens, so `/a` → `/ab` is allowed);
  - same-path `move`;
  - atomic rollback leaves the input unchanged;
  - `test` numeric equality: `1 == 1.0` and `-0.0 == 0`, which Rust gets wrong; `2^53+1 ≠ 2^53`.
- **`diff_patch`**: round-trips with special keys, nested arrays and rotations; Rust `json-patch` accepts every generated patch.
- **RFC 7396**: all 15 Appendix A cases plus nested-null and array cases.
- **Query amplification**: `$..*..*..*..*`, repeated `[*,*,*,*,*]`, repeated index/slice/name selectors, 100 000 `||` terms, 10 000-deep parens/functions/filters, and O(N²) root scans all stop at `LimitExceeded` or finish quickly in all 4 modes.
- **Regex compile bombs**: `((a{1000}){1000}){1000}`, `(a{100000}){100000}` and `\p{L}{1000}` fail to compile, so `match` returns `false`, in < 0.6 s. Rust behaves the same (its regex size limit). Peak RSS is up to 235 MiB native; this is noted for `packages/regex` and is not a jsonpath finding.

## 6. Four-mode consistency

`audit/pion_driver` was built in `native_dbg`, `native_rel`, `wasm_dbg` and `wasm_rel` (serially) and run on all 909 differential cases (715 CTS + 194 RFC). The stdout SHA-256 values were identical in every mode:
- CTS: `05b0e0cd…210f`
- RFC: `26c3fadb…c98c`

Every probe that completes in two or more modes prints byte-identical step output across them.

The divergence between modes is in **failure behaviour**. Native has a much deeper stack (it survives the 20 000-deep `resolve_mut` that traps wasm). This is why P0-1 reproduces on wasm with only about 2 600 levels.

## 7. Benchmark fairness (`packages/jsonpath/bench`)

`sh run_audit.sh --bench` runs the existing Pion and Rust W1 binaries on the same corpus, split by query class (median of 5, 20 iterations, stdout identical in each split):

| W1 query subset | Pion (run A / run B) | Rust (run A / run B) | Pion speed-up |
| --- | ---: | ---: | ---: |
| all 6 queries (as published) | 53.6 / 60.3 ms | 137.2 / 164.1 ms | 2.56× / 2.72× |
| 2 queries with `match()` / `search()` | 36.0 / 45.5 ms | 117.1 / 276.4 ms | 3.25× / 6.08× |
| 4 queries without regex | 20.2 / 28.5 ms | 22.6 / 33.0 ms | **1.12× / 1.16×** |

Run B was taken on the loaded shared machine (load average ≈ 8), so its absolute numbers are noisier. The split is stable across both runs.

- **W1 is not a fair "parser/engine" comparison.** `serde_json_path 0.7.2` calls `regex::Regex::new` inside `match_func` / `search` (`registry.rs:60/74`) **for every node evaluated**, not once per parse as the README says. Pion precompiles constant patterns. About 85% of Rust's W1 time is spent in those 2 regex queries. Without them the gap is ~1.1×. The 2.49× headline therefore measures a known `serde_json_path` design cost (real for users of that crate). The README attribution ("`nom` + regex recompilation per parse") is inaccurate and should say "per evaluated node". Both sides re-parse the query on every iteration, which is symmetric.
- **W2 (0.57×)**: fair. Same precompiled queries, both sides only count matches, and the corpus is emitted with `sort_keys=True`, so Rust's default `BTreeMap` order equals Pion's insertion order and the checksums match. The corpus is built so that this ordering difference never shows; documents with unsorted keys would give different `$.*` order (not a correctness issue).
- **W3 (0.87×)**: fair, slightly favouring Pion. Rust deep-clones `before` for every round-trip (`before.clone()`), while Pion's Copy-on-Write needs no clone. Both perform an equivalent deep-equality check.
- No harness defects (warm-up, interleaving, SHA-256 verification) were found in `bench/run_bench.sh` / `scripts/bench_compare.py`.

## 8. Suite layout

```text
audit/REPORT.md          this report
audit/run_audit.sh       one-shot entry (POSIX sh) → python3 -I audit/audit.py --out /private/tmp/rt-jsonpath-audit
audit/audit.py           orchestrator: build 4 modes + Rust oracle, CTS, RFC differential, cross-apply, 4-mode SHA-256, probes, --bench
audit/cases.py           194 hand-written RFC cases with RFC-derived expectations and finding ids
audit/cts/cts.json       official CTS, pinned commit 20ebdcce (BSD-2, audit/cts/LICENSE)
audit/pion_driver/       Pion JSONL driver (query / parse / pointer / patch / merge / diff / eq)
audit/pion_probe/        Pion DoS / stack-safety probes (one process per probe, so crashes are attributable)
audit/rust_oracle/       serde_json_path 0.7.2 + json-patch 4.2.0 oracle, Cargo.lock committed, built --locked
```

Gating rule: any `FAIL` line exits 1. `INFO` lines (Rust reference results, benchmark split) never gate. Timeouts and RSS caps are generous for an O(n) or O(n log n) implementation: 100 000-key probes allow 10 s native / 20 s wasm, and RSS caps are 256 MiB to 1 GiB (+160 MiB for the node runtime under wasm).
