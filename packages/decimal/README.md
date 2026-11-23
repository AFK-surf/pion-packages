# `decimal` — Pure Pion 128-bit Exact Decimal Arithmetic (`rust_decimal` Port)

Zero-dependency, pure-Pion port of Rust's [`paupino/rust-decimal`](https://github.com/paupino/rust-decimal) (`rust_decimal`), providing **128-bit exact base-10 arithmetic** (`val struct Decimal` with a 96-bit unsigned mantissa `lo64` + `hi`, sign bit, and scale `0..=28`) with zero IEEE-754 floating-point drift. Designed for billing, token accounting, financial ledgers, quotas, and reporting on both **Native** and **WebAssembly (`wasm32`)** targets without `World` dependencies.

## Features

- **128-bit Value Representation (`pub val struct Decimal { pub lo64 : UInt64, pub hi : UInt, pub flags : UInt }`)**:
  - Range: `±79,228,162,514,264,337,593,543,950,335` (`2^96 - 1`), scale `0..=28`.
  - Storing the lower 64 bits directly in `lo64 : UInt64` eliminates 32-bit packing/unpacking on the 64-bit fast paths (common in currency/token billing).
- **Parsing & Formatting (`src/parse.pion`, `src/fmt.pion`)**:
  - `Decimal::from_str` (supports `+`/`-`, `_` digit separators, automatic rounding past 28 fractional digits, and scientific notation `e`/`E`).
  - `Decimal::from_str_exact` (strict: rejects any precision loss with `Err(DecimalError::Underflow)`).
  - `Decimal::from_scientific` (exact) & `Decimal::from_scientific_lossy` (rounds negative exponents within `|exp| <= 28`).
  - `Decimal::from_str_radix` (radices `2..=36`).
  - `Decimal::to_string` & `Decimal::write_to(sb)` using **9-digit (`1_000_000_000`) chunking** (at most 4 divisions for a full 96-bit mantissa) and exact-size `Bytes` formatting, preserving trailing zeros per `scale`.
  - `Decimal::serialize` / `Decimal::deserialize`: 16-byte little-endian wire format `[flags, lo, mid, hi]` compatible with `rust_decimal`.
- **Exact Checked Arithmetic (`src/ops.pion`)**:
  - `checked_add`, `checked_sub`, `checked_mul`, `checked_div`, `checked_rem`, `neg`, `abs`.
  - 64-bit fast paths (`hi == 0` with same-scale `UInt64` ops and 128-bit widening multiply `u64_mul_wide` for cross-scale alignment up to `diff <= 19`).
  - Full 96/128/192-bit arithmetic with automatic scale reduction and Banker's rounding (`u192_rescale`), plus Knuth 32/64/96-bit long division (`partial_divide_64` / `partial_divide_96`).
- **All 7 Rounding Strategies & Scale Operations (`src/round.pion`)**:
  - `round`, `round_dp`, `round_dp_with_strategy`: `MidpointNearestEven` (Banker's rounding), `MidpointAwayFromZero`, `MidpointTowardZero`, `ToZero`, `AwayFromZero`, `ToNegativeInfinity`, `ToPositiveInfinity`.
  - `normalize` (strips trailing zeros and converts `-0`/`-0.0` to `0`), `rescale`, `set_scale`, `floor`, `ceil`, `trunc`, `trunc_with_scale`, `fract`.
- **Comparison, Sorting & Math (`src/cmp.pion`, `src/math.pion`)**:
  - Total numerical ordering (`compare`, `eq`, `lt`, `le`, `gt`, `ge`, `min_val`, `max_val`) treating `-0.0 == 0.0` and `1.0 == 1.00`, plus in-place `Decimal::sort`.
  - `checked_powu`, `checked_powi` / `powi` (exact negative-exponent reciprocal path for `|x| < 1`), `sqrt` (Babylonian method with 2-cycle detection and residual selection), `to_i64`, `to_u64`, `to_f64`.
- **Day-1 Red-Team Defenses (`redteam_test.pion`)**:
  - Huge exponents (`1e999999999`, `1e-999999999`, `1.5e4294967296`, `-20165.4676_e-+4294967292`) are rejected in O(len) with zero allocation / no OOM.
  - Iterative O(1)-stack parser handles 10,000+ leading zeros or underscore separators without stack overflow.
  - Explicit `Err(DecimalError::DivisionByZero)` for `0`, `-0`, `0.0000` divisors; explicit `Err(DecimalError::Overflow)` on `MAX + 1`, `MIN - 1`, `MAX * 2`, `MAX / 0.1`, `2^128`.
  - Rejects malformed inputs (`""`, `" "`, `"."`, `"_1"`, `"1.0.0"`, trailing garbage after 28dp like `"1.000...5zzz"`, `MAX + 1` strings).

## Verification

```sh
pionc fmt --check packages/decimal
pionc check --json packages/decimal
pionc test --json packages/decimal

# Native debug & release smoke
pionc build packages/decimal/wasm_smoke -o /private/tmp/decimal_smoke_dbg && /private/tmp/decimal_smoke_dbg
pionc build --release packages/decimal/wasm_smoke -o /private/tmp/decimal_smoke_rel && /private/tmp/decimal_smoke_rel

# Wasm32 debug & release smoke
pionc build --target wasm32 packages/decimal/wasm_smoke -o /private/tmp/decimal_smoke_dbg.wasm
pionc run --target wasm32 packages/decimal/wasm_smoke
pionc build --release --target wasm32 packages/decimal/wasm_smoke -o /private/tmp/decimal_smoke_rel.wasm
pionc run --release --target wasm32 packages/decimal/wasm_smoke
```

## Head-to-Head Benchmarks (Pion Native `--release` vs Rust `rust_decimal = 1.37.2` `--release`)

Measured on `Darwin arm64` with `pionc 0.1.0 (arm64_apple, self-hosted)` and `rustc 1.100.0` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification). Run locally via:

```sh
sh packages/decimal/bench/run_bench.sh
```

### Bench 1: Mixed Decimal Parse + Format (500,000 ops, 6.56 MB)

50,000 mixed decimal strings (2dp currency, 6dp micro-billing, integers, 8dp FX rates, 96-bit ledger balances, 18dp high-precision fractions) × 10 steady-state rounds (`from_str` + `to_string` + FNV-1a over every output byte).

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_decimal`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 66.802 | 65.948 | 67.252 | 98.14 | 133.60 | 5.38 MiB | **0.79x** |
| `rust_decimal` (`1.37.2`) | 53.100 | 52.495 | 54.534 | 123.47 | 106.20 | 3.38 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `6a0482dc3aee4ddc3a4c80783d683008c2445a1dccd3fd2ec58e8cbffef1ae48`

### Bench 2: Billing Arithmetic Stream (2,000,000 ops)

400,000 transactions × 5 core idiomatic `Decimal` operations (`checked_mul`, `checked_add`, `checked_sub`, `checked_div`, `round_dp(2)`), accumulating an exact running `grand_total` and FNV-1a checksum.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_decimal`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 104.280 | 103.543 | 108.294 | 52.14 | **1.73 MiB** | **0.48x** |
| `rust_decimal` (`1.37.2`) | 49.576 | 46.317 | 74.693 | 24.79 | 1.81 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `3d0da5b89dfe19db270abada6e5ea031da0006e447090b5e4e684c4f1ba92f50`

### Bench 3: Sort + Aggregate + Banker's Rounding (500,000 ops)

50,000 mixed-scale `Decimal` values × 10 rounds: in-place `Decimal::sort` (vs Rust `Vec::sort_unstable`), `round_dp(2)` Banker's rounding on every element, and exact sum/min/median/max aggregation.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_decimal`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 142.054 | 141.275 | 143.745 | 284.11 | 7.92 MiB | **0.35x** |
| `rust_decimal` (`1.37.2`) | 49.741 | 49.058 | 50.258 | 99.48 | 4.12 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `d83ad65315d2b3ccb76bcd83b313962ed82c2f7511163a437f3549806d38f7dd`

### Performance & Compiler Analysis

- **Strengths**:
  - **Parse + Format reaches 0.79x of Rust `--release` (98.14 MB/s, 133.6 ns/op)** thanks to the iterative `UInt64` 18-digit fast path in `parse_radix10_core` and 9-digit chunking (`1_000_000_000`) into exact-size `Bytes` in `Decimal::to_string`.
  - **Lower RSS on Bench 2 (1.73 MiB vs Rust 1.81 MiB)** — zero heap churn in the 64-bit arithmetic fast path.
- **Honest Bottlenecks (why Bench 2 is 0.48x and Bench 3 is 0.35x)**:
  1. **`Result[Decimal, DecimalError]` & `Array[Decimal]` boxing overhead**: In `pionc 0.1.0`, returning `Result[Decimal, DecimalError]` wraps the 16-byte `val struct Decimal` in a tagged enum allocation, and `Array[Decimal]` stores boxed elements (visible in Bench 3 RSS: 7.92 MiB vs Rust's contiguous 16 B/elem `Vec<Decimal>` at 4.12 MiB), adding pointer indirection on every comparison during sort.
  2. **Software 64×64→128-bit multiply**: Pion does not yet expose a native `UInt128` / `arm64 umulh` intrinsic, so cross-scale widening (`u64_mul_wide`) uses 4×32-bit schoolbook products instead of a single `mul` + `umulh` instruction pair.
  3. **Heap `FixedArray[UInt]` in `checked_div`**: `checked_div` allocates small 3-word `FixedArray[UInt]` buffers for the general 32/64/96-bit Knuth long-division path (whereas Rust keeps `[u32; 3]` on the stack).
- **Compiler Workaround (`pionc 69a0189d` `--release`)**:
  - `Decimal::round`, `Decimal::round_dp`, and `Decimal::rescale` route through an internal integer-tagged `round_dp_code(self, dp, code)` helper rather than referencing fieldless `RoundingStrategy` variants directly, avoiding the `pionc 69a0189d` `--release` cross-package inlining bug for fieldless enum variants. Verified with `wasm_smoke` passing in Native debug, Native `--release`, Wasm32 debug, and Wasm32 `--release`.
