# `protobuf` — Pure Pion Protocol Buffers v2/v3 Codec, `.proto` Parser, Dynamic Reflection & Proto3 JSON

Pure Pion implementation of **Protocol Buffers v2/v3** with zero C / `protoc` dependencies, zero `World` dependency, and full Native + Wasm32 compatibility — benchmarked head-to-head against **Rust `prost` (`0.13.5`, `--release`)** and **Go `google.golang.org/protobuf` (`v1.36.6`, `protowire`)**.

## Features

- **Zero-Copy Wire Format Codec (`WireReader` / `WireWriter`)**:
  - Strict 1..10-byte varint codec (rejects `>10` bytes or 10th byte `> 0x01`), 10-byte sign-extended negative `int32`, ZigZag `sint32`/`sint64`, little-endian `fixed32`/`sfixed32`/`float` (bit-exact IEEE-754 binary32) and `fixed64`/`sfixed64`/`double`.
  - Length-delimited `bytes` (zero-copy `read_bytes_range()`), strict UTF-8 `string` validation (rejecting overlong encodings, UTF-16 surrogates, `>U+10FFFF`, and truncated sequences), packed repeated fields, and iterative StartGroup/EndGroup pairing.
  - Tag validation (`1..536870911`, rejecting `0`, unknown wire types `6`/`7`, and optional reserved range `19000..19999` enforcement).
- **`.proto` v2/v3/Edition 2023 Schema Lexer, Validator & Lexical-Scope Linker (`parse_schema` / `parse_schemas`)**:
  - Supports `syntax = "proto2"|"proto3"`, `edition = "2023"`, `package`, `import [public|weak]`, `option` (including string-aware `{ ... }` aggregates), nested `message`/`enum`/`extend`, proto2 `group` fields, `oneof`, `map<K, V>`, `optional`/`required`/`repeated`, `reserved` ranges/names, field options (`[packed = ...]`, `[json_name = ...]`, `[default = ...]`), octal/hex integer literals with overflow checking, full `\xHH`/`\OOO`/`\uHHHH`/`\UHHHHHHHH` string escapes, and `//` / `/* */` comments.
  - Full `protoc`-compatible lexical-scope type linking (innermost-to-outermost, no message/enum shadowing) with O(1) linked descriptor dispatch, built-in Well-Known Types (`Timestamp`, `Duration`, `Wrappers`, `Struct`, `Value`, `ListValue`, `Empty`, `Any`, `FieldMask`, `DescriptorProto`), and `parse_schemas` multi-file linking.
  - Semantic validation: rejects invalid/reserved/duplicate field numbers & names, JSON name conflicts, proto3 `required` / missing enum `0`, unaliased duplicate enum values, unresolved types, out-of-range defaults, duplicate `package`, invalid map keys, and nesting ≥ 32.
- **Dynamic Reflection (`DynamicMessage`)**:
  - 100% iterative (explicit heap stack) schema-driven `decode_dynamic` / `encode_dynamic` without `protoc` code generation.
  - Typed getters (`get_int32`, `get_int64`, `get_uint32`, `get_uint64`, `get_bool`, `get_float`, `get_double`, `get_string`, `get_bytes`, `get_enum`, `get_message`, `get_list`, `get_map`) and `set_field` / `set_field_by_name` (enforcing `oneof` exclusivity).
  - Dual-compatibility packed + unpacked repeated decoding, O(N) in-place submessage merge semantics, O(1) last-wins map deduplication, proto2 `required` field checking and non-strict UTF-8 string compatibility, and **byte-exact lossless unknown field roundtrip** (preserving raw bytes including non-minimal varints and nested groups).
- **Proto3 Canonical JSON (`to_proto3_json`)**:
  - 100% iterative serialization in descriptor field order, `lowerCamelCase` field names (respecting `json_name`), explicit presence for proto3 `optional`/oneof and proto2 fields, `emit_defaults` (`EmitUnpopulated`), WKT JSON mappings (RFC 3339 `Timestamp`, `Duration`, unwrapped `Wrappers`, `Struct`/`Value`/`ListValue`, `Empty`, `FieldMask`), 64-bit integer stringification, standard Base64 for `bytes`, exact shortest IEEE-754 binary32 `float` formatting, enum name mapping, `"NaN"`/`"Infinity"`/`"-Infinity"`, and RFC 8259 string escaping.
- **Day-1 DoS & Security Hardening (`DecodeOptions`)**:
  - Default limits: `max_depth = 100` (hard-capped at 400 for cross-target RC-drop safety), `max_fields = 100000`, `max_bytes = 64 MiB`, `strict_utf8 = true` (proto3).
  - Iterative decode/encode/JSON and group skipping reject 50,000-level nested StartGroup / submessage payloads cleanly without stack overflow or Wasm32 trap.
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

## Compliance & Red-Team Test Suite (29 unit + 44 audit tests)

- **`wire_test.pion` (9 tests)**: Official Protobuf encoding guide vectors (`Test1`..`Test4`), 1..10-byte varints, negative 10-byte `int32`, ZigZag `sint32`/`sint64`, IEEE-754 LE `float`/`double` & fixed32/64, tag boundary `1..536870911` & reserved `19000..19999`, nested StartGroup/EndGroup skipping, packed `sint64`/`double`, and multibyte UTF-8.
- **`schema_test.pion` (4 tests)**: Full proto3 and proto2 schema parsing (nested messages/enums, oneof, map, options, reserved, comments), multi-file `parse_schemas` cross-file linking, plus rejection of invalid/reserved/duplicate field numbers and illegal map keys.
- **`dynamic_test.pion` (8 tests)**: Full scalar + nested + repeated + map + oneof roundtrip, mixed packed/unpacked repeated decode, oneof exclusivity & empty-value roundtrip, nested submessage merge, byte-exact lossless unknown field preservation (including non-minimal varints and groups), WKT JSON mappings (`Duration`, `Wrappers`, `Empty`), and Proto3 Canonical JSON.
- **`redteam_test.pion` (8 tests)**: 50,000-level nested StartGroup and nested message depth bombs, `0x7FFFFFFF` / `u64::MAX` length-delimited OOM defense, invalid UTF-8 rejection, 11-byte and 10th-byte `> 0x01` varint overflow, truncated primitives, orphan/unclosed/mismatched groups, unknown wire types 6/7, field number 0, and `max_fields`/`max_bytes` enforcement.
- **`audit/redteam_test.pion` (44 tests)**: 31 red-team differential regression tests + 13 control tests verified against Go `google.golang.org/protobuf` v1.36.6 (`dynamicpb` / `protojson` / `protocompile`) and Rust `prost` 0.13.5.
- **`wasm_smoke/`**: Verified exit code `0` across all 4 modes (Native debug, Native release, Wasm32 debug via Node `pion_wasm_rt.mjs`, Wasm32 release via Node `pion_wasm_rt.mjs`).

## Head-to-Head Benchmarks

Run the reproducible benchmark suite (`Pion Native --release` vs `Rust prost 0.13.5 --release --locked` vs `Go google.golang.org/protobuf v1.36.6`, pinned via `Cargo.lock` & `go.sum`, strictly interleaved `--warmup 1 --rounds 5`, mandatory byte-for-byte stdout SHA-256 verification):

```sh
sh packages/protobuf/bench/run_bench.sh
```

### Workload 1: OTel/RPC Span Batch Decode (100,000 nested spans)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `49 B` (`sha256:34e1a7ae7c6c0e93...`) | Input: `24398500 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_prost) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 115.646 | 105.939 | 117.208 | 210.97 | 1156.46 | 2.84 MiB | 0.47x |
| `rust_prost` | 54.200 | 53.464 | 56.525 | 450.15 | 542.00 | 2.50 MiB | 1.00x (baseline) |
| `go_protobuf` | 43.227 | 41.709 | 44.736 | 564.43 | 432.27 | 11.08 MiB | 1.25x |

_SHA-256 verified identical across all implementations and rounds: `34e1a7ae7c6c0e93a5a1f83cf1fd2189afaa5b72fe069f883c626f060ef81072`._

### Workload 2: OTel/RPC Span Batch Encode (100,000 nested spans)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `60 B` (`sha256:f534611558427306...`) | Input: `24398500 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_prost) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 39.001 | 37.328 | 39.826 | 625.60 | 390.00 | 3.12 MiB | 0.47x |
| `rust_prost` | 18.271 | 17.146 | 19.970 | 1335.40 | 182.71 | 3.19 MiB | 1.00x (baseline) |
| `go_protobuf` | 16.866 | 16.352 | 17.339 | 1446.63 | 168.66 | 5.28 MiB | 1.08x |

_SHA-256 verified identical across all implementations and rounds: `f534611558427306246af382838fa2f7e0e94a5cd99be4ae7544f44d17f0d829`._

### Workload 3: Packed Repeated `sint64` + `double` Roundtrip (8 x 400k values, ~19.1 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `71 B` (`sha256:092a2171c4c9da7c...`) | Input: `19110272 B` | Ops: `3200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_prost) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 24.728 | 23.752 | 25.456 | 772.83 | 7.73 | 13.02 MiB | 0.91x |
| `rust_prost` | 22.519 | 21.396 | 22.737 | 848.62 | 7.04 | 10.97 MiB | 1.00x (baseline) |
| `go_protobuf` | 21.188 | 21.007 | 21.988 | 901.95 | 6.62 | 24.34 MiB | 1.06x |

_SHA-256 verified identical across all implementations and rounds: `092a2171c4c9da7cefae2d64dd1822b00965fb3fa8fdadd0ba65bfc34b547dce`._

### DynamicMessage vs Go `dynamicpb` Head-to-Head (`audit/run_audit.sh` Section 6, SHA-256 verified)

| Workload | Pion Median (ms) | Go `dynamicpb` Median (ms) | Pion Speedup (vs Go) | Peak RSS (Pion / Go) |
| --- | ---: | ---: | ---: | ---: |
| OTel spans (2,000 × 20): Dynamic Decode | 127.275 | 205.256 | **1.61x** | 3.80 / 16.97 MiB |
| OTel spans (2,000 × 20): Dynamic Decode + Proto3 JSON | 270.435 | 440.897 | **1.63x** | 3.97 / 18.03 MiB |
| OTel spans (2,000 × 20): Dynamic Decode + Re-encode | 217.606 | 365.582 | **1.68x** | 3.89 / 16.98 MiB |
| `map<string,int64>` 50k distinct entries (×5): Decode + JSON | 113.330 | 194.031 | **1.71x** | 22.16 / 40.88 MiB |
| `map<string,int64>` 50k distinct entries (×5): Roundtrip | 107.533 | 90.999 | 0.85x | 20.02 / 27.48 MiB |
| `merge_unknown_10000` (40 KB adversarial merge) | 11.038 | 11.732 | **1.06x** | 3.91 / 9.66 MiB |
| `bigschema_2000` (2,000-message schema, 20k `Leaf`) | 16.762 | 34.043 | **2.03x** | 12.97 / 28.28 MiB |

### Honest Performance Analysis

- **Strengths**:
  - **Dynamic Reflection (`DynamicMessage` / `to_proto3_json`)**: Pion outperforms Go `google.golang.org/protobuf` `dynamicpb` / `protojson` by **1.61x–2.03x** across OTel span decode/JSON/roundtrip, 50k-entry map JSON, and 2,000-message large schema decode, with **4–4.5x lower peak RSS** (3.8–3.9 MiB vs 17–18 MiB).
  - On tight numeric packed arrays (**Workload 3**), Pion achieves **772.8 MB/s (7.73 ns/op)** — **0.91x of Rust `prost --release`** and **0.86x of Go `protowire`**, with nearly half Go's peak RSS (13.02 MiB vs 24.34 MiB).
  - Adversarial O(N) in-place submessage merge (`merge_unknown_10000`) beats Go `dynamicpb` (**1.06x**), and 4,000-message schema decode runs in `0.01s` vs Go's `0.04s`.
- **Gaps & Root Causes**:
  - On hand-coded nested Span encode/decode (**Workloads 1 & 2**), Pion achieves **0.47x of Rust `prost`** (`211.0 MB/s` decode, `625.6 MB/s` encode; single-pass length-prefixed encode improved Span encode by ~24% over sub-writer copy). The remaining gap is due to per-field heap allocations for `Span` / `KeyValue` / `SpanEvent` structs and `Array` push growth in Pion's runtime, plus byte-by-byte copy loops in `WireWriter` where Rust/Go lower to SIMD `memcpy`.
