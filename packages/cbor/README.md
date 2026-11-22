# `cbor` — Pure Pion CBOR (RFC 8949 + CTAP2) Codec

Pure Pion implementation of **CBOR (Concise Binary Object Representation, RFC 8949)** with **Core Deterministic Encoding (§4.2.1)**, **CTAP2 / RFC 7049 Canonical Encoding**, **IEEE-754 binary16 (float16) bit-exact conversion**, **RFC 8949 §8 Diagnostic Notation**, and **DoS/OOM-resistant decoding** inspired by Go's [`fxamacker/cbor`](https://github.com/fxamacker/cbor).

- Zero C glue, zero `World` dependency, `Send`-safe immutable values.
- Full `-2^64 .. 2^64 - 1` integer precision via `CborValue::Unsigned(UInt64)` and `CborValue::Negative(UInt64)` (`-1 - n`).
- Native (`arm64_apple` / Linux) and `wasm32` verified.

## API Overview

```pion
import "cbor"

// Data model
pub enum CborValue {
  Unsigned(UInt64)
  Negative(UInt64)
  Bytes(Bytes)
  Text(String)
  Array(Array[CborValue])
  Map(Array[(CborValue, CborValue)])
  Tag(UInt64, CborValue)
  Bool(Bool)
  Null
  Undefined
  Simple(Int)
  Float(Double)
}

// Options
pub val struct DecodeOptions {
  pub max_depth : Int            // default: 32
  pub max_elements : Int         // default: 131072
  pub reject_duplicate_keys : Bool
  pub require_canonical : Bool
  pub allow_trailing_bytes : Bool
}

pub enum SortMode {
  None
  CoreDeterministic // RFC 8949 §4.2.1 bytewise lexicographic order
  Ctap2             // RFC 7049 §3.9 / CTAP2 length-first then bytewise order
}

pub val struct EncodeOptions {
  pub sort_mode : SortMode
  pub shortest_float : Bool
}

// Entrypoints
pub fn decode(data : Bytes, opts : DecodeOptions) -> Result[CborValue, CborError]
pub fn decode_default(data : Bytes) -> Result[CborValue, CborError]
pub fn validate(data : Bytes, opts : DecodeOptions) -> Result[Unit, CborError]
pub fn encode(value : CborValue, opts : EncodeOptions) -> Result[Bytes, CborError]
pub fn encode_default(value : CborValue) -> Result[Bytes, CborError]
pub fn to_diagnostic(value : CborValue) -> String
```

## Compliance & Security Test Suite (209 tests)

- **`appendix_a_test.pion` (83 tests)**: All RFC 8949 Appendix A official test vectors (`cbor/test-vectors/appendix_a.json`), including integers `0..2^64-1`, `-1..-2^64`, float16 subnormals/normals/±0.0/±Inf/NaN, float32/64, UTF-8 text strings, byte strings, definite & indefinite-length containers, tags (`0, 1, 2, 3, 23, 24, 32`), and simple values.
- **`canonical_test.pion` (45 tests)**: RFC 8949 §4.2 Core Deterministic Encoding, CTAP2 / RFC 7049 length-first sorting vs Core Deterministic bytewise lexicographic sorting, shortest integer/float encoding, duplicate key rejection, and strict canonical decode validation.
- **`security_test.pion` (56 tests)**: Ported from `fxamacker/cbor` — truncated inputs, trailing bytes, reserved additional info (28/29/30), unexpected break codes (`0xff`), invalid simple values (`0xf8 0x00..0x1f`), strict UTF-8 validation (including split multi-byte chunks across indefinite text strings), depth limit (`max_depth = 32`), element limit (`max_elements`), duplicate key detection, and OOM defense against crafted huge lengths (`u64::MAX`).
- **`diagnostic_test.pion` (25 tests)**: RFC 8949 §8 Diagnostic Notation and WebAuthn/COSE/CTAP2/Telemetry roundtrip tests.

## Benchmarks

Run the cross-language head-to-head benchmark (`Pion Native` vs `Go fxamacker/cbor/v2` vs `Rust ciborium`, mandatory stdout SHA-256 verification):

```sh
sh packages/cbor/bench/run_bench.sh
```

### CBOR: Deterministic Batch Encode (50k WebAuthn/COSE + Telemetry)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `58 B` (`sha256:b14fb8d50078493f...`) | Ops: `50000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs go_fxamacker) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 138.962 | 137.165 | 153.740 | 2779.23 | 1.78 MiB | 0.87x |
| `go_fxamacker` | 120.254 | 115.331 | 141.477 | 2405.08 | 12.33 MiB | 1.00x (baseline) |
| `rust_ciborium` | 85.764 | 84.385 | 87.391 | 1715.29 | 2.06 MiB | 1.40x |

_SHA-256 verified identical across all implementations and rounds: `b14fb8d50078493f9c8c4349e6dd969f3289721f95fe1cc96f1cda48a7b61e0b`._

### CBOR: Batch Decode + Tree Walk (80k WebAuthn/COSE + Telemetry)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `67 B` (`sha256:3e1929251b4f124f...`) | Input: `23508920 B` | Ops: `80000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs go_fxamacker) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 149.661 | 139.664 | 159.145 | 157.08 | 1870.76 | 9.19 MiB | 1.13x |
| `go_fxamacker` | 169.493 | 142.346 | 221.261 | 138.70 | 2118.67 | 24.97 MiB | 1.00x (baseline) |
| `rust_ciborium` | 139.573 | 127.944 | 159.863 | 168.43 | 1744.67 | 6.72 MiB | 1.21x |

_SHA-256 verified identical across all implementations and rounds: `3e1929251b4f124f4f35012b86df7c3b1ad83579b233cee32aacc5fb05a48ece`._
