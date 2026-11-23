# `json` — Strict RFC 8259 JSON & RFC 8785 (JCS) for Pion

A zero-dependency, pure-Pion, `World`-free, `Send`-clean strict **RFC 8259** JSON parser, lossless value model, RFC 6901 JSON Pointer evaluator, and **RFC 8785 (JCS)** canonical serializer.

Designed to replace ad-hoc `Json` boilerplate across Pion repositories and eliminate the `> 2^53` `Int64` precision loss of `Double`-only JSON representations.

## Features

- **Strict RFC 8259 compliance**: rejects comments (`//`, `/* */`), trailing commas, single-quoted strings, unquoted keys, leading zeros (`01`), leading `+`, trailing/leading dots (`1.`, `.5`), non-RFC-8259 whitespace (`\v`, `\f`, NBSP, UTF-8 BOM), unescaped control characters (`0x00..0x1F`), lone UTF-16 surrogates, and invalid UTF-8 (overlong sequences, UTF-8 surrogates, code points `> U+10FFFF`, truncated sequences).
- **Lossless number model (`Json::Int` / `Json::Float` / `Json::BigNum` + `JsonNumber`)**:
  - Pure integers in `Int64::MIN..=Int64::MAX` (`-9223372036854775808`..`9223372036854775807`, including `> 2^53` Snowflake IDs and nanosecond timestamps) are parsed directly into `Json::Int(Int64)` without ever passing through `Double`.
  - Out-of-range integers (e.g. `u64::MAX = 18446744073709551615`, arbitrary-precision integers) and binary64-overflowing exponents (`1e500`) are preserved losslessly as `Json::BigNum(raw_repr)`, with exact `as_u64()`, `as_i64()`, `as_f64()`, and `raw_repr()` accessors.
  - Floating-point parsing uses **Eisel-Lemire 128-bit fast path + pure-Pion BigInt (Algorithm M) exact 0-ULP fallback** (handles subnormals, exact half-ULP ties-to-even, and 768+ digit literals identically on Native and Wasm32).
  - Floating-point formatting uses **pure-Pion Ryu** shortest roundtrip (zero module-level mutable state; bit-exact across Native and Wasm32).
- **Order-preserving + O(1) lookup `JsonObject`**:
  - Preserves field insertion order for deterministic serialization and diffs.
  - Uses inline linear scan for small objects (`<= 8` keys) and automatically promotes to a deterministic-seed open-addressing hash index (`> 8` keys) for O(1) lookup with zero O(n²) degradation on 50k+ key objects.
  - Configurable `DuplicateKeyPolicy`: `LastWins` (default, matching `serde_json` `preserve_order`), `FirstWins`, or `Reject` (prevents key-smuggling).
- **Ergonomic immutable API**:
  - Constructors: `Json::null`, `Json::bool`, `Json::int`, `Json::float`, `Json::big_num`, `Json::str`, `Json::arr`, `Json::obj`.
  - Readers: `get`, `get_str`, `get_i64`, `get_u64`, `get_f64`, `get_bool`, `get_array`, `get_obj`, `is_null`, `at`, `pointer` (RFC 6901).
  - Immutable mutators: `set_field`, `without_keys`, `merge_object`.
- **RFC 8785 (JCS) Canonical Serialization (`stringify_canonical`)**:
  - Sorts object keys by **UTF-16 code unit** order (so supplementary characters like `😀` `U+1F600` (`0xD83D 0xDE00`) sort before BMP `U+E000..U+FFFF` such as `דּ` `U+FB33`).
  - Uses ES6/Ryu shortest number serialization (`-0.0` → `0`, `1.0` → `1`, lowercase `\u00xx` control escapes).
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

All 22 test suites pass on Native, and `packages/json/wasm_smoke` builds and executes identically across all 4 modes (`native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel`, exit 0, identical stdout SHA-256 `d8dcc005eaee0b2c31bd24683d10dc2eee1c9bca0c2c97927cf7eb1180dca657`).

## Head-to-Head Benchmarks

Measured on `Darwin arm64` (Apple Silicon) via `sh packages/json/bench/run_bench.sh` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte parity across all implementations and rounds):

- **Pion**: `packages/json` (`pionc build --release`)
- **Rust**: `serde_json =1.0.145` (`cargo build --release`, locked in `bench/rust_bench/Cargo.lock`)
- **Go**: `encoding/json` (`go1.27.3`, stdlib, locked in `bench/go_bench/go.mod` & `go.sum`)

### W1: Large Realistic JSON Document Parse (`5 × 3,444,775 B = 17,223,875 B`)
SHA-256: `f6dc207b4a9af2d5974b99dd534a9692346268fe3c8225777edada50232c024d`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_serde_json` | 111.921 | 110.706 | 131.678 | 153.89 | 29.25 MiB | 1.00x (baseline) |
| `pion_json` | **143.528** | 140.372 | 144.326 | **120.00** | 30.52 MiB | **0.78x** (1.59x vs Go) |
| `go_encoding_json` | 227.835 | 211.472 | 258.313 | 75.60 | 47.05 MiB | 0.49x |

### W2: Parse + Extract/Filter/Mutate + Stringify Roundtrip (`8 × 2,074,535 B = 16,596,280 B`)
SHA-256: `00d7bc9247539a2f51b1c6d0320176125e0468424d8fa12cdc3be3a8120e5f57`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_serde_json` | 177.464 | 152.279 | 191.930 | 93.52 | 31.45 MiB | 1.00x (baseline) |
| `go_encoding_json` | 242.171 | 237.716 | 255.807 | 68.53 | 45.77 MiB | 0.73x |
| `pion_json` | **379.442** | 371.321 | 404.948 | **43.74** | **27.33 MiB** | **0.47x** (0.64x vs Go) |

### W3: Wide 50,000-Key Object Parse + 50k Random Lookups + RFC 8785 Canonical Stringify (`5 × 1,550,101 B = 7,750,505 B`, 250k lookups)
SHA-256: `082b4e7fccf677c67dec5e18345d8de4e15390c87db029605aae3a4b6de50861`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_serde_json` | 250.145 | 247.816 | 259.825 | 30.98 | 1000.58 | 11.61 MiB | 1.00x (baseline) |
| `pion_json` | **748.154** | 712.391 | 837.990 | **10.36** | **2992.61** | **22.31 MiB** | **0.33x** (1.03x vs Go) |
| `go_encoding_json` | 767.329 | 719.650 | 778.980 | 10.10 | 3069.32 | 30.34 MiB | 0.33x |

### Honest Performance Analysis

- **Strengths**: On pure parsing (W1), `pion_json` reaches **120 MB/s** (78% of Rust `serde_json --release`, **1.59x faster than Go `encoding/json`**) with nearly identical RSS to Rust (30.5 MiB vs 29.3 MiB). On wide 50k-key objects with random lookups and RFC 8785 canonicalization (W3), `pion_json` edges out Go `encoding/json` (**1.03x faster**, 26% lower peak RSS). On W2, `pion_json` achieves the **lowest peak RSS** of all three implementations (27.3 MiB).
- **Gaps & Trade-offs**: On W2 (0.47x vs Rust) and W3 (0.33x vs Rust), `pion_json` trails Rust `serde_json` due to: (1) dynamic `Json::pointer` path parsing inside the hot loop in W2 (vs Rust's zero-copy borrowed `&str` pointer slice), (2) per-object heap allocation of `Array[(String, Json)]` for each mutated output item, and (3) bottom-up merge sort allocating two temporary `Array`s of 50k entries in W3.
