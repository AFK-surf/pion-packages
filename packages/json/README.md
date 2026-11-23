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

All 28 test suites pass on Native, and `packages/json/wasm_smoke` builds and executes identically across all 4 modes (`native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel`, exit 0, identical stdout SHA-256 `0c0ec01bb7ab362dcf231b0bef02bde9c8cd31e640054d5940dd8586a475f8f9`).

## Head-to-Head Benchmarks

Measured on `Darwin arm64` (Apple Silicon) via `sh packages/json/bench/run_bench.sh` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte parity across all implementations and rounds):

- **Pion**: `packages/json` (`pionc build --release`)
- **Rust**: `serde_json =1.0.145` (`cargo build --release`, locked in `bench/rust_bench/Cargo.lock`)
- **Go**: `encoding/json` (`go1.27.3`, stdlib, locked in `bench/go_bench/go.mod` & `go.sum`)

### W1: Large Realistic JSON Document Parse (`5 × 3,444,775 B = 17,223,875 B`)
SHA-256: `f6dc207b4a9af2d5974b99dd534a9692346268fe3c8225777edada50232c024d`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_serde_json` | 55.022 | 54.472 | 56.658 | 313.03 | 29.23 MiB | 1.00x (baseline) |
| `pion_json` | **100.040** | 98.238 | 118.875 | **172.17** | 30.53 MiB | **0.55x** (1.48x vs Go) |
| `go_encoding_json` | 147.643 | 146.578 | 158.153 | 116.66 | 44.64 MiB | 0.37x |

### W2: Parse + Extract/Filter/Mutate + Stringify Roundtrip (`8 × 2,074,535 B = 16,596,280 B`)
SHA-256: `00d7bc9247539a2f51b1c6d0320176125e0468424d8fa12cdc3be3a8120e5f57`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_serde_json` | 96.097 | 89.984 | 98.210 | 172.70 | 31.47 MiB | 1.00x (baseline) |
| `pion_json` | **171.425** | 169.439 | 179.179 | **96.81** | **27.55 MiB** | **0.56x** (1.00x vs Go) |
| `go_encoding_json` | 171.952 | 171.583 | 177.898 | 96.52 | 44.12 MiB | 0.56x |

### W3: Wide 50,000-Key Object Parse + 50k Random Lookups + RFC 8785 Canonical Stringify (`5 × 1,550,101 B = 7,750,505 B`, 250k lookups)
SHA-256: `db0c9e142e81aa1bd4b279e36dd2f35ff408e5896cf1b569e2065285fff8347e`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_serde_json` | 100.787 | 99.323 | 103.404 | 76.90 | 403.15 | 11.62 MiB | 1.00x (baseline) |
| `pion_json` | **156.211** | 152.201 | 162.996 | **49.62** | **624.84** | **22.33 MiB** | **0.65x** (2.43x vs Go) |
| `go_encoding_json` | 379.590 | 375.135 | 388.004 | 20.42 | 1518.36 | 29.77 MiB | 0.27x |

### Honest Performance Analysis

- **Strengths**: On pure parsing (W1), `pion_json` reaches **172 MB/s** (0.55x of Rust `serde_json --release`, **1.48x faster than Go `encoding/json`**) with nearly identical RSS to Rust (30.5 MiB vs 29.2 MiB). On W2, `pion_json` matches Go `encoding/json` while achieving the **lowest peak RSS** of all three (27.6 MiB). On W3 (50k-key parse + lookups + RFC 8785 JCS), fast byte-wise UTF-16 ordering (`0xEE..0xEF` vs `0xF0..0xF4` fix-up) brings `pion_json` to **156.2 ms** (**0.65x Rust**, **2.43x faster than Go**). On adversarial 40k-key workloads (`audit/run_audit.sh bench`), `pion_json` handles colliding keys at **13.1 ms** (0.83x Rust, 1.1x vs ordinary keys) and `without_keys` (20k of 40k) at **14.4 ms** (0.81x Rust, lower RSS).
- **Methodology & Trade-offs**: Rust `serde_json` is built with default features (without `float_roundtrip`), so its float parsing takes a faster, not always 0-ULP path while `pion_json` is strictly 0-ULP; in W3, Rust uses `BTreeMap` (`O(log n)` lookups) and allocates per-key strings via `serde_json::to_string`, which partially handicaps Rust in W3 while W1/W2 slightly favor Rust. Remaining W1/W2 gaps vs Rust come from Pion's pre-parse full-string UTF-8 pass and bounds-checked byte scanning.
