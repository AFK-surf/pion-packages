# `semver`

Pure-Pion, zero-dependency, production-grade **SemVer 2.0.0** and **Cargo `VersionReq`** parser, comparator, and constraint solver, ported from Rust [`dtolnay/semver`](https://github.com/dtolnay/semver) (`=1.0.28`).

- **Zero `World` dependency** — `Send`-safe value types (`Version`, `Prerelease`, `BuildMetadata`, `Comparator`, `Op`, `VersionReq`).
- **Dual-target verified** — Native (`arm64_apple`) and WebAssembly (`wasm32`, `packages/semver/wasm_smoke`).
- **100% `dtolnay/semver =1.0.28` differential & red-team verified** — full port of `test_version.rs`, `test_version_req.rs`, and `test_identifier.rs`, plus 166,458 differential fuzz cases (0 mismatches), 296M+ exhaustive `VersionReq::matches` matrix checks (including `u64::MAX`), and 23/23 red-team audit tests.

## Features

- **Strict SemVer 2.0.0 parsing & formatting** (`Version::parse`, `Version::to_string`, `Version::write_to`):
  - Full unsigned 64-bit component domain (`UInt64`, `0 ..= 18446744073709551615`), matching Rust `u64`.
  - Rejects leading zeros in numeric components and numeric prerelease segments, empty segments, whitespace, missing `minor`/`patch`, and non-ASCII characters.
  - Exact `dtolnay/semver` structured error kinds (`SemverErrorKind`) and diagnostic messages, including Rust `char::escape_debug` quoting and `exceeds u64::MAX` overflow diagnostics.
- **Total ordering & SemVer precedence**:
  - `Version::compare` / `Version::equals` / `Version::hash`: total ordering & structural equality including `build` metadata (matching Rust `Ord`/`Eq`/`Hash`, with `a.equals(b) => a.hash() == b.hash()`).
  - `Version::cmp_precedence`: SemVer 2.0.0 precedence comparison (ignores `build` metadata; release > prerelease; numeric < alphanumeric).
  - `Version::compare_full` / `Version::equals_exact`: explicit aliases for `compare` / `equals`.
- **Full Cargo `VersionReq` & `Comparator` semantics**:
  - Operators `=`, `>`, `>=`, `<`, `<=`, `~`, `^`, `*` (plus `x`/`X` wildcards, `1.*`, `1.2.*`, implicit caret `1` / `1.2`), plus `VersionReq::from_comparators`.
  - Comma-separated AND intersection (`>=1.2.3, <2.0.0`) with legal whitespace handling.
  - Exact Cargo prerelease opt-in rule: a prerelease version matches a `VersionReq` only if all comparators match **and** at least one comparator with the same `(major, minor, patch)` explicitly specifies a non-empty prerelease.
  - **100% live cache-coherent evaluation**: mutating `Version.pre`, `Version.build`, or `VersionReq.comparators` (`push` / index assign) is immediately reflected in `matches`, `to_string`, `compare`, and `hash` with zero stale caches.
- **Red-Team Security Defenses**:
  - **Zero-overflow arbitrary-length numeric prerelease/build comparison**: numeric identifiers are compared by decimal digit length + ASCII lexicographic order, never overflowing 64-bit integers.
  - **Overflow-free `u64::MAX` matching**: `^18446744073709551615.0.0`, `~0.18446744073709551615`, and `>18446744073709551615` never compute `major + 1` or `minor + 1`.
  - **DoS resistance**: hard cap of `32` comparators per `VersionReq` (`max_comparators()`), strict `O(N)` linear scanning and comparison with zero `O(n²)` allocations or backtracking.

## Quick Example

```pion
import "semver"

let req = match semver::parse_req(">=1.2.3-alpha.1, <2.0.0") {
  Ok(r) => r
  Err(e) => ...
}
let v1 = match semver::parse_version("1.2.3-alpha.11+build.42") {
  Ok(v) => v
  Err(e) => ...
}
let matched = req.matches(v1) // true
```

## Verification

```sh
pionc fmt --check packages/semver
pionc check --json packages/semver
pionc test --json packages/semver
sh packages/semver/audit/run_audit.sh
pionc build --release --target wasm32 -o /tmp/semver_smoke.wasm packages/semver/wasm_smoke
node "$HOME/.pion/share/pion/pion_wasm_rt.mjs" /tmp/semver_smoke.wasm
```

- **Unit tests**: `35/35` passing (`version_test.pion`, `version_req_test.pion`, `identifier_test.pion`, `redteam_test.pion`).
- **Red-team audit**: `23/23` passing, `166,458/166,458` differential cases byte-identical (`0` mismatches), exhaustive `small` + `max` + `u64::MAX` matrices byte-identical.
- **Wasm32**: compiles cleanly with `--release --target wasm32` and exits `0` under Node.js (`pion_wasm_rt.mjs`).

## Formal Verification (Lean 4)

The pure comparison and Cargo `Comparator` matching kernels in `packages/semver/src/{types,compare,eval}.pion` are marked `#verify` and extracted directly into Lean 4 (`Semver.Types`, `Semver.Funs`) via `pionc extract-lean` (on top of `Aeneas.Std` and `PionLean`, Lean `v4.36.0-rc2`, Aeneas `1dc8ad31b1`, with `0` external axioms).

### Reproducing the Proofs

```sh
sh packages/semver/proofs/run_proofs.sh
```

The script builds an isolated Lake project under `/private/tmp/pion-lean-semver` (zero git worktree pollution), runs `pionc extract-lean --json`, builds `PionLean Semver SemverProofs`, rejects any `sorry`/`admit`/`bv_decide`/`native_decide`, audits `#print axioms` across all 32 theorems, and runs `#guard` + `#eval` differential checks against native Pion execution (including `UInt64::MAX = 18446744073709551615`).

### Verified Theorems (`packages/semver/proofs/SemverProofs.lean`)

All **32** theorems are kernel-checked with **0 `sorry` / `admit` / `native_decide` / `bv_decide`** and depend strictly on the three standard Lean axioms (`propext`, `Classical.choice`, `Quot.sound`), verified by `packages/semver/proofs/CheckAxioms.lean`:

1. **Core `(major, minor, patch : UInt64)` Lexicographic Strict Total Order (`semver.cmp_core`)**:
   - `cmp_core_total`: panic/trap-free totality across the full `0 .. 2^64 - 1` domain, returning `r ∈ {-1, 0, 1}`.
   - `cmp_core_refl`: reflexivity (`cmp_core m n p m n p = ok 0`).
   - `cmp_core_antisymm`: antisymmetry (`cmp_core a b = ok (-r) ↔ cmp_core b a = ok r`).
   - `cmp_core_eq_zero_iff`: equivalence consistency (`cmp_core a b = ok 0 ↔ a = b`).
   - `cmp_core_lt_iff`: exact lexicographic `<` characterization.
   - `cmp_core_trans_lt`, `cmp_core_trans_le`: strict `<` and non-strict `≤` transitivity.
2. **SemVer 2.0.0 Prerelease & Build Metadata Precedence (`semver.cmp_precedence_core`, `semver.cmp_pre_segment_order`)**:
   - `cmp_precedence_release_gt_pre`, `cmp_precedence_pre_lt_release`: release versions strictly outrank any non-empty prerelease with the same `(major, minor, patch)` (SemVer 2.0.0 §11.3).
   - `cmp_precedence_ignores_build`, `cmp_precedence_same_except_build`: build metadata is completely ignored in precedence comparison (SemVer 2.0.0 §10).
   - `cmp_pre_segment_order_numeric_lt_alpha`, `cmp_pre_segment_order_refl`, `cmp_pre_segment_order_antisymm`, `cmp_pre_segment_order_trans_lt`: strict total ordering and numeric `<` alphanumeric precedence for prerelease segments (SemVer 2.0.0 §11.4).
3. **Cargo `Comparator` / `Op` Interval Matching & `UInt64::MAX` Overflow Immunity (`semver.matches_release`, `semver.pre_is_compatible`)**:
   - `matches_release_total_no_overflow`: all 8 operators (`Exact`, `Greater`, `GreaterEq`, `Less`, `LessEq`, `Tilde`, `Caret`, `Wildcard`) never panic or overflow across full `UInt64`.
   - `matches_release_caret_major_pos`, `matches_release_caret_zero_minor_pos`, `matches_release_caret_zero_zero`: exact three-regime Cargo `Caret` (`^M.m.p`) specification (`M > 0`, `M = 0 ∧ m > 0`, `M = 0 ∧ m = 0`).
   - `matches_release_tilde_spec`: exact Cargo `Tilde` (`~M.m.p`) specification.
   - `matches_release_caret_u64_max`, `matches_release_tilde_u64_max`, `matches_release_greater_u64_max`: `UInt64::MAX` overflow immunity (no `major + 1` or `minor + 1` wraparound to `0`).
   - `matches_release_exact_iff`, `matches_release_wildcard_eq_exact`: `Exact` and `Wildcard` exactness.
   - `matches_release_refl_ge`, `matches_release_refl_caret`, `matches_release_refl_tilde`: reflexivity on full triples.
   - `matches_release_lt_ge_complement`, `matches_release_gt_le_complement`: exact complementarity of `Less`/`GreaterEq` and `Greater`/`LessEq` for all comparators (full and partial).
   - `matches_release_ge_monotone`: monotonicity of `GreaterEq` with respect to `cmp_core`.
   - `pre_is_compatible_spec`: exact Cargo prerelease opt-in compatibility rule.

## Head-to-Head Benchmarks (Pion Native vs Rust `dtolnay/semver =1.0.28 --release`)

Run via:

```sh
sh packages/semver/bench/run_bench.sh
```

Measured on `Darwin arm64` (`pionc 0.1.0 arm64_apple` @ `AFK-surf/pion@69a0189` vs `rustc --release` with `opt-level = 3, lto = "thin"` and locked `semver = "=1.0.28"`), `--warmup 1 --rounds 5` strictly interleaved, with mandatory stdout SHA-256 verification.

### Bench 1: `Version::parse` + Full Sort + `to_string` (20,000 versions × 20 iters = 400,000 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_semver`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 177.238 | 166.837 | 193.783 | 23.84 | 443.10 | 4.55 MiB | 0.38x |
| `rust_semver` | 67.990 | 65.522 | 72.005 | 62.15 | 169.98 | 4.59 MiB | 1.00x (baseline) |

- Verified identical stdout SHA-256: `02415012c4d54846f0f03929fdd05e9c9dd375c43dd34f59cd469811933bb31a`
- _Methodology note_: Rust uses `slice::sort` (stable driftsort) while Pion uses median-of-three quicksort + insertion sort; because `Version` has a total order, outputs are byte-identical, though the timing includes sorting algorithm differences.

### Bench 2: `VersionReq::parse` + `VersionReq::matches` Matrix (2,000 reqs × 500 versions × 5 iters = 5,000,000 matches)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_semver`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 102.161 | 99.505 | 105.935 | 20.43 | 3.91 MiB | 0.27x |
| `rust_semver` | 27.603 | 26.376 | 28.535 | 5.52 | 3.31 MiB | 1.00x (baseline) |

- Verified identical stdout SHA-256: `b1a5400ab4ce74ab82882bf3f8c09dbdcff5513c351a819ea026a841f78e5605`

### Bench 3: Complex 32-Comparator `VersionReq::parse` + `matches` + `to_string` (20,000 reqs × 3 iters = 60,000 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_semver`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 129.408 | 126.698 | 134.359 | 2156.80 | 15.97 MiB | **1.06x** |
| `rust_semver` | 137.344 | 135.647 | 141.844 | 2289.06 | 16.53 MiB | 1.00x (baseline) |

- Verified identical stdout SHA-256: `c8a02307acbf6a5d9df9148e2ee3c78a6af80feabbe8b5596a837f4d8f3391f3`

### Bench 4: Dirty Input Rejection (`Version::parse` + `VersionReq::parse`, 100,000 invalid inputs × 5 iters × 2 = 1,000,000 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_semver`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 79.490 | 78.182 | 80.460 | 79.49 | 8.92 MiB | **1.36x** |
| `rust_semver` | 107.903 | 106.188 | 108.596 | 107.90 | 8.50 MiB | 1.00x (baseline) |

- Verified identical stdout SHA-256: `dc0303b9ce5fa81eefe28b9669a72398c8824bb936bc5c93269b4ce3081f4764`

### Correctness vs Throughput Trade-off Notes

- Removing the parse-time interval cache on `VersionReq` and `pre_len`/`build_len` caches on `Version` eliminated all P1 cache-coherence bugs (mutating `req.comparators`, `v.pre`, or `v.build` is always live) and doubled complex 32-comparator req parsing throughput (**Bench 3: 1.06x faster than Rust**, **Bench 4: 1.36x faster than Rust**).
- The remaining gap on Bench 1 (`0.38x`) and Bench 2 (`0.27x`) reflects current `pionc 0.1.0` (QBE) codegen ceilings for RC-managed `val struct` fields (`Array[Comparator]` element loads, `Option[UInt64]`/`Prerelease`/`BuildMetadata` RC traffic on live reads) compared to Rust's stack-borrowed `&Version`/`&Comparator` and pointer-tagged SSO `Identifier`.
