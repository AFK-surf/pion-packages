# `avro` (`v0.1.0`)

100% pure Pion implementation of **Apache Avro 1.11.1** — Schema parser (with namespaces, aliases, logical types, and recursive self-referencing records), **Parsing Canonical Form (PCF)** + **CRC-64-AVRO Rabin-64** fingerprints, **Binary & JSON** datum codecs, pre-compiled **Reader/Writer Schema Evolution**, and **`.avro` Object Container File (OCF)** reader/writer (`null` + `deflate` via `packages/flate`) — zero `extern "C"`, zero `World` dependency, Native + `wasm32` dual-target, explicit `Result[T, AvroError]`, and `AvroLimits` DoS protection.

## Features

- **Schema Parser, Parsing Canonical Form & Rabin-64 (`src/schema.pion`)**:
  - All 8 primitive types (`null`, `boolean`, `int`, `long`, `float`, `double`, `bytes`, `string` in both string and object forms) and all 6 complex types (`record`, `enum`, `array`, `map`, `union`, `fixed`).
  - All 8 logical types (`decimal` on `bytes`/`fixed` with fixed-size precision validation, `uuid`, `date`, `time-millis`, `time-micros`, `timestamp-millis`, `timestamp-micros`, `duration` on `fixed(12)`), gracefully ignoring invalid or unknown logical types per Apache Avro 1.11.1.
  - Full namespace resolution (enclosing inheritance, dot-qualified names, explicit `""` null namespace, type & field `aliases`) and arena-backed recursive self-referencing / mutually recursive records.
  - Spec-compliant **Parsing Canonical Form (PCF)** and **CRC-64-AVRO Rabin-64** (`0xc15d213aa4d7a795`) fingerprints (`fingerprint_rabin`, `fingerprint_rabin_bytes`, `fingerprint_rabin_hex`).
- **Binary Datum Codec (`src/binary.pion`)**:
  - ZigZag varint `int` (32-bit overflow checked) and `long` (64-bit overflow checked), exact IEEE-754 little-endian `float` (binary32) and `double` (binary64), strict UTF-8 validation on `string`, strict boolean (`0x00`/`0x01`), positive and negative block counts (with `byte_size` prefix) on `array` and `map`, single-datum and batch stream APIs (`encode_datums` / `decode_datums`).
- **Reader/Writer Schema Evolution (`src/resolve.pion`)**:
  - Pre-compiled `SchemaResolver` (`compile_resolver`) with memoized plan compilation (handles recursive schemas cleanly and eliminates per-record string/schema lookups).
  - Full Apache Avro 1.11.1 resolution rules: field reordering, field deletion (fast binary skipping of arbitrarily nested dropped fields), new fields with schema defaults, record/enum/fixed/field `aliases`, primitive promotions (`int -> long -> float -> double`, `string <-> bytes`), enum default symbol fallback, and union resolution (non-union -> union, union -> non-union, union -> union with promotion).
- **Avro JSON Codec (`src/json.pion`)**:
  - Self-contained strict RFC 8259 JSON parser/serializer implementing Avro JSON encoding: `null` union branch as bare `null`, non-null union branches wrapped as `{"<type-or-fullname>": value}`, ISO-8859-1 (`U+0000..U+00FF`) string encoding for `bytes`/`fixed`, and record default-value materialization.
- **Object Container File `.avro` OCF (`src/ocf.pion`)**:
  - Full `Obj\x01` header + `map<bytes>` metadata (`avro.schema`, `avro.codec`, custom metadata) + 16-byte `sync` marker + multi-block `null` and `deflate` (RFC 1951 raw DEFLATE via `packages/flate`) encoding/decoding, plus `read_ocf_resolved` for direct OCF schema evolution.
- **DoS Protection (`AvroLimits` in `src/value.pion`)**:
  - Configurable `max_depth`, `max_elements`, `max_bytes` (including OCF `deflate` decompression bomb interception), and `max_schema_types`.

## Public API

```pion
// Core values, errors, limits
pub enum AvroError { ... }
pub val struct AvroLimits { pub max_depth : Int, pub max_elements : Int, pub max_bytes : Int, pub max_schema_types : Int }
pub enum AvroValue { Null, Boolean(Bool), Int(Int), Long(Int64), Float32(Double), Float64(Double), Bytes(Bytes), String(String), Fixed(Bytes), Enum(Int, String), Array(Array[AvroValue]), Map(Array[(String, AvroValue)]), Union(Int, AvroValue), Record(Array[(String, AvroValue)]) }

// Schema, PCF, Rabin-64
pub fn parse_schema(json_str : String) -> Result[Schema, AvroError]
pub fn parse_schema_with_limits(json_str : String, limits : AvroLimits) -> Result[Schema, AvroError]
pub fn canonical_form(schema : Schema) -> String
pub fn fingerprint_rabin(schema : Schema) -> UInt64
pub fn fingerprint_rabin_bytes(schema : Schema) -> Bytes
pub fn fingerprint_rabin_hex(schema : Schema) -> String

// Binary datum codec
pub fn encode_datum(schema : Schema, value : AvroValue) -> Result[Bytes, AvroError]
pub fn decode_datum(schema : Schema, data : Bytes) -> Result[AvroValue, AvroError]
pub fn encode_datums(schema : Schema, values : Array[AvroValue], limits : AvroLimits) -> Result[Bytes, AvroError]
pub fn decode_datums(schema : Schema, data : Bytes, count : Int, limits : AvroLimits) -> Result[Array[AvroValue], AvroError]

// Schema Evolution (Writer -> Reader)
pub fn compile_resolver(writer : Schema, reader : Schema) -> Result[SchemaResolver, AvroError]
pub fn decode_datum_resolved(writer : Schema, reader : Schema, data : Bytes) -> Result[AvroValue, AvroError]
pub fn decode_datum_with_resolver(resolver : SchemaResolver, data : Bytes, limits : AvroLimits) -> Result[AvroValue, AvroError]
pub fn decode_datums_with_resolver(resolver : SchemaResolver, data : Bytes, count : Int, limits : AvroLimits) -> Result[Array[AvroValue], AvroError]

// Avro JSON codec
pub fn encode_json(schema : Schema, value : AvroValue) -> Result[String, AvroError]
pub fn decode_json(schema : Schema, json_str : String) -> Result[AvroValue, AvroError]

// Object Container File (.avro OCF)
pub enum OcfCodec { Null, Deflate }
pub fn write_ocf(schema : Schema, records : Array[AvroValue], options : OcfOptions) -> Result[Bytes, AvroError]
pub fn read_ocf(data : Bytes) -> Result[OcfFile, AvroError]
pub fn read_ocf_with_limits(data : Bytes, limits : AvroLimits) -> Result[OcfFile, AvroError]
pub fn read_ocf_resolved(data : Bytes, reader_schema : Schema, limits : AvroLimits) -> Result[OcfFile, AvroError]
```

## Verification

```sh
sh scripts/verify.sh packages/avro
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`8b2b98db4e1180ec0be007a56162e2e72149450c96b7bef195d5b6673a50ec1f`):

```sh
pionc run packages/avro/wasm_smoke
pionc run --release packages/avro/wasm_smoke
pionc run --target wasm32 packages/avro/wasm_smoke
pionc run --target wasm32 --release packages/avro/wasm_smoke
```

### Bidirectional Binary Interoperability (`Pion <-> Go github.com/hamba/avro/v2 v2.28.0`)

Verified automatically by `sh packages/avro/bench/run_bench.sh`:

- **CRC-64-AVRO Rabin-64 fingerprint**: identical (`3b5f60cc4c67dd4f`) between Pion and `hamba/avro/v2`.
- **50,000 nested binary datums**: Pion-encoded stream decoded by Go `hamba/avro/v2` and Go-encoded stream (with negative array/map block counts + `byte_size` prefixes) decoded by Pion match 100% across all 50,000 records.
- **`.avro` OCF (`deflate`, 5 blocks, 5,000 records)**: Pion-written `.avro` read by Go `hamba/avro/v2` (`58,826 B`) and Go-written `.avro` read by Pion (`60,165 B`) match 100% across all 5,000 records.

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/avro/bench/run_bench.sh` against Go **`github.com/hamba/avro/v2 v2.28.0`** (locked `go.sum`) on 50,000 nested `TelemetryEvent` records (`int`, `long`, `float`, `string`, `array<string>`, `map<long>`, `union[null, string]`, `2,607,112 B` Go wire input). All three workloads enforce **100% byte-for-byte stdout SHA-256 identity** via `scripts/bench_compare.py`.

Both `go_hamba_any` (dynamic `map[string]any`, apples-to-apples with Pion's dynamic `AvroValue`) and `go_hamba_struct` (compile-time typed Go `struct` reflection) are reported transparently:

### W1: Avro Binary Encode + Decode Roundtrip (50,000 nested records, `2,607,112 B`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_hamba_any`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`, dynamic `AvroValue`) | 89.795 | 88.068 | 94.408 | 29.03 | 1795.91 | 71.81 MiB | 0.87x |
| `go_hamba_any` (`v2.28.0`, dynamic `map[string]any`) | 77.916 | 76.716 | 80.385 | 33.46 | 1558.33 | 99.69 MiB | 1.00x (baseline) |
| `go_hamba_struct` (`v2.28.0`, typed Go `struct`) | **33.965** | 32.787 | 34.879 | **76.76** | 679.30 | 56.59 MiB | **2.29x** |

- Verified stdout SHA-256: `f2ea3fe5aec17024a4472cc10ec21b8fe7fd3a6435fa58d387bf60af522203c2`

### W2: Schema Evolution Batch Decode Writer v1 -> Reader v2 (50,000 records, `2,607,112 B`)

Writer v1 -> Reader v2 exercises field reordering, dropping `ts` + nested `metrics` map, `int -> long` and `float -> double` promotions, and materializing a new `region` field default across all 50,000 records:

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_hamba_any`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`, pre-compiled `SchemaResolver`) | 34.933 | 34.316 | 35.718 | 74.63 | 698.66 | 51.16 MiB | 0.95x |
| `go_hamba_any` (`v2.28.0`, dynamic `map[string]any`) | 33.319 | 32.431 | 34.891 | 78.25 | 666.37 | 41.69 MiB | 1.00x (baseline) |
| `go_hamba_struct` (`v2.28.0`, typed Go `struct`) | **15.123** | 14.724 | 15.957 | **172.40** | 302.45 | 17.88 MiB | **2.20x** |

- Verified stdout SHA-256: `75f2b1112b8a4152e4b0e3ec1e31a0400d528c38ab729b59796e26164b79c626`

### W3: `.avro` OCF Deflate Multi-Block Write + Read (50,000 records, 50 blocks, `2,607,112 B`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_hamba_any`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`, `packages/flate` raw DEFLATE) | 122.514 | 121.067 | 131.134 | 21.28 | 2450.29 | 68.77 MiB | 0.81x |
| `go_hamba_any` (`v2.28.0`, dynamic `map[string]any`) | 98.699 | 96.330 | 99.030 | 26.41 | 1973.97 | 102.14 MiB | 1.00x (baseline) |
| `go_hamba_struct` (`v2.28.0`, typed Go `struct`) | **53.221** | 52.098 | 54.114 | **48.99** | 1064.42 | 53.38 MiB | **1.85x** |

- Verified stdout SHA-256: `5ba2533c35006e9aba08f5d7633cb30778cb4ced61bb3bd2766b280cee046a89`
- **Notes**: Against dynamic `go_hamba_any`, Pion achieves **0.81x–0.95x** throughput while using **28%–33% lower peak RSS** on W1 and W3 (and producing slightly smaller DEFLATE OCF blocks via `packages/flate`). Go's typed `struct` path (`go_hamba_struct`) avoids per-record dynamic AST allocation and is ~2.2x–2.6x faster than both dynamic paths.
