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
