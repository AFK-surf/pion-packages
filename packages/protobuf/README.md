# `protobuf` — Pure Pion Protocol Buffers v2/v3 Codec, `.proto` Parser, Dynamic Reflection & Proto3 JSON

Pure Pion implementation of **Protocol Buffers v2/v3** with zero C / `protoc` dependencies, zero `World` dependency, and full Native + Wasm32 compatibility — benchmarked head-to-head against **Rust `prost` (`0.13.5`, `--release`)** and **Go `google.golang.org/protobuf` (`v1.36.6`, `protowire`)**.

## Features

- **Zero-Copy Wire Format Codec (`WireReader` / `WireWriter`)**:
  - Strict 1..10-byte varint codec (rejects `>10` bytes or 10th byte `> 0x01`), 10-byte sign-extended negative `int32`, ZigZag `sint32`/`sint64`, little-endian `fixed32`/`sfixed32`/`float` (bit-exact IEEE-754 binary32) and `fixed64`/`sfixed64`/`double`.
  - Length-delimited `bytes` (zero-copy `read_bytes_range()`), strict UTF-8 `string` validation (rejecting overlong encodings, UTF-16 surrogates, `>U+10FFFF`, and truncated sequences), packed repeated fields, and iterative StartGroup/EndGroup pairing.
  - Tag validation (`1..536870911`, rejecting `0`, unknown wire types `6`/`7`, and optional reserved range `19000..19999` enforcement).
- **`.proto` v2/v3 Schema Lexer & AST Parser (`parse_schema`)**:
  - Supports `syntax = "proto2"|"proto3"`, `package`, `import [public|weak]`, `option`, nested `message` and `enum`, `oneof`, `map<K, V>`, `optional`/`required`/`repeated`, `reserved` ranges/names, field options (`[packed = ...]`, `[json_name = ...]`, `[default = ...]`), `//` and `/* */` comments.
  - Rejects invalid/reserved field numbers (`0`, `19000..19999`, `>536870911`), duplicate tags, and illegal map key types (`float`, `double`, `bytes`, messages/enums).
- **Dynamic Reflection (`DynamicMessage`)**:
  - Schema-driven `decode_dynamic` / `encode_dynamic` without `protoc` code generation.
  - Typed getters (`get_int32`, `get_int64`, `get_uint32`, `get_uint64`, `get_bool`, `get_float`, `get_double`, `get_string`, `get_bytes`, `get_enum`, `get_message`, `get_list`, `get_map`) and `set_field` / `set_field_by_name` (enforcing `oneof` exclusivity).
  - Dual-compatibility packed + unpacked repeated decoding, submessage merge semantics, and **lossless unknown field roundtrip** (varint, fixed32, fixed64, length-delimited, and nested groups).
- **Proto3 Canonical JSON (`to_proto3_json`)**:
  - `lowerCamelCase` field names (respecting `json_name`), 64-bit integer stringification, standard Base64 for `bytes`, enum name mapping, `"NaN"`/`"Infinity"`/`"-Infinity"` float encoding, and RFC 8259 string escaping.
- **Day-1 DoS & Security Hardening (`DecodeOptions`)**:
  - Default limits: `max_depth = 100`, `max_fields = 100000`, `max_bytes = 64 MiB`, `strict_utf8 = true`.
  - Iterative group skipping and bounded message recursion reject 50,000-level nested StartGroup / submessage payloads cleanly without stack overflow or Wasm32 trap.
  - Immediate bounds check on length-delimited headers prevents OOM on crafted `len = 0x7FFFFFFF` / `u64::MAX` inputs.

## API Overview

```pion
import "protobuf"

// Wire codec
let w = protobuf::WireWriter::new()
w.write_int32_field(1, 150)
w.write_string_field(2, "testing")
let raw = w.to_bytes()

let r = protobuf::WireReader::new(raw)
let tag = r.read_tag()?
let val = r.read_int32()?

// Schema + Dynamic Reflection + Proto3 JSON
let schema = protobuf::parse_schema("syntax = \"proto3\"; message Item { int64 id = 1; string name = 2; }")?
let msg = protobuf::decode_dynamic_default(schema, "Item", raw)?
let reencoded = protobuf::encode_dynamic(schema, msg)?
let json = protobuf::to_proto3_json(schema, msg)?
```

## Compliance & Red-Team Test Suite (26 tests)

- **`wire_test.pion` (9 tests)**: Official Protobuf encoding guide vectors (`Test1`..`Test4`), 1..10-byte varints, negative 10-byte `int32`, ZigZag `sint32`/`sint64`, IEEE-754 LE `float`/`double` & fixed32/64, tag boundary `1..536870911` & reserved `19000..19999`, nested StartGroup/EndGroup skipping, packed `sint64`/`double`, and multibyte UTF-8.
- **`schema_test.pion` (3 tests)**: Full proto3 and proto2 schema parsing (nested messages/enums, oneof, map, options, reserved, comments) plus rejection of invalid/reserved/duplicate field numbers and illegal map keys.
- **`dynamic_test.pion` (6 tests)**: Full scalar + nested + repeated + map + oneof roundtrip, mixed packed/unpacked repeated decode, oneof exclusivity & empty-value roundtrip, nested submessage merge, lossless unknown field preservation (including groups), and Proto3 Canonical JSON.
- **`redteam_test.pion` (8 tests)**: 50,000-level nested StartGroup and nested message depth bombs, `0x7FFFFFFF` / `u64::MAX` length-delimited OOM defense, invalid UTF-8 rejection, 11-byte and 10th-byte `> 0x01` varint overflow, truncated primitives, orphan/unclosed/mismatched groups, unknown wire types 6/7, field number 0, and `max_fields`/`max_bytes` enforcement.
- **`wasm_smoke/`**: Verified exit code `0` across all 4 modes (Native debug, Native release, Wasm32 debug via Node `pion_wasm_rt.mjs`, Wasm32 release via Node `pion_wasm_rt.mjs`).

## Head-to-Head Benchmarks

Run the reproducible benchmark suite (`Pion Native --release` vs `Rust prost 0.13.5 --release` vs `Go 1.27 google.golang.org/protobuf v1.36.6`, strictly interleaved `--warmup 1 --rounds 5`, mandatory byte-for-byte stdout SHA-256 verification):

```sh
sh packages/protobuf/bench/run_bench.sh
```

### Workload 1: OTel/RPC Span Batch Decode (100,000 nested spans)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `49 B` (`sha256:34e1a7ae7c6c0e93...`) | Input: `24398500 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_prost) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 104.453 | 101.806 | 110.845 | 233.58 | 1044.53 | 2.84 MiB | 0.47x |
| `rust_prost` | 49.515 | 46.881 | 82.408 | 492.75 | 495.15 | 2.48 MiB | 1.00x (baseline) |
| `go_protobuf` | 39.840 | 37.833 | 42.180 | 612.42 | 398.40 | 11.33 MiB | 1.24x |

_SHA-256 verified identical across all implementations and rounds: `34e1a7ae7c6c0e93a5a1f83cf1fd2189afaa5b72fe069f883c626f060ef81072`._

### Workload 2: OTel/RPC Span Batch Encode (100,000 nested spans)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `60 B` (`sha256:f534611558427306...`) | Input: `24398500 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_prost) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 46.074 | 45.538 | 49.588 | 529.55 | 460.74 | 3.12 MiB | 0.43x |
| `rust_prost` | 19.738 | 18.491 | 20.209 | 1236.10 | 197.38 | 3.19 MiB | 1.00x (baseline) |
| `go_protobuf` | 17.975 | 17.355 | 19.273 | 1357.38 | 179.75 | 5.36 MiB | 1.10x |

_SHA-256 verified identical across all implementations and rounds: `f534611558427306246af382838fa2f7e0e94a5cd99be4ae7544f44d17f0d829`._

### Workload 3: Packed Repeated `sint64` + `double` Roundtrip (8 x 400k values, ~19.1 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `71 B` (`sha256:092a2171c4c9da7c...`) | Input: `19110272 B` | Ops: `3200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_prost) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 26.188 | 26.041 | 29.783 | 729.73 | 8.18 | 13.02 MiB | 0.94x |
| `rust_prost` | 24.515 | 22.855 | 25.552 | 779.54 | 7.66 | 10.97 MiB | 1.00x (baseline) |
| `go_protobuf` | 23.633 | 22.704 | 25.232 | 808.62 | 7.39 | 24.12 MiB | 1.04x |

_SHA-256 verified identical across all implementations and rounds: `092a2171c4c9da7cefae2d64dd1822b00965fb3fa8fdadd0ba65bfc34b547dce`._

### Honest Performance Analysis

- **Strengths**:
  - On tight numeric packed arrays (**Workload 3**), Pion achieves **729.7 MB/s (8.18 ns/op)** — **0.94x of Rust `prost --release`** and **0.90x of Go `protowire`**, while keeping peak RSS at **13.02 MiB** (nearly half of Go's 24.12 MiB).
  - Peak RSS on nested Span workloads is **2.84–3.12 MiB**, matching Rust `prost` (2.48–3.19 MiB) and 2–4x lower than Go (5.36–11.33 MiB).
- **Gaps & Root Causes**:
  - On nested message encode/decode (**Workloads 1 & 2**), Pion is currently **0.43x–0.47x of Rust `prost`** (`233.6 MB/s` decode, `529.6 MB/s` encode). The primary bottlenecks are per-field heap allocations for `Span` / `KeyValue` / `SpanEvent` structs and `Array` push growth in Pion's runtime, plus byte-by-byte copy loops in `WireWriter` where Rust/Go lower to SIMD `memcpy` and inline `prost::encoding` helpers.
