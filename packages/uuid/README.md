# `uuid` — Pure Pion RFC 9562 UUID & Crockford Base32 ULID

Zero-dependency, pure-Pion implementation of **RFC 9562 UUID (v1 / v3 / v4 / v5 / v6 / v7 / v8 / Nil / Max)** and **Crockford Base32 ULID** (including monotonic generators), backed by zero-heap-allocation 128-bit `val struct` values and built-in RFC 1321 MD5 & FIPS 180-4 SHA-1.

## Features

- **128-bit value types (`val struct { hi : Int64, lo : Int64 }`)**:
  - `Uuid` and `Ulid` carry zero heap allocation when held by value.
  - Strict unsigned 128-bit lexicographical ordering (`compare`, `Uuid::sort`, `Ulid::sort`, `sort_u128_pairs_raw`) across all four sign quadrants (no signed `Int64` MSB-flip bug).
- **RFC 9562 UUID**:
  - Parsing (`Uuid::parse`, `Uuid::parse_slice`, `Uuid::parse_bytes`): hyphenated (36 B), simple (32 B), braced `{...}` (38 B), and URN `urn:uuid:...` (45 B), case-insensitive with strict length/separator/hex validation.
  - Formatting: `to_hyphenated`, `to_hyphenated_upper`, `to_simple`, `to_simple_upper`, `to_braced`, `to_braced_upper`, `to_urn`, `to_urn_upper`, plus zero-allocation buffer encoders `encode_hyphenated` / `encode_simple`.
  - Constructors: `nil()`, `max()`, `NAMESPACE_DNS` / `NAMESPACE_URL` / `NAMESPACE_OID` / `NAMESPACE_X500`, `new_v1`, `new_v3` (pure-Pion RFC 1321 MD5), `from_random_bytes_v4` / `new_v4_from_u64_pair`, `new_v5` (pure-Pion FIPS 180-4 SHA-1), `new_v6`, `new_v7` / `new_v7_from_parts`, `new_v8`, and `V7Context` (RFC 9562 §6.2 Method 1 monotonic counter with explicit `SequenceOverflow`).
  - Inspection: `version()`, `version_num()`, `variant()`, `timestamp_ms()`, `is_nil()`, `is_max()`, `from_bytes` / `to_bytes` / `from_u64_pair` / `as_u64_pair`.
- **Crockford Base32 ULID**:
  - 26-character Crockford Base32 encoding (canonical uppercase) and case-insensitive decoding (`i`/`I`/`l`/`L` → `1`, `o`/`O` → `0`, rejecting `u`/`U` and all invalid characters, and rejecting 128-bit overflow when the leading character `> '7'`).
  - `from_parts`, `timestamp_ms`, `random_parts`, `from_bytes` / `to_bytes`, `to_uuid` / `from_uuid`, `increment`, and `MonotonicUlid` (strictly +1 on the 80-bit random payload within the same millisecond; explicit `Err(UlidError::Overflow)` on 80-bit saturation without wrapping into the timestamp).
- **Dual-target**: Verified on Native (`arm64_apple`) and WebAssembly (`wasm32` via `packages/uuid/wasm_smoke`).

## Verification

```sh
pionc fmt --check packages/uuid
pionc check --json packages/uuid
pionc test --json packages/uuid
pionc build --release --target wasm32 -o /tmp/uuid_wasm_smoke.wasm packages/uuid/wasm_smoke
pionc run --target wasm32 packages/uuid/wasm_smoke
```

## Head-to-Head Benchmarks (Pion Native vs Rust `uuid` 1.29.3 + `ulid` 1.2.1 `--release`)

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte verification). Re-run with `sh packages/uuid/bench/run_bench.sh`.

### Bench 1: UUID Batch Parse + Unsigned 128-bit Sort + Format (500,000 UUIDs, 18.58 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | ops/s | Peak RSS | Speedup (vs `rust_uuid`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 51.829 | 49.241 | 68.147 | 358.39 | 103.66 | 9.65M | 37.16 MiB | **0.80x** |
| `rust_uuid` | 41.664 | 39.741 | 51.016 | 445.83 | 83.33 | 12.00M | 27.22 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `bd498b7cbd566a04855c18a2e04f7023b0eecd792506b74294c63ef0cfb86ba6`

### Bench 2: UUID v5 (SHA-1) + v7 Generation & Format (200,000 pairs)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | pairs/s | Peak RSS | Speedup (vs `rust_uuid`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 61.298 | 60.349 | 62.899 | 306.49 | 3.26M | 1.72 MiB | **0.52x** |
| `rust_uuid` | 31.758 | 29.614 | 34.230 | 158.79 | 6.30M | 1.83 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `8fdf059e12772e0821eb03434f84da85c291fe48b992f8b125d99411f4e65eaf`

### Bench 3: ULID Batch Parse + Unsigned 128-bit Sort + Format (500,000 ULIDs, 13.50 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | ops/s | Peak RSS | Speedup (vs `rust_ulid`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 45.825 | 44.963 | 47.124 | 294.60 | 91.65 | 10.91M | 29.33 MiB | **0.78x** |
| `rust_ulid` | 35.535 | 34.801 | 38.483 | 379.91 | 71.07 | 14.07M | 22.36 MiB | 1.00x (baseline) |

- Verified common stdout SHA-256: `2e742fca70b81a55e4a9533ada0a80b682b55aafbeee7f62b0b61e3c6b8a4c3a`

### Optimization & Compiler Ceiling Notes

Iterative profiling with `otool -tv` yielded a **2.1–3.6x** speedup over the initial Green implementation (Bench 1: `178.7 ms → 51.8 ms`, Bench 2: `128.4 ms → 61.3 ms`, Bench 3: `161.9 ms → 45.8 ms`) via:
1. Unrolled zero-allocation register-window SHA-1 (`sha1_single_block_into`) eliminating 400k `FixedArray` allocations in Bench 2;
2. Primitive-word raw batch APIs (`parse_uuid_lines_raw`, `parse_ulid_lines_raw`, `sort_u128_pairs_raw`, `encode_uuid_hyphenated_raw`, `encode_ulid_bytes_raw`) eliminating >1.5M cross-package `val struct`/`Result` box+RC cycles;
3. Local stack-scoped 128-entry hex/Crockford LUTs (eliminating 13M global-array `rc_inc`/`rc_dec` calls) and in-place 8-bit MSD American Flag radix sort.

The remaining gap to `rustc`/LLVM (`-O3`, thin LTO) reflects current `pionc 0.1.0 (arm64_apple, self-hosted)` codegen limits observed in disassembly:
- **Bounds-check elimination**: Every `Bytes`/`String`/`FixedArray` indexed load/store emits a runtime length load + compare + branch (`_pion_panic_oob`), totaling ~50–70M bounds checks per 500k batch, whereas LLVM eliminates all bounds checks on fixed-size `[u8; 36]`/`[u8; 26]` slices.
- **Register allocation in SHA-1**: The 21-live-variable unrolled 80-round SHA-1 kernel emits a 688-byte stack frame (`sub sp, sp, #0x2b0`) with register spills under `pionc`, whereas LLVM keeps all 21 32-bit state and message-schedule words in ARM64 GPRs with zero spills.
