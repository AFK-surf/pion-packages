# `resp` — Pure Pion Redis RESP2 & RESP3 Codec + Cluster Router

Pure Pion, zero-dependency, zero-`World` Sans-IO implementation of the complete **Redis Serialization Protocol (RESP2 & RESP3)** and **Redis Cluster CRC16-XMODEM slot router**, portable across **Native** and **Wasm32**.

## Features

- **Complete RESP2 & RESP3 Wire Format (all 15 frame types)**:
  - RESP2: `SimpleString (+)`, `SimpleError (-)`, `Integer (:)`, `BulkString ($)`, `Array (*)`, plus lossless `NullBulk ($-1)` and `NullArray (*-1)`.
  - RESP3: `Null (_)`, `Boolean (#t/#f)`, `Double (,)` (including `inf`, `-inf`, `nan`), `BigNumber (()`, `BulkError (!)`, `VerbatimString (=)`, `Map (%)`, `Set (~)`, `Attribute (|)` (out-of-band metadata attached to the following target frame, including nested and streamed attributes), and `Push (>)`.
  - **Streamed Chunked Types**: streamed `BulkString` (`$?` + `;len\r\n...\r\n;0\r\n`), streamed `Array` (`*?`), `Map` (`%?`), `Set` (`~?`), and `Attribute` (`|?`) terminated by `.\r\n`.
  - **Redis Inline Commands**: `decode_inline` and opt-in top-level inline support in `StreamDecoder` (`set_allow_inline(true)` / `with_allow_inline(true)`) strictly matching Redis `sdssplitargs` double-quote (`\n`, `\r`, `\t`, `\b`, `\a`, `\xHH`, `\"`, `\\`), single-quote (`\'` only; `\\` stays literal), mid-token quotes, and C `isspace()` (`\v`, `\f`) rules, capped by `max_inline_len` (default 64 KiB).
- **Sans-IO Streaming Pipeline (`StreamDecoder`)**:
  - Incremental **O(n)** parser with persistent frame stack, streamed-bulk accumulator, and inline scan cursor (handles arbitrary TCP fragmentation down to 1-byte trickle and coalesced multi-frame pipelines via `next_frame()` / `drain_frames()`).
  - Client-safe by default (`allow_inline = false`); rejects non-RESP prefix bytes immediately.
  - Automatic prefix compaction and buffer shrinking (`0` memory leak across long-lived connections).
- **DoS & Security Hardening (`RespLimits`)**:
  - Explicit `max_depth`, `max_bulk_len`, `max_collection_len`, `max_buffer_bytes`, `max_total_nodes`, and `max_inline_len` (64 KiB default).
  - Overflow-safe length bounds checks (safe even with `Int::max` limits on Native and Wasm32) and pre-allocation OOM bomb defense.
  - Iterative stack-safe decoding and encoding (`0` call-stack recursion, `0` stack overflow on 100,000-layer nested payloads on both Native and Wasm32).
  - Strict CRLF validation (rejects lone `\r` / `\n` in `SimpleString` / `SimpleError` on both decode and encode), strict RESP3 `Double` grammar, and `+`/`-` `BigNumber` support.
- **Command Builder & Redis Cluster Routing**:
  - `encode_command`, `encode_command_strings`, and reusable `PipelineBuilder` with direct ASCII integer formatting.
  - Single-pass **CRC16-XMODEM (`poly 0x1021`, init `0x0000`)** and Redis `{hash_tag}` slot calculation `key_slot` / `key_slot_string` (`0..16383`, strictly honoring Redis's first-`{` to first-`}` non-empty tag rule with zero `String -> Bytes` allocation).
  - `MOVED <slot> <host>:<port>` / `ASK <slot> <host>:<port>` parser (IPv4, hostname, bracketed/unbracketed IPv6, and Redis 7 `unknown-endpoint` empty host `:<port>`), `CLUSTER SLOTS` topology parser (supporting Redis 7 `Null` preferred endpoints and rejecting overlapping/duplicate slot ranges), and O(1) 16384-slot `ClusterRouter`.

## API Overview

```pion
import "resp"

// Core frame model & limits
pub enum RespFrame {
  SimpleString(String)
  SimpleError(String)
  Integer(Int64)
  BulkString(Bytes)
  Array(Array[RespFrame])
  Null
  NullBulk
  NullArray
  Boolean(Bool)
  Double(Double)
  BigNumber(String)
  BulkError(Bytes)
  VerbatimString(String, Bytes)
  Map(Array[(RespFrame, RespFrame)])
  Set(Array[RespFrame])
  Attribute(Array[(RespFrame, RespFrame)], RespFrame)
  Push(Array[RespFrame])
}

pub val struct RespLimits {
  pub max_depth : Int           // default: 128
  pub max_bulk_len : Int        // default: 67108864 (64 MiB)
  pub max_collection_len : Int  // default: 1048576
  pub max_buffer_bytes : Int    // default: 67108928 (64 MiB + 64 B framing overhead)
  pub max_total_nodes : Int     // default: 2097153 (1 + 2 * max_collection_len)
  pub max_inline_len : Int      // default: 65536 (64 KiB, Redis PROTO_INLINE_MAX_SIZE)
}

// Codec & streaming
pub fn encode(frame : RespFrame) -> Result[Bytes, RespError]
pub fn decode(data : Bytes, limits : RespLimits) -> Result[RespFrame, RespError]
pub fn decode_default(data : Bytes) -> Result[RespFrame, RespError]
pub fn decode_prefix(data : Bytes, offset : Int, limits : RespLimits) -> Result[(RespFrame, Int), RespError]
pub fn decode_inline(line : Bytes, limits : RespLimits) -> Result[Array[Bytes], RespError]
pub struct StreamDecoder { ... } // feed, next_frame, drain_frames, buffered_len, buffer_capacity, reset

// Command & pipeline encoding
pub fn encode_command(args : Array[Bytes]) -> Bytes
pub fn encode_command_strings(args : Array[String]) -> Bytes
pub struct PipelineBuilder { ... } // new, with_capacity, push_command, push_command_strings, push_frame, finish, clear

// Redis Cluster CRC16-XMODEM & routing
pub fn crc16_xmodem(data : Bytes) -> Int
pub fn crc16_xmodem_slice(data : Bytes, start : Int, len : Int) -> Int
pub fn crc16_xmodem_string(s : String) -> Int
pub fn key_slot(key : Bytes) -> Int
pub fn key_slot_string(key : String) -> Int
pub fn parse_cluster_redirect(err_msg : String) -> Option[ClusterRedirect]
pub fn parse_cluster_redirect_frame(frame : RespFrame) -> Option[ClusterRedirect]
pub fn parse_cluster_slots(frame : RespFrame) -> Result[Array[SlotRange], RespError]
pub struct ClusterRouter { ... } // new, from_slots, update_from_slots, apply_moved, route_slot, route_key, covered_slots
```

## Verification

```sh
sh scripts/verify.sh packages/resp
```

- **Package Test Suite**: 15/15 tests pass across `resp_spec_test.pion`, `command_cluster_test.pion`, and `security_test.pion`.
- **Red-Team Audit Suite**: `STRICT=1 sh packages/resp/audit/run_audit.sh` — **1,044/1,044 PASS** (`0 FAIL`, exit `0`), 4-mode byte-identical, 900k-iteration fuzz 0 mismatches / 0 panics, flat RSS, linear O(n) complexity.

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`1174dd56e80e3a8cb9b4b9e5af7de931f01fcba76205e3b137a27694bc773b7f`):

```sh
pionc run packages/resp/wasm_smoke
pionc run --release packages/resp/wasm_smoke
pionc run --target wasm32 packages/resp/wasm_smoke
pionc run --target wasm32 --release packages/resp/wasm_smoke
```

## Head-to-Head Benchmarks (`Linux x86_64`, `warmup=1`, `rounds=5`)

Run via `sh packages/resp/bench/run_bench.sh` against Rust **`redis-protocol 6.0.0`** (`--release`, locked `Cargo.lock`), strictly interleaved via `scripts/bench_compare.py` with mandatory byte-for-byte stdout SHA-256 verification.

### W1: 200,000 Mixed RESP3 Responses Streaming Decode (137B chunks)

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` | Input: `5,731,182 B` | Ops: `200,000` | Stdout SHA-256: `b0e9a02f61dab29da01cc60bc45f762ab23d89118c6a46803b38bedc5d2989f9`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Speedup (vs `rust_redis_protocol`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | **118.462** | **100.196** | **224.948** | **48.38** | **592.31** | **1.66x** |
| `rust_redis_protocol` (`6.0.0`, `--release`) | 197.165 | 158.589 | 299.159 | 29.07 | 985.82 | 1.00x (baseline) |

### W2: 500,000 Pipelined Commands Encode + Decode Roundtrip (`SET`/`GET`/`HSET`/`MGET`)

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` | Ops: `500,000` | Stdout SHA-256: `378354e9ec08373e4055fba30435922b5f828c3dee13f0d6a793834c941816c0`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Speedup (vs `rust_redis_protocol`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | **250.361** | **223.280** | **341.631** | **500.72** | **2.37x** |
| `rust_redis_protocol` (`6.0.0`, `--release`) | 592.635 | 577.731 | 656.320 | 1185.27 | 1.00x (baseline) |

### W3: 2,000,000 Cluster `key_slot` (`{hash_tag}`) + 500,000 `MOVED`/`ASK` Redirect Parse

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` | Ops: `2,000,000` | Stdout SHA-256: `dcb9d7eab4bae30aa394d5aab73c52a40d4545a0665a28eca07c9b94285ebf00`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Speedup (vs `rust_redis_protocol`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 94.540 | 82.153 | 112.237 | 47.27 | 0.88x |
| `rust_redis_protocol` (`6.0.0`, `--release`) | **83.262** | **65.493** | **94.079** | **41.63** | **1.00x (baseline)** |

> **Honest Performance Analysis**:
> - **W1 (1.66x vs Rust `redis-protocol`, 2.08x faster than baseline)**: Zero-boxing `StreamDecoder::drain_fast` + `push_scalar_fast` (handling top-level scalars, Clinger exact fast-path Doubles, and flat Arrays/Sets/Pushes/Maps without `Result`/`Option`/`DecodeContainer` heap boxing), native `Bytes::slice` (`memcpy`, zero `memset`), and zero-alloc `find_crlf_strict_idx` push Pion cleanly ahead of Rust's `decode_bytes_mut`.
> - **W2 (2.37x vs Rust `redis-protocol`, 3.64x faster than baseline)**: Single-reservation hoisted `PipelineBuilder::push_command` + zero-`memset` `ByteBuf::to_bytes` + fast `StreamDecoder::feed` (`Bytes::slice` on empty buffer) + zero-container flat-Array decoding outperform Rust by over 2.3x.
> - **W3 (0.88x vs Rust `redis-protocol`, 1.62x faster than baseline)**: Single-pass table-free GF(2) CRC16-XMODEM (`x^16 + x^12 + x^5 + 1`, zero global RC retain/release, zero table bounds checks) and zero-tuple inlined `parse_cluster_redirect` cut runtime from `153.1 ms` to `94.5 ms`; the remaining ~11 ms gap is due to heap-boxed `Option[ClusterRedirect]` enum allocations (500k calls) vs Rust's stack-allocated `Option<Redirect>`.

## Formal Verification (Lean 4)

The core RESP2/RESP3 wire-prefix & inline-space classifiers, signed 64-bit decimal overflow guard, `RespLimits` framing-slack invariants, CRC16-XMODEM (`poly 0x1021`) bit-step, and Redis Cluster 16384-slot routing guards (`src/types.pion`, `src/decode.pion`, `src/cluster.pion`) are annotated with `#verify`, extracted directly via `pionc extract-lean` (`1` type, `12` functions, `0` externals), and formally verified in Lean 4 with **24 theorems**, **0 `sorry`**, **0 `admit`**, **0 custom `axiom`**, **0 `bv_decide`**, **0 `native_decide`**, and **44/44** native-vs-Lean differential cross-checks:

- `proofs/RespProofs/WireAndLimits.lean` (12 theorems): `RespLimits::default` / `with_max_inline_len` invariants, `effective_max_buffer_bytes` non-shrinking / overflow-free ≥16 B framing slack / idempotency, exact 15-byte `is_resp_prefix` characterization and strict disjointness from both C `isspace()` (`is_inline_space`) and ASCII alphanumerics, `hex_nibble` bounds & `'A'..'F'` case-insensitivity, and exact signed 64-bit `i64_parse_will_overflow` iff characterization.
- `proofs/RespProofs/ClusterAndCrc16.lean` (12 theorems): `crc16_bit_step` `[0, 65535]` totality, `0 → 0`, `0x8000 → 0x1021` generator polynomial exactness, and `2 * crc` linearity for `0 ≤ crc < 32768`; `crc16_to_slot` `[0, 16383]` validity / `crc % 16384` / idempotency; `is_valid_cluster_slot` & `is_valid_slot_range` exact iff characterizations, boundary checks, endpoint validity, and singleton equivalence.
- `proofs/CheckAxioms.lean`: verifies all 24 theorems depend only on Lean's standard axioms (`propext`, `Classical.choice`, `Quot.sound`).
- `proofs/EvalDiff.lean`: 44-case Lean vs native Pion differential cross-check (`diff -u` zero differences).

```sh
LEAN_NUM_THREADS=2 LEAN_MEM_LIMIT=8192 bash packages/resp/proofs/run_proofs.sh
```
