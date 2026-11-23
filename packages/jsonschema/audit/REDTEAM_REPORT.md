# Red-team audit: `packages/jsonschema` (W10 `RT-jsonschema`)

- **Target**: `origin/feat/pkg-jsonschema` @ `75fcab7` (`packages/jsonschema` v0.1.0, `src/` 3,595 lines).
- **References**: Rust `jsonschema =0.29.1` (`default-features = false`, offline: no HTTP/file retrieval, same scope as
  Pion), Node `ajv@8.17.1` (`ajv/dist/2020` + `ajv` draft-07, `strict:false, allErrors:true`, `ajv-formats@3.0.1` when
  formats are asserted), official **JSON-Schema-Test-Suite @ `83e866b`** (2025-02-19, the suite generation contemporary
  with jsonschema 0.29.1; `refRemote.json` excluded because it needs an HTTP remote server).
- **Toolchain**: `pionc 0.1.0` (`AFK-surf/pion@c375cee`), cargo 1.100.0, node v24.22.2, Darwin arm64 (tokyo-mac-studio-0).
- **Reproduce everything**: `sh packages/jsonschema/audit/run_audit.sh` (sections: `build unit suite redteam modes deep dos bench`).
  All artifacts land in `/private/tmp/rt-jsonschema`; the worktree stays clean.

## Summary

| Severity | Count | Findings |
| --- | ---: | --- |
| **P0** | 1 | P0-1 validation depth cut-off returns `false` → `not` / `if` turn it into **acceptance** (fail-open, reachable through `is_valid_str` with 70-level input) |
| **P1** | 9 | P1-1 `multipleOf` relative tolerance accepts non-multiples · P1-2 recursive data > ~64 levels reported invalid · P1-3 `\w \d \s` are Unicode, not ECMA-262 · P1-4 lookaround / backrefs / `\cX` rejected (schemas fail to compile) · P1-5 `$anchor` before `$id` is mis-scoped · P1-6 pointer `$ref` into an embedded resource uses the wrong base URI · P1-7 Draft-07 sibling `$id` beside `$ref` changes the base · P1-8 quadratic annotation bookkeeping (`unevaluated*` and every `validate()` call) · P1-9 `uniqueItems` hash saturates at depth 64 → O(N²) |
| **P2** | 11 | `$dynamicRef`/`$recursiveRef` silently ignored (fail-open), `$id` in unknown keywords, Draft-07 enforces 2020-only keywords, `multipleOf` quotient overflow, compile depth budget, draft-04/2019-09 auto-detection, no bundled meta-schemas, format strictness gaps, 9 unimplemented formats silently pass, O(R·N) `required` / O(R²) compile tables, raised `max_depth` is not stack-safe |
| **Fairness** | 3 | README W1/W2 ranking is dominated by process start-up (steady state Pion = **0.30x** Rust, slower than ajv); W3 builds a new `Ajv` instance per schema; no workload exercises `validate()` / `unevaluated*` / wide objects |
| **Controls / leads** | — | 100 % of the in-scope Draft 2020-12 core suite outside `$dynamicRef` + meta-schemas; 3 cases where Pion is right and Rust 0.29.1 wrong; `$ref` DAG / anyOf fan-out where Rust needs 10 GB and 23-40 s; 4-mode byte-identical transcripts |

Red-team unit tests (`audit/redteam_test.pion`): **18 `redteam_*` FAIL (evidence), 7/7 `control_*` PASS**.

## 1. Official JSON-Schema-Test-Suite differential (`run_audit.sh suite`)

Pass = verdict equals the suite's `valid`; a compile error counts as a failure.

| Group | Cases | Pion | Rust 0.29.1 | ajv 8.17.1 | Pion fails where Rust passes |
| --- | ---: | ---: | ---: | ---: | --- |
| `draft2020-12/*.json` | 1224 | 1190 (97.22 %) | 1206 (98.53 %) | 1160 (94.77 %) | 20: `dynamicRef` 14, `unevaluated*` with `$dynamicRef` 2, meta-schema `$ref` 4 |
| `draft7/*.json` | 890 | 884 (99.33 %) | 890 (100 %) | 882 (99.10 %) | 6: meta-schema `$ref` 4, **sibling `$id` (P1-7)** 2 |
| `draft2020-12/optional` | 158 | 133 (84.18 %) | 153 (96.84 %) | 148 (93.67 %) | 22: ecmascript-regex 18 (P1-3/4), unknownKeyword 2 (P2-2), float-overflow 1 (P2-4), dynamicRef 1 |
| `draft7/optional` | 118 | 91 (77.12 %) | 116 (98.31 %) | 108 (91.53 %) | 25: ecmascript-regex 18, content 4 (not asserted, see P2-9), unknownKeyword 2, float-overflow 1 |
| `draft2020-12/optional/format` (assert) | 491 | 426 (86.76 %) | 491 (100 %) | 443 (90.22 %) | 65: unimplemented formats 63 (idn-hostname 34, duration 11, relative-json-pointer 7, iri 4, …), email IPv6 literal 1, regex `\a` 1 |
| `draft7/optional/format` (assert) | 434 | 382 (88.02 %) | 434 (100 %) | 392 (90.32 %) | 52: all unimplemented formats |

The remaining Pion "failures" (14 core2020, 2+2 optional) need HTTP remotes and fail for **all three** implementations.
Every one of the 11 formats Pion implements passes the suite except `email` (IPv6 literal) and `regex` (`\a`), both P2-8.
`is_valid()` and `validate()` never disagreed on any of the 3,511 suite + red-team cases.

## 2. P0

### P0-1 Depth cut-off is reported as "invalid", and `not` / `if` invert it → fail-open

- **Root cause**: `validate.pion:143-145` (`is_valid_fast`), `:567-569` (`eval_node_ann`), `:888-891` (`validate_node_collect`)
  return `false` when `depth > max_depth`. That `false` flows into `not` (`:429-433`, `:805-808`, `:1169-1173`) and `if`
  (`:437-449`, `:812-826`, `:1178-1194`) as if the sub-schema had genuinely failed. Every evaluation hop counts
  (`items` + `$ref` = 2 per data level), so the default budget of 128 is exhausted by **~64 levels of data** while the
  public parser (`is_valid_str`, `strict_json` `max_depth: 128`) happily accepts 127 levels.
- **Repro** (`redteam_P0_1_*`, `out_redteam.report.txt` `depth/not-bypass-70`, `depth/anyOf-bypass-70`):
  ```
  schema   {"$defs":{"t":{"type":"array","items":{"$ref":"#/$defs/t"}}},"not":{"$ref":"#/$defs/t"}}
  instance [[[[ … 70 levels … ]]]]
  Pion: V (accepted)     Rust 0.29.1: I     ajv 8.17.1: I     depth 30: Pion I (correct)
  schema   {"$defs":{"t":…},"if":{"$ref":"#/$defs/t"},"then":false}   → same flip
  ```
- **Impact**: any deny-list written with `not`, `if/then:false`, `oneOf` exclusivity or `anyOf` fallbacks can be bypassed
  by an attacker who controls nesting depth. The package's own `redteam_test.pion` treats "depth exceeded ⇒ false" as the
  desired behaviour, so the defect is by design rather than an oversight.
- **Fix direction**: make the cut-off a distinct third state that aborts the whole validation (error/`Err`), never a
  `false` that combinators can negate; count only data-consuming hops (or detect non-consuming `$ref` cycles separately).

## 3. P1

### P1-1 `multipleOf` tolerance proportional to the instance accepts non-multiples
- **Root cause**: `validate.pion:57-59` `rem <= 1e-12 * max(|x|, |m|)` — the tolerance grows with |x|.
- **Repro** (`redteam_P1_1_*`): `{"multipleOf":1}` vs `1000000000.0005` → Pion **V**, Rust I, ajv I;
  `{"multipleOf":0.01}` vs `10000000000.005` → Pion **V**, Rust I, ajv I. `multipleOf: 1` is the common "integer" idiom
  and `0.01` the money idiom.
- Note the other side is a lead: decimal cases `0.3 % 0.1`, `19.99 % 0.01`, `0.0075 % 0.0001` are right in Pion and wrong
  in both Rust and ajv (`control_multipleof_decimal_beats_rust_and_ajv`). A fix should keep those (e.g. tolerance relative
  to `m` and to the quotient's ULP, or exact decimal arithmetic on the lexical number).

### P1-2 Legitimate recursive data deeper than ~64 levels is reported invalid
- Same root cause as P0-1. `{"type":"object","properties":{"c":{"$ref":"#"}}}` with a 70-level `{"c":{"c":…}}` → Pion **I**,
  Rust V, ajv V; even `{"items":{"$ref":"#"}}` vs a 127-level array (`run_audit.sh deep`, `instance_str 127`) → `false`.
  `validate()` reports keyword `maxDepth`, `is_valid()` gives no way to tell a cut-off from a real failure.

### P1-3 `pattern` / `patternProperties` / `format: regex` use Unicode shorthand classes
- **Root cause**: `compiler.pion:606`, `:741`, `format.pion:506` call `packages/regex` (Rust-`regex`-style Unicode
  `\w \d \s`), not ECMA-262 semantics. Rust jsonschema translates patterns to ECMA semantics; ajv uses JS `RegExp` (`u`).
- **Repro** (`redteam_P1_3_*`; suite optional `ecmascript-regex.json` 18 failures per draft):
  `^\w+$` vs `"café"` → Pion **V**; `^\d+$` vs Arabic-Indic `"١٢"` → Pion **V**;
  `patternProperties {"^\w+$":{}} + additionalProperties:false` vs `{"café":1}` → Pion **V** (key escapes the deny rule).
  Rust and ajv: I for all. Identifier / numeric-ID patterns therefore accept non-ASCII look-alikes.

### P1-4 ECMA-262 lookaround, backreferences and `\cX` are rejected at compile time
- `{"pattern":"^(?!admin$).*$"}`, `^(?=.*[0-9])(?=.*[a-z]).{8,}$`, `(?<=\$)\d+`, `^(a+)-\1$`, `^\cJ$` → Pion
  `Err(InvalidRegex: look-around is not supported (linear-time guarantee))`; Rust (fancy-regex) and ajv compile and
  validate them. Password-policy and reserved-word patterns are common in real schemas (OpenAPI), so whole schemas fail
  to load. The linear-time guarantee is a legitimate design choice, but it should be documented as a deviation, and
  `format: regex` should not call such patterns invalid (P2-8).

### P1-5 `$anchor` before `$id` in the same object is registered under the parent scope
- **Root cause**: `compiler.pion:290-332` — one pass over the entries; `$anchor` uses `next_scope`, which only changes
  when `$id` is reached. JSON object key order is not semantic.
- **Repro** (`redteam_P1_5_*`): `{"$id":"http://e.com/root","$defs":{"A":{"$anchor":"a","$id":"http://e.com/inner","type":"integer"}},"$ref":"http://e.com/inner#a"}`
  → Pion `Err(UnresolvedRef)`; Rust/ajv compile (1 → V, "x" → I). Swapping the two keys makes Pion work (control).

### P1-6 A JSON-Pointer `$ref` that walks into an embedded resource compiles it with the outer base URI
- **Root cause**: `compiler.pion:430-451` resolves the pointer from the scope's root value and calls
  `compile_into(…, target_scope, …)` with the scope of the *outer* resource; `$id`s crossed by the pointer are ignored.
- **Repro** (`redteam_P1_6_*`): root `http://e.com/root.json`, `#/$defs/inner/$defs/x` = `{"$ref":"y.json"}` inside
  resource `http://e.com/sub/inner.json` → must resolve to `http://e.com/sub/y.json` (integer). Pion resolves
  `http://e.com/y.json` (string): `1` → Pion **I**, Rust V, ajv V.

### P1-7 Draft-07: sibling `$id` beside `$ref` changes the base URI
- **Root cause**: `compiler.pion:973-995` applies `$id` to `eff_scope` before resolving `$ref`; Draft-07 says all `$ref`
  siblings (including `$id`) are ignored. Official `draft7/ref.json` group 6 fails both tests (Pion "a" → V, 1 → I).

### P1-8 Quadratic annotation bookkeeping (`unevaluated*`, and *every* `validate()` call)
- **Root cause**: `EvalAnn.add_prop/has_prop/add_item/has_item` (`validate.pion:473-531`) are linear scans over an array,
  called once per key/index → O(N²). `validate_node_collect` calls `add_prop` for every matched property even when the
  schema has no `unevaluated*` (`validate.pion:1065`, `:1074`, `:1081`), so plain `validate()` on wide objects is quadratic.
- **Repro** (`run_audit.sh dos`, release builds; cells `compile/is_valid/validate ms`):

  | probe | Pion | Rust 0.29.1 | ajv |
  | --- | --- | --- | --- |
  | `unevaluatedProperties` over 50k keys | 0 / **6,547** / **6,610** ms | 10 / 3 / 2 ms | 35 ms |
  | `additionalProperties:true` + `uP:false`, 50k keys | 0 / **6,480** / **11,760** ms | 7 / 2 / 2 ms | 26 ms |
  | `contains` + `unevaluatedItems:false`, 50k items | 0 / **1,023** / **896** ms | 2 / 0 / 0 ms | 23 ms |
  | plain `additionalProperties`, 50k keys (`validate()` only) | 0 / 1 / **3,204** ms | 2 / 0 / 0 ms | 26 ms |
  | 50 `patternProperties` × 20k keys (`validate()`) | 0 / 30 / **964** ms | 2 / 11 / 11 ms | 130 ms |

  Doubling N quadruples the time (5k → 20k → 50k: 78 ms → 1.15 s → 6.5 s). A single 1 MB request body is enough for a
  multi-second CPU stall per validation.

### P1-9 `uniqueItems` hash saturates at depth 64 → O(N²) deep comparisons
- **Root cause**: `hash.pion:31-33` returns the constant `0xDEADBEEF` beyond depth 64, so all deep items collide into one
  linear-probe chain and every insert runs `value_eq` against all previous items (`hash.pion:113-123`). README claims
  "O(N) open-addressing structural hash".
- **Repro**: 4,000 distinct arrays that differ only below depth 64 → Pion is_valid **6.6 s** (1,000 items: 373 ms),
  Rust **5 ms**; ajv is quadratic too (12 s). Fix: keep hashing iteratively (bounded work, not bounded depth) or salt
  by the path of the first differing leaf.

## 4. P2

| Id | Finding | Evidence / root cause |
| --- | --- | --- |
| P2-1 | `$dynamicRef`, `$dynamicAnchor`, `$recursiveRef`, `$recursiveAnchor` are silently **ignored** (README lists them as not implemented) — the keyword becomes a no-op, i.e. **fail-open**: `{"$defs":{"s":{"$dynamicAnchor":"s","type":"string"}},"$dynamicRef":"#s"}` accepts `1`. Recommend a compile-time `Err` until implemented. | `compile_keyword` (`compiler.pion:478-944`) has no branch; suite `dynamicRef.json` 14 + 2 `unevaluated*` failures; `redteam_P2_1_*` |
| P2-2 | `$id` / `$anchor` inside unknown keywords are registered as real resources (first registration wins) | `collect_resources` walks every key except `const/enum/default/examples` (`compiler.pion:336-347`); suite `optional/unknownKeyword.json`; `redteam_P2_2_*` |
| P2-3 | Draft-07 mode enforces 2019+/2020-only keywords: `prefixItems`, `minContains`/`maxContains`, `dependentRequired`, `dependentSchemas`, `unevaluated*`, `$anchor` | `compile_keyword` is draft-agnostic; e.g. draft-07 `{"contains":{"const":1},"minContains":0}` vs `[]` → Pion V, Rust/ajv I; `redteam_P2_3_*` |
| P2-4 | `multipleOf` returns `false` when `x/m` overflows (README claims overflow-safe `1e308`): `{"type":"integer","multipleOf":0.5}` vs `1e308` → I (suite `float-overflow.json`); `2^30 % 2^-1000` → I | `validate.pion:50-53`; `redteam_P2_4_*` |
| P2-5 | Compile depth budget (128) is shared by `$ref` hops and JSON nesting: a 200-hop non-recursive `$ref` chain and a 70-level `properties` schema are rejected with `LimitExceeded` (collect_resources counts 2 levels per `properties`) | `compiler.pion:281`, `:412`, `:451`, `:466`, `:957`; Rust/ajv compile both; `redteam_P2_5_*` |
| P2-6 | `$schema` auto-detection only knows `draft-07`/`draft-06`; draft-04 and 2019-09 URIs fall back to 2020-12 semantics: draft-04 `exclusiveMinimum: true` fails to compile, 2019-09 `$recursiveRef` silently ignored | `detect_draft` `compiler.pion:1075-1089`; Rust auto-detects draft-04; `redteam_P2_6_*` |
| P2-7 | No bundled meta-schemas: `$ref` to `https://json-schema.org/draft/2020-12/schema` / draft-07 is `UnresolvedRef` (suite `defs.json`, `definitions.json`, `ref.json` "remote ref, containing refs itself") | Rust bundles them offline; `redteam_P2_7_*` |
| P2-8 | Format strictness vs Rust: `uri` accepts non-numeric port `http://example.com:abc/`, unclosed `http://[::1/`, invalid IP-literal `http://[zz]/`, second `#` (`format.pion:412-452` only checks characters); `email` rejects RFC 5321 `a@[IPv6:::1]` (`format.pion:399-405` only IPv4 literals); `format: regex` follows P1-3/P1-4 (`^(?!a)` "invalid", `\a` "valid") | `out_redteam.report.txt` `fmt/*`; `redteam_P2_8_*` |
| P2-9 | 9 formats silently pass with `validate_formats: true` (`duration`, `uri-reference`, `iri`, `iri-reference`, `idn-email`, `idn-hostname`, `relative-json-pointer`, `uri-template`, plus `contentEncoding/contentMediaType` in Draft-07) — 63/52 suite format failures | `check_format` `format.pion:484-513` falls through to `true`; `redteam_P2_9_*` |
| P2-10 | Non-hashed lookups: `required`/`dependentRequired` are O(R·N) (`object_has_key`, `validate.pion:121-132`): 2,000 names × 50k keys = 347 ms vs Rust ≤ 1 ms; compile-time scope/anchor/memo tables are linear lists (`compiler.pion:227-271`) → O(R²) compile: 8,000 `$anchor` refs = 623 ms vs Rust 25 ms | `run_audit.sh dos` |
| P2-11 | Raising `CompileOptions.max_depth` is not stack-safe: compiler recursion (`collect_resources`/`compile_into`) has no independent guard, so `compile_str_with(max_depth: 1e6)` of a 10,000-level schema SIGSEGVs natively and a 300-level schema traps on wasm32 (`RangeError: Maximum call stack size exceeded`) instead of `LimitExceeded`. Defaults (128) are safe on both targets. | `run_audit.sh deep` (`schema_str_opt`) |
| P2-12 | Integers beyond 2^53 collapse to `f64` (inherited from `json5::Json5Value::Number(Double)`): `{"maximum":9007199254740992}` accepts `9007199254740993` (Rust I, ajv V). Implementation-defined by the spec; document it. | `num/2^53+1-*` cases |

In the `dos` table the Pion `deep_*` rows show SIGSEGV because the audit driver lifts the json5 parser limit to
200,000 and the resulting value overflows the stack when dropped — the platform note below, not the validator.

Platform note (not a `jsonschema` defect, reported for the lead): dropping a `json5::Json5Value` nested ≥ ~50,000 levels
(native) or ≥ ~2,000 levels (wasm32, node default stack) overflows the stack even without calling `jsonschema`
(`run_audit.sh deep`, mode `build_only`). The package README's "50,000-level … 0 trap on Wasm32" claim only holds for
string input, which the parser rejects at depth 128.

## 5. Controls and areas where Pion is equal or better

- **Core 2020-12 semantics**: outside `$dynamicRef` and meta-schema refs, Pion passes **every** in-scope `draft2020-12/*.json`
  test, including all `unevaluatedProperties`/`unevaluatedItems`, `ref.json`, `anchor.json`, `id` and `defs` groups.
- **Pion right, Rust 0.29.1 wrong** (spec-checked, ajv agrees with Pion where noted):
  - failed `anyOf` branch must not leak annotations to `unevaluatedProperties` (Rust V, Pion/ajv I);
  - `items` inside `anyOf` behind a recursive `$ref` annotates every index (Rust I, Pion/ajv V; also the `anyof_ue_*` probes);
  - decimal `multipleOf` (`0.3 % 0.1`, `19.99 % 0.01`): Rust and ajv both I, Pion V.
- **Equality and numbers** (`control_numbers_and_equality`): `1 == 1.0`, `0 == -0.0`, `true != 1`, `false != 0`,
  `null != false`, key-order-independent objects, `uniqueItems` hash path, duplicate instance keys (last wins),
  `1.0`/`1e20`/`-0.0` are integers, `exclusiveMinimum: 0` rejects `-0.0`.
- **References**: `~01` not double-unescaped, `%25`/`%20`, pointer into arrays, boolean targets, nested-resource local
  pointers, anchor scoping, 2020-12 siblings applied / Draft-07 siblings ignored.
- **Formats implemented**: leap years, leap seconds with offsets, `±24:00` rejected, lowercase `t`/`z`, IPv4 leading zeros,
  IPv6 zone IDs, hostname label/total lengths, json-pointer `~2`, UUID braces — all correct.
- **Resource blow-ups where Pion leads** (`run_audit.sh dos`):

  | probe | Pion | Rust 0.29.1 | ajv |
  | --- | --- | --- | --- |
  | `$ref` DAG fan-out 2^22 (`allOf:[d_{i+1}, d_{i+1}]`) | V, 108 ms is_valid / 595 ms validate, **3 MB** | 8.2 s is_valid, 20.4 s wall, **12.7 GB RSS** (one earlier run: TIMEOUT > 40 s) | 49 ms |
  | 2-way `anyOf` recursion, depth 18, invalid leaf | 16 ms, 3 MB | 2,394 ms, **9.6 GB** | 222 ms |
  | 100k distinct strings / numbers `uniqueItems` | 2 ms | 1 ms | strings TIMEOUT, numbers 17 s |
  | 8,000 `$ref` targets compile | 312 ms | 22 ms | stack overflow (`Maximum call stack`) |
  | 100k-deep instance / 40k-deep schema via `compile_str` / `is_valid_str` (`deep` section) | clean `Err(maximum nesting depth exceeded)` | SIGABRT stack overflow (serde, recursion limit off) | `RangeError` |

- **Build modes**: the driver's verdict transcripts over all 3,511 cases (suite + red-team) are byte-identical in
  native/wasm32 × debug/release (`run_audit.sh modes`, verdict SHA-256 prefix `ed32fc9b33fe5b56`; one run per mode,
  timing column excluded).

## 6. Benchmark fairness (`run_audit.sh bench`)

1. **README W1/W2 measure process start-up, not validation.** Each run lasts 25-100 ms; splitting fixed cost (0
   iterations: start, read, parse, compile) from the slope over 2,000 iterations (`bench/steady_state.py`, the package's own
   unmodified drivers and corpora):

   | | Pion fixed | Pion steady | Rust fixed | Rust steady | ajv fixed | ajv steady |
   | --- | ---: | ---: | ---: | ---: | ---: | ---: |
   | W1 (MCP tool call) | 5 ms | 400-657 ns/op | 13-14 ms | 122-141 ns/op | 78-90 ms | 103-200 ns/op |
   | W2 (manifest) | 5-6 ms | 1,133-2,123 ns/op | 14-16 ms | 330-387 ns/op | 79-108 ms | 524-564 ns/op |

   Steady-state Pion is **~0.30x Rust** and **slower than ajv** on both workloads, versus README's "0.79x-0.87x of Rust,
   3.3-3.4x faster than ajv" (ajv's 85-110 ms is Node start + one-off codegen). The ranges are three separate runs on a
   shared machine (the last one is printed by `run_audit.sh bench`).
2. **W3 is biased against ajv**: `bench.js` creates `new Ajv2020()` for every schema (meta-schema compiled again each
   time), so "~332x faster than ajv" mostly measures Ajv construction; idiomatic code reuses one instance.
3. **Coverage bias**: every workload calls only `is_valid` on small objects without `unevaluated*`. The adversarial
   workloads (same drivers, same SHA-256 discipline, `--warmup 1 --rounds 5`):

   | workload | Pion | Rust | ajv | Pion vs Rust |
   | --- | ---: | ---: | ---: | ---: |
   | a1 wide objects (1000 keys, `additionalProperties`) | 35.1 ms | 24.0 ms | 163.4 ms | 0.68x |
   | a2 `unevaluatedProperties`, 300-key objects | 266.7 ms | 48.0 ms | 139.6 ms | **0.18x** |
   | a3 `uniqueItems`, 2000 objects | 53.4 ms | 61.2 ms | 26,546 ms | **1.15x** |
   | a4 recursive `$ref` tree depth 40 | 36.6 ms | 37.1 ms | 92.8 ms | 1.01x |
   | a5 W1 schema, 5000 distinct instances | 64.0 ms | 41.0 ms | 101.3 ms | 0.64x |

   (a4 stays below the depth cut-off of P0-1; at depth ≥ 64 Pion would answer differently and the SHA check would fail.)
4. Minor: `bench/rust_bench/Cargo.toml` says `jsonschema = "0.29.0"` and `run_bench.sh` "=0.29.0" while the lockfile
   resolves 0.29.1 (README says 0.29.1).

## 7. Layout

```
audit/pion.toml, redteam_test.pion   18 redteam_* (FAIL = evidence) + 7 control_* (PASS)
audit/run_audit.sh                   one-shot runner (build unit suite redteam modes deep dos bench)
audit/diff/pion_driver/              Pion differential driver (is_valid + validate + timings)
audit/diff/rust_oracle/              Rust jsonschema =0.29.1 oracle (Cargo.lock pinned, offline)
audit/diff/node_oracle/oracle.js     ajv 8.17.1 (+ajv-formats 3.0.1) oracle
audit/diff/gen_suite.py              JSON-Schema-Test-Suite -> cases; gen_redteam.py: 196 curated adversarial cases
audit/diff/run_diff.py               three-way comparison + per-case report; four_modes.sh: native/wasm32 x debug/release
audit/dos/gen_dos.py, run_dos.py     33 complexity / stack probes; dos/pion_deep: public-API stack probe
audit/bench/gen_adv.py, run_adv.sh   adversarial head-to-head + steady_state.py fairness split
```
