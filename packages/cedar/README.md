# `cedar` — Pure-Pion AWS Cedar Policy Language & Authorization Engine

Pure-Pion implementation of the **AWS Cedar** authorization policy language and evaluation engine (targeting Cedar v4 / v3 semantics and parity with official Rust `cedar-policy` / `cedar-policy-core`).

- **Zero C/FFI Dependencies / `World`-Free Core**: 100% pure Pion (reusing `packages/json5` for strict RFC 8259 JSON Entity & Request deserialization), runs identically on Native and `wasm32` with no global mutable state.
- **Complete Cedar Lexer, Parser & Canonical Formatter (`src/lexer.pion`, `src/parser.pion`, `src/format.pion`)**:
  - Annotations (`@id("...")`, `@key("value")`, and Cedar v4 valueless `@key`) with duplicate-key rejection; `//` line comments (rejecting non-Cedar `/* ... */` block comments).
  - Full `permit` / `forbid` scope constraints: `principal` / `resource` (`any`, `==`, `in`, `is Type`, `is Type in Entity`), `action` (`any`, `==`, `in Entity`, `in [...]`), and multiple `when { ... }` / `unless { ... }` clauses.
  - Complete Cedar expression grammar & precedence: `if ... then ... else ...`, short-circuit `||` / `&&`, non-associative relational operators (`==`, `!=`, `<`, `<=`, `>`, `>=`, `in`, `has`, `like`, `is`, `is ... in`), `+` / `-` / `*`, unary `!` / `-` (with exact `-9223372036854775808` `i64::MIN` literal support), `.attr` / `["attr"]`, set `[...]` & record `{ k: v }` literals (duplicate key rejection), method calls, and extension calls.
  - Strict Cedar string & pattern escapes (`\n`, `\r`, `\t`, `\\`, `\'`, `\"`, `\0`, ASCII `\x00..\x7F`, `\u{...}` with UTF-16 surrogate and `> U+10FFFF` rejection, `\*` literal star allowed strictly in `like` patterns).
  - Canonical idempotent formatter (`format_policy`, `format_policy_set`, `format_expr`, `format_entity_uid`).
- **Entity Store & Cycle-Safe Transitive Closure (`src/entities.pion`, `src/hash_map.pion`)**:
  - Namespaced `EntityUid` (`Namespace::Type::"id"`), O(1) chained-hash UID index, and precomputed cycle-safe transitive ancestor closure (`Entities::is_in` runs in O(log A) with zero allocations, handles cyclic parent graphs without infinite loops, and preserves reflexivity even for unknown entities).
  - Cedar v4 entity `tags` (`Entity::with_tags`, `.hasTag`, `.getTag`).
  - Standard Cedar JSON Entities & Request deserialization (`entities_from_json`, `request_from_json`, `entities_from_json5`, `request_from_json5`) with `__entity` and `__extn` support and float/null rejection.
- **Authorizer & Extensions (`src/eval.pion`, `src/ext_decimal.pion`, `src/ext_ip.pion`)**:
  - **Default Deny + Forbid Overrides Permit** semantics with structured `Response` (`decision`, `diagnostics.reason`, `diagnostics.errors`).
  - Per-policy error isolation: runtime errors (`TypeError`, `IntegerOverflow`, `EntityDoesNotExist`, `AttrNotFound`, `TagNotFound`, `ExtensionError`) in one policy are recorded in `diagnostics.errors` without aborting evaluation of other policies; satisfied `forbid` policies still override all `permit` policies.
  - Strict checked 64-bit signed arithmetic (`+`, `-`, `*`, unary `-`) with zero silent wraparound.
  - O(N×M) non-backtracking UTF-8-aware `like` wildcard matcher (immune to exponential backtracking DoS).
  - Full `decimal("...")` (4-decimal fixed-point `Int64`, `lessThan`/`lessThanOrEqual`/`greaterThan`/`greaterThanOrEqual`/`==`) and `ip("...")` (IPv4/IPv6 + CIDR, `isIpv4`/`isIpv6`/`isLoopback`/`isMulticast`/`isInRange`/`==`) extensions.
- **Explicit Safety Budgets (`CedarLimits`)**:
  - Configurable `max_depth`, `max_tokens`, `max_policies`, `max_entities`, and `max_steps` validated via `validate_limits` to guard against stack overflow and resource exhaustion on both Native and Wasm32.

## Quick Start

```pion
import "cedar"

let policies = match cedar::parse_policy_set(
  "@id(\"allow-eng\") permit(principal in Group::\"eng\", action == Action::\"deploy\", resource is Service) when { context.client_ip.isInRange(ip(\"10.0.0.0/8\")) };",
) {
  Ok(ps) => ps
  Err(e) => panic(e.to_string())
}

let entities = match cedar::entities_from_json(
  "[{\"uid\":{\"type\":\"User\",\"id\":\"alice\"},\"attrs\":{},\"parents\":[{\"type\":\"Group\",\"id\":\"eng\"}]}]",
) {
  Ok(es) => es
  Err(e) => panic(e.to_string())
}

let req = match cedar::request_from_json(
  "{\"principal\":{\"type\":\"User\",\"id\":\"alice\"},\"action\":{\"type\":\"Action\",\"id\":\"deploy\"},\"resource\":{\"type\":\"Service\",\"id\":\"api\"},\"context\":{\"client_ip\":{\"__extn\":{\"fn\":\"ip\",\"arg\":\"10.1.2.3\"}}}}",
) {
  Ok(r) => r
  Err(e) => panic(e.to_string())
}

let resp = match cedar::Authorizer::new().is_authorized(req, policies, entities) {
  Ok(r) => r
  Err(e) => panic(e.to_string())
}
```

## Verification

```sh
sh scripts/verify.sh packages/cedar
```

4-mode `wasm_smoke` (each with a clean `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/private/tmp/w16-cedar-nd pionc run packages/cedar/wasm_smoke
PION_CACHE_DIR=/private/tmp/w16-cedar-nr pionc run --release packages/cedar/wasm_smoke
PION_CACHE_DIR=/private/tmp/w16-cedar-wd pionc run --target wasm32 packages/cedar/wasm_smoke
PION_CACHE_DIR=/private/tmp/w16-cedar-wr pionc run --target wasm32 --release packages/cedar/wasm_smoke
```

All 4 modes exit `0` with byte-identical stdout:
`cedar_wasm_smoke: OK checks=4` (`sha256:f0c80fb66bc0f602453bda4421798de64d6afa7c615ee732f50fb7eaac715593`).

## Head-to-Head Benchmarks vs Official Rust `cedar-policy` (`v4.15.0 --release`)

Run with:

```sh
sh packages/cedar/bench/run_bench.sh
```

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, `Cargo.lock` pinned at `cedar-policy v4.15.0`, mandatory stdout SHA-256 verification across all rounds and implementations):

### W1: Policy Set Parse + Format (`10,000` policies = 200 multi-tenant RBAC/ABAC policies × 50 rounds)

SHA-256: `a091e50786636ac9f49c7e79cdba6d0c65afe7e8a0c85bd009576c381d1e06e3` (`70 B`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Throughput (ops/s) | Peak RSS | Speedup (vs `cedar_policy_rust`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 44.688 | 43.592 | 45.204 | 4,468.77 | 223,774 | 3.23 MiB | **4.41x** |
| `cedar_policy_rust` | 196.975 | 195.666 | 237.180 | 19,697.49 | 50,768 | 10.28 MiB | 1.00x (baseline) |

### W2: Large-Scale Authorization (`60` policies, `250`-node Entity DAG, `3,000` mixed Allow/Deny requests)

Every single request prints `<idx>:<Allow|Deny>:<sorted determining policy IDs>`; all 3,000 decisions and policy IDs are verified byte-identical.
SHA-256: `ca8bacaaadc2b207d0608b392bb868ee87b83fd0f9d14bc3fb4d595232c34407` (`56,040 B`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Throughput (reqs/s) | Peak RSS | Speedup (vs `cedar_policy_rust`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 26.499 | 25.282 | 29.600 | 8,833.07 | 113,212 | 2.97 MiB | **5.10x** |
| `cedar_policy_rust` | 135.274 | 131.160 | 139.210 | 45,091.32 | 22,177 | 8.42 MiB | 1.00x (baseline) |

### W3: Extensions & Predicates (`decimal` / `ip` CIDR / `like` / Sets, `2,000` requests)

Every single request prints `<idx>:<Allow|Deny>:<sorted determining policy IDs>`; all 2,000 decisions and policy IDs are verified byte-identical.
SHA-256: `7db3c9990119f457b2e669c44397434aee97c9baf9b74e93bfd947b030ec9aa8` (`28,797 B`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Throughput (reqs/s) | Peak RSS | Speedup (vs `cedar_policy_rust`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 9.648 | 8.959 | 10.034 | 4,823.85 | 207,297 | 2.48 MiB | **2.05x** |
| `cedar_policy_rust` | 19.768 | 19.450 | 20.287 | 9,883.85 | 101,174 | 6.47 MiB | 1.00x (baseline) |

### Scope & Architecture Comparison vs Rust `cedar-policy`

- **Why `packages/cedar` is fast & lean (`2.48–3.23 MiB` RSS)**: Direct hand-written lexer + recursive-descent parser (no LALRPOP CST/miette diagnostic tree allocation), precomputed sorted ancestor arrays for O(log A) zero-allocation `in` queries, and direct `Value` construction in requests without per-request `RestrictedExpression` evaluation.
- **Features present in Rust `cedar-policy v4.15.0` not yet in `packages/cedar v0.1.0`**:
  - Policy templates & slots (`?principal`, `?resource`) and template linking.
  - Cedar Schema language parsing & static typechecking / validation.
  - Partial evaluation (unknowns / residual policies).
  - Cedar v4.2+ `datetime` and `duration` extensions (currently `decimal` and `ip` are implemented).
  - Exact 64-bit integers beyond `±2^53` inside JSON Entities/Request (since `packages/json5` stores JSON numbers as IEEE 754 `Double`; Cedar policy literals support full exact `i64::MIN..i64::MAX`).
