# `decimal` — Pure Pion 128-bit Exact Decimal Arithmetic (`rust_decimal` Port)

Zero-dependency, pure-Pion port of Rust's [`paupino/rust-decimal`](https://github.com/paupino/rust-decimal) (`rust_decimal =1.37.2`), providing **128-bit exact base-10 arithmetic** (`val struct Decimal` with a 96-bit unsigned mantissa `lo64` + `hi`, sign bit, and scale `0..=28`) with zero IEEE-754 floating-point drift. Designed for billing, token accounting, financial ledgers, quotas, and reporting on both **Native** and **WebAssembly (`wasm32`)** targets without `World` dependencies.

## Features

- **128-bit Value Representation (`pub val struct Decimal { pub lo64 : UInt64, pub hi : UInt, pub flags : UInt }`)**:
  - Range: `±79,228,162,514,264,337,593,543,950,335` (`2^96 - 1`), scale `0..=28`.
  - Storing the lower 64 bits directly in `lo64 : UInt64` eliminates 32-bit packing/unpacking on the 64-bit fast paths (common in currency/token billing).
- **Parsing & Formatting (`src/parse.pion`, `src/fmt.pion`)**:
  - `Decimal::from_str`: iterative O(1)-stack base-10 parser (`+`/`-`, `_` digit separators, automatic rounding past 28 fractional digits, negative-zero sign clearing, and strict rejection of `e`/`E` matching `rust_decimal::FromStr`).
  - `Decimal::from_str_exact`: strict base-10 parser rejecting any precision loss with `Err(DecimalError::Underflow)`.
  - `Decimal::from_scientific` (exact) & `Decimal::from_scientific_lossy` (rounds negative exponents within `|exp| <= 28`), using zero-copy `[start, end)` slice parsing and scalar power-of-10 scaling.
  - `Decimal::from_str_radix`: radices `2..=36` with overflowing fractional digit rounding (without `rust_decimal` 1.37.2's `estimated_max_precision` truncation/panic bugs).
  - `Decimal::to_string` & `Decimal::write_to(sb)`: **9-digit (`1_000_000_000`) chunking** (at most 4 divisions for a full 96-bit mantissa) and exact-size `Bytes` formatting, preserving trailing zeros per `scale`.
  - `Decimal::serialize` / `Decimal::deserialize`: 16-byte little-endian wire format `[flags, lo, mid, hi]` bit-for-bit interoperable with `rust_decimal =1.37.2` (including `0x801F_0000` 5-bit scale masking and scale 29–31 carry rules).
- **Zero-Allocation Exact Checked Arithmetic (`src/ops.pion`)**:
  - `checked_add`, `checked_sub`, `checked_mul`, `checked_div`, `checked_rem`, `neg`, `abs`.
  - 64-bit fast paths (`hi == 0` with same-scale `UInt64` ops and 128-bit widening multiply `u64_mul_wide` for cross-scale alignment up to `diff <= 19`).
  - Full 96/128/192-bit scalar arithmetic (`checked_mul` / `finish_mul_192_scalar`, `checked_div` 32/64/96-bit Knuth long division + `unscale_div_scalar`) with **zero heap `FixedArray` allocations** on the multiply and division hot paths and bit-exact scale/rounding parity with `rust_decimal =1.37.2`.
- **All 7 Rounding Strategies & Scale Operations (`src/round.pion`)**:
  - `round`, `round_dp`, `round_dp_with_strategy`: `MidpointNearestEven` (Banker's rounding), `MidpointAwayFromZero`, `MidpointTowardZero`, `ToZero`, `AwayFromZero`, `ToNegativeInfinity`, `ToPositiveInfinity` — single-pass zero-allocation scalar 96-bit rounding with negative-zero sign clearing (matching `rust_decimal`).
  - `normalize` (strips trailing zeros and converts `-0`/`-0.0` to `0`), `rescale` (safely caps scale at 28 without panicking), `set_scale`, `floor`, `ceil`, `trunc`, `trunc_with_scale` (pads zeros up to target scale capped at 28 without panicking), `fract`.
- **Comparison, Worst-Case O(n log n) Sorting & Math (`src/cmp.pion`, `src/math.pion`)**:
  - Total numerical ordering (`compare`, `eq`, `lt`, `le`, `gt`, `ge`, `min_val`, `max_val`) treating `-0.0 == 0.0` and `1.0 == 1.00`.
  - In-place `Decimal::sort`: **Introsort** (interior-quartile median-of-three quicksort + `2 * log2(n)` **Heapsort** fallback + insertion-sort cutoff), immune to O(n²) McIlroy quicksort-killer sequences.
  - `checked_powu`, `checked_powi` / `powi` (exact `rust_decimal` overflow, scale, and reciprocal parity), `sqrt` (Babylonian method with 2-cycle detection and residual selection), `to_i64`, `to_u64`, `to_f64` (exact integral/fractional split conversion matching `rust_decimal` bit-for-bit).
- **Red-Team Verification (`redteam_test.pion` & `audit/`)**:
  - 167,139-op differential audit vs `rust_decimal =1.37.2` (`sh packages/decimal/audit/run_audit.sh`): **27 / 33 operations 100% bit-for-bit identical (0 mismatches)**, 0 value accuracy regressions (`judge_exact.py`), 16 / 16 audit tests passing, and byte-identical stdout SHA-256 across Native debug/release and Wasm32 debug/release.
  - Linear-time DoS resistance on 200k–1M-character hostile inputs, huge exponents (`1e±99999999999999999`), `powi(2, 1e9)`, `MAX % 1e-28`, and 50k McIlroy sort-killer permutations.

## Verification

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"

pionc fmt --check packages/decimal/src packages/decimal/decimal_test.pion packages/decimal/redteam_test.pion
pionc check --json packages/decimal
pionc test --json packages/decimal
(cd packages/decimal && pionc test --json audit)

# Native debug & release smoke
pionc build packages/decimal/wasm_smoke -o /private/tmp/pion-decimal-audit/smoke_dbg && /private/tmp/pion-decimal-audit/smoke_dbg
pionc build --release packages/decimal/wasm_smoke -o /private/tmp/pion-decimal-audit/smoke_rel && /private/tmp/pion-decimal-audit/smoke_rel

# Wasm32 debug & release smoke
pionc build --target wasm32 packages/decimal/wasm_smoke -o /private/tmp/pion-decimal-audit/smoke_dbg.wasm
pionc run --target wasm32 packages/decimal/wasm_smoke
pionc build --release --target wasm32 packages/decimal/wasm_smoke -o /private/tmp/pion-decimal-audit/smoke_rel.wasm
pionc run --release --target wasm32 packages/decimal/wasm_smoke

# Full red-team differential + DoS + adversarial benchmarks
sh packages/decimal/audit/run_audit.sh

# End-to-end Lean 4 formal verification (0 sorry / 0 admit / standard axioms + native diff)
sh packages/decimal/proofs/run_proofs.sh
```

## Formal Verification (Lean 4)

The pure 96/128-bit arithmetic, flag/sign/scale, wire-format, comparison, and truncation kernels in `packages/decimal/src/*.pion` are annotated with `#verify`, extracted directly into Lean 4 (`Decimal.Types` / `Decimal.Funs`) via `pionc extract-lean`, and machine-checked in [`proofs/DecimalProofs.lean`](proofs/DecimalProofs.lean) with **0 `sorry`**, **0 `admit`**, **0 `native_decide`**, and **0 `bv_decide`**, depending strictly on Lean's 3 standard axioms (`propext`, `Classical.choice`, `Quot.sound`):

- **96/128-bit Multi-Precision Arithmetic Kernels**:
  - `u64_mul_wide_spec`: exact 64×64 → 128-bit unsigned multiplication (`lo + 2^64 * hi = a * b`, never traps).
  - `u96_cmp_spec`, `u96_cmp_refl`, `u96_cmp_antisymm`, `u96_cmp_trans_lt`: strict total order on 3-word `[lo, mid, hi]` 96-bit unsigned integers, equivalent to mathematical `Nat` ordering on `lo + 2^32 * mid + 2^64 * hi`.
  - `inc96_spec`, `mul10_add96_spec`, `overflow96_div10_spec`, `pow10_u32_spec`, `pow10_u64_spec`: exact 96-bit `+ 1`, `* 10 + digit`, and overflow detection (never silently truncates overflow).
  - `reduce_scale_overflow96_spec`, `aligned_add_96_add_no_overflow`, `aligned_add_96_add_overflow_scale0`, `aligned_add_96_add_overflow_rescale`, `aligned_add_96_sub_spec`: exact 96-bit aligned add/sub, guaranteed `Err(Overflow)` at `scale = 0`, and valid rescaling for `1 ≤ scale ≤ 28`.
- **Flags, Sign, Scale (`0..=28`) & `neg` / `abs` / `is_zero` Invariants**:
  - `make_flags_spec`, `Decimal.from_parts_ok_spec`, `Decimal.from_parts_err_spec`, `Decimal.set_scale_spec`, `Decimal.scale_le_28`: `scale` is strictly bounded in `0..=28` and `scale > 28` always returns `Err(ScaleExceedsMaximumPrecision)`.
  - `Decimal.neg_spec`, `Decimal.neg_involutive`, `Decimal.abs_spec`, `Decimal.abs_idempotent`, `Decimal.abs_neg`, `Decimal.is_zero_spec`: `neg (neg d) = d`, `is_sign_negative (abs d) = false`, `abs (abs d) = abs d`, and `abs (neg d) = abs d`.
- **16-Byte Binary Wire Format (`serialize` ↔ `deserialize`) & Red-Team F-5 Mask (`0x801F0000`)**:
  - `Decimal.serialize_spec`, `Decimal.serialize_length`, `Decimal.deserialize_serialize_roundtrip`: exact bit-for-bit roundtrip `deserialize (serialize d) = ok (Ok d)` for every valid `Decimal`.
  - `Decimal.deserialize_wrong_length_err`: rejects any non-16-byte input with `Err(EmptyData)`.
  - `Decimal.deserialize_always_valid`: for any 16-byte input (including arbitrary reserved bits or 5-bit scales 29..31), `deserialize` never traps, masks reserved bits outside `0x801F0000`, and always returns a strictly valid `Decimal` (`scale ≤ 28`).
- **Exact Cross-Scale Decimal Comparison & Truncation**:
  - `cmp_magnitude_spec`, `Decimal.compare_spec`, `Decimal.compare_neg_zero_eq_pos_zero`, `Decimal.compare_refl`, `Decimal.compare_antisymm`, `Decimal.compare_trans_lt`, `Decimal.eq_spec`, `Decimal.lt_spec`, `Decimal.le_spec`: full cross-scale (`0..=28`) numerical ordering matching exact rational arithmetic (`a * 10^s2 ⋛ b * 10^s1`), with `-0 == +0` at all scales.
  - `truncate_core_spec`, `Decimal.trunc_spec`, `scale_up_96_spec`: exact integer truncation (`dec_mag d / 10^(dec_scale d)`) and overflow-safe scale-up preserving numerical value.

Run `sh packages/decimal/proofs/run_proofs.sh` to reproduce extraction, `lake build`, `#print axioms` audit (`proofs/CheckAxioms.lean`), and the 20-case Lean-vs-Native differential cross-check (`proofs/EvalDiff.lean` + `diff -u`).

## Head-to-Head Benchmarks (Pion Native `--release` vs Rust `rust_decimal =1.37.2` `--release`)

Measured on `Linux x86_64` with `pionc 0.1.0 (amd64_sysv, self-hosted)` and `rustc 1.100.0` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification).

### Standard Workloads (`sh packages/decimal/bench/run_bench.sh`)

#### Bench 1: Mixed Decimal Parse + Format (500,000 ops, 6.56 MB)

50,000 mixed decimal strings (2dp currency, 6dp micro-billing, integers, 8dp FX rates, 96-bit ledger balances, 18dp high-precision fractions) × 10 steady-state rounds (`from_str` + `to_string` + FNV-1a over every output byte).

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Speedup (vs `rust_decimal`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 48.443 | 44.745 | 53.819 | 135.34 | 96.89 | **1.00x** (baseline `0.79x`, +26% faster) |
| `rust_decimal` (`1.37.2`) | 48.291 | 44.498 | 75.666 | 135.76 | 96.58 | 1.00x (baseline) |

- Verified common stdout SHA-256: `6a0482dc3aee4ddc3a4c80783d683008c2445a1dccd3fd2ec58e8cbffef1ae48`

#### Bench 2: Billing Arithmetic Stream (2,000,000 ops)

400,000 transactions × 5 core idiomatic `Decimal` operations (`checked_mul`, `checked_add`, `checked_sub`, `checked_div`, `round_dp(2)`), accumulating an exact running `grand_total` and FNV-1a checksum.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Speedup (vs `rust_decimal`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` | 88.965 | 84.259 | 105.259 | 44.48 | **0.56x** (baseline `0.42x`, +28% faster) |
| `rust_decimal` (`1.37.2`) | 49.783 | 48.089 | 55.042 | 24.89 | 1.00x (baseline) |

- Verified common stdout SHA-256: `3d0da5b89dfe19db270abada6e5ea031da0006e447090b5e4e684c4f1ba92f50`

#### Bench 3: Sort + Aggregate + Banker's Rounding (500,000 ops)

50,000 mixed-scale `Decimal` values × 10 rounds: in-place SoA `Decimal::sort` (vs Rust `Vec::sort_unstable`), `round_dp(2)` Banker's rounding on every element, and exact sum/min/median/max aggregation.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Speedup (vs `rust_decimal`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` | 74.391 | 70.460 | 86.665 | 148.78 | **0.76x** (baseline `0.37x`, **1.84× faster**) |
| `rust_decimal` (`1.37.2`) | 56.180 | 49.505 | 84.257 | 112.36 | 1.00x (baseline) |

- Verified common stdout SHA-256: `d83ad65315d2b3ccb76bcd83b313962ed82c2f7511163a437f3549806d38f7dd`

### Performance & Compiler Analysis

- **Key Optimizations Applied**:
  - **Zero-allocation SoA `Decimal::sort`**: Extracts `Array[Decimal]` into contiguous `FixedArray`s with a 64-bit order-preserving IEEE-754 sortable key (`±8 ULP` safety margin with exact 96-bit `cmp_raw` tie-break) and call-free inner partition loops, eliminating ~16M per-comparison heap allocations and lifting Bench 3 from `0.37x` → **`0.76x`** (`1.84×–2.07×` faster).
  - **Zero module-level constant array RC overhead**: Replaced all module-level `POWERS_10`, `POWERS_10_U64`, `POW_OV_*`, `POWERS_10_F64`, and `DIGIT_CHARS` lookups with pure scalar functions (`pow10_u32`, `pow10_u64`, `pow_ov_hi`, `pow_ov_lo64`, `pow10_f64`, `digit_byte_to_char`).
  - **Zero hot-path tuple / `val struct` intermediate allocations**: Inlined 64×64→128-bit multiplies (`cmp_magnitude`, `add_sub_core`, `checked_mul`), split `checked_div` into dedicated `checked_div_32` / `checked_div_64` / `checked_div_96` + `finish_div_unscale` (with 64-bit fast paths and division-free `mod 5` early exit), and added compact 18-char `parse_radix10_slice` and division-free `to_string` 32/64-bit direct-`Bytes` formatting — bringing Parse + Format to **`1.00x`** of `rust_decimal`.
- **Honest Remaining Compiler Bottlenecks**:
  1. **`val struct Decimal` & `Result[Decimal, DecimalError]` heap boxing**: In `pionc 0.1.0`, every `val struct` construction and `Result[Decimal, DecimalError]` return allocates on the heap (`pion_alloc_uninit` + RC), accounting for ~50% of Bench 2 (`Billing Arithmetic`, 18 heap allocs/tx) and ~35% of A4 (`checked_div`) runtime.
  2. **Software 64×64→128-bit multiply**: Pion does not yet expose a native `UInt128` / `mulq` / `umulh` intrinsic, so cross-scale widening and 96×96 multiplication use 32-bit schoolbook products.
- **Compiler Workaround (`pionc` `--release`)**:
  - `Decimal::round`, `Decimal::round_dp`, and `Decimal::rescale` route through an internal integer-tagged `round_dp_code(self, dp, code, clear_zero_sign)` helper rather than referencing fieldless `RoundingStrategy` variants directly. Verified with `wasm_smoke` passing byte-identically across Native debug, Native `--release`, Wasm32 debug, and Wasm32 `--release`.
