# `avro` (`v0.1.0`)

100% pure Pion implementation of **Apache Avro 1.11.1** — Schema parser (with namespaces, aliases, logical types, and recursive self-referencing records), **Parsing Canonical Form (PCF)** + **CRC-64-AVRO Rabin-64** fingerprints, **Binary & JSON** datum codecs, pre-compiled **Reader/Writer Schema Evolution**, and **`.avro` Object Container File (OCF)** reader/writer (`null` + `deflate` via `packages/flate`) — zero `extern "C"`, zero `World` dependency, Native + `wasm32` dual-target, explicit `Result[T, AvroError]`, and `AvroLimits` DoS protection.

## Features

- **Schema Parser, Parsing Canonical Form & Rabin-64 (`src/schema.pion`)**:
  - All 8 primitive types (`null`, `boolean`, `int`, `long`, `float`, `double`, `bytes`, `string` in both string and object forms), object-form named references (`{"type": "F"}`), empty unions (`[]`), and all 6 complex types (`record`, `enum`, `array`, `map`, `union`, `fixed`).
  - All 8 logical types (`decimal` on `bytes`/`fixed` with fixed-size precision validation, `uuid`, `date`, `time-millis`, `time-micros`, `timestamp-millis`, `timestamp-micros`, `duration` on `fixed(12)`), gracefully ignoring invalid or unknown logical types per Apache Avro 1.11.1.
  - Full namespace resolution (enclosing inheritance, dot-qualified names, explicit `""` null namespace, type & field `aliases`), O(1) hash-map symbol/field/branch deduplication, and arena-backed recursive self-referencing / mutually recursive records with iterative O(1)-host-stack parsing and serialization.
  - Spec-compliant **Parsing Canonical Form (PCF)** (`canonical_form`), full-metadata JSON serialization (`schema_to_json`), and **CRC-64-AVRO Rabin-64** (`0xc15d213aa4d7a795`) fingerprints (`fingerprint_rabin`, `fingerprint_rabin_bytes`, `fingerprint_rabin_hex`).
- **Binary Datum Codec (`src/binary.pion`)**:
  - Iterative O(1)-host-stack encoder, decoder, and skipper; ZigZag varint `int` (32-bit overflow checked) and `long` (64-bit overflow checked), exact IEEE-754 little-endian `float` (binary32) and `double` (binary64), strict UTF-8 validation on `string`, strict boolean (`0x00`/`0x01`), positive and negative block counts (with `byte_size` prefix) on `array` and `map`, single-datum and batch stream APIs (`encode_datums` / `decode_datums`).
- **Reader/Writer Schema Evolution (`src/resolve.pion`)**:
  - Pre-compiled `SchemaResolver` (`compile_resolver`) with memoized plan compilation and iterative O(1)-host-stack execution (`exec_resolve`).
  - Full Apache Avro 1.11.1 resolution rules: unqualified name matching (`a.X -> b.X`) + `aliases`, field reordering, field deletion (fast binary skipping of arbitrarily nested dropped fields), new fields with schema defaults, single-rounding `int/long -> float` promotion (`int64_to_float32_bits`), sNaN-quieting `float -> double` promotion, `string <-> bytes`, enum default symbol fallback, and union resolution.
  - **Strict UTF-8 policy on `bytes -> string` promotion**: unlike Java Avro / `hamba/avro/v2`, Pion validates RFC 3629 UTF-8 when promoting `bytes` to `string` and returns `Err(AvroError::InvalidUtf8(...))` on invalid byte sequences.
- **Avro JSON Codec (`src/json.pion`)**:
  - Self-contained strict RFC 8259 iterative JSON parser/serializer implementing Avro JSON encoding: `null` union branch as bare `null`, non-null union branches wrapped as `{"<type-or-fullname>": value}`, ISO-8859-1 (`U+0000..U+00FF`) string encoding for `bytes`/`fixed`, `-0.0` sign preservation, `"NaN"`/`"Infinity"`/`"-Infinity"` round-trip, last-wins map duplicate key deduplication, O(1) record field lookup, and record default-value materialization.
- **Object Container File `.avro` OCF (`src/ocf.pion`)**:
  - Full `Obj\x01` header with full-metadata `avro.schema` (`schema_to_json`, preserving `logicalType`/`default`/`aliases`/`doc`/`order`) + `avro.codec` + custom metadata + 16-byte `sync` marker + multi-block `null` and `deflate` (RFC 1951 raw DEFLATE via `packages/flate`) encoding/decoding, `read_ocf_resolved`, and streaming block-by-block `OcfReader` (`OcfReader::open`, `OcfReader::open_resolved`, `OcfReader::next_block`).
- **DoS Protection (`AvroLimits` in `src/value.pion`)**:
  - Configurable `max_depth` (default `512`), file-wide cumulative `max_elements` (default `1,000,000` collection elements across all OCF blocks), `max_bytes` (default `64 MiB`, including OCF `deflate` decompression bomb interception), and `max_schema_types` (default `65,536`).

## Public API

```pion
// Core values, errors, limits
pub enum AvroError { ... }
pub val struct AvroLimits { pub max_depth : Int, pub max_elements : Int, pub max_bytes : Int, pub max_schema_types : Int }
pub enum AvroValue { Null, Boolean(Bool), Int(Int), Long(Int64), Float32(Double), Float64(Double), Bytes(Bytes), String(String), Fixed(Bytes), Enum(Int, String), Array(Array[AvroValue]), Map(Array[(String, AvroValue)]), Union(Int, AvroValue), Record(Array[(String, AvroValue)]) }

// Schema, PCF, full JSON, Rabin-64
pub fn parse_schema(json_str : String) -> Result[Schema, AvroError]
pub fn parse_schema_with_limits(json_str : String, limits : AvroLimits) -> Result[Schema, AvroError]
pub fn canonical_form(schema : Schema) -> String
pub fn schema_to_json(schema : Schema) -> String
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
pub fn OcfReader::open(data : Bytes, limits : AvroLimits) -> Result[OcfReader, AvroError]
pub fn OcfReader::open_resolved(data : Bytes, reader_schema : Schema, limits : AvroLimits) -> Result[OcfReader, AvroError]
pub fn OcfReader::next_block(self : OcfReader) -> Result[Option[Array[AvroValue]], AvroError]
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

### W1: Avro Binary Encode + Decode Roundtrip (50,000 nested records, `2,607,112 B` reference input)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s)* | ns/op | Peak RSS | Speedup (vs `go_hamba_any`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`, dynamic `AvroValue`) | 109.163 | 107.772 | 116.065 | 23.88 | 2183.26 | 72.03 MiB | 0.73x |
| `go_hamba_any` (`v2.28.0`, dynamic `map[string]any`) | 79.457 | 78.084 | 81.513 | 32.81 | 1589.14 | 98.31 MiB | 1.00x (baseline) |
| `go_hamba_struct` (`v2.28.0`, typed Go `struct`) | **33.958** | 33.261 | 36.321 | **76.77** | 679.16 | 56.73 MiB | **2.34x** |

- Verified stdout SHA-256: `f2ea3fe5aec17024a4472cc10ec21b8fe7fd3a6435fa58d387bf60af522203c2`

### W2: Schema Evolution Batch Decode Writer v1 -> Reader v2 (50,000 records, `2,607,112 B`)

Writer v1 -> Reader v2 exercises field reordering, dropping `ts` + nested `metrics` map, `int -> long` and `float -> double` promotions, and materializing a new `region` field default across all 50,000 records:

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_hamba_any`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`, pre-compiled `SchemaResolver`) | 47.841 | 46.736 | 48.737 | 54.50 | 956.82 | 51.42 MiB | 0.71x |
| `go_hamba_any` (`v2.28.0`, dynamic `map[string]any`) | 34.008 | 33.233 | 39.491 | 76.66 | 680.15 | 41.69 MiB | 1.00x (baseline) |
| `go_hamba_struct` (`v2.28.0`, typed Go `struct`) | **15.572** | 15.508 | 19.128 | **167.42** | 311.44 | 17.83 MiB | **2.18x** |

- Verified stdout SHA-256: `75f2b1112b8a4152e4b0e3ec1e31a0400d528c38ab729b59796e26164b79c626`

### W3: `.avro` OCF Deflate Multi-Block Write + Read (50,000 records, 50 blocks, `2,607,112 B` reference input)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s)* | ns/op | Peak RSS | Speedup (vs `go_hamba_any`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`, `packages/flate` raw DEFLATE) | 146.121 | 138.100 | 150.085 | 17.84 | 2922.43 | 69.03 MiB | 0.68x |
| `go_hamba_any` (`v2.28.0`, dynamic `map[string]any`) | 99.143 | 96.727 | 110.251 | 26.30 | 1982.86 | 104.55 MiB | 1.00x (baseline) |
| `go_hamba_struct` (`v2.28.0`, typed Go `struct`) | **54.536** | 54.383 | 56.419 | **47.81** | 1090.72 | 54.16 MiB | **1.82x** |

- Verified stdout SHA-256: `5ba2533c35006e9aba08f5d7633cb30778cb4ced61bb3bd2766b280cee046a89`
- **Notes**:
  - `*` Throughput in W1 and W3 divides the shared W2 Go wire input size (`2,607,112 B`) by round-trip median time across all implementations for consistent relative ratios; actual bytes processed in W1/W3 include both encode/compress and decode/decompress passes.
  - Against dynamic `go_hamba_any`, Pion's iterative stack-safe dynamic `AvroValue` path achieves **0.68x–0.73x** throughput while using **27%–34% lower peak RSS** on W1 and W3 (and producing slightly smaller DEFLATE OCF blocks via `packages/flate`).
  - Go's compile-time typed `struct` path (`go_hamba_struct`) avoids per-record dynamic AST allocation and is **1.82x–2.34x faster than `go_hamba_any`** (and **2.68x–3.21x faster than Pion**).
