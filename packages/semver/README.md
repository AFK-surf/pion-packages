# `semver`

Pure-Pion, zero-dependency, production-grade **SemVer 2.0.0** and **Cargo `VersionReq`** parser, comparator, and constraint solver, ported from Rust [`dtolnay/semver`](https://github.com/dtolnay/semver) (`v1.0.28`).

- **Zero `World` dependency** — immutable `Send`-safe value types (`Version`, `Prerelease`, `BuildMetadata`, `Comparator`, `Op`, `VersionReq`).
- **Dual-target verified** — Native (`arm64_apple`) and WebAssembly (`wasm32`, `packages/semver/wasm_smoke`).
- **100% `dtolnay/semver` test compliance** — full port of `test_version.rs`, `test_version_req.rs`, and `test_identifier.rs` plus Day-1 red-team security & overflow vectors.

## Features

- **Strict SemVer 2.0.0 parsing & formatting** (`Version::parse`, `Version::to_string`, `Version::write_to`):
  - Rejects leading zeros in numeric components and numeric prerelease segments, empty segments, whitespace, missing `minor`/`patch`, and non-ASCII characters.
  - Exact `dtolnay/semver` structured error kinds (`SemverErrorKind`) and diagnostic messages.
- **Precedence & total ordering**:
  - `Version::compare` / `Version::equals`: SemVer 2.0.0 precedence (ignores `build` metadata; release > prerelease; numeric < alphanumeric).
  - `Version::compare_full` / `Version::equals_exact`: total ordering including `build` metadata (`0 < 00 < 1 < 01 < 001 < 2 < 10`, matching `dtolnay/semver`).
- **Full Cargo `VersionReq` & `Comparator` semantics**:
  - Operators `=`, `>`, `>=`, `<`, `<=`, `~`, `^`, `*` (plus `x`/`X` wildcards, `1.*`, `1.2.*`, implicit caret `1` / `1.2`).
  - Comma-separated AND intersection (`>=1.2.3, <2.0.0`) with legal whitespace handling.
  - Exact Cargo prerelease opt-in rule: a prerelease version matches a `VersionReq` only if all comparators match **and** at least one comparator with the same `(major, minor, patch)` explicitly specifies a non-empty prerelease.
- **Day-1 Red-Team Security Defenses**:
  - **Zero-overflow arbitrary-length numeric prerelease/build comparison**: numeric identifiers are compared by decimal digit length + ASCII lexicographic order, never overflowing 64-bit integers (tested up to 41+ digit numbers).
  - **Strict 64-bit overflow detection** on `major`/`minor`/`patch` (`0 ..= Int64::MAX = 9223372036854775807`).
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
pionc build --release --target wasm32 -o /tmp/semver_smoke.wasm packages/semver/wasm_smoke
node "$HOME/.pion/share/pion/pion_wasm_rt.mjs" /tmp/semver_smoke.wasm
```

- **Tests**: `35/35` passing (`version_test.pion`, `version_req_test.pion`, `identifier_test.pion`, `redteam_test.pion`).
- **Wasm32**: compiles cleanly with `--release --target wasm32` and exits `0` under Node.js (`pion_wasm_rt.mjs`).

## Head-to-Head Benchmarks (Pion Native vs Rust `dtolnay/semver v1.0.28 --release`)

Run via:

```sh
sh packages/semver/bench/run_bench.sh
```

Measured on `Darwin arm64` (`pionc 0.1.0 arm64_apple` vs `rustc --release` with `opt-level = 3, lto = "thin"` and `semver v1.0.28`), `--warmup 1 --rounds 5` strictly interleaved, with mandatory stdout SHA-256 verification.

### Bench 1: `Version::parse` + Full Sort + `to_string` (20,000 versions × 20 iters = 400,000 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_semver`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 111.488 | 105.631 | 113.615 | 37.90 | 278.72 | 5.33 MiB | 0.59x |
| `rust_semver` | 65.572 | 63.900 | 67.118 | 64.44 | 163.93 | 4.61 MiB | 1.00x (baseline) |

- Verified identical stdout SHA-256: `02415012c4d54846f0f03929fdd05e9c9dd375c43dd34f59cd469811933bb31a`

### Bench 2: `VersionReq::parse` + `VersionReq::matches` Matrix (2,000 reqs × 500 versions × 5 iters = 5,000,000 matches)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_semver`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 29.619 | 27.518 | 30.668 | 5.92 | 4.12 MiB | 0.79x |
| `rust_semver` | 23.545 | 22.463 | 24.847 | 4.71 | 3.31 MiB | 1.00x (baseline) |

- Verified identical stdout SHA-256: `b1a5400ab4ce74ab82882bf3f8c09dbdcff5513c351a819ea026a841f78e5605`

### Optimization & Compiler Ceiling Notes

Hotspot profiling (`otool -tv`) and optimization passes reduced Bench 2 latency by **3.9×** (`114.8 ms → 29.6 ms`, `0.23x → 0.79x–0.94x`) and Bench 1 latency by **1.6×** (`179.6 ms → 111.5 ms`, `0.36x → 0.59x`):

1. **Precompiled O(1) release-version interval bounds** on `VersionReq` + single-major prerelease filter (collapses arbitrary multi-comparator checks to 2–6 integer comparisons with zero array iteration).
2. **Primitive `pre_len`/`build_len` guards + empty identifier singletons** on `Version` (eliminates all RC inc/dec traffic on `pre`/`build` along the hot paths of `matches`, `compare_full`, and `to_string`).
3. **Cold-path outlining** (`matches_pre_slow`, `compare_full_tail`) so the QBE backend avoids callee-saved register spills (`x19..x28`) on fast paths.
4. **Inlined decimal scanning** in `Version::parse`, direct `String::slice`, and zero-allocation integer formatting in `Version::to_string`.

The remaining gap against `rustc -O3 + LTO` reflects current `pionc 0.1.0` (QBE) codegen ceilings:
- **Bench 2 (~1.2 ns/op gap)**: `VersionReq::matches` itself executes in ~1.5 ns, while the caller loop incurs ~4 ns/op for non-inlined cross-package calls plus `Array[Version]` element RC inc/dec (vs LLVM inlining `&Version` borrows with zero RC).
- **Bench 1 (~115 ns/op gap)**: `dtolnay/semver` returns `Result<Version, Error>` on the stack with pointer-tagged inline SSO `Identifier` (zero heap allocations for plain and short prerelease/build versions), whereas `pionc` currently heap-allocates `Ok(Version)` + `Version` + `String` and performs RC operations on `Array[Version]` indexing/swaps during sorting.
