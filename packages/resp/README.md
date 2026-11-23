# `resp` — Pure Pion Redis RESP2 & RESP3 Codec + Cluster Router

Pure Pion, zero-dependency, zero-`World` Sans-IO implementation of the complete **Redis Serialization Protocol (RESP2 & RESP3)** and **Redis Cluster CRC16-XMODEM slot router**, portable across **Native** and **Wasm32**.

## Features

- **Complete RESP2 & RESP3 Wire Format (all 15 frame types)**:
  - RESP2: `SimpleString (+)`, `SimpleError (-)`, `Integer (:)`, `BulkString ($)`, `Array (*)`, plus lossless `NullBulk ($-1)` and `NullArray (*-1)`.
  - RESP3: `Null (_)`, `Boolean (#t/#f)`, `Double (,)` (including `inf`, `-inf`, `nan`), `BigNumber (()`, `BulkError (!)`, `VerbatimString (=)`, `Map (%)`, `Set (~)`, `Attribute (|)` (out-of-band metadata attached to the following target frame, including nested and streamed attributes), and `Push (>)`.
  - **Streamed Chunked Types**: streamed `BulkString` (`$?` + `;len\r\n...\r\n;0\r\n`), streamed `Array` (`*?`), `Map` (`%?`), `Set` (`~?`), and `Attribute` (`|?`) terminated by `.\r\n`.
  - **Redis Inline Commands**: `decode_inline` and top-level inline support in `StreamDecoder` with Redis `sdssplitargs` double-quote (`\n`, `\r`, `\t`, `\b`, `\a`, `\xHH`, `\"`, `\\`) and single-quote (`\'`, `\\`) escaping.
- **Sans-IO Streaming Pipeline (`StreamDecoder`)**:
  - Handles arbitrary TCP fragmentation (down to 1-byte trickle) and coalesced multi-frame pipelines (`next_frame()` / `drain_frames()`).
  - Automatic prefix compaction and buffer shrinking (`0` memory leak across long-lived connections).
- **DoS & Security Hardening (`RespLimits`)**:
  - Explicit `max_depth`, `max_bulk_len`, `max_collection_len`, `max_buffer_bytes`, and `max_total_nodes`.
  - Pre-allocation OOM bomb defense (rejects oversized `$999999999` / `*999999999` headers before allocating).
  - Iterative stack-safe decoding and encoding (`0` call-stack recursion, `0` stack overflow on 20,000-layer nested payloads on both Native and Wasm32).
  - CRLF injection rejection in `SimpleString` / `SimpleError` encoding.
- **Command Builder & Redis Cluster Routing**:
  - `encode_command`, `encode_command_strings`, and reusable `PipelineBuilder` with direct ASCII integer formatting.
  - Standard **CRC16-XMODEM (`poly 0x1021`, init `0x0000`)** and Redis `{hash_tag}` slot calculation `key_slot` (`0..16383`, strictly honoring Redis's first-`{` to first-`}` non-empty tag rule).
  - `MOVED <slot> <host>:<port>` / `ASK <slot> <host>:<port>` parser (IPv4, hostname, and `[IPv6]:port`), `CLUSTER SLOTS` topology parser, and O(1) 16384-slot `ClusterRouter`.

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
  pub max_buffer_bytes : Int    // default: 67108864 (64 MiB)
  pub max_total_nodes : Int     // default: 1048576
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

- **Package Test Suite**: 13/13 tests pass across `resp_spec_test.pion`, `command_cluster_test.pion`, and `security_test.pion`.

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`1174dd56e80e3a8cb9b4b9e5af7de931f01fcba76205e3b137a27694bc773b7f`):

```sh
pionc run packages/resp/wasm_smoke
pionc run --release packages/resp/wasm_smoke
pionc run --target wasm32 packages/resp/wasm_smoke
pionc run --target wasm32 --release packages/resp/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/resp/bench/run_bench.sh` against Rust **`redis-protocol 6.0.0`** (`--release`, locked `Cargo.lock`), strictly interleaved via `scripts/bench_compare.py` with mandatory byte-for-byte stdout SHA-256 verification.

### W1: 200,000 Mixed RESP3 Responses Streaming Decode (137B chunks)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `5,731,182 B` | Ops: `200,000` | Stdout SHA-256: `b0e9a02f61dab29da01cc60bc45f762ab23d89118c6a46803b38bedc5d2989f9`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_redis_protocol`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | **57.031** | 55.652 | 58.544 | **100.49** | **285.16** | 12.69 MiB | **1.21x** |
| `rust_redis_protocol` (`6.0.0`, `--release`) | 68.720 | 68.008 | 73.192 | 83.40 | 343.60 | **7.70 MiB** | 1.00x (baseline) |

### W2: 500,000 Pipelined Commands Encode + Decode Roundtrip (`SET`/`GET`/`HSET`/`MGET`)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Ops: `500,000` | Stdout SHA-256: `378354e9ec08373e4055fba30435922b5f828c3dee13f0d6a793834c941816c0`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_redis_protocol`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 284.623 | 271.536 | 414.568 | 569.24 | 2.80 MiB | 0.82x |
| `rust_redis_protocol` (`6.0.0`, `--release`) | **233.693** | 225.732 | 257.232 | **467.39** | **2.33 MiB** | **1.00x (baseline)** |

### W3: 2,000,000 Cluster `key_slot` (`{hash_tag}`) + 500,000 `MOVED` Redirect Parse

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Ops: `2,000,000` | Stdout SHA-256: `97429500fae4ba83cf0e155836eba3777635bd7a1b3f90455971b8909b1d492c`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_redis_protocol`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 109.895 | 81.091 | 376.485 | 54.95 | **1.78 MiB** | 0.31x |
| `rust_redis_protocol` (`6.0.0`, `--release`) | **34.497** | 32.440 | 78.675 | **17.25** | 1.92 MiB | **1.00x (baseline)** |

> **Honest Performance Analysis**:
> - **W1 (1.21x faster than Rust `redis-protocol`)**: Pion's `StreamDecoder` scans directly in a compacted single-allocation byte buffer without cloning a `BytesMut` view per chunk, outperforming `redis-protocol` on fragmented 137B streaming RESP3 decode.
> - **W2 (0.82x)**: `redis-protocol` uses zero-copy `bytes::Bytes` reference-counted sub-slicing during batch decode, whereas Pion currently allocates owned `Bytes` slices per `BulkString`.
> - **W3 (0.31x)**: `parse_cluster_redirect` converts `String -> Bytes -> String` for owned `host` extraction on each `MOVED` parse (500k allocations), whereas Rust's zero-copy `&str` slicing avoids allocations on the redirect string.
