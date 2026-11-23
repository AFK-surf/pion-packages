# Red-team audit: `packages/graphql` vs graphql-js and apollo-parser

Target: `packages/graphql` at `5378e21` (branch `feat/pkg-graphql`), `pionc 0.1.0`, Darwin arm64 (Apple M-series).

Oracles:

| Oracle | Version | Used for |
|---|---|---|
| Node `graphql` (graphql-js) | `16.10.0` (`node/package.json`) | token stream with decoded values; full AST (canonical dump mirrored byte for byte by the Pion probe); `print`; `stripIgnoredCharacters`; 13 schema-free validation rules |
| Rust `apollo-parser` | `=0.8.4` (`rust/Cargo.lock`) | accept/reject and token boundaries (it is a lossless CST parser and never decodes strings); timings |
| GraphQL spec, October 2021 edition | spec.graphql.org/October2021 | where the oracles disagree with the spec |

Reproduce everything with one command (about 10 minutes, perf included). All build output goes to `/private/tmp/rt-graphql`, and `git status --porcelain --ignored` stays empty:

```sh
sh packages/graphql/audit/run_audit.sh            # QUICK=1 for a ~3 minute run
```

| Part | Contents |
|---|---|
| `redteam_test.pion` | 30 tests: 5 `p0_`, 6 `p1_`, 8 `p2_` (each failure is evidence) and 11 `control_` tests that must pass |
| `probe/` | Pion batch probe (`tok`, `tokb`, `parse`, `parseb`, `min`, `print`, `valid`, `one`), built native debug/release and wasm32 debug/release |
| `node/oracle.js` | graphql-js oracle, same CLI and canonical AST dump |
| `rust/` | apollo-parser oracle (`parse`, `tok`, `one`) |
| `scripts/spec_diff.py` | 259 hand-written cases (control chars, BOM, escapes, block strings, numbers, keywords, SDL, executable) |
| `scripts/tok_diff.py` | 18,000 random lexer inputs + 4,500 raw-byte / truncated-UTF-8 inputs |
| `scripts/fuzz_diff.py` | 6,000 grammar-generated documents (1/3 byte-mutated), AST compared with graphql-js |
| `scripts/roundtrip_diff.py` | print and minify semantic preservation, idempotency, byte comparison with `stripIgnoredCharacters` |
| `scripts/valid_diff.py` | 33 hand cases + 6,000 fuzzed executable documents vs graphql-js rules |
| `scripts/dos.py` | 23 crash / complexity probes at N and 2N under `/usr/bin/time -l` |
| `scripts/wasm4.py` | Native debug/release vs Wasm32 debug/release (executed under node), SHA-256 of every output |
| `scripts/perf.py` | 5 un-curated corpora × parse/print/minify, Pion native + wasm32, graphql-js, apollo-parser |

`pionc test --json -p graphql_audit packages/graphql/audit` gives `total=30 passed=11 failed=19`: all 19 p0/p1/p2 tests fail (the evidence) and all 11 controls pass. The package's own suite and sources are untouched (`git diff --name-only origin/feat/pkg-graphql..HEAD` lists only `packages/graphql/audit/**`).

## Summary

The lexer and parser are very good. Across 6,000 fuzzed documents the AST matches graphql-js on 100%, and the 259 hand cases differ only on the control-character rows below. The problems are in the printer (silent data loss), the validator (most schema-free graphql-js rules are missing), and in AST teardown, which recurses even though the package advertises "0 recursion".

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| P0-1 | P0 | `print_document` deletes leading spaces/tabs of single-line block strings (values and descriptions). Print is not idempotent: each print strips another level. | `p0_print_block_string_leading_spaces_lost`, `p0_print_block_description_leading_whitespace_lost`, `p0_print_not_idempotent`; `roundtrip_diff.py`: 197/3,573 fuzz docs |
| P0-2 | P0 | `print_document` drops every argument description (field arguments and directive-definition arguments). | `p0_print_drops_field_argument_description`, `p0_print_drops_directive_argument_description`; `roundtrip_diff.py`: 387/3,573 fuzz docs |
| P1-1 | P1 | U+007F (DEL) is rejected in comments, strings and block strings. It is a legal Oct 2021 SourceCharacter and graphql-js and apollo-parser accept it. | `p1_del_in_*` (3 tests); `spec_diff.py` |
| P1-2 | P1 | `validate_executable` passes documents that contain SDL (`type`, `schema`, `directive`, `scalar` …): no ExecutableDefinitions rule. | `p1_validate_accepts_sdl_in_executable_document`; `valid_diff.py`: 347–457 fuzz docs |
| P1-3 | P1 | No NoUndefinedVariables: `$v` used but never declared (directly, in a directive, through a fragment, or in one of two operations sharing a fragment) passes. | `p1_validate_misses_undefined_variable*`; `valid_diff.py`: the largest bucket (562–740 docs) |
| P1-4 | P1 | Native SIGSEGV / Wasm32 stack-overflow trap when a deep AST is released (raised `max_depth`). Wasm32 traps from selection depth 800 (with `max_depth` 1000, the value the package's own test uses), native from ~25k. | `dos.py` (rc -11), `wasm4.py` (rc 1, `RangeError`; wasm32 debug already at list depth 2,000); not a Pion test because it kills the test binary |
| P2-1 | P2 | No NoUnusedVariables | `p2_validate_misses_unused_variable` |
| P2-2 | P2 | No NoUnusedFragments | `p2_validate_misses_unused_fragment` |
| P2-3 | P2 | No UniqueDirectivesPerLocation (`@skip` twice) | `p2_validate_misses_duplicate_skip` |
| P2-4 | P2 | The body of a duplicate fragment definition is never walked: unknown spreads and limit counts inside it are invisible | `p2_validate_skips_duplicate_fragment_body` |
| P2-5 | P2 | `minify_query` copies block strings verbatim. The README says it matches `stripIgnoredCharacters` byte for byte; it does on 1,398/3,573 docs, and output is 2.5% larger overall | `p2_minify_block_string_not_minimized`; `roundtrip_diff.py` M2 |
| P2-6 | P2 | `\u{…}` with more than 8 hex digits is accepted; graphql-js and apollo-parser reject it | `p2_variable_unicode_escape_over_8_digits_accepted` |
| P2-7 | P2 | The default `max_tokens = 500,000` rejects a 1.5–2 MB realistic SDL (the shape of the package's own W1 corpus). `bench/pion_bench` silently raises it to 5,000,000 | `p2_default_max_tokens_rejects_realistic_large_schema`; `dos.py` "SDL n types" `parsedef` |
| P2-8 | P2 | Error columns count UTF-8 bytes, not characters (`{ f(x: "ééé") ! }`: graphql-js column 15, Pion 18) | `p2_error_column_counts_utf8_bytes` |
| P2-9 | P2 (perf) | Pion Wasm32 parses 1.3–1.8× slower than graphql-js on node in 4 of 5 corpora. Pion native only ties apollo on deep realistic queries and uses 1.4–3× apollo's RSS on token-dense input | `perf.py` |

---

## P0: silent data corruption in `print_document`

The README calls `print_document` "canonical, idempotent". Over 3,573 fuzzed documents that Pion accepts, `parse(print(parse(x))) != parse(x)` for 584 (16%). graphql-js agrees that the printed text means something different (`P2` column of `roundtrip_diff.py`). `roundtrip_diff.py` attributes every failure to one of two causes:

```
P1 root cause:  387 x argument/input-value description dropped by print_document (P0-2)
P1 root cause:  197 x block string leading whitespace lost by print_document (P0-1)
```

### P0-1: leading whitespace of block strings is deleted

`write_block_string` (`src/printer.pion:50`) falls back to the multi-line form whenever the value starts with a space or tab, and always puts a newline after the opening `"""`. §2.9.4 BlockStringValue then removes the common indentation, which is computed only over lines after the first, and that now includes the value's own first line. graphql-js `printBlockString` handles this with `skipLeadingNewLine = isSingleLine && isWhiteSpace(value[0])`.

| | text | value |
|---|---|---|
| input | `{ f(x: """  a""") }` | `"  a"` |
| Pion print | `f(x: """⏎  a⏎""")` | re-parsed: `"a"` |
| graphql-js print | `f(x: """  a⏎""")` | `"  a"` |

The same happens to descriptions (`"""\tTabbed doc"""` → `Tabbed doc`). Each round trip strips another level, so the printer is not idempotent (`"""    deep"""` → `"""⏎    deep⏎"""` → `"""deep"""`).

### P0-2: argument descriptions are dropped

`write_input_value_def` (`src/printer.pion:341`) never writes `iv.description`. It is used for field arguments and directive-definition arguments, so every `"doc" arg: T` loses its documentation in the printed SDL. Input-object fields are not affected, because `write_input_fields_def` calls `write_description` itself. Formatting an SDL file with this printer, or any schema registry or codegen step that re-prints SDL, silently deletes argument documentation.

```
type T { f("how many" first: Int): Int }      →  type T {\n  f(first: Int): Int\n}
directive @cost("""weight""" w: Int) on FIELD  →  directive @cost(w: Int) on FIELD
```

## P1: spec deviations, validation gaps, crash

### P1-1: DEL (U+007F) is rejected

`is_invalid_source_byte` (`src/lexer.pion:243`) adds `b == 0x7F`. The October 2021 SourceCharacter is `/[\u0009\u000A\u000D\u0020-\uFFFF]/`, so DEL is legal in comments, strings and block strings. graphql-js and apollo-parser both accept it:

```
src  : '# \x7f\n{ a }'   pion: ERR InvalidSyntax … invalid control character in comment   node: (op query …)   rust: OK
```

Rejecting the other C0 controls (BEL, VT, FF, NUL…) is **correct** for the October 2021 edition. graphql-js 16 and apollo-parser follow the later full-Unicode draft, so those rows of `spec_diff.py` / `tok_diff.py` are not counted against Pion (see Fairness). `control_c0_controls_rejected_per_oct2021` pins this.

### P1-2 / P1-3: `validate_executable` misses ExecutableDefinitions and NoUndefinedVariables

`valid_diff.py` runs the 13 graphql-js executable rules that need no schema. Pion implements 8 of them (UniqueOperationNames, LoneAnonymousOperation, UniqueFragmentNames, KnownFragmentNames, NoFragmentCycles, UniqueVariableNames, UniqueArgumentNames, UniqueInputFieldNames) and is missing 5 (ExecutableDefinitions, NoUndefinedVariables, NoUnusedVariables, NoUnusedFragments, UniqueDirectivesPerLocation). Result on fuzzed executable documents: identical error sets for only 16.6% of documents.

```
562 x graphql-js reports NoUndefinedVariables, Pion does not   e.g. '{E1(false:null a:$false) @x1 @type}'
392 x graphql-js reports NoUnusedFragments, Pion does not
347 x graphql-js reports ExecutableDefinitions, Pion does not   e.g. 'scalar S'
 28 x graphql-js reports NoUnusedVariables, Pion does not
 14 x DuplicateArgumentName (inside SDL directive arguments, which only an executable-definition check would reach)
 12 x UndefinedFragment (inside a duplicate fragment body, P2-4)
```

A server that uses `validate_executable` as its gate (which the README example suggests) accepts `type Evil { a: Int } schema { query: Evil } { a }` with 0 errors. It also accepts `query { a(x: $undefined) }`, which then fails at execution, or binds `null` silently in executors that don't re-check.

### P1-4: deep ASTs crash on release (native SIGSEGV, Wasm32 trap)

The parser, printer and validator are iterative, as advertised. But releasing a deep `Document` recurses in the runtime's reference-count teardown, one native frame per nesting level. With the default `max_depth = 128` this is unreachable. With a raised `max_depth` (the package's own `redteam__50k_nested_selection_sets_no_sigsegv` test uses `ParseOptions::new(1000, …)` and the README promises "0 SIGSEGV, 0 Wasm32 trap"):

| input (probe `one … parse`, max_depth raised) | native debug/release | wasm32 debug/release |
|---|---|---|
| selection depth 600 | ok | ok |
| selection depth 800 | ok | **trap** `RangeError: Maximum call stack size exceeded` |
| selection depth 30,000 | **SIGSEGV** (rc -11) | trap |
| list value depth 2,000 | ok | ok in release, **trap** in debug |
| list value depth 5,000 | ok | **trap** |
| list value depth 60,000 | **SIGSEGV** | trap |

Binary search on native (`ulimit -s` 8 MB): selection crashes from ~25k, list values ~43k, list types ~130k. Parsing and validation finish first (probe `one valid` prints its result, then the process dies), so the crash is in teardown. The root cause is in the Pion runtime (recursive `rc_dec`). The package-level mitigation is to clamp `max_depth` (wasm-safe value < ~700 selections) or tear the tree down iteratively, and to correct the README claim. For comparison: apollo-parser with its recursion limit removed also aborts (stack overflow) and is quadratic on deep values (`dos.py`: 4.8 s → 19.5 s for 30k → 60k). graphql-js throws a catchable `RangeError` already during parsing.

## P2: gaps and edge cases

- **P2-1/2/3** missing rules: NoUnusedVariables, NoUnusedFragments, UniqueDirectivesPerLocation (only `@skip`/`@include`/`@deprecated`/… are known non-repeatable without a schema).
- **P2-4** `validate_executable_impl` registers only the first definition of a duplicated fragment name and never walks the second body. The document is still rejected (DuplicateFragmentName), but nothing in that body is checked or counted.
- **P2-5** `minify_query` emits the raw block-string slice. Meaning is always preserved (M1: 3,573/3,573), but the README's "byte-for-byte" claim holds only without block strings. The `bench/` W3 SHA-256 check cannot see this because `gen_data.py` puts no block strings in queries.
- **P2-6** `\u{000000041}`: Pion accepts, graphql-js and apollo reject (graphql-js allows at most 8 hex digits). The October 2021 edition has only `\uXXXX`, so `\u{…}` is a draft-spec extension in all three. This is a strictness divergence, not a safety issue.
- **P2-7** default `max_tokens = 500,000`: `dos.py` "SDL n types" `parsedef` fails at offset 1,466,676 of a 2.0 MB schema. The W1 benchmark passes only because `bench/pion_bench` uses `ParseOptions::new(128, 5000000, 5000000)`, and the README does not say so.
- **P2-8** error columns are byte offsets on the line; graphql-js reports characters (UTF-16 units).
- **P2-9** performance weak spots (below).

## DoS probes (`dos.py`, N and 2N)

Everything Pion does is linear, and Pion is the fastest implementation in every algorithmic probe:

| probe | Pion | graphql-js | apollo-parser |
|---|---|---|---|
| diamond fragment bomb, 13/14 levels (2^14 fields from 1 KB) | 6–11 ms, reports MaxFields + MaxAliases | 80 ms, **OK** (no limits at all) | – |
| diamond fan-out 8, 5 levels (8^5 fields) | 8 ms, reported | 76 ms, OK | – |
| 26-level diamond (2^26 fields) | `control_diamond_fragment_bomb_detected_fast`: passes in ms (O(V+E) DP with a 1e9 cap) | – | – |
| `{a{a{…` 50k, default options | `LimitExceeded` in 4 ms | `RangeError` (stack) | recursion limit error |
| fragment chain 60k | 64 ms, linear | **`Maximum call stack size exceeded`** | – |
| 120k distinct aliases / args / input fields / 60k vars | 26–45 ms, growth ≈1.7–2 | 0.7–1.2 s | – |
| 200k unknown spreads (error storm) | 42 ms, 60 MB | 0.71 s | – |
| 8 MB comment / block string / escape-heavy string | 14–28 ms | 76–134 ms | 20–25 ms |
| unterminated 6 MB block string | 16 ms | 202 ms, 272 MB | 19 ms |

HashDoS: `Map[String, _]` uses the runtime's seeded hash (`arc4random`/`getrandom` seed, wasm32 `crypto.getRandomValues`). 120k-key validations scale linearly, and collisions cannot be precomputed without the seed. Only `PION_HASH_SEED` pins it.

## Native vs Wasm32 (`wasm4.py`)

All corpora produce SHA-256-identical output on native debug, native release, wasm32 debug and wasm32 release (the wasm builds are executed, not just compiled). Each mode covers 6,259 docs: `parse`, `tok`, `min`, `print`, `valid`. Also identical: 4,000 raw/truncated byte inputs for `parseb`/`tokb`, and 9 stress inputs at the default limits (50k nesting of every kind, 500k-token query, 2 MB comment, 1 MB name). The only divergence is the stack depth at which the teardown crash of P1-4 happens.

## Adversarial performance (`perf.py`, 5 rounds interleaved, median, includes process start-up)

Numbers are from the `run_audit.sh` run (log in `$AUDIT_TMP/run_audit.log`). A separate earlier run was 5–25% faster for every implementation (machine shared with other jobs); the rankings were the same, except that C2 parse became a near-tie between Pion and apollo in this run.

| corpus | op | Pion native | Pion wasm32 | graphql-js | apollo-parser |
|---|---|---:|---:|---:|---:|
| C1 bench W1 SDL 2.0 MB ×3 | parse | **86 ms** / 31 MiB | 225 ms / 98 MiB | 168 ms / 343 MiB | 120 ms / **23 MiB** |
| | print | **103 ms** | 241 ms | 885 ms | – |
| C2 deep realistic query (depth 100) 4.2 MB ×10 | parse | **1,234 ms** / 104 MiB | 2,720 ms | 1,476 ms / 1,564 MiB | 1,248 ms / **75 MiB** |
| | print | **1,477 ms** | 3,003 ms | 13,833 ms | – |
| | min | **640 ms** | 1,074 ms | 1,909 ms | – |
| C3 escape-heavy strings 3.1 MB ×10 | parse | **161 ms** / **15 MiB** | 430 ms | 458 ms / 396 MiB | 291 ms / 20 MiB |
| | print | **234 ms** | 487 ms | 1,437 ms | – |
| | min | **156 ms** | 326 ms | 553 ms | – |
| C4 block-string-heavy SDL 2.4 MB ×5 | parse | **129 ms** | 327 ms | 229 ms | 176 ms |
| | print | **154 ms** | 361 ms | 697 ms | – |
| | min | **90 ms** | 224 ms | 253 ms | – |
| C5 flat 400k-field query 2.0 MB ×5 | parse | **183 ms** / 107 MiB | 415 ms / 187 MiB | 279 ms / 507 MiB | 315 ms / **36 MiB** |
| | print | **215 ms** | 489 ms | 3,246 ms | – |
| | min | **81 ms** | 175 ms | 327 ms | – |

Weak spots (P2-9), reported as found:
- **Pion Wasm32 vs graphql-js on node.** Wasm32 parse is slower in C1 (1.34×), C2 (1.84×), C4 (1.42×) and C5 (1.49×), and only wins C3 (escape-heavy). Wasm32 is 1.7–2.7× slower than Pion native overall. In the deployment where both run in the same JS engine, graphql-js parses faster.
- **Deep realistic queries.** On C2 (depth-100 nesting with arguments, objects and inline fragments) Pion native parse ties apollo-parser (1,234 vs 1,248 ms in this run, 918 vs 1,146 ms in the earlier one). The W1/W2 leads of 1.4–2× do not carry over to this shape.
- **Memory on token-dense input.** Pion native RSS is 3.0× apollo's on C5 and 1.4× on C2. It is still 4–14× below graphql-js.
- apollo-parser 0.8.4 rejects `\u{…}` escapes and UTF-16 surrogate-pair escapes (`paired surrogate not supported yet`, apollo-rs#657). The first C3 corpus contained them, so apollo's "fast" time there was an error exit. The corpus was changed to escapes all three accept.

## Benchmark fairness review of `bench/`

- **W1 (SDL).** Pion runs with `max_tokens` raised 10× over the default (P2-7). apollo-parser builds a lossless rowan CST (every whitespace and comment token is a node) and does error recovery. It is the lossless/IDE design, not a like-for-like AST parser, and that explains part of Pion's 1.4× lead. Reproduced here: 81 vs 113 ms.
- **W2 (parse + validate).** All three run the same hand-written subset of checks, so the comparison is fair. graphql-js is faster than Pion there (2.34× vs 2.08× vs apollo, as the README already says honestly). The Rust validator allocates a `String` per name (`name.text().to_string()`), a handicap of the bench code, not of apollo.
- **W3 (minify + reparse + print).** The SHA-256 covers only counts, `min_bytes` and an FNV of the minified text, not the printed output. P0-1/P0-2 are invisible to it. The Rust "print" is `doc.syntax().to_string()` (lossless CST text, no formatting), so Rust does strictly less work than the two real pretty-printers. The corpus has no block strings, which hides P2-5.
- All `node` timings include ~40 ms of process start-up and JIT warm-up per round.

## Fairness: where Pion is equal or better (controls)

- **Parser conformance.** 6,000/6,000 fuzzed documents give the same AST as graphql-js, including keyword-as-name contexts (`on`, `true`, `null`, `fragment` …), `fragment on` rejection, enum values `true/false/null`, ConstValue `$var` rejection in all 5 const positions, empty `()`/`{}` rejection, `type T` without fields, leading `&`/`|`, and no description on `extend`. 246 of the 259 hand cases match; the 13 others are the control-character and `\u{}` rows above.
- **Lexer.** Numbers (`-0`, `-00`, `1.0.2`, `123a`, `1...`), all escapes including surrogate pairs and lone surrogates, block-string dedent with tabs/CR/CRLF/`\"""`, strict RFC 3629 UTF-8: identical to graphql-js on 99.5–98.6% of random lexer inputs, and every difference is a control character.
- **C0 controls.** Pion is the only one of the three that follows the October 2021 SourceCharacter (it rejects BEL/VT/FF/NUL in comments and strings).
- **Surrogate pairs and `\u{…}`.** Pion and graphql-js decode them; apollo-parser 0.8.4 rejects both.
- **Minifier.** Never changes meaning (3,573/3,573 judged by graphql-js) and never glues tokens. It is byte-identical to `stripIgnoredCharacters` whenever no block string is present.
- **Diamond / exponential fragments.** Detected in O(V+E) with saturating counters. graphql-js has no depth/alias/field limits.
- **Recursion during parse.** Default limits stop 50k nesting in 4 ms with an error. graphql-js overflows its stack on 25k nesting and on a 30k fragment chain (inside NoFragmentCycles), and apollo stops at depth 500.
- **Throughput.** Pion native is the fastest of the three on every corpus for parse, print and minify (C2 parse only ties apollo). The printer is 4.5–15× faster than graphql-js, and Pion's RSS is 3–15× below graphql-js everywhere.
- **Native/Wasm32 parity.** Byte-identical on every corpus (except the P1-4 depth threshold).
