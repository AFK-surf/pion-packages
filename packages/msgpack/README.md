# `msgpack` — Pure Pion MessagePack Codec (Spec + Timestamp ext `-1`)

Pure Pion, zero-C-dependency implementation of the complete **MessagePack binary serialization specification** (on par with Rust [`rmp`/`rmpv`](https://github.com/3Hren/msgpack-rust) and Go [`vmihailenco/msgpack/v5`](https://github.com/vmihailenco/msgpack)):

- **Complete wire format**: `nil`, `bool`, positive/negative `fixint`, `uint8`/`16`/`32`/`64`, `int8`/`16`/`32`/`64`, `float32`/`64` (exact IEEE-754 bit preservation including `±0.0`, `±Inf`, and NaN payloads), `fixstr`/`str8`/`16`/`32`, `bin8`/`16`/`32`, `fixarray`/`array16`/`32`, `fixmap`/`map16`/`32`, `fixext1`/`2`/`4`/`8`/`16`, `ext8`/`16`/`32`, and **standard Timestamp extension type `-1` (32/64/96-bit)**.
- **Strict spec & security**: rejects reserved marker `0xC1`, enforces strict RFC 3629 UTF-8 validation on `str`, validates Timestamp nanoseconds (`0..=999_999_999`) on both decode and `Ext(-1, ...)` encode, canonical shortest encoding by default (with optional strict `require_canonical` decoding), streaming prefix decoding (`decode_prefix` / `decode_prefix_at` / `decode_all`) without O(N²) buffer copies, pre-allocation OOM bomb defense, `Int64` overflow-checked encoding (clean `MaxBytesExceeded` error above 2 GiB), `max_depth` / `max_items` / `max_bytes` limits, keyed SipHash-1-3 HashDoS-resistant O(n) duplicate map key rejection, and stack-safe iterative traversal (`0` SIGSEGV on 100,000-layer nested inputs in `validate`).
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
  pub max_depth : Int              // default: 512 (honoured by both decode and validate; see Depth & Limit Semantics below)
  pub max_items : Int              // default: 1048576 (per-frame in decode_all)
  pub max_bytes : Int              // default: 67108864 (64 MiB, per single str/bin/ext payload)
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

## Depth, Limit & Runtime Semantics

- **Default `max_depth = 512`**: `DecodeOptions::default()` and `DecodeOptions::strict()` default to `512` (more conservative than Rust `rmpv`'s `1024` and Go's unbounded decoder) to leave ~2× call-stack safety margin on Wasm32 (`node --stack-size=900..984` drops recursive `Map` chains up to ~1,052 levels).
- **Explicit `max_depth` & Pion RC drop stack limits**: `decode`, `decode_prefix`, `decode_all`, and `validate` (including with `reject_duplicate_keys: true`) all strictly honour the caller's `opts.max_depth`. Note that while traversal itself is iterative above depth 64, **Pion's compiler-generated RC destructor is recursive**: very deep `MsgpackValue` trees will hit the runtime stack limit on drop (Native ~51.5k array levels; Wasm32 ~1,052 map / ~1,680 array levels under Node's default 984 KB stack). For 100,000-layer validation without building a tree, use zero-tree `validate` (0 SIGSEGV on both Native and Wasm32).
- **`max_items` & `max_bytes` scope**: `max_items` bounds total items decoded per single value (in `decode_all`, the counter resets per frame rather than across the entire stream). `max_bytes` bounds each individual `str`, `bin`, or `ext` payload length rather than the cumulative stream size.
- **Timestamp `Ext(-1, ...)` roundtrip & >2 GiB encode**: `encode` validates `Ext(-1, payload)` (must be 4, 8, or 12 bytes with `nsec < 1_000_000_000`) and accumulates total encoded size in `Int64`, returning `Err(MaxBytesExceeded(2147483647))` if output exceeds Pion's 32-bit `Bytes` capacity (0 SIGABRT / 0 Wasm trap).

## Compliance & Security Test Suite (27 package tests + 11 red-team audit tests)

- **`suite_test.pion` (15 tests)**: Full port of all 15 official [`msgpack/msgpack-test-suite`](https://github.com/kawanet/msgpack-test-suite) YAML suites (`10.nil`, `11.bool`, `12.binary`, `20.number-positive`, `21.number-negative`, `22.number-float`, `23.number-bignum`, `30.string-ascii`, `31.string-utf8`, `32.string-emoji`, `40.array`, `41.map`, `42.nested`, `50.timestamp`, `60.ext`), verifying decoding of every non-canonical/canonical wire form and canonical shortest re-encoding.
- **`spec_test.pion` (7 tests)**: All 256 first-byte markers (confirming reserved `0xC1` is rejected with `InvalidMarker(0xC1, 0)`), every signed/unsigned integer boundary (`Int64::MIN..UInt64::MAX`), `require_canonical` rejection of overlong encodings, IEEE-754 `float32`/`float64` exact bit-level roundtrip (`±0.0`, `±Inf`, quiet/signaling/negative NaNs with payloads, subnormals), `str` vs `bin` distinction & strict RFC 3629 UTF-8 rejection (overlong, surrogates, `> U+10FFFF`, truncated), signed ext types `-128..=127` & Timestamp 32/64/96-bit validation (rejecting `nsec >= 1_000_000_000` and invalid lengths), and multi-frame streaming via `decode_prefix` / `decode_prefix_at` / `decode_all`.
- **`security_test.pion` (5 tests)**: Day-1 red-team defenses — 5-byte OOM pre-allocation bombs (`array32`/`map32`/`str32`/`bin32`/`ext32` with `0xFFFFFFFF`) rejected before any allocation, 100,000-layer nested arrays & maps (`0` SIGSEGV under `decode_default`, explicit `max_depth: 2048`, and zero-tree iterative `validate`, plus iterative `decode`/`encode` roundtrip at depth 512), exact `max_depth`/`max_items`/`max_bytes` boundaries, truncated inputs for all marker types, trailing bytes rejection, and keyed SipHash-1-3 O(n) duplicate map key rejection.

## Benchmarks

Run the 3-way head-to-head benchmark (`Pion Native --release` vs `Rust rmpv 1.3.1 --release` vs `Go vmihailenco/msgpack/v5 v5.4.1`, strictly interleaved, mandatory stdout SHA-256 verification):

```sh
sh packages/msgpack/bench/run_bench.sh
```

> **Benchmark Methodology Note**: The official `bench/` suite compares dynamic-tree codecs (`MsgpackValue` vs Rust `rmpv::Value` via `read_value` vs Go `any` / `map[string]any` with `SetSortMapKeys(true)`). For full transparency, the **Idiomatic & Adversarial Comparison** section below also reports head-to-head numbers against idiomatic Go typed structs (`struct` + `msgpack` tags) and zero-copy Rust `rmpv::decode::read_value_ref`, where those specialized paths outperform dynamic-tree decoding/encoding.

### Workload 1: Nested RPC/Telemetry Decode (40 × 2,000 = 80,000 records)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `67 B` (`sha256:988b268324c5f308...`) | Input: `13655320 B` | Ops: `80000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs go_vmihailenco) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **71.684** | 70.188 | 75.939 | **190.49** | **896.06** | 7.66 MiB | **1.65x** |
| `rust_rmpv` | 108.612 | 95.365 | 113.814 | 125.73 | 1357.65 | 6.62 MiB | 1.09x |
| `go_vmihailenco` | 118.004 | 114.465 | 122.632 | 115.72 | 1475.05 | 15.77 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `988b268324c5f308408ec8f8c6f2b855114df4704c463f0240a64a64e491c1df`._

### Workload 2: Nested RPC/Telemetry Encode (50,000 records)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `48 B` (`sha256:76af0c6f9e92027a...`) | Ops: `50000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs go_vmihailenco) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **36.296** | 35.673 | 38.111 | **725.92** | **1.78 MiB** | **1.30x** |
| `rust_rmpv` | 37.416 | 35.998 | 38.195 | 748.32 | 1.98 MiB | 1.26x |
| `go_vmihailenco` | 47.108 | 46.527 | 48.053 | 942.17 | 11.25 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `76af0c6f9e92027a3c488da154c32a0c13b5bba73a8aec34daa7ed9e2d7377f2`._

### Workload 3: Large `bin` + `str` + `array` Decode (4 × ~16 MiB = ~64 MiB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `57 B` (`sha256:556ed267b0263a59...`) | Input: `64811276 B`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs go_vmihailenco) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 29.840 | 28.826 | 31.210 | 2171.92 | **37.64 MiB** | 0.81x |
| `rust_rmpv` | 25.849 | 24.355 | 28.997 | 2507.25 | 40.06 MiB | 0.94x |
| `go_vmihailenco` | **24.195** | 23.763 | 26.274 | **2678.71** | 67.84 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `556ed267b0263a59107e7938427c471ffe6938cdf76b06c916625136a90d7ed1`._

### Idiomatic & Adversarial Comparison (from `audit/run_audit.sh`, SHA-256 verified)

| Workload | Pion | Go (idiomatic struct / `any`) | Rust `rmpv::read_value` | Rust `rmpv::read_value_ref` |
| --- | ---: | ---: | ---: | ---: |
| W1 decode-rpc 80k (vs Go typed struct) | 69.9 ms | **61.9 ms** (struct, Go 1.13×) / 119.9 ms (`any`) | 96.6 ms | — |
| W1 RPC generic tree walk (80k) | 62.5 ms | 116.1 ms (`any`) | 94.6 ms | **54.5 ms** (Rust ref 1.15×) |
| W2 encode-rpc 50k (vs Go typed struct) | 39.4 ms | **27.8 ms** (struct, Go 1.42×) / 48.0 ms (`any`) | 37.6 ms | — |
| 1M `int` array ×5 | 82.9 ms | 120.9 ms (`any`) | 60.9 ms | **53.2 ms** |
| 1M `float32` array ×5 | 69.9 ms | 112.6 ms (`any`) | 59.6 ms | **48.6 ms** |
| 1M `float64` array ×5 | 81.5 ms | 117.8 ms (`any`) | 63.3 ms | **54.7 ms** |
| Depth 100 × 10k ×5 (`decode_iter` path) | 396.1 ms | **241.5 ms** (`any`) | 530.7 ms | 397.3 ms |
| 10k-key `str` map ×50 (dup reject) | **43.8 ms** | 62.2 ms (Go map) | 121.1 ms | — |
| Streaming 256 KiB / 65,536 frames (`decode_prefix_at`) | 14.9 ms (2.3 MiB RSS) | 22.5 ms | **12.8 ms** | — |
| Streaming 2 MiB / 524,288 frames (`decode_prefix_at`) | 52 ms (5.7 MiB RSS) | 103 ms | **36 ms** | — |
| HashDoS 262,144 crafted uint64 keys (`reject_duplicate_keys`) | **30 ms** (random: 34 ms) | 55 ms (Go map) | 57 ms (HashSet) | — |

### Performance Notes

- **Dynamic Tree vs Typed / Zero-Copy**: Against dynamic-tree baselines (`rmpv::read_value` and Go `any`), Pion leads W1 RPC decode (`1.65x` vs Go, `1.52x` vs Rust) and W2 RPC encode (`1.30x` vs Go, `1.03x` vs Rust) with the lowest Peak RSS. Against specialized paths, Go typed structs remain faster (`1.13x` decode / `1.42x` encode) and Rust zero-copy `read_value_ref` remains faster on borrowed trees (`1.15x`) and dense 1M numeric arrays (`1.44–1.56x`).
- **Adversarial & Streaming Hardening**: Keyed SipHash-1-3 eliminates HashDoS (`262,144` adversarial uint64 keys in `30 ms`, matching random-key speed and beating Go/Rust). Disabling whole-buffer `to_string()` caching in `decode_prefix_at` eliminates the `<= 2 MiB` O(N²) streaming cliff (`2 MiB / 524k` frames in `52 ms` at `5.7 MiB` RSS). Compact single-stack `IterFrame` reduces depth-100 decoding to `396 ms` (matching `rmpv::read_value_ref`).
- **Workload 3 (64 MiB Large Payload Decode)**: Pion sustains **>2.17 GB/s** with the lowest Peak RSS (**37.64 MiB** vs Rust 40.06 MiB and Go 67.84 MiB), trailing Rust (`0.87x`) and Go (`0.81x`) because Pion performs full scalar RFC 3629 UTF-8 validation over 12.5 MiB of multi-byte UTF-8 text (whereas Go `msgpack` skips UTF-8 validation and Rust uses SIMD `std::str::from_utf8`).
