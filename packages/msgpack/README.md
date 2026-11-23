# `msgpack` — Pure Pion MessagePack Codec (Spec + Timestamp ext `-1`)

Pure Pion, zero-C-dependency implementation of the complete **MessagePack binary serialization specification** (on par with Rust [`rmp`/`rmpv`](https://github.com/3Hren/msgpack-rust) and Go [`vmihailenco/msgpack/v5`](https://github.com/vmihailenco/msgpack)):

- **Complete wire format**: `nil`, `bool`, positive/negative `fixint`, `uint8`/`16`/`32`/`64`, `int8`/`16`/`32`/`64`, `float32`/`64` (exact IEEE-754 bit preservation including `±0.0`, `±Inf`, and NaN payloads), `fixstr`/`str8`/`16`/`32`, `bin8`/`16`/`32`, `fixarray`/`array16`/`32`, `fixmap`/`map16`/`32`, `fixext1`/`2`/`4`/`8`/`16`, `ext8`/`16`/`32`, and **standard Timestamp extension type `-1` (32/64/96-bit)**.
- **Strict spec & security**: rejects reserved marker `0xC1`, enforces strict RFC 3629 UTF-8 validation on `str`, validates Timestamp nanoseconds (`0..=999_999_999`), canonical shortest encoding by default (with optional strict `require_canonical` decoding), streaming prefix decoding (`decode_prefix` / `decode_prefix_at` / `decode_all`), pre-allocation OOM bomb defense, `max_depth` / `max_items` / `max_bytes` limits, O(n) hash-table duplicate map key rejection, and stack-safe iterative traversal (`0` SIGSEGV on 100,000-layer nested inputs).
- **Portable**: zero `World` dependency, Native (`arm64_apple` / Linux) and `wasm32` (debug & release) verified.

## API Overview

```pion
import "msgpack"

// Data model
pub enum MsgpackValue {
  Nil
  Bool(Bool)
  Int(Int64)              // Signed integer (-2^63 .. 2^63 - 1)
  UInt(UInt64)            // Unsigned integer (0 .. 2^64 - 1)
  Float32(Double)         // IEEE-754 binary32 (exact 32-bit pattern preserved)
  Float64(Double)         // IEEE-754 binary64 (exact 64-bit pattern preserved)
  Str(String)             // Valid RFC 3629 UTF-8 string
  Bin(Bytes)              // Arbitrary raw binary bytes
  Array(Array[MsgpackValue])
  Map(Array[(MsgpackValue, MsgpackValue)])
  Ext(Int, Bytes)         // Extension (signed 8-bit type in -128..=127, payload)
  Timestamp(Int64, Int)   // Standard ext -1: (seconds, nanoseconds in 0..=999_999_999)
}

// Options
pub val struct DecodeOptions {
  pub max_depth : Int              // default: 128 (tree decode hard-capped at 1024; validate supports arbitrary depth)
  pub max_items : Int              // default: 1048576
  pub max_bytes : Int              // default: 67108864 (64 MiB)
  pub reject_duplicate_keys : Bool // default: false (true in DecodeOptions::strict())
  pub require_canonical : Bool     // default: false (true in DecodeOptions::strict())
  pub decode_timestamp : Bool      // default: true
  pub allow_trailing_bytes : Bool  // default: false
}

pub val struct EncodeOptions {
  pub compact_floats : Bool        // default: false (true in EncodeOptions::compact())
}

// Entrypoints
pub fn decode(data : Bytes, opts : DecodeOptions) -> Result[MsgpackValue, MsgpackError]
pub fn decode_default(data : Bytes) -> Result[MsgpackValue, MsgpackError]
pub fn decode_prefix(data : Bytes, opts : DecodeOptions) -> Result[(MsgpackValue, Int), MsgpackError]
pub fn decode_prefix_at(data : Bytes, offset : Int, opts : DecodeOptions) -> Result[(MsgpackValue, Int), MsgpackError]
pub fn decode_all(data : Bytes, opts : DecodeOptions) -> Result[Array[MsgpackValue], MsgpackError]
pub fn validate(data : Bytes, opts : DecodeOptions) -> Result[Unit, MsgpackError]
pub fn encode(value : MsgpackValue, opts : EncodeOptions) -> Result[Bytes, MsgpackError]
pub fn encode_default(value : MsgpackValue) -> Result[Bytes, MsgpackError]
pub fn msgpack_equals(lhs : MsgpackValue, rhs : MsgpackValue) -> Bool
pub fn error_message(err : MsgpackError) -> String
```

## Compliance & Security Test Suite (27 test groups)

- **`suite_test.pion` (15 tests)**: Full port of all 15 official [`msgpack/msgpack-test-suite`](https://github.com/kawanet/msgpack-test-suite) YAML suites (`10.nil`, `11.bool`, `12.binary`, `20.number-positive`, `21.number-negative`, `22.number-float`, `23.number-bignum`, `30.string-ascii`, `31.string-utf8`, `32.string-emoji`, `40.array`, `41.map`, `42.nested`, `50.timestamp`, `60.ext`), verifying decoding of every non-canonical/canonical wire form and canonical shortest re-encoding.
- **`spec_test.pion` (7 tests)**: All 256 first-byte markers (confirming reserved `0xC1` is rejected with `InvalidMarker(0xC1, 0)`), every signed/unsigned integer boundary (`Int64::MIN..UInt64::MAX`), `require_canonical` rejection of overlong encodings, IEEE-754 `float32`/`float64` exact bit-level roundtrip (`±0.0`, `±Inf`, quiet/signaling/negative NaNs with payloads, subnormals), `str` vs `bin` distinction & strict RFC 3629 UTF-8 rejection (overlong, surrogates, `> U+10FFFF`, truncated), signed ext types `-128..=127` & Timestamp 32/64/96-bit validation (rejecting `nsec >= 1_000_000_000` and invalid lengths), and multi-frame streaming via `decode_prefix` / `decode_prefix_at` / `decode_all`.
- **`security_test.pion` (5 tests)**: Day-1 red-team defenses — 5-byte OOM pre-allocation bombs (`array32`/`map32`/`str32`/`bin32`/`ext32` with `0xFFFFFFFF`) rejected before any allocation, 100,000-layer nested arrays & maps (`0` SIGSEGV under both `decode_default` and zero-tree iterative `validate`, plus iterative `decode`/`encode` roundtrip at depth 512), exact `max_depth`/`max_items`/`max_bytes` boundaries, truncated inputs for all marker types, trailing bytes rejection, and optional O(n) hash duplicate map key rejection (verified up to 2,001-key maps).

## Benchmarks

Run the 3-way head-to-head benchmark (`Pion Native --release` vs `Rust rmpv 1.3.1 --release` vs `Go vmihailenco/msgpack/v5 v5.4.1`, strictly interleaved, mandatory stdout SHA-256 verification):

```sh
sh packages/msgpack/bench/run_bench.sh
```

### Workload 1: Nested RPC/Telemetry Decode (40 × 2,000 = 80,000 records)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `67 B` (`sha256:988b268324c5f308...`) | Input: `13655320 B` | Ops: `80000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs go_vmihailenco) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **67.778** | 61.501 | 68.280 | **201.47** | **847.23** | 7.64 MiB | **1.64x** |
| `rust_rmpv` | 86.633 | 85.458 | 94.968 | 157.62 | 1082.91 | 6.62 MiB | 1.28x |
| `go_vmihailenco` | 111.301 | 108.084 | 114.387 | 122.69 | 1391.27 | 16.00 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `988b268324c5f308408ec8f8c6f2b855114df4704c463f0240a64a64e491c1df`._

### Workload 2: Nested RPC/Telemetry Encode (50,000 records)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `48 B` (`sha256:76af0c6f9e92027a...`) | Ops: `50000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs go_vmihailenco) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 34.053 | 32.811 | 42.999 | 681.05 | **1.78 MiB** | **1.37x** |
| `rust_rmpv` | **31.795** | 31.150 | 33.584 | **635.90** | 1.98 MiB | **1.47x** |
| `go_vmihailenco` | 46.602 | 43.521 | 47.938 | 932.05 | 11.84 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `76af0c6f9e92027a3c488da154c32a0c13b5bba73a8aec34daa7ed9e2d7377f2`._

### Workload 3: Large `bin` + `str` + `array` Decode (4 × ~16 MiB = ~64 MiB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `57 B` (`sha256:556ed267b0263a59...`) | Input: `64811276 B`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs go_vmihailenco) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 32.236 | 31.345 | 35.286 | 2010.53 | **37.62 MiB** | 0.90x |
| `rust_rmpv` | **27.502** | 25.553 | 27.998 | **2356.61** | 40.05 MiB | **1.06x** |
| `go_vmihailenco` | 29.030 | 25.936 | 30.026 | 2232.55 | 68.28 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `556ed267b0263a59107e7938427c471ffe6938cdf76b06c916625136a90d7ed1`._

### Performance Notes

- **Workload 1 (RPC Decode)**: Pion leads both Go (`1.64x`) and Rust `rmpv` (`1.28x`) at **201.5 MB/s** (`847 ns/op`) thanks to single-pass lazy `data.to_string()` string slicing for `<= 2 MiB` buffers and direct recursive decoding up to depth 64 without heap-frame allocations.
- **Workload 2 (RPC Encode)**: Pion beats Go (`1.37x`) with the lowest Peak RSS (**1.78 MiB** vs 11.84 MiB) via two-pass exact pre-allocation, while trailing Rust `rmpv` slightly (`0.93x`, 681 vs 636 ns/op) due to `rmpv`'s reusable `Vec<u8>` buffer across iterations versus Pion's fresh `Bytes::new(total)` per record.
- **Workload 3 (64 MiB Large Payload Decode)**: Pion sustains **>2.0 GB/s** with the lowest Peak RSS (**37.62 MiB** vs Rust 40.05 MiB and Go 68.28 MiB), trailing Rust (`0.85x`) and Go (`0.90x`) because Pion performs full scalar RFC 3629 UTF-8 validation over 12.5 MiB of multi-byte UTF-8 text (whereas Go `msgpack` skips UTF-8 validation and Rust uses SIMD `std::str::from_utf8`).
