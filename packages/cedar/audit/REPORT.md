# Red-team audit: `packages/cedar` v0.1.0 vs Rust `cedar-policy =4.15.0`

Target: `origin/feat/pkg-cedar` @ `aab79f9` (`packages/cedar/src/**`, 4,624 lines, read in full;
`bench/**`, `wasm_smoke/**`, the five `*_test.pion` files).
Reference: official Rust `cedar-policy = "=4.15.0"` (default features `ipaddr` + `decimal` +
`datetime`; `audit/rust/Cargo.lock` committed, every build `--locked`), the Cedar v4 language
reference where useful. Toolchain: `pionc 0.1.0` built from `AFK-surf/pion@66d2b4b`,
`cargo 1.100.0`, Darwin arm64 (Apple M5 Max, shared machine).

Everything is reproducible with one command; build products go to `/private/tmp/rt-cedar-audit`
(own `PION_CACHE_DIR`s and `CARGO_TARGET_DIR`), the worktree stays clean:

```sh
sh packages/cedar/audit/run_audit.sh            # full gate, ~1 min today (exit 1: defects reproduced)
sh packages/cedar/audit/run_audit.sh --quick    # smaller fuzz / DoS subset
sh packages/cedar/audit/run_audit.sh --bench    # + benchmark-fairness tables (~1 min, not gated)
pionc test --json -p cedar_audit packages/cedar/audit   # only the red/control unit tests
```

| Path | Purpose |
| --- | --- |
| `redteam_test.pion` | 24 `p0_*`/`p1_*`/`p2_*` tests asserting the reference behaviour — **24 FAIL today** |
| `control_test.pion` | 8 `control_*` tests pinning what Pion already gets right — **8/8 PASS** |
| `src/lib.pion` | shared helpers: `decide(..)` prints the same transcript line as the oracle |
| `diff/` | `pion_driver` (Pion) + `rust/src/bin/oracle.rs` (cedar-policy) on one case format; `gen_cases.py` (540 curated cases), `gen_fuzz.py` (seeded grammar fuzzer), `compare.py`, `xfmt*.py` (formatter output re-read by cedar-policy), `test_expect.py` (re-derives every unit-test expectation from cedar-policy) |
| `dos/` | `pion_dos` + `rust/src/bin/dos.rs` twins, `run_dos.py` (time + 4-mode crash gates) |
| `bench_fair/` | `run_bench_fair.sh`, Pion twin for W4–W6; Rust side is `rust/src/bin/bench_fair.rs` |
| `rust/` | one Cargo project (`cedar-policy =4.15.0`, `Cargo.lock`) with the three Rust binaries |

`run_audit.sh` exits **0 only if every gate passes**: red + control tests, test expectations agree
with cedar-policy, differential corpus + fuzz + formatter cross-validity, 4-mode byte identity,
DoS/crash probes, and an untouched worktree. It exits 1 today. Nothing under `audit/` needs to
change for a fixed tree to reach 0: tests never touch private representation (e.g. `IpAddrVal`
fields), they go through `parse_policy_set` / `entities_from_json` / `request_from_json` /
`Authorizer`, and wherever a fail-closed fix is as good as matching the reference (rejecting an
over-deep policy at parse time under the documented `max_depth`, refusing a whole request when a
budget runs out, rejecting >2^53 JSON integers) the test and the gate accept it.

## Summary

| Severity | Count | Findings |
| --- | ---: | --- |
| **P0** | 2 | **P0-1** any `forbid` whose condition is a flat chain of ≥129 terms (`a \|\| b \|\| …`, `&&`, `+`, …) fails the evaluator's depth check and is silently dropped → **Allow** where cedar-policy says Deny (a 129-user deny-list is enough); **P0-2** unknown / misspelled / unsupported calls (`isInRnage(..)`, `isBlocked(..)`, the default-on `datetime`/`duration`) parse fine, error at evaluation, and a `forbid` using them is dropped → **Allow** (cedar-policy rejects the policy set or evaluates the call) |
| **P1** | 7 | P1-1 one request-wide `max_steps` counter: earlier policies exhaust it and later `forbid`s are dropped → Allow; P1-2 JSON entity type names never validated + ambiguous `type\0id` lookup key → identity confusion (`User\0a`/`"b"` inherits `User::"a\0b"`'s groups and attrs); P1-3 JSON loader accepts what cedar-policy rejects (duplicate keys, `1.0`/`1e0`/`-0`, missing `attrs`/`parents`, cyclic hierarchies, nested `__entity`) and silently rounds integers >2^53; P1-4 `ip` masks host bits, flipping `==`/`!=`/`contains`; P1-5 formatter output can't be re-parsed by Pion itself (nested `if`); P1-6 wasm32 `RangeError`: `format_policy_set` on a ~1,850-term chain under **default** limits, and the parser below the documented `max_safe_depth()`; P1-7 O(n²)/O(n³) blow-ups: set dedupe / `==` / `containsAll` (50k elements: 3 s vs 0.02 s), insertion-sorted ancestor lists (reverse chain 4k: 5.4 s vs 0.28 s forward) |
| **P2** | 9 | `has a.b.c` paths rejected; >4 chained unary ops accepted; reserved words accepted as attrs/record keys but rejected as annotation keys, and the formatter emits them bare; action scope not restricted to `Action` types; `\u{2a}`/`\x2a` in `like` treated as literal; `@id` used as policy id (duplicates rejected); IPv4-embedded IPv6 accepted; lax `__extn`/duplicate-entity handling (Pion stricter, tolerated); README "zero allocation" claim |
| Red tests | 24 | 24 FAIL / 0 pass (each passes once its defect is fixed) |
| Control tests | 8 | 8 / 8 PASS |
| Self-consistency | 91 | every red/control expectation re-derived from cedar-policy: 91 / 91 consistent |
| Differential | 15,540 cases | curated 540: 435 agree, **95 mismatch** (all assigned to findings below), 10 tolerated fail-closed gaps; fuzz 3 × 5,000 (seeds 1–3): **15,000 / 15,000 agree** (plus 60,000 more from seeds 2–4 × 20,000 during the audit: 0 mismatches) |
| Formatter cross-check | 12,436 | Pion's `format_policy_set` output re-read by cedar-policy: curated 431/436 same meaning (5 = P2-3), fuzz 12,000 / 12,000 |
| 4 build modes | 15,540 transcripts | native debug = native `--release` = wasm32 debug = wasm32 `--release`: **byte-identical** (SHA-256 per corpus). DoS probes: 3 wasm32 `RangeError`s (P1-6), 1 native SIGSEGV with raised limits (informational) |
| Benchmarks | W1–W6 | published W2/W3 asymmetry is real but small (W3 2.05× claimed → 1.63–1.82× fair); new blind spot W5 large sets: Pion **0.02–0.03×** (≈36–40× slower); W4 JSON load 1.9–3.5× and W6 `like` 1.8–1.9× faster |

The core evaluator is in good shape: on 15,000 random well- and ill-typed policies exercising
arithmetic, comparison, short-circuiting, `in`/`is`/`has`/`like`, sets, records, tags, decimal and
ip, Pion and cedar-policy agree on every decision, determining-policy set and erroring-policy
set. The defects cluster at the **edges the fuzzer does not reach**: resource limits that turn
into dropped `forbid`s (P0-1, P1-1), a parser that accepts calls the reference rejects (P0-2,
P2-*), and the JSON / extension loaders (P1-2..4).

---

## P0 — security (Allow where cedar-policy denies)

### P0-1 Flat chains of ≥129 terms exceed `max_depth` at evaluation → `forbid` silently dropped

```cedar
permit(principal, action, resource);
forbid(principal, action, resource) when {
  principal == User::"u0" || principal == User::"u1" || … || principal == User::"alice"   // 129+ terms
};
```

cedar-policy: `Deny` (forbid #1 determining). Pion: `Allow r=0 e=1` — the forbid is in
`diagnostics.errors` with `LimitExceeded "evaluation depth exceeds max_depth"`. Reproduced for
`||` (129, 130, 200, 1000 terms), `unless { p != a && … }` exemption lists, `1 + 1 + … == 129`,
`principal in G0 || … `, `context.s like "x0*" || …` (`p0.depth_*` cases). The cliff is exactly
128 binary nodes, i.e. a 129-entry deny list — an ordinary policy, ~4 KB of text, well inside the
default `max_tokens`. The same shape on a `permit` fails closed (`p0_1_permit_allowlist…`: Deny
where cedar-policy allows).

Root cause: the parser counts nesting, not AST height — `parse_or`/`parse_and`/`parse_add`/
`parse_mult` build left-deep trees in a loop at constant `depth` (`src/parser.pion:490-497`,
`506-513`, `649-661`, `670-677`), so a 1,000-term chain parses at depth 1. `eval_expr` then
recurses into the left operand first with `depth + 1` (`src/eval.pion:329`, `349`, `369`, `411`, …)
and fails the check at `src/eval.pion:285-287` before the first term is even evaluated (so
short-circuiting does not save it). `is_authorized_impl` records the error and moves on
(`src/eval.pion:918`), which is correct Cedar semantics for a *genuine* evaluation error, but here
the "error" is Pion's own budget.

Fix direction: either evaluate associative chains iteratively (flatten `||`/`&&`/`+` runs), or
make the parser charge depth for chain length so the policy is rejected at parse time (fail-closed;
the gate accepts `PERR`). Tests: `p0_1_*` (5).

### P0-2 Unknown / unsupported functions and methods are accepted by the parser → `forbid` dropped

```cedar
permit(principal, action, resource);
forbid(principal, action, resource) when { context.ip.isInRnage(ip("192.168.0.0/16")) };  // typo
forbid(principal, action, resource) when { datetime("2026-01-01") < datetime("2027-01-01") };
```

cedar-policy: the typo / unknown function (`isBlocked(principal)`, `[1].foo()`, `"a".length()`,
`A::ip(..)`, …) is a **parse error** of the whole policy set (`UnknownMethod`/`UnknownFunction`,
`cst_to_ast.rs`); `datetime`/`duration` are enabled by default in 4.15 and the forbid applies →
`Deny`. Pion: `Allow r=0 e=1` in every case — the parser accepts any method name and any path as
an extension call (`src/parser.pion:754-759`, `920-925`), evaluation fails with
`ExtensionError "unknown method"/"unknown extension function"` (`src/eval.pion:651`, `813`), the
forbid lands in `errors` and is ignored. A policy author who misspells one method name in a
deny rule, or writes a time-boxed forbid with `datetime`, gets fail-open behaviour with no
diagnostic at load time. Arity is also only checked at evaluation (cedar-policy agrees there, so
those cases are not counted). Tests: `p0_2_*` (4); cases `p1.unknown_fn.*`, `gap.datetime.*`,
`gap.duration.*`.

Fix: validate method / function names (and namespaces) against the known extension table at
parse time; until `datetime`/`duration` exist, reject them at parse time (the gate tolerates a
fail-closed `PERR` for the documented gap, not an `Allow`).

## P1

### P1-1 `max_steps` is one counter per request, so earlier policies can exhaust it for later `forbid`s

`EvalCtx` is created once per request (`src/eval.pion:899`) and `tick()` (`275-282`) counts
across all policies. With default limits (1,000,000 steps) a set of 7,000 non-matching permits of
~160 nodes each followed by a satisfied `forbid` gives **`Allow` with 904 errors** (the last 904
policies, forbid included, all fail with `LimitExceeded`); cedar-policy: `Deny`. The outcome
depends on policy order. Reaching it needs >131,072 tokens in total, i.e. several `PolicySet`s
merged or `parse_policy_set_with_limits` — realistic for large multi-tenant deployments.
Fix: per-policy budget, or make exhaustion a request-level `Err` (fail closed; both accepted).
Test `p1_1_step_budget_must_not_drop_later_forbid`; probe `budget 7000`.

### P1-2 Entity type names are never validated; the `type + "\0" + id` key is ambiguous

`json_parse_uid` (`src/entities.pion:225-246`) accepts any string as an entity type
(`"user name"`, `"NS::"`, `"1User"`, `"if"`, `"User::\"x\""`, `"User\u0000x"`, …); cedar-policy
rejects all of them (`p1.json_type.*`, `p1.req_type.*`: EERR / RERR, Pion Allow). Combined with
`entity_uid_key` = `type + "\u{0}" + id` (`src/hash_map.pion:28-30`) two different UIDs share a key:

```text
entities: User::"a\u0000b"  attrs {admin: true}  parents [Group::"admins"]
request : principal = {"type": "User\u0000a", "id": "b"}
permit(principal in Group::"admins", action, resource);         -> Pion Allow, cedar-policy RERR
permit(principal, action, resource) when { principal.admin };    -> Pion Allow, cedar-policy RERR
```

`entities_is_in_impl` / `entities_get_impl` look the principal up by key (`src/entities.pion:185-207`)
and return the other entity's ancestors and attributes. Fix: validate type names with the policy
grammar's `Path` rules (and/or use an unambiguous key, e.g. length-prefixed). Tests `p1_2_*`.

### P1-3 JSON entity / request loader accepts what cedar-policy rejects

All of these load in Pion and are rejected by `Entities::from_json_str` (EERR):
duplicate object keys anywhere (strict mode still uses `DuplicateKeyPolicy::LastWins`,
`json5/src/types.pion:82`, and `json_obj_find` scans from the end, `src/entities.pion:213-223`);
floats with integral value `1.0`, `1e0`, `1e2` and `-0` (`src/entities.pion:261-270` converts
any integral double); entities without `attrs` or without `parents` (defaulted at `393-416`);
**cyclic hierarchies** including self-parenthood (`TransitiveClosureError::HasCycle` in
cedar-policy; Pion's closure is cycle-*safe* by design, `134-180`, so a policy over a cyclic
store returns Allow where the reference refuses the data); and `{"__entity": {"__entity": {..}}}`
is unwrapped recursively into an entity (`229-230`) where cedar-policy reads a record. The
documented ">2^53 integer" gap is not fail-closed either: the guard `d > 9007199254740992.0`
(`262`) lets `9007199254740993` through after IEEE rounding, so `principal.a == 9007199254740993`
is **false** in Pion and true in cedar-policy. Tests `p1_3_*`; cases `p1.json_*`, `p1.cycle.*`,
`gap.json_bigint.00/.02`.

### P1-4 `ip(..)` masks host bits at parse time

cedar-policy keeps the address as written (`IPAddr { addr, prefix }`, derived `Eq`), Pion stores
`addr & mask(prefix)` (`src/ext_ip.pion:254-293`) and compares the masked value (`442-444`):

| expression | cedar-policy | Pion |
| --- | --- | --- |
| `ip("10.0.0.1/24") == ip("10.0.0.0/24")` | false | **true** |
| `ip("192.168.1.77/16") != ip("192.168.0.0/16")` | true | **false** |
| `[ip("10.0.0.1/24")].contains(ip("10.0.0.0/24"))` | false | **true** |
| `ip("::1/64") == ip("::/64")` | false | **true** |

`isInRange`, `isLoopback`, `isMulticast` agree (cedar-policy masks there too). Any `==`/`!=`/set
membership on CIDR values flips. Test `p1_4_ip_equality_keeps_host_bits`; cases `p1.ip_hostbits.*`.

### P1-5 `format_policy_set` output is not always re-parsable (by Pion itself)

The formatter wraps every `if` in parentheses and re-emits the else-branch nesting
(`src/format.pion:81-88`), so a policy with 70 nested `if … else if …` (parse depth 70) formats to
text that needs depth ~140 and fails `parse_policy_set` with `LimitExceeded` (`p1.fmt_depth.if_070.fmt`,
`if_100.fmt`: `FERR`). The README promises idempotent parse → format → parse. Flat chains do not
hit this (each `Binary` adds one paren level but the 128 eval limit is reached first); for very
long chains the formatter emits O(n) nested parentheses — a 1,000-term `||` chain becomes 999
nested `(`, which overflowed cedar-policy's own LALRPOP parser on an 8 MiB stack (the oracle runs on
a 1 GiB thread for that reason). Test `p1_5_format_output_must_reparse`.

### P1-6 wasm32 stack overflow (`RangeError`) under default limits and below `max_safe_depth()`

| probe | native dbg/rel | wasm32 dbg / rel | cedar-policy |
| --- | --- | --- | --- |
| `fmt_chain_default 3000` — parse (default limits) + `format_policy_set` of a 3,000-term `\|\|` chain (~30 KB) | ok | **RangeError** (threshold 1,700–1,850 terms) | ok |
| `deep_parse 0` — `max_depth = max_safe_depth()` (256), 250 nested parens | ok | **RangeError** (threshold 150–165) | ok |
| `deep_eval 0` — same, then authorize | ok | **RangeError** | ok |
| `deep_eval 120` (default-limit depth) | ok | ok | ok |
| `fmt_chain 200000` (raised `max_tokens`) | **SIGSEGV** (≥200k terms) | — | ok (1 GiB thread) — informational, not gated |

`write_expr` (`src/format.pion:35-199`) recurses once per AST level with no bound; any service
that formats an accepted policy (≤ default `max_tokens`) can be crashed on wasm32. The parser's
~9 frames per nesting level (`parse_primary` → `parse_expr` → `parse_or` → … → `parse_member`,
`src/parser.pion:452-806`) overflow the wasm32 stack at ~160 levels, so `max_safe_depth()` = 256
(`src/types.pion:125-127`, documented as "safe across Native and Wasm32") is not safe; the
default 128 is. Fix: iterative formatter (or depth-bounded with explicit error), and lower
`max_safe_depth()` to what wasm32 actually sustains (the probe follows `max_safe_depth()`, so
lowering it is a valid fix). Gate: `run_dos.py` 4-mode rows.

### P1-7 Super-linear hot spots (attacker-sized request JSON)

| probe (Pion native `--release` vs cedar-policy `--release`) | Pion | cedar-policy | root cause |
| --- | ---: | ---: | --- |
| `ctx_set 50000` — `request_from_json` with a 50k-element context set (≈290 KB) | 2.97 s | 0.03 s | `set_insert_unique` linear scan per element, `src/entities.pion:279` → `src/eval.pion:6-15` |
| `ent_set 50000` — same set as an entity attribute | 3.04 s | 0.03 s | same |
| `set_lit 50000` — 50k-element set literal in a policy, evaluated per request | 3.13 s | 0.08 s | `src/eval.pion:588-600` |
| `contains_all 50000` / `set_eq 50000` | 3.17 / 3.32 s | 0.02 s | `set_contains` linear inside a loop: O(n·m), `src/eval.pion:17-26`, `48-60`, `689-722` |
| `chain_rev 4000` — parent chain whose ancestor lists come out in descending order | 5.42 s | 2.35 s | insertion sort per ancestor list, `src/entities.pion:23-36`, `177` → O(n³) total |
| `chain_fwd 4000` — same chain, ascending order | 0.28 s | 2.37 s | (best case of the same sort) |

A 1.3 MB request (200k elements, under json5's `max_nodes`) costs ~50 s of CPU per request.
Memory, by contrast, is excellent (chain 4k: 91 MB Pion vs 1.8 GB cedar-policy). Fix: sort/hash
based set construction and comparison; sort ancestor lists with an O(n log n) sort (or keep
the BFS stamp bitmap). Gates: `time` ≤ 20× reference + 0.5 s, `selfrel` reverse ≤ 10× forward + 0.5 s.

## P2 — parity / robustness

| id | finding (cedar-policy vs Pion) | where | test / cases |
| --- | --- | --- | --- |
| P2-1 | Cedar 4 `e has a.b.c` attribute paths are rejected (`PERR`) | `src/parser.pion:584-599` | `p2_1_*`, `p2.has_path.*` |
| P2-2 | more than 4 chained `!`/`-` must be a parse error (`UnaryOpLimit`); Pion accepts any count | `src/parser.pion:681-715` | `p2_2_*`, `p2.unary_limit.*` |
| P2-3 | reserved words (`if`, `in`, `then`, `true`, `__cedar`, …) accepted as `.attr`, `has attr`, record keys; but rejected as annotation keys (`@if("x")`, `@in` are legal); `is_simple_ident` (`src/format.pion:17-33`) prints `{"if": 1}["if"]` as `{if: 1}.if`, which cedar-policy cannot read | `src/parser.pion:203`, `587`, `750`, `842` | `p2_3_*` (2), `p2.ident.*`, `p2.scope.00-02`, `p2.fmt_ident.*` (xfmt) |
| P2-4 | action scope accepts non-`Action` entity types (`action == User::"view"`, `action in [Action::"read", User::"x"]`) | `src/parser.pion:358-402` | `p2_4_*`, `p2.scope.09-11` |
| P2-5 | in `like`, only `\*` is a literal star; `\u{2a}` / `\x2a` decode to `*` and are wildcards in cedar-policy, literals in Pion | `src/lexer.pion:226-267` | `p2_5_*`, `p2.like_escape.*` |
| P2-6 | `@id("..")` is used as the policy id: two policies with the same `@id`, or `@id("policy1")` before an auto-numbered policy, make the set unparsable (cedar-policy: annotations are just annotations, ids are `policy0..`) | `src/parser.pion:225-228`, `306`, `975-977` | `p2_6_*`, `p2.policy_id.*` |
| P2-7 | IPv4-embedded IPv6 (`::ffff:192.0.2.1`, `::1.2.3.4`, `64:ff9b::192.0.2.33`) is accepted; cedar-policy rejects it on purpose (`str_contains_colons_and_dots`) and caps input length at 43 | `src/ext_ip.pion:116-146` | `p2_7_*`, `p2.ip_embedded.*` |
| P2-8 | Pion is *stricter* than the reference (tolerated, fail-closed): duplicate entity entries, `{"__extn": {"fn": "ip"}}` without `arg` (a record in cedar-policy) | `src/entities.pion:76-85`, `315-341` | `tol.*` |
| P2-9 | README: "`Entities::is_in` … with zero allocations" — every lookup concatenates `type + "\0" + id` (`src/hash_map.pion:28-30`, `src/entities.pion:198-202`) | — | — |

Documented gaps, verified to fail **closed** (tolerated by the gate): templates (`?principal`,
`?resource` → `PERR`), JSON `datetime` extension values (`EERR`), JSON integers ≥ 2^63−1 (`EERR`),
parse depth > `max_depth` (`lim.*`: 130 nested parens / sets → `PERR`, cedar-policy accepts).
Not fail-closed, therefore counted above: `datetime`/`duration` in policies (P0-2) and
2^53 < |n| < 2^63 in JSON (P1-3).

## What is robust (measured, not assumed)

- **Authorization semantics**: default deny, forbid-overrides-permit, per-policy error isolation
  in both directions, positional determining/erroring policy sets — 15,000 / 15,000 fuzz cases and
  every `ctl.auth.*` / `ctl.sc.*` case agree with cedar-policy.
- **Short-circuiting**: `false && <error>`, `true || <error>`, `true || 1`, dead `if` branches,
  `has`-guarded access, `is T in <non-entity>` — all identical.
- **Integers**: exact `i64::MIN` literal (`-9223372036854775808`), `-(i64::MIN)`, `MIN * -1`,
  `MAX + 1`, `--1`, leading zeros, oversize literals — identical, no silent wraparound.
- **Strings / patterns**: `\n \r \t \\ \" \' \0 \xNN (≤7F) \u{..}` and every rejection
  (surrogates, >10FFFF, `\x80`, `\q`, `A`, empty/oversized `\u{}`), raw control bytes — identical.
  The `like` matcher is genuinely linear: 200,000 × `*a`·200 in 5 ms (cedar-policy 8 ms).
- **Entities**: reflexive `in` on unknown entities, multi-hop closure, namespaced types
  (`NS1::User::"a"` ≠ `NS2::User::"a"`), `has`/`getTag`/`hasTag` on unregistered entities,
  star DAG of 100k (0.03 s vs 0.38 s), and ~20× less memory than cedar-policy on deep chains (91 MB vs 1.8 GB at 4k).
- **decimal**: all 34 grammar / range / comparison probes identical (including `-0.0`, both
  range ends, `+1.0`, `1.`, `.5`, 5 fraction digits, Unicode digits).
- **ip grammar** (outside P1-4 / P2-7): leading zeros, prefix range and leading-zero prefix,
  `::` placement, hextet length, cross-family `isInRange`, loopback / multicast prefix rules — identical.
- **Formatter**: 12,431 formatted policy sets re-read by cedar-policy with identical meaning.
- **Portability**: 15,540 differential transcripts byte-identical across native debug/release and
  wasm32 debug/release; the 8 control tests and the package's own 18 tests pass.

## Benchmark review (`packages/cedar/bench/`)

Re-run with `run_audit.sh --bench` (`scripts/bench_compare.py`, warmup 1, 5 interleaved rounds,
SHA-256 enforced on every implementation; same machine). Two runs on a shared machine (load
varied between them); median ms of run 1, ratio range over both runs:

| workload | Pion | Rust (published driver) | Rust (fair driver) | Pion vs fair Rust |
| --- | ---: | ---: | ---: | ---: |
| W2 3,000 requests | 26.4 | 137.5 | 135.4 | **4.89–5.12×** faster |
| W3 2,000 requests | 9.8 | 20.1 | 17.9 | **1.63–1.82×** faster (published claims 2.05×) |
| W4 JSON entity load, 2,000-entity DAG × 20 (new) | 210.9 | — | 744.7 | **1.85–3.53×** faster (Pion side noisy) |
| W5 large-set predicates, 1,000-element sets × 2,000 req (new) | 1,060.0 | — | 26.3 | **0.02–0.03× (≈36–40× slower)** |
| W6 `like`-heavy, 12 policies × 5,000 req (new) | 27.5 | — | 50.6 | **1.84–1.88×** faster |

Fairness findings:
1. **Request construction is asymmetric** (W2/W3). The Rust driver's `uid()` runs
   `EntityTypeName::from_str` (the full Cedar parser) twice per request and `Context::from_pairs`
   re-evaluates every `RestrictedExpression` (re-parsing the `ip`/`decimal` strings) per request,
   while the Pion driver parses its 7 ips / 7 decimals once and builds UIDs as struct literals.
   `rust/src/bin/bench_fair.rs` hoists exactly that work (same SHA-256
   `ca8bacaa…` / `7db3c999…`). The effect is small for W2 (~1.5 %) and ~11 % for W3, so the published
   W3 ratio overstates Pion by ~0.2–0.4×; W2's ~5× is real.
2. **W1 compares different work**: Rust `Policy::to_string()` returns the retained source text
   (no formatting), Pion runs its formatter; the SHA only covers counts. Rust also builds a CST,
   source spans and miette diagnostics. If anything W1 is conservative for Pion — but its stdout
   does not verify formatter output.
3. **Blind spots**: none of W1–W3 uses sets larger than 2 elements, so the O(n·m) set algebra
   (P1-7) never shows; W5 shows it at realistic sizes (1,000 granted scopes). JSON entity loading
   (W4) was not benchmarked although it is a headline feature — Pion is faster there.
4. The Rust bench manifest says `cedar-policy = "4.4"` but its lockfile pins 4.15.0 and the script
   builds without `--locked`; pin `=4.15.0` and build `--locked` so the table cannot drift.

## Reproduction map

| finding | unit test(s) | differential case prefix | DoS / 4-mode probe |
| --- | --- | --- | --- |
| P0-1 | `p0_1_*` | `p0.depth_*`, `p1.depth_permit_allowlist` | — |
| P0-2 | `p0_2_*` | `p1.unknown_fn.*`, `gap.datetime.*`, `gap.duration.*` | — |
| P1-1 | `p1_1_*` | — | `budget 7000` |
| P1-2 | `p1_2_*` | `p1.json_type.*`, `p1.req_type.*`, `p1.uid_collision.*` | — |
| P1-3 | `p1_3_*` | `p1.json_attr.*`, `p1.json_ent.*`, `p1.cycle.*`, `gap.json_bigint.00/02` | — |
| P1-4 | `p1_4_*` | `p1.ip_hostbits.*` | — |
| P1-5 | `p1_5_*` | `p1.fmt_depth.if_*.fmt` | — |
| P1-6 | — | — | `fmt_chain_default 3000`, `deep_parse 0`, `deep_eval 0` |
| P1-7 | — | — | `ctx_set`, `ent_set`, `set_lit`, `contains_all`, `set_eq`, `chain_rev` |
| P2-1..7 | `p2_*` | `p2.*` (+ xfmt `p2.fmt_ident.*`, `p2.ident.03`) | — |
