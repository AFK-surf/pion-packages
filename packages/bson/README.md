# `bson` (`v0.1.0`)

100% pure Pion implementation of **BSON 1.1** binary document codec, **ObjectId (12B)**, **IEEE 754-2008 BID `Decimal128` (16B)**, and **MongoDB Extended JSON v2 (Canonical & Relaxed)** — zero `extern "C"`, zero `World` dependency, 100% iterative (stack-safe on Native and `wasm32`), explicit `Result[T, BsonError]`, and `BsonLimits` DoS protection.

## Features

- **Complete BSON 1.1 Binary Codec (`src/types.pion`, `src/decode.pion`, `src/encode.pion`)**:
  - All 19+ BSON element types (`0x01` Double, `0x02` String, `0x03` Document, `0x04` Array, `0x05` Binary, `0x06` Undefined, `0x07` ObjectId, `0x08` Boolean, `0x09` DateTime, `0x0A` Null, `0x0B` Regex, `0x0C` DbPointer, `0x0D` JavaScript, `0x0E` Symbol, `0x0F` JavaScriptWithScope, `0x10` Int32, `0x11` Timestamp, `0x12` Int64, `0x13` Decimal128, `0xFF` MinKey, `0x7F` MaxKey).
  - Full `BinarySubtype` support: `Generic (0x00)`, `Function (0x01)`, `BinaryOld (0x02)` with inner 4-byte length validation, `UuidOld (0x03)`, `Uuid (0x04)`, `Md5 (0x05)`, `Encrypted (0x06)`, `Column (0x07)`, `Sensitive (0x08)`, `Vector (0x09)`, `Reserved(0x0A..0x7F)`, `UserDefined(0x80..0xFF)`.
  - Strict validation: document length `>= 5`, trailing `0x00` terminator, no trailing unconsumed bytes, overflow-safe length bounds checks, strict UTF-8 across keys/strings/regex/code/symbol/DBPointer (in both `decode`, `encode`, and `from_extjson`), string length `>= 1` with NUL terminator, no embedded NUL in C-strings, strict Boolean (`0x00`/`0x01`), alphabetical Regex options normalization, opt-in sequential array key validation (`validate_array_keys` defaults to `false` per BSON Corpus, enable via `BsonLimits::default().with_validate_array_keys(true)`), and `BsonLimits` (`max_depth`, `max_doc_bytes`, `max_elements`).
  - Two-pass pre-allocated iterative encoder and iterative decoder immune to deep-nesting stack overflow on both Native and `wasm32`.
- **`ObjectId` (`src/oid.pion`) & IEEE 754-2008 BID `Decimal128` (`src/decimal128.pion`)**:
  - 12-byte `ObjectId`: 24-hex case-insensitive parse, lowercase hex format, big-endian 32-bit Unix timestamp extraction, lexicographical `compare` and `eq`.
  - Complete 128-bit Binary Integer Decimal (`Decimal128`) string ↔ 16-byte little-endian BID bidirectional codec: 34-digit precision, exponents `-6176..+6111`, trailing zero preservation (`0.00`, `-0.00`, `0E-7`, `0E+2`), `NaN`/`Infinity`/`-Infinity`, non-canonical BID `> 10^34 - 1` decoding to zero, and strict overflow/underflow/syntax rejection.
- **MongoDB Extended JSON v2 (`src/extjson.pion`)**:
  - Iterative Canonical and Relaxed Extended JSON v2 serializer and parser (`$numberInt`, `$numberLong`, `$numberDouble`, `$numberDecimal`, `$oid`, `$date` ISO-8601 & `$numberLong`, `$binary`, `$uuid`, `$regularExpression`, `$timestamp`, `$code`, `$scope`, `$symbol`, `$dbPointer`, `$undefined`, `$minKey`, `$maxKey`).
  - Preserves exact 64-bit integer precision beyond `2^53` and `Int32`/`Int64`/`Double` distinction in Relaxed mode.

## Public API

```pion
pub enum BinarySubtype { Generic, Function, BinaryOld, UuidOld, Uuid, Md5, Encrypted, Column, Sensitive, Vector, Reserved(Int), UserDefined(Int) }
pub struct ObjectId { pub bytes : Bytes }
pub struct Decimal128 { pub bytes : Bytes }
pub struct BsonDocument { pub entries : Array[(String, BsonValue)] }
pub enum BsonValue { Double(Double), Str(String), Document(BsonDocument), Array(Array[BsonValue]), Binary(BinarySubtype, Bytes), Undefined, ObjectId(ObjectId), Bool(Bool), DateTime(Int64), Null, Regex(String, String), DbPointer(String, ObjectId), JavaScript(String), Symbol(String), JavaScriptWithScope(String, BsonDocument), Int32(Int), Timestamp(Int64, Int64), Int64(Int64), Decimal128(Decimal128), MinKey, MaxKey }
pub enum ExtJsonMode { Canonical, Relaxed }
pub val struct BsonLimits { pub max_depth : Int, pub max_doc_bytes : Int, pub max_elements : Int, pub validate_array_keys : Bool }
// BsonLimits::default().with_validate_array_keys(true) enables strict sequential array key checking (default: false)
pub enum BsonError { ... }

// Binary BSON 1.1
pub fn decode(data : Bytes) -> Result[BsonDocument, BsonError]
pub fn decode_with_limits(data : Bytes, limits : BsonLimits) -> Result[BsonDocument, BsonError]
pub fn encode(doc : BsonDocument) -> Result[Bytes, BsonError]
pub fn encode_with_limits(doc : BsonDocument, limits : BsonLimits) -> Result[Bytes, BsonError]

// ObjectId
pub fn ObjectId::from_bytes(b : Bytes) -> Result[ObjectId, BsonError]
pub fn ObjectId::from_hex(hex : String) -> Result[ObjectId, BsonError]
pub fn ObjectId::to_hex(self : ObjectId) -> String
pub fn ObjectId::to_bytes(self : ObjectId) -> Bytes
pub fn ObjectId::timestamp_seconds(self : ObjectId) -> Int64
pub fn ObjectId::compare(self : ObjectId, other : ObjectId) -> Int
pub fn ObjectId::eq(self : ObjectId, other : ObjectId) -> Bool

// Decimal128 (IEEE 754-2008 BID)
pub fn Decimal128::from_bytes(b : Bytes) -> Result[Decimal128, BsonError]
pub fn Decimal128::to_bytes(self : Decimal128) -> Bytes
pub fn Decimal128::from_string(s : String) -> Result[Decimal128, BsonError]
pub fn Decimal128::to_string(self : Decimal128) -> String
pub fn Decimal128::is_nan(self : Decimal128) -> Bool
pub fn Decimal128::is_infinite(self : Decimal128) -> Bool
pub fn Decimal128::is_negative(self : Decimal128) -> Bool
pub fn Decimal128::is_zero(self : Decimal128) -> Bool
pub fn Decimal128::eq(self : Decimal128, other : Decimal128) -> Bool

// Extended JSON v2
pub fn to_extjson(doc : BsonDocument, mode : ExtJsonMode) -> Result[String, BsonError]
pub fn to_extjson_with_limits(doc : BsonDocument, mode : ExtJsonMode, limits : BsonLimits) -> Result[String, BsonError]
pub fn from_extjson(src : String) -> Result[BsonDocument, BsonError]
pub fn from_extjson_with_limits(src : String, limits : BsonLimits) -> Result[BsonDocument, BsonError]
```

## Verification

```sh
sh scripts/verify.sh packages/bson
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`1728aa18aadbb7e067aa5b165dff7526bac1df54ef7463b470d7cae7dec16d9b`):

```sh
pionc run packages/bson/wasm_smoke
pionc run --release packages/bson/wasm_smoke
pionc run --target wasm32 packages/bson/wasm_smoke
pionc run --target wasm32 --release packages/bson/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/bson/bench/run_bench.sh` against Rust **`bson 2.15.0` (`--release --locked`)** on 1,000 composite documents (nested subdocument + array + `ObjectId` + `DateTime` + `Binary` Generic/UUID + `Decimal128` + `Int64`). All three workloads verify **100% byte-for-byte stdout SHA-256 identity** via `scripts/bench_compare.py`:

### W1: BSON Decode (50,000 composite documents, 12,012,500 B)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_ref`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`, owned `BsonDocument` + walk) | 59.839 | 57.878 | 67.074 | 200.75 | 1196.77 | 2.83 MiB | **1.67x** |
| `rust_ref` (`bson 2.15.0`, `Document::from_reader` + walk by ref) | 99.650 | 97.915 | 110.859 | 120.55 | 1993.01 | 2.84 MiB | 1.00x (baseline) |
| `rust_raw` (`bson 2.15.0`, `RawDocument::from_bytes` zero-copy walk) | **31.190** | 30.627 | 32.818 | 385.14 | 623.80 | 2.50 MiB | **3.19x** (`rust_raw` is **1.92x** faster than Pion) |

- Verified stdout SHA-256: `5aaa2cd2a70a7fd150fdbe14ebfe1ef0c98b0a5c6cc23cd95f70595cae079a09`
- Note: `rust_ref` walks `Document` strictly by reference (no `doc.clone()`). For read-only traversal without materializing an owned DOM, Rust's zero-copy `RawDocument` API (`rust_raw`) validates every element on the fly and is ~1.92x faster than Pion's owned-tree decode.

### W2: BSON Encode (50,000 composite documents, 12,012,500 B)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_bson`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 44.761 | 44.409 | 45.382 | 268.37 | 895.23 | 4.45 MiB | **1.05x** |
| `rust_bson` (`2.15.0`, `--release --locked`) | 47.095 | 46.181 | 48.115 | 255.07 | 941.90 | 5.72 MiB | 1.00x (baseline) |

- Verified stdout SHA-256: `fb667c1dcaef24a105c6ba39aa0d733c65a33f7b9327d7877b94392fb11a7d7f`

### W3: BSON ↔ Extended JSON v2 Canonical + Relaxed Roundtrip (20,000 docs, 4,805,000 B)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_bson`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 175.664 | 173.493 | 189.812 | 27.35 | 8783.22 | 4.73 MiB | **1.40x** |
| `rust_bson` (`2.15.0`, `--release --locked`) | 245.903 | 243.389 | 253.249 | 19.54 | 12295.13 | 5.98 MiB | 1.00x (baseline) |

- Verified stdout SHA-256: `f3a6ca6a2132d4c515a511e57fcfc1b1c126809eb78834e70af071b89ad9d016`
- Note: Rust `bson`'s public Extended JSON API goes through `serde_json::Value` (with `preserve_order` / `IndexMap`), and `into_*_extjson(self)` consumes its input (requiring a `doc.clone()` per document). Pion serializes/parses directly between `BsonDocument` and JSON text.

## Formal Verification (Lean 4)

The core BSON 1.1 `BinarySubtype` wire codec, `BsonLimits` defaults, `ObjectId` hex nibble decoder, and IEEE 754-2008 BID `Decimal128` 128-bit ordering & bit-layout classifiers (`src/types.pion`, `src/oid.pion`, `src/decimal128.pion`) are annotated with `#verify`, extracted directly via `pionc extract-lean` (`2` types, `13` functions, `0` externals), and formally verified in Lean 4 with **24 theorems**, **0 `sorry`**, **0 `admit`**, **0 custom `axiom`**, **0 `bv_decide`**, **0 `native_decide`**, and **42/42** native-vs-Lean differential cross-checks:

- `proofs/BsonProofs/SubtypeAndLimits.lean` (12 theorems): full 256-byte `BinarySubtype::from_byte` ↔ `to_byte` wire bijection (for all `0..255` and all canonical subtypes), `to_byte` `[0, 255]` totality, `Reserved (0x0A..0x7F)` vs `UserDefined (0x80..0xFF)` range partitioning, `binary_subtype_eq` equivalence relation (reflexive, symmetric, transitive), `BsonLimits::default` / `with_validate_array_keys` invariants, and `oid_hex_val` `[0, 15]` / `-1` bounds, digit exactness, and `'A'..'F'` case-insensitivity.
- `proofs/BsonProofs/Decimal128Core.lean` (12 theorems): exact 128-bit unsigned ordering `u128_gt` (`a_hi * 2^64 + a_lo > b_hi * 2^64 + b_lo`, irreflexive, asymmetric, transitive), `ascii_lower` exactness and idempotency, IEEE 754-2008 BID `NaN`/`Infinity`/`Zero` mutual exclusivity across all `2^128` bit patterns, canonical `+0`/`-0` signed zero verification, §3.5.2 non-canonical `comb2 = 3` → zero, and `dec128_hi_is_negative` exact MSB (`hi ≥ 2^63`) characterization.
- `proofs/CheckAxioms.lean`: verifies all 24 theorems depend only on Lean's standard axioms (`propext`, `Classical.choice`, `Quot.sound`).
- `proofs/EvalDiff.lean`: 42-case Lean vs native Pion differential cross-check (`diff -u` zero differences).

```sh
LEAN_NUM_THREADS=2 LEAN_MEM_LIMIT=8192 bash packages/bson/proofs/run_proofs.sh
```
