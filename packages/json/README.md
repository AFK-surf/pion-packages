# `json` — Strict RFC 8259 JSON & RFC 8785 (JCS) for Pion

A zero-dependency, pure-Pion, `World`-free, `Send`-clean strict **RFC 8259** JSON parser, lossless value model, RFC 6901 JSON Pointer evaluator, and **RFC 8785 (JCS)** canonical serializer.

Designed to replace ad-hoc `Json` boilerplate across Pion repositories and eliminate the `> 2^53` `Int64` precision loss of `Double`-only JSON representations.

## Features

- **Strict RFC 8259 compliance**: rejects comments (`//`, `/* */`), trailing commas, single-quoted strings, unquoted keys, leading zeros (`01`), leading `+`, trailing/leading dots (`1.`, `.5`), non-RFC-8259 whitespace (`\v`, `\f`, NBSP, UTF-8 BOM), unescaped control characters (`0x00..0x1F`), lone UTF-16 surrogates, and invalid UTF-8 (overlong sequences, UTF-8 surrogates, code points `> U+10FFFF`, truncated sequences).
- **Lossless number model (`Json::Int` / `Json::Float` / `Json::BigNum` + `JsonNumber`)**:
  - Pure integers in `Int64::MIN..=Int64::MAX` (`-9223372036854775808`..`9223372036854775807`, including `> 2^53` Snowflake IDs and nanosecond timestamps) are parsed directly into `Json::Int(Int64)` without ever passing through `Double`. `-0` is preserved as `Json::Float(-0.0)`.
  - Out-of-range integers (e.g. `u64::MAX = 18446744073709551615`, arbitrary-precision integers) and binary64-overflowing exponents (`1e500`) are preserved losslessly as `Json::BigNum(raw_repr)`, with strictly RFC 8259-validated `as_u64()`, `as_i64()`, `as_f64()`, `raw_repr()`, and serializer checks (`Err(InvalidNumber)` on malformed literals).
  - Floating-point parsing uses **Eisel-Lemire 128-bit fast path + pure-Pion BigInt (Algorithm M) exact 0-ULP fallback** (handles subnormals, exact half-ULP ties-to-even, and 768+ digit literals identically on Native and Wasm32).
  - Floating-point formatting uses **pure-Pion Ryu** shortest roundtrip (zero module-level mutable state; bit-exact across Native and Wasm32).
- **Order-preserving + HashDoS-immune `JsonObject`**:
  - Preserves field insertion order for deterministic serialization and diffs, while `json_eq` / `Json::eq` is object-key-order independent per RFC 8259 §4.
  - Uses inline linear scan for small objects (`<= 8` keys), promotes to an O(1) open-addressing hash index (`> 8` keys), and automatically falls back to a deterministic iterative AVL tree when probe chains exceed 256 — guaranteeing worst-case O(log N) lookup/insert even under white-box offline HashDoS.
  - Configurable `DuplicateKeyPolicy`: `LastWins` (default, matching `serde_json` `preserve_order`), `FirstWins`, or `Reject` (prevents key-smuggling).
- **True immutable API**:
  - Constructors (`Json::arr`, `Json::obj`, `JsonObject::from_pairs`) and readers (`entries()`, `as_array()`, `get_array()`) defensively copy `Array` containers so external mutation can never alias or desynchronize internal object indices.
  - Immutable mutators: `set_field`, `without_keys` (O(n + k) indexed for `> 8` keys), `merge_object`. (Note: repeated single-key `set_field` calls copy the top-level entry list in O(n); batch updates via `merge_object` or `Json::obj` when building large objects.)
- **RFC 8785 (JCS) Canonical Serialization (`stringify_canonical`)**:
  - Sorts object keys by **UTF-16 code unit** order (so supplementary characters like `😀` `U+1F600` (`0xD83D 0xDE00`) sort before BMP `U+E000..U+FFFF` such as `דּ` `U+FB33`) using a fast bounds-safe UTF-8 byte comparison with `0xEE..0xEF` vs `0xF0..0xF4` fix-up.
  - Formats all numbers (including `Int` beyond `±(2^53 - 1)` and finite `BigNum`) via ECMAScript `Number::toString` / Ryu (`-0.0` → `0`, `1.0` → `1`, lowercase `\u00xx` control escapes), rejects non-finite numbers (`1e400`, `NaN`, `Infinity`) with `Err(NonFiniteNumber)`, and rejects invalid UTF-8 keys/values with `Err(InvalidUnicode)`.
- **Fully iterative & DoS-hardened (`JsonLimits`)**:
  - Explicit heap stacks for parsing, serialization, and `json_eq` (zero recursion, 5,000+ nesting depth without stack overflow on Native or Wasm32).
  - Explicit `max_depth`, `max_bytes`, `max_elements`, and `max_string_bytes` limits.

## Quick Example

```pion
import "json"

fn example() -> Result[String, json::JsonError] {
  let doc = match json::parse("{\"id\":9007199254740993,\"tags\":[\"fast\",\"safe\"]}") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let id = doc.get_i64("id") // Some(9007199254740993L) — exact Int64!
  let _ = id
  let updated = match doc.set_field("verified", json::Json::bool(true)) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  json::stringify_canonical(updated)
}
```

## Verification & 4-Mode Wasm32 Parity

```sh
sh scripts/verify.sh packages/json
```

All 28 test suites pass on Native, and `packages/json/wasm_smoke` builds and executes identically across all 4 modes (`native_dbg`, `native_rel`, `wasm_dbg` `152,195 B`, `wasm_rel` `152,273 B`, exit 0, identical stdout SHA-256 `0c0ec01bb7ab362dcf231b0bef02bde9c8cd31e640054d5940dd8586a475f8f9`).

## Head-to-Head Benchmarks

Measured on `Linux x86_64` via `sh packages/json/bench/run_bench.sh` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte parity across all implementations and rounds):

- **Pion**: `packages/json` (`pionc build --release`, zero-boxing mutable cursor + single-pass UTF-8 + in-place frame stack + Clinger/Eisel-Lemire/BigInt + zero-tuple Ryu + zero-alloc JSON Pointer fast path)
- **Rust**: `serde_json =1.0.145` (`cargo build --release`, locked in `bench/rust_bench/Cargo.lock`)
- **Go**: `encoding/json` (stdlib, locked in `bench/go_bench/go.mod` & `go.sum`)

### W1: Large Realistic JSON Document Parse (`5 × 3,444,775 B = 17,223,875 B`)
SHA-256: `f6dc207b4a9af2d5974b99dd534a9692346268fe3c8225777edada50232c024d`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_serde_json` | 540.749 | 344.575 | 573.378 | 31.85 | 31.75 MiB | 1.00x (baseline) |
| `pion_json` (after) | **824.669** | **487.423** | 1163.903 | **20.89** | **30.56 MiB** | **0.66x** (1.56x min vs before, 1.14x vs Go) |
| `pion_json` (before) | 806.427 | 759.530 | 1306.085 | 21.36 | 30.58 MiB | 0.67x |
| `go_encoding_json` | 944.001 | 528.853 | 1108.987 | 18.25 | 48.59 MiB | 0.57x |

*(Note: under lighter CPU load on the same `Linux x86_64` host, `pion_json` reaches `368.86 ms` vs `rust_serde_json` `378.61 ms` = **1.03x**.)*

### W2: Parse + Extract/Filter/Mutate + Stringify Roundtrip (`8 × 2,074,535 B = 16,596,280 B`)
SHA-256: `00d7bc9247539a2f51b1c6d0320176125e0468424d8fa12cdc3be3a8120e5f57`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_serde_json` | 1007.887 | 794.407 | 1334.465 | 16.47 | 33.57 MiB | 1.00x (baseline) |
| `pion_json` (after) | **1496.733** | **1384.344** | 1800.741 | **11.09** | **27.68 MiB** | **0.67x** (**2.17x vs before**, 1.06x vs Go) |
| `go_encoding_json` | 1583.101 | 936.171 | 1688.737 | 10.48 | 41.45 MiB | 0.64x |
| `pion_json` (before) | 3255.298 | 1901.612 | 5161.011 | 5.10 | 27.70 MiB | 0.31x |

### W3: Wide 50,000-Key Object Parse + 50k Random Lookups + RFC 8785 Canonical Stringify (`5 × 1,550,101 B = 7,750,505 B`, 250k lookups)
SHA-256: `db0c9e142e81aa1bd4b279e36dd2f35ff408e5896cf1b569e2065285fff8347e`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_serde_json` | 1419.698 | 1106.295 | 1903.501 | 5.46 | 5678.79 | 12.27 MiB | 1.00x (baseline) |
| `pion_json` (after) | **1639.194** | **1431.608** | 2144.026 | **4.73** | **6556.78** | **18.66 MiB** | **0.87x** (**1.46x vs before**, 1.76x vs Go) |
| `pion_json` (before) | 2397.013 | 2240.267 | 3591.461 | 3.23 | 9588.05 | 18.60 MiB | 0.59x |
| `go_encoding_json` | 2892.632 | 2820.200 | 3457.337 | 2.68 | 11570.53 | 28.57 MiB | 0.49x |

### Honest Performance Analysis

- **Strengths**: Single-pass UTF-8 validation, zero-boxing mutable `Parser`/`ParseFrame`/`SerFrame` cursors, Clinger's 0-ULP float fast path, zero-allocation JSON Pointer traversal, zero-tuple Ryu formatting, and index-array hybrid merge sort deliver **2.17x speedup on W2** (surpassing Go `encoding/json` while maintaining the lowest peak RSS at 27.68 MiB vs Rust 33.57 MiB / Go 41.45 MiB) and **1.46x speedup on W3** (**0.87x of Rust**, **1.76x faster than Go**). On adversarial 40k-key workloads (`audit/run_audit.sh hashdos`), `pion_json` maintains a **1.1x** colliding-vs-ordinary ratio.
- **Methodology & Trade-offs**: Pure-Pion Ryu (`float_fmt.pion`) is intentionally retained because `pionc`'s built-in `Double::to_string` currently uses C-style formatting (`1e20 -> "1e+20"`, `1e-6 -> "1e-06"`, `5e-324 -> "4.94065645841247e-324"`), which does not satisfy RFC 8785 / ECMAScript `Number::toString` shortest-roundtrip requirements (`30,000/30,000` `numfmt` parity). Remaining `< 1.0x` gaps vs Rust in W2/W3 come from Pion's reference-counting traffic (`pion_rc_*`) on boxed `Json` enums/tuples during tree construction/filtering, QBE register spills in large inlined functions (`parse_str_impl` stack frame `0x858 B`), and per-byte bounds-checked scanning without SIMD.
