# `uuid` — Pure Pion RFC 9562 UUID & Crockford Base32 ULID

Zero-dependency, pure-Pion implementation of **RFC 9562 UUID (v1 / v3 / v4 / v5 / v6 / v7 / v8 / Nil / Max)** and **Crockford Base32 ULID** (including monotonic generators), backed by zero-heap-allocation 128-bit `val struct` values and built-in RFC 1321 MD5 & FIPS 180-4 SHA-1.

## Features

- **128-bit value types (`val struct { hi : Int64, lo : Int64 }`)**:
  - `Uuid` and `Ulid` carry zero heap allocation when held by value.
  - Strict unsigned 128-bit lexicographical ordering (`compare`, `Uuid::sort`, `Ulid::sort`, `sort_u128_pairs_raw`, `sort_u128_pairs_fixed`) across all four sign quadrants (no signed `Int64` MSB-flip bug), with preallocated flat scratch buffers and O(n) duplicate/common-prefix fast-skip.
- **RFC 9562 UUID**:
  - Parsing (`Uuid::parse`, `Uuid::parse_slice`, `Uuid::parse_bytes`): hyphenated (36 B), simple (32 B), braced `{...}` (38 B), and URN `urn:uuid:...` (45 B), case-insensitive with strict length/separator/hex validation.
  - Formatting: `to_hyphenated`, `to_hyphenated_upper`, `to_simple`, `to_simple_upper`, `to_braced`, `to_braced_upper`, `to_urn`, `to_urn_upper`, plus zero-allocation buffer encoders `encode_hyphenated` / `encode_simple`.
  - Constructors: `nil()`, `max()`, `NAMESPACE_DNS` / `NAMESPACE_URL` / `NAMESPACE_OID` / `NAMESPACE_X500`, `new_v1`, `new_v3` (pure-Pion RFC 1321 MD5), `from_random_bytes_v4` / `new_v4_from_u64_pair`, `new_v5` (pure-Pion FIPS 180-4 SHA-1), `new_v6`, `new_v7` / `new_v7_from_parts`, `new_v8`, `V7Context` (RFC 9562 §6.2 Method 1 12-bit monotonic counter with explicit `SequenceOverflow`), and `V7Context42` (RFC 9562 §6.2 Method 2 42-bit monotonic counter with 0 ms drift at 100k+ same-ms bursts).
  - Inspection: variant-agnostic `version()` (aligned with Rust `uuid 1.29.3`), `version_num()`, `variant()`, `timestamp_ms()` (supports v1 / v6 Gregorian ticks and v7 Unix ms), `is_nil()`, `is_max()`, `from_bytes` / `to_bytes` / `from_u64_pair` / `as_u64_pair`.
- **Crockford Base32 ULID**:
  - 26-character Crockford Base32 encoding (canonical uppercase) and case-insensitive decoding (`Ulid::parse` / `Ulid::parse_slice` accept Crockford aliases `i`/`I`/`l`/`L` → `1`, `o`/`O` → `0`; `Ulid::parse_strict` / `Ulid::parse_slice_strict` reject `I`/`L`/`O` matching Rust `ulid 1.2.1`; both reject `u`/`U`, all invalid characters, and 128-bit overflow when the leading character `> '7'`).
  - `from_parts`, `timestamp_ms`, `random_parts`, `from_bytes` / `to_bytes`, `to_uuid` / `from_uuid`, `increment`, and `MonotonicUlid` (strictly +1 on the 80-bit random payload within the same millisecond; explicit `Err(UlidError::Overflow)` on 80-bit saturation without wrapping into the timestamp).
- **Dual-target**: Verified on Native (`arm64_apple`) and WebAssembly (`wasm32` via `packages/uuid/wasm_smoke` and full 8,594-case differential corpus).

## Verification

```sh
pionc fmt --check packages/uuid
pionc check --json packages/uuid
pionc test --json packages/uuid
pionc build --release --target wasm32 -o /tmp/uuid_wasm_smoke.wasm packages/uuid/wasm_smoke
node "$HOME/.pion/share/pion/pion_wasm_rt.mjs" /tmp/uuid_wasm_smoke.wasm
```

## Head-to-Head Benchmarks (Pion Native & Wasm32 vs Rust `uuid` 1.29.3 + `ulid` 1.2.1 `--release`)

Measured on `Darwin arm64` with `pionc 0.1.0 (arm64_apple, self-hosted)` (`AFK-surf/pion@69a0189d`) via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification). Both the **idiomatic typed API** (`Uuid::parse_slice`/`Ulid::parse_slice` + `Uuid::sort`/`Ulid::sort` + `encode_*` or `to_hyphenated()`/`to_string()`) and the **raw batch API** (`parse_*_lines_raw` + `sort_u128_pairs_raw` + `encode_*_raw`) are reported side by side.

### Bench 1: UUID Batch Parse + Unsigned 128-bit Sort + Format (500,000 UUIDs, 18.58 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_uuid`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_raw` (batch raw API) | 58.609 | 57.422 | 60.509 | 316.93 | 117.22 | 37.17 MiB | **0.73x** |
| `pion_typed_buf` (idiomatic + `encode_hyphenated`) | 81.613 | 77.261 | 83.555 | 227.60 | 163.23 | 37.17 MiB | **0.52x** |
| `pion_typed_str` (idiomatic + `to_hyphenated()`) | 95.766 | 92.492 | 96.617 | 193.96 | 191.53 | 37.17 MiB | **0.45x** |
| `rust_uuid` | 42.648 | 41.546 | 44.361 | 435.55 | 85.30 | 27.20 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `bd498b7cbd566a04855c18a2e04f7023b0eecd792506b74294c63ef0cfb86ba6`

### Bench 2: UUID v5 (SHA-1) + v7 Generation & Format (200,000 pairs)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_uuid`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_raw` (raw API) | 51.575 | 50.587 | 54.540 | 257.88 | 1.72 MiB | **0.66x** |
| `pion_typed_buf` (idiomatic + `encode_hyphenated`) | 54.142 | 53.770 | 58.134 | 270.71 | 1.72 MiB | **0.63x** |
| `pion_typed_str` (idiomatic + `to_hyphenated()`) | 66.239 | 61.882 | 66.744 | 331.19 | 1.73 MiB | **0.51x** |
| `rust_uuid` | 34.020 | 32.672 | 35.191 | 170.10 | 1.81 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `8fdf059e12772e0821eb03434f84da85c291fe48b992f8b125d99411f4e65eaf`

### Bench 3: ULID Batch Parse + Unsigned 128-bit Sort + Format (500,000 ULIDs, 13.50 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_ulid`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_raw` (batch raw API) | 51.307 | 48.936 | 53.095 | 263.12 | 102.61 | 29.33 MiB | **0.70x** |
| `pion_typed_buf` (idiomatic + `encode_bytes`) | 68.050 | 63.266 | 70.431 | 198.38 | 136.10 | 27.48 MiB | **0.53x** |
| `pion_typed_str` (idiomatic + `to_string()`) | 76.993 | 75.505 | 83.259 | 175.34 | 153.99 | 27.48 MiB | **0.46x** |
| `rust_ulid` | 35.727 | 35.293 | 38.685 | 377.87 | 71.45 | 22.38 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `2e742fca70b81a55e4a9533ada0a80b682b55aafbeee7f62b0b61e3c6b8a4c3a`

### Bench 4: Adversarial Sort Distributions (1,000,000 × 128-bit keys, Before vs After Flat-Scratch + Duplicate Fast-Skip)

| Distribution | `Uuid::sort` (before → after) | `sort_u128_pairs_raw` (before → after) | `Ulid::sort` (before → after) | Rust `sort_unstable` |
| --- | ---: | ---: | ---: | ---: |
| `random` | 92.4 → **91.2 ms (0.52x)** | 50.5 → **51.3 ms (0.92x)** | 90.4 → **90.5 ms (0.52x)** | 47.4 ms |
| `dup33` (every value ×33) | 190.0 → **74.5 ms (0.63x, 2.55x↑)** | 136.1 → **60.0 ms (0.78x, 2.27x↑)** | 195.9 → **77.6 ms (0.60x, 2.52x↑)** | 46.8 ms |
| `deep33` (33 share 15B prefix) | 224.6 → **105.2 ms (0.51x, 2.13x↑)** | 181.4 → **87.1 ms (0.62x, 2.08x↑)** | 230.9 → **105.8 ms (0.51x, 2.18x↑)** | 53.7 ms |
| `lastbyte` (only last byte differs) | 139.8 → **52.9 ms (0.77x, 2.64x↑)** | 54.0 → **41.2 ms (0.99x)** | 128.0 → **52.9 ms (0.77x, 2.42x↑)** | 40.7 ms |
| `signed` (`0x7FFF…/0x8000…`) | 148.8 → **83.3 ms (0.56x, 1.79x↑)** | 76.2 → **65.2 ms (0.72x)** | 151.1 → **83.9 ms (0.56x, 1.80x↑)** | 46.9 ms |
| `equal` (all 1M identical) | 106.1 → **44.0 ms (0.69x, 2.41x↑)** | 41.2 → **34.0 ms (0.89x)** | 106.3 → **43.2 ms (0.70x, 2.46x↑)** | 30.3 ms |

### Bench 5: Wasm32 Timings (Node `v24.22.2` + `pion_wasm_rt.mjs`, Baseline: Native Rust)

| Workload | `wasm_pion_raw` | `wasm_pion_typed` (`buf`) | `native_pion_raw` | `native_rust` |
| --- | ---: | ---: | ---: | ---: |
| UUID batch 500k | 132.768 ms (0.32x) | 157.947 ms (0.27x) | 57.297 ms (0.75x) | 42.748 ms |
| UUID v5+v7 200k | 100.029 ms (0.33x) | 102.257 ms (0.32x) | 50.635 ms (0.65x) | 33.056 ms |
| ULID batch 500k | 110.696 ms (0.36x) | 148.081 ms (0.27x) | 52.724 ms (0.75x) | 39.548 ms |

### Optimization & Compiler Notes (`AFK-surf/pion@69a0189d`)

1. **Zero-allocation SHA-1 tuple return (`sha1_single_block` → `(UInt64, UInt64)`)**: Eliminated 200k per-call `FixedArray` allocations in `Uuid::new_v5`, bringing idiomatic `pion_typed_buf` to **54.1 ms (0.63x)** vs `pion_raw` **51.6 ms (0.66x)**.
2. **Top-level read-only LUTs hoisted to local handles**: `hex_decode_lut`, `crockford_decode_lut`, `crockford_strict_lut`, and `crockford_enc_lut` replace branchy ASCII/Crockford arithmetic in `Uuid::parse_slice`, `Ulid::parse_slice`, and `Ulid::encode_bytes`, speeding up idiomatic ULID batch by **2.13x** (`144.7 ms → 68.1 ms`, `0.26x → 0.53x`) and idiomatic UUID batch by **1.35x** (`110.4 ms → 81.6 ms`, `0.37x → 0.52x`).
3. **Flat-scratch MSD radix sort with XOR common-prefix/equal fast-skip**: All four sort APIs reuse a single `16 × 768` scratch buffer and jump directly to the first differing byte (or return immediately when all keys in a bucket are equal), delivering **1.8–2.6x** speedups on duplicate-heavy and common-prefix adversarial distributions.
