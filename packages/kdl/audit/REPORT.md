# Red-team audit: `packages/kdl` v0.1.0 (`feat/pkg-kdl` @ `0616f30`)

Auditor: `RT-kdl` (independent adversarial review). Toolchain: `pionc 0.1.0` (`AFK-surf/pion@66d2b4b`),
node v24.22.2 (wasm32 runner), Rust 1.100.0. Machine: Darwin arm64.

References (all pinned):

| Reference | Pin | Role |
| --- | --- | --- |
| KDL 2.0.0 spec + official test suite | `kdl-org/kdl` commit `6ceecd8` (tag `2.0.0`), `tests/test_cases` tree `c243145` | authority (319 cases) |
| Rust `kdl` | `=6.7.1` (+ `kdl` 4.7.1 for `parse_v1`), `oracle/rust/Cargo.lock`, `--locked` | differential oracle |
| Python `float()` | correctly rounded strtod | float oracle |

Reproduce everything with `sh packages/kdl/audit/run_audit.sh` (≈ 90 s; exit 0 = all PASS, 1 = defects
remain, 2 = harness error). It fetches the CC-BY-SA official suite into `/private/tmp` (not vendored),
builds the Rust oracle and the probe in 4 modes (`native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel`),
and writes nothing inside the repository. A future fix branch should reach exit 0 without touching
`audit/`.

Result at `0616f30`: **805 PASS / 35 FAIL** — 1 P0, 4 P1, 10 P2 findings (below).

## Verdict

The parser core is strong: 313/319 official cases, stricter than Rust `kdl` on two official invalid
cases, bit-exact float parsing, a formatter that round-trips everything thrown at it (also through
Rust), no stack overflow anywhere up to 200,000 levels, and byte-identical output in all 4 modes.
It is **not ready to tag**: the query engine returns wrong (duplicated) results and can be driven
out of memory by a 300-byte document within the default limits (P0). Multi-line strings handle
whitespace escapes in the wrong order (P1). Wide nodes take quadratic time (P1). Numeric query
filters never match (P1). The README's "Complete KDL v2.0.0 Compliance" claim does not hold, and
the official suite was never ported (P1).

## P0

### P0-1 Query engine duplicates results; on nested data the duplication grows combinatorially until the process runs out of memory

`src/query.pion` `eval_query_chain` (lines 560-604) expands each step from **every** node in
`current`. `current` can hold an ancestor together with its descendants, and duplicates of either,
and nothing de-duplicates it. Both `collect_descendants(current, false)` and the `Child` branch
therefore yield the same node once per matching ancestor path. The duplicates then feed the next step.

| Selector / doc | Expected | Got |
| --- | --- | --- |
| `>> a >> b` on `a { a { a { b } } }` | `b` ×1 | `b` ×3 (`q_descendant_dedup`) |
| `>> a a` on the same doc | 2 nodes | 3 (`q_desc_ws_dedup`) |
| `a a a a a a a a` on a 24-deep `a{…}` chain (default limits) | 17 | **245,157** |
| same, 40-deep | 33 | **15,380,937** (1.1 s) |
| same, 48-deep (240 bytes of input) | 41 | native: 62.9 M nodes, 4.0 GB RSS; **wasm32: `RangeError: WebAssembly.Memory.grow()` → instance dies** |
| same, 56-deep | 49 | native 202.9 M nodes, **13.0 GB RSS** |

The default `max_depth=128` permits all of these. The wrong results alone, on ordinary
`>> x >> y` selectors over same-named nesting, would block a release.
**Fix**: de-duplicate by node identity after every step, or evaluate CSS-style: for each node in one
pre-order walk, test the selector right-to-left against its ancestor stack. That costs O(nodes × steps),
and the result comes out in document order. Unions (`a, a`) also need de-duplication (see P2-6).

## P1

### P1-1 Multi-line strings: dedent runs *before* whitespace escapes are resolved (spec requires after)

SPEC §Multi-line Strings / *Interaction with Whitespace Escapes*: "implementations MUST dedent the
string *after* resolving all whitespace escapes, but *before* resolving other backslash escapes".
`parse_multiline_string` (`src/parser.pion` ~535-638) first detects the closing line and dedents
the raw physical lines (`dedent_lines`). Only then does it unescape the dedented text.

- 3 official valid cases are rejected: `multiline_string_escape_in_closing_line(_shallow)`,
  `multiline_string_escape_newline_at_end`. The spec's own allowed example is rejected too
  (`case_ml_ws_escape_joins_less_indented`), and so is `case_ml_ws_escape_shallow_line`.
- **Silent wrong value**: `node """⏎    a⏎   \⏎␍⏎"""` is accepted as `"    a\n   "`. Per spec, and per
  Rust, it is `" a"` (`case_ml_ws_escape_eats_final_newlines`; found by the mutation fuzzer).

**Fix**: per physical line, resolve `\`+whitespace/newline runs first, joining lines. Then find the
closing line and dedent. Then resolve the remaining escapes. An escape that pulls the closing `"""`
onto a line with non-whitespace content stays an error.

### P1-2 O(n²) property insertion: wide nodes are a CPU DoS that `KdlLimits` does not bound

`add_prop_last_wins` (`src/parser.pion:1203`) linearly scans all earlier entries for every property.

| 100,000 distinct props on one node (1.2 MB) | native_dbg | native_rel | wasm_dbg | wasm_rel | Rust kdl 6.7.1 |
| --- | ---: | ---: | ---: | ---: | ---: |
| parse time | 12.9 s | 10.9 s | 21.2 s | 21.2 s | **0.30 s** |

The default `max_tokens=5,000,000` admits about 2.5 M properties, i.e. roughly 6,000× this cost.
**Fix**: keep a key→index hash map per node while parsing (or dedupe once at node end with a map),
preserving last-wins semantics.

### P1-3 Query filters with float / radix / exponent literals never match

`QParser::parse_value` (`src/query.pion`) only tries a decimal `Int64`. Every other number
(`1.5`, `0x10`, `1e3`) becomes `KdlValue::Str`, so `n[x=1.5]` never matches `n x=1.5`
(`q_float_filter`, `q_hex_filter`, `q_exp_filter`). **Fix**: reuse the KDL number scanner
(`parse_number_token`) for filter values.

### P1-4 The official compliance suite was never ported; README over-claims compliance

`compliance_v2_*_test.pion` has 27 hand-written themed tests, not the 319 official
`tests/test_cases` (AGENTS.md §1.1: port the upstream suite first). The official suite immediately
shows 6 failures (P1-1, P2-1, P2-2) that the package's own tests miss. The README says "Complete
KDL v2.0.0 Compliance". **Fix**: port `tests/test_cases` (input + expected_kdl) as data-driven tests.
`run_audit.sh` [A] already shows how.

## P2

- **P2-1 Integers outside Int64 are rejected.** The parser raises an explicit `NumberOverflow` and
  never wraps or loses precision silently (✓). Rejected inputs include 2 official valid cases (`hex`,
  `hex_int`), `9223372036854775808`, `-9223372036854775809` and `0xffffffffffffffff` (common u64
  hashes). Rust keeps all of them as `i128`. The spec leaves representation to the implementation,
  but rejecting the document is a compatibility gap. Options: `i128`/bignum `KdlValue`, or a
  `KdlValue::BigInt(String)` fallback.
- **P2-2 VT (`U+000B`).** Pion treats VT as a newline, following the SPEC newline table. The official
  test `vertical_tab_whitespace` (and Rust) treat it as whitespace (`node⟨VT⟩arg` → one node with
  argument `arg`). This is a spec-vs-test conflict; I recommend following the official suite.
- **P2-3 `escline` is not accepted where the grammar uses `node-space`.** It fails inside `( … )`,
  around `=`, and between a type and its value (`case_esc_in_type`, `case_esc_around_eq`,
  `case_esc_after_type`; Rust accepts all three). `try_parse_type` and the property path call
  `skip_ws` instead of `skip_node_space` (`src/parser.pion` ~1172-1198, 1517, 1543-1559).
- **P2-4 Grammar leniency.** Stray `;` is accepted (`n;;`, `;n`, `;` alone on a line or after a
  newline-terminated child); `;` is only a node-terminator, and Rust rejects all four. `n{a}` is
  accepted without `node-space+` before the children block, and `format_compact` *emits* that
  form (`n 1{a}`), so its output only parses on lenient parsers. Note that the package's own test
  `v2_valid_semicolons_and_escline` asserts `a 1; b 2; ; c 3` is valid, and
  `v2_valid_nested_children_and_inline_blocks` uses `a{b{…}}`. Both tests need updating with the fix.
- **P2-5 v1 identifiers reject `#`.** KDL v1 allows `#` in identifiers (`a#b 1`; Rust `kdl` 4.7.1
  accepts). `is_kdl_ident_char` applies the v2 exclusion list in v1 mode.
- **P2-6 Query dialect gaps.** The union `a, a` returns `a` twice. `["0"=5]` cannot address a property
  literally named `0`, because quoted keys are still turned into argument indexes. INFO: KQL `||`,
  `top()`, `[]` and `[val()]` are unsupported. `a > b` only starts from top-level `a` (KQL matches at
  any depth). The README documents its own dialect, so these are listed, not failed.
- **P2-7 AST is lossy for `node {}`.** An explicitly empty children block is dropped, so `format`
  prints `node` (Rust keeps `children: Some(empty)`).
- **P2-8 Duplicate property position.** `n a=1 b=2 a=3` formats as `n a=3 b=2`: the last value lands
  in the *first* occurrence's slot. Lookup semantics are right; entry order differs from Rust and
  from the official `expected_kdl` convention.
- **P2-9 Negative `KdlLimits` silently mean "unlimited".** `KdlLimits::new(-1, -1, -1)` parses a
  300-deep document. Reject or clamp negatives; document `0`.
- **P2-10 Shared mutable global in a "World-free" pure library.** `ryu_digit_buf`
  (`src/float_fmt.pion:571`) is one module-level `FixedArray` reused by every `format` call. This is
  harmless single-threaded but is not `Send`-clean if formatting ever runs concurrently. Use a local
  buffer.

INFO: `format` of a D-deep tree is O(D²) bytes of indentation by design. 3,000-deep → 36 MB, fine.
20,000-deep (only reachable after raising `max_depth`) → 1.6 GB, which exhausts wasm32 memory.
`format_compact` is linear.

## What held up (PASS highlights)

- **Official suite**: 313/319. Pion correctly rejects `unicode_delete_fail` and
  `multiline_raw_string_single_line_err_fail`, which Rust `kdl` 6.7.1 wrongly accepts.
- **Identifiers/keywords/disallowed code points**: bare `true/false/null/inf/-inf/nan` are rejected;
  `.5`, `+.5` and `+1x` are rejected; bidi controls, a mid-document BOM, NUL, DEL, invalid UTF-8 and
  CESU surrogates are rejected, while their escaped forms are accepted.
- **Strings**: `\u{…}` range, surrogates, 7-digit escapes, `\/` (v2) and `\s`; whitespace escapes across
  NBSP, LS and CRLF; raw strings with inner quotes and hashes; CRLF/NEL/LS/PS/FF normalisation in
  multi-line strings; Unicode-space indentation; mismatch errors.
- **Numbers**: underscores, radix prefixes, exact Int64 MIN/MAX, `-0.0`, subnormals, halfway cases,
  `2.2250738585072011e-308`. In-run: 20,000 generated floats bit-exact vs correctly rounded strtod.
  Exploratory run: 37,865 bit-exact. Rust `kdl` itself rejects 533/40,000 long-mantissa floats.
- **Slashdash / escline / comments**: every combination in [B], including `/- {…} {…}` chains,
  dangling slashdash, `/-/-`, and nested `/* /* */ */`.
- **Formatter round-trip**: 301 in-run round-trip checks (official + adversarial + 14 hostile
  fixtures: keyword-like names, reserved characters, every control and bidi character, float edge
  values, `#nan`/`#inf`). Each one passes `format` and `format_compact` through Pion re-parse,
  equality and idempotence, **and Rust re-parses to the same AST**. Exploratory mutation fuzz: 8,908
  accepted documents, 0 mismatches.
- **Stack safety**: 20,000-deep parse/compact/equals/query/drop, 200,000-deep with `KdlLimits(0,0,0)`,
  20,000-deep slashdashed blocks, and 100,000 nested block comments, all without crashing in 4 modes.
  Native release run times (from the hand run; the audit applies 5–10 s budgets): 0.04–1.2 s.
- **4-mode identity**: dump (496 v2+v1 docs), query, API, DoS, float fuzz and every formatted file are
  byte-identical across `native_dbg`, `native_rel`, `wasm_dbg` and `wasm_rel`.

## Differential notes on the oracle (Rust `kdl` 6.7.1 deviations, so they are not counted against Pion)

Rust `kdl` 6.7.1 accepts a literal `U+007F` and `#"""one line"""#`. It accepts `/-/-a`, `/--inf`
and `#true/- a`. It rejects `1_1.0`, rejects `/- a;` inside a block, rejects floats with mantissas of
roughly 40 digits or more, and treats VT as whitespace. The cases where the spec decides are marked in
`cases.py`, and Pion is judged against the spec.

## Benchmark fairness (`packages/kdl/bench`, W1/W2/W3)

The reproduction on this machine matches the README: W1 **14.06×**, W2 **13.68×**, W3 **14.08×**, with
stdout SHA-256 identical across implementations and rounds.

1. **The speed-up is real against the reference crate, but it is architecture, not language.**
   Rust `kdl` 6.7.1 builds a lossless CST: it keeps comments, whitespace, raw literal text and
   `i128`, through `winnow` with error recovery. Turning off its default `span`/`serde` features
   changes nothing (W1 1.87 s vs 1.92 s), so the cost is the CST design itself. The README states
   this correctly. It is a fair "vs the reference implementation" number, not a parser-technology
   comparison.
2. **W2 workloads are not identical.** Rust runs `autoformat()` and `to_string()` over the CST, while
   Pion runs `format(AST)`. Both are "parse + format + re-parse", but Rust does more formatting work.
   Acceptable with a footnote.
3. **W3 is labelled "Query" but neither side calls a query engine.** Both use accessors only.
   `kdl::query`, which has the P0 above, is not benchmarked at all.
4. **The corpus avoids Pion's weak shape.** No node in W1–W3 has many properties. On a 100,000-property
   node Pion is about **36× slower** than Rust (10.9 s vs 0.30 s, P1-2). AGENTS.md §1.3 requires
   recording weak cases. Add a wide-node workload to the benchmark, or fix P1-2 first.

## Files

- `run_audit.sh`: one-shot reproduction (official suite fetch and verify, Rust oracle `--locked`,
  4-mode build, driver).
- `driver.py`: differential suites [A]–[H] and verdict lines. `cases.py`: adversarial v2/v1/formatter/query
  cases with spec-derived expectations.
- `src/main.pion` (`kdl_audit`): probe with `dump` (canonical AST plus format round-trip), `query`,
  `dos` and `api`.
- `oracle/rust`: Rust `kdl` 6.7.1 canonical-AST oracle (`dump`, `count`).
