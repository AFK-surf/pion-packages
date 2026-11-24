# `structured_fields` (`v0.1.0`)

Pure-Pion, zero-dependency implementation of **RFC 9651 (Structured Field Values for HTTP)** (obsoleting RFC 8941) — complete parser, strict canonical serializer, `SfvLimits` DoS protection, and browser-oriented helpers (`Priority`, `Permissions-Policy`, multi-header joining). Zero `extern "C"`, zero `World` dependency, zero floating point (`Double`/`Float`), zero module-level mutable state, and full Native + `wasm32` support.

## Features

- **All 8 RFC 9651 §3.3 Bare Item Types**:
  - **Integer** (§3.3.1): `Int64` strictly bounded to `[-999_999_999_999_999, +999_999_999_999_999]` (max 15 digits including leading zeros; rejects leading `+`, bare `-`, overflow).
  - **Decimal** (§3.3.2): Exact `Int64` thousandths (`Decimal { scaled_milli : Int64 }`, unit `1/1000`) strictly bounded to `[-999_999_999_999.999, +999_999_999_999.999]` (max 12 integer digits + 1–3 fractional digits). Zero floating-point arithmetic anywhere; `-0.0` normalizes to `0.0`; `Decimal::from_scaled_rounded` provides exact integer round-half-to-even (RFC 9651 §4.1.5).
  - **String** (§3.3.3): Strict printable ASCII (`0x20..=0x7E`), only `\"` and `\\` escapes permitted; rejects control characters, non-ASCII bytes, unterminated quotes, and unknown escapes.
  - **Token** (§3.3.4): Strict RFC 9651 ABNF (`ALPHA / "*"` first char, `tchar / ":" / "/"` subsequent).
  - **Byte Sequence** (§3.3.5): `:base64:` RFC 4648 §4 standard Base64 with RFC 9651 §4.2.7 padding handling (forgiving omitted/partial padding and non-zero pad bits while rejecting mid-stream padding, excess padding beyond the 4-char quantum, whitespace, and non-Base64 chars; canonical padded output on serialization).
  - **Boolean** (§3.3.6): `?1` / `?0` only.
  - **Date** (RFC 9651 §3.3.7): `@<integer>` Unix epoch seconds (`Int64`, strictly `[-999_999_999_999_999, +999_999_999_999_999]`, rejects decimals).
  - **Display String** (RFC 9651 §3.3.8): `%"..."` with strict lowercase `%xx` percent-decoding (`0-9a-f` only; rejects uppercase `%C3`), strict RFC 3629 UTF-8 validation (rejects overlong encodings, UTF-16 surrogates, code points `> U+10FFFF`, and truncated sequences), and canonical lowercase percent-escaping on serialization.
- **All 3 Top-Level Structures & Parameters**:
  - **Item** (`parse_item` / `serialize_item`), **List** (`parse_list` / `serialize_list` + `InnerList`), **Dictionary** (`parse_dictionary` / `serialize_dictionary`), and **Parameters** (ordered `Key -> BareItem`, strict lowercase keys).
  - Duplicate dictionary and parameter keys overwrite values in place while preserving first-seen key order (RFC 9651 §4.2.2 / §4.2.3.2), backed by a lazy `Map[String, Int]` index for O(1) amortized lookup against quadratic CPU DoS.
  - Multi-header field joining: `parse_list_fields` and `parse_dictionary_fields` combine multiple HTTP field lines with `", "` while enforcing `max_input_bytes` prior to allocation.
  - Strict whitespace handling: leading SP (`0x20`) only on all types; trailing SP (`0x20`) only on Items (rejecting trailing `HTAB`); OWS (`SP / HTAB`) around commas and trailing OWS on Lists and Dictionaries (per RFC 9651 §4.2.1 / §4.2.2); rejects `\r`, `\n`, and trailing garbage.
- **Strict Serializer Validation & `SfvLimits` DoS Protection**:
  - Every serializer validates integer/decimal/date bounds, key/token charsets, printable ASCII strings (blocking CRLF header injection), valid UTF-8 display strings, and unique dictionary/parameter keys (rejecting hand-built duplicate keys with `SfvError::InvalidKey` in O(n) time so serialized output is always a canonical fixed point), enforcing `max_output_bytes` incrementally.
  - Note: per RFC 9651 §4.1, an empty List or Dictionary serializes to `""`; callers MUST omit the HTTP header rather than sending an empty field value.
  - Any negative field in `SfvLimits` is immediately rejected with `SfvError::LimitExceeded`; `0` strictly means `0` allowed.
- **Browser-Oriented Helpers**:
  - `parse_priority` / `serialize_priority` (RFC 9218 HTTP `Priority: u=1, i`).
  - `parse_permissions_policy` (W3C `Permissions-Policy` directives; returned origin strings are unvalidated SFV strings and callers MUST validate origins per W3C Permissions Policy §9.2 before enforcing policy).
  - `get_param`, `get_dict_member`, `is_valid_key`, `is_valid_token`.

## Public API

```pion
pub val struct SfvLimits {
  pub max_input_bytes : Int
  pub max_list_members : Int
  pub max_inner_list_items : Int
  pub max_dict_members : Int
  pub max_params : Int
  pub max_string_bytes : Int
  pub max_output_bytes : Int
}

pub val struct Decimal { pub scaled_milli : Int64 }
pub val struct Priority { pub urgency : Int, pub incremental : Bool }

pub enum BareItem {
  Integer(Int64)
  Decimal(Decimal)
  String(String)
  Token(String)
  ByteSequence(Bytes)
  Boolean(Bool)
  Date(Int64)
  DisplayString(String)
}

pub struct Param { pub key : String, pub value : BareItem }
pub struct Item { pub value : BareItem, pub params : Array[Param] }
pub struct InnerList { pub items : Array[Item], pub params : Array[Param] }
pub enum ListEntry { Item(Item), InnerList(InnerList) }
pub struct DictMember { pub key : String, pub value : ListEntry }
pub struct PermissionsDirective { pub feature : String, pub allow_all : Bool, pub allow_self : Bool, pub origins : Array[String] }

pub enum SfvError {
  InvalidSyntax(String)
  InvalidNumber(String)
  InvalidString(String)
  InvalidToken(String)
  InvalidByteSequence(String)
  InvalidBoolean(String)
  InvalidDate(String)
  InvalidDisplayString(String)
  InvalidKey(String)
  TrailingData(String)
  LimitExceeded(String)
}

// Parsing
pub fn parse_item(input : String) -> Result[Item, SfvError]
pub fn parse_item_with_limits(input : String, limits : SfvLimits) -> Result[Item, SfvError]
pub fn parse_list(input : String) -> Result[Array[ListEntry], SfvError]
pub fn parse_list_with_limits(input : String, limits : SfvLimits) -> Result[Array[ListEntry], SfvError]
pub fn parse_list_fields(fields : Array[String]) -> Result[Array[ListEntry], SfvError]
pub fn parse_list_fields_with_limits(fields : Array[String], limits : SfvLimits) -> Result[Array[ListEntry], SfvError]
pub fn parse_dictionary(input : String) -> Result[Array[DictMember], SfvError]
pub fn parse_dictionary_with_limits(input : String, limits : SfvLimits) -> Result[Array[DictMember], SfvError]
pub fn parse_dictionary_fields(fields : Array[String]) -> Result[Array[DictMember], SfvError]
pub fn parse_dictionary_fields_with_limits(fields : Array[String], limits : SfvLimits) -> Result[Array[DictMember], SfvError]

// Serialization
pub fn serialize_item(item : Item) -> Result[String, SfvError]
pub fn serialize_item_with_limits(item : Item, limits : SfvLimits) -> Result[String, SfvError]
pub fn serialize_list(list : Array[ListEntry]) -> Result[String, SfvError]
pub fn serialize_list_with_limits(list : Array[ListEntry], limits : SfvLimits) -> Result[String, SfvError]
pub fn serialize_dictionary(dict : Array[DictMember]) -> Result[String, SfvError]
pub fn serialize_dictionary_with_limits(dict : Array[DictMember], limits : SfvLimits) -> Result[String, SfvError]
pub fn serialize_bare_item(item : BareItem) -> Result[String, SfvError]

// Browser & lookup helpers
pub fn parse_priority(input : String) -> Result[Priority, SfvError]
pub fn serialize_priority(p : Priority) -> Result[String, SfvError]
pub fn parse_permissions_policy(input : String) -> Result[Array[PermissionsDirective], SfvError]
pub fn get_param(params : Array[Param], key : String) -> Option[BareItem]
pub fn get_dict_member(dict : Array[DictMember], key : String) -> Option[ListEntry]
pub fn is_valid_key(s : String) -> Bool
pub fn is_valid_token(s : String) -> Bool
```

## Concurrency & `Send` Guarantees

Verified directly with `pionc check --json` using `scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })` capture probes on every public type:

| Type | `Send` Status | Reason / Cross-`spawn` Pattern |
| --- | --- | --- |
| `SfvLimits` | **`Send`** | `val struct` of `Int` — may be captured directly across `spawn`. |
| `Decimal` | **`Send`** | `val struct` of `Int64` — may be captured directly across `spawn`. |
| `SfvError` | **`Send`** | `enum` carrying `String` — may be captured directly across `spawn`. |
| `Priority` | **`Send`** | `val struct` of `Int` and `Bool` — may be captured directly across `spawn`. |
| `BareItem` | `!Send` | Contains `ByteSequence(Bytes)` (`Bytes` is a mutable buffer). |
| `Param`, `Item`, `InnerList`, `ListEntry`, `DictMember`, `PermissionsDirective` | `!Send` | Contain `Array[...]` and/or `BareItem`. |

To pass parsed SFV structures across a `spawn` boundary, serialize to a canonical `String` (which is `Send`) via `serialize_item` / `serialize_list` / `serialize_dictionary` and re-parse inside the spawned task.

## Quick Start

```pion
import "structured_fields"

match structured_fields::parse_dictionary("u=1, i") {
  Ok(dict) =>
    match structured_fields::serialize_dictionary(dict) {
      Ok(canonical) => { let _ = canonical } // "u=1, i"
      Err(_) => ()
    }
  Err(_) => ()
}

match structured_fields::parse_priority("u=1, i") {
  Ok(p) => { let _ = (p.urgency, p.incremental) } // (1, true)
  Err(_) => ()
}
```

## Verification

```sh
sh scripts/verify.sh packages/structured_fields
```

- **Unit & Security Suite**: `pionc test --json packages/structured_fields` — **30 / 30 tests passing**, covering all 8 bare items, 3 top-level structures, exact `Int64` `Decimal` & round-half-to-even, RFC 9651 Dates & Display Strings (including lowercase `%xx` and UTF-8 overlong/surrogate rejection), duplicate key overwrite order, multi-header field joining, strict whitespace/trailing rejection, serializer anti-injection and duplicate-key rejection checks, all 7 `SfvLimits` negative/zero bounds, 10,000-key O(1) DoS stress test, and browser helpers.
- **Official IETF & Rust `sfv` Bidirectional Cross-Check**: **251 / 251** core vectors from [`httpwg/structured-field-tests`](https://github.com/httpwg/structured-field-tests) (`binary.json`, `boolean.json`, `date.json`, `dictionary.json`, `display-string.json`, `examples.json`, `item.json`, `list.json`, `listlist.json`, `number.json`, `param-dict.json`, `param-list.json`, `param-listlist.json`, `string.json`, `token.json`) verified **100% byte-for-byte identical** (`parse + serialize`) against Rust `sfv 0.16.1` (**0 unexplained discrepancies**).

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical `271 B` stdout SHA-256 (`f8311f93f4000564e4e346f72bf2ce4e02a7f80448fcd2978feaa510e45db504`):

| Mode | Binary Size (`Linux x86_64` / `wasm32`) | Stdout SHA-256 (`271 B`) |
| --- | ---: | --- |
| Native Debug | `154,744 B` | `f8311f93f4000564...` |
| Native Release | `261,496 B` | `f8311f93f4000564...` |
| Wasm32 Debug | `92,288 B` | `f8311f93f4000564...` |
| Wasm32 Release | `92,015 B` | `f8311f93f4000564...` |

## Head-to-Head Benchmarks

Measured on `Linux x86_64` (`pionc 0.1.0 --release` vs Rust `sfv 0.16.1 --release`) via `sh packages/structured_fields/bench/run_bench.sh` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-exact equality).

### Corpus 1: Real-World Browser HTTP Headers (`24 headers × 5,000 = 120,000` parse+serialize ops, `7,105,000 B`)

Includes `Sec-CH-UA`, `Permissions-Policy`, `Priority`, `Cache-Status`, `Accept-CH`, `Content-Digest`, `Signature-Input`, `Signature`, and `Dictionary-Available`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_sfv`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | **73.620** | 69.908 | 89.881 | **96.51** | **613.50** | **2.09 MiB** | 1.03x |
| `rust_sfv` (`0.16.1 --release`) | 76.044 | **68.881** | **81.949** | 93.43 | 633.70 | **2.09 MiB** | 1.00x (baseline) |

_Stdout SHA-256 verified identical across all rounds: `02d5fdad1e5bb9ddbb8dd72577d8ae8f8ce158884a7db93a1805b2c83207c5a6`._

### Corpus 2: Complex Nested RFC 9651 (`16 cases × 4,000 = 64,000` parse+serialize ops, `7,156,000 B`)

Heavy mix of nested dictionaries, inner lists, Base64 byte sequences, multi-byte UTF-8 display strings, RFC 9651 dates, boundary decimals, and multi-parameter entries.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_sfv`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 99.589 | 87.863 | **111.735** | 71.86 | 1,556.08 | **2.07 MiB** | 0.91x |
| `rust_sfv` (`0.16.1 --release`) | **90.799** | **82.730** | 119.072 | **78.81** | **1,418.73** | 2.15 MiB | 1.00x (baseline) |

_Stdout SHA-256 verified identical across all rounds: `3debee67da84f79a28a8d51b9cbe60f1244b60f54b8d4c76aebb64d085bd2972`._

### Honest Performance Notes

- **Throughput**: On Corpus 1 (real-world browser headers), `pion` matches/edges past Rust `sfv 0.16.1` at **`1.03x`** (`96.51 MB/s` vs `93.43 MB/s`, `613.50 ns/op` vs `633.70 ns/op`), driven by zero-copy `code_unit_at`/`slice` parsing, 64-bit bitmask character classification, error-path-only ASCII scanning, and direct `StringBuilder` integer/decimal/string formatting. On Corpus 2 (deeply nested structures, Base64, and percent-encoded display strings), `pion` runs at **`0.91x`** (`71.86 MB/s` vs `78.81 MB/s`), with the remaining ~9% gap attributable to per-node heap allocation and RC overhead for AST structs/enums (`Item`, `BareItem`, `ListEntry`, `Param`, empty `Array[Param]`) compared to Rust's flat by-value `Vec`/`IndexMap` layout.
- **Peak RSS**: `pion` matches or uses slightly less peak resident memory on both corpora (`2.07–2.09 MiB` vs `2.09–2.15 MiB`).

## Third-Party Test Vector Attribution

The 251 official conformance test vectors in `bench/gen_data.py` are derived from [`httpwg/structured-field-tests`](https://github.com/httpwg/structured-field-tests), Copyright (c) 2018- IETF Trust and the persons identified as authors of the code, licensed under the **BSD-3-Clause** license.

## License

MIT (matching `AFK-surf/pion-packages`).
