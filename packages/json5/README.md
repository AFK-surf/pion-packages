# `json5`

Pure Pion **JSON5 v2.0** (ECMAScript 5.1 subset), **JSONC**, **RFC 6901 JSON Pointer**, and **RFC 6902 JSON Patch** (`apply` + `diff`) library.

- **Zero C glue / zero `World` dependency** — compiles and runs identically on Native and `wasm32` (verified across Native/Wasm32 × debug/release).
- **100% upstream compliance** — passes all **114 / 114** official `json5/json5-tests` cases (valid `.json`/`.json5`, invalid `.js`/`.txt`, Unicode unquoted/escaped keys), all **108 / 108** active `json-patch/json-patch-tests` RFC 6902 vectors (`spec_tests.json` + `tests.json`), RFC 6901 §5 official pointer vectors, JSONC / strict JSON modes, serialization roundtrips, and Day-1 red-team suites (**241 / 241** tests passing).
- **100% iterative parser & serializer (0 recursion)** — uses an explicit heap container stack with zero call-stack growth; verified on 10,000-level deep nesting (`[[[...]]]`) with 0 SIGSEGV, bounded by configurable `max_depth` (default `128`) and `max_nodes` (default `1_000_000`).
- **Bit-exact IEEE-754 shortest roundtrip float formatting (Ryu)** — pure Pion 128-bit integer arithmetic guarantees bit-exact roundtrip for finite binary64 doubles (`to_json_string` rejects `NaN`/`Infinity`/`-Infinity` per RFC 8259; `to_json5_string` preserves them).
- **Day-1 adversarial hardening** — strict UTF-8 validation (`parse_bytes`), malformed UTF-16 surrogate escape rejection, float overflow rejection (`1e400`), configurable duplicate-key policies (`LastWins`, `FirstWins`, `Reject`) backed by a seeded open-addressing `HashIndex` for wide objects (HashDoS-resistant), huge array index overflow/OOM guards, RFC 6902 §4.4 self-descendant `move` rejection, and atomic transaction rollback on `apply_patch` failure.

## API

```pion
pub struct Json5Error {
  pub line : Int
  pub col : Int
  pub offset : Int
  pub message : String
}

pub enum Json5Value {
  Null
  Bool(Bool)
  Number(Double)
  Str(String)
  Array(Array[Json5Value])
  Object(Array[(String, Json5Value)])
}

pub enum DuplicateKeyPolicy {
  LastWins
  FirstWins
  Reject
}

pub struct ParseOptions {
  pub max_depth : Int
  pub max_nodes : Int
  pub duplicate_keys : DuplicateKeyPolicy
  pub allow_json5 : Bool
  pub allow_comments : Bool
  pub allow_trailing_commas : Bool
  pub reject_overflow : Bool
}

// Parsing
pub fn parse(src : String) -> Result[Json5Value, Json5Error]
pub fn parse_with_options(src : String, opts : ParseOptions) -> Result[Json5Value, Json5Error]
pub fn parse_bytes(src : Bytes) -> Result[Json5Value, Json5Error]
pub fn parse_bytes_with_options(src : Bytes, opts : ParseOptions) -> Result[Json5Value, Json5Error]
pub fn parse_jsonc(src : String) -> Result[Json5Value, Json5Error]

// Serialization
pub fn to_json_string(value : Json5Value) -> Result[String, Json5Error]
pub fn to_json_string_pretty(value : Json5Value, indent : Int) -> Result[String, Json5Error]
pub fn to_json5_string(value : Json5Value) -> String
pub fn to_json5_string_pretty(value : Json5Value, indent : Int) -> String

// Accessors & Structural Equality
pub fn value_eq(a : Json5Value, b : Json5Value) -> Bool
pub fn get(value : Json5Value, key : String) -> Option[Json5Value]
pub fn get_index(value : Json5Value, index : Int) -> Option[Json5Value]
pub fn is_null(value : Json5Value) -> Bool
pub fn as_bool(value : Json5Value) -> Option[Bool]
pub fn as_number(value : Json5Value) -> Option[Double]
pub fn as_int(value : Json5Value) -> Option[Int64]
pub fn as_str(value : Json5Value) -> Option[String]
pub fn as_array(value : Json5Value) -> Option[Array[Json5Value]]
pub fn as_object(value : Json5Value) -> Option[Array[(String, Json5Value)]]
pub fn value_len(value : Json5Value) -> Int
pub fn is_empty(value : Json5Value) -> Bool

// RFC 6901 JSON Pointer
pub struct JsonPointer { pub tokens : Array[String] }
pub fn JsonPointer::parse(ptr : String) -> Result[JsonPointer, Json5Error]
pub fn JsonPointer::to_string(self : JsonPointer) -> String
pub fn pointer_escape(token : String) -> String
pub fn pointer_unescape(token : String) -> Result[String, Json5Error]
pub fn pointer_get(doc : Json5Value, ptr : String) -> Result[Option[Json5Value], Json5Error]
pub fn pointer_get_parsed(doc : Json5Value, ptr : JsonPointer) -> Option[Json5Value]

// RFC 6902 JSON Patch & Diff
pub enum PatchOp {
  Add(String, Json5Value)
  Remove(String)
  Replace(String, Json5Value)
  Move(String, String)
  Copy(String, String)
  Test(String, Json5Value)
}
pub struct Patch { pub ops : Array[PatchOp] }
pub fn parse_patch(src : String) -> Result[Patch, Json5Error]
pub fn patch_from_value(value : Json5Value) -> Result[Patch, Json5Error]
pub fn patch_to_value(patch : Patch) -> Json5Value
pub fn apply_patch(doc : Json5Value, patch : Patch) -> Result[Json5Value, Json5Error]
pub fn diff(a : Json5Value, b : Json5Value) -> Patch
```

## Example

```pion
import "json5"

let src = "// Editor config\n{ host: 'localhost', port: 0x1F90, tags: ['dev',], }\n"
match json5::parse(src) {
  Ok(doc) => {
    let std_json = json5::to_json_string(doc)
    let port = json5::pointer_get(doc, "/port")
    let patch = json5::parse_patch("[{\"op\":\"replace\",\"path\":\"/port\",\"value\":8081}]")
    let _ = (std_json, port, patch)
  }
  Err(e) => {
    // e.line, e.col, e.offset, e.message
    let _ = e
  }
}
```

## Verification

```sh
pionc fmt --check packages/json5
pionc check --json packages/json5
pionc test --json packages/json5
pionc run packages/json5/wasm_smoke
pionc run --release packages/json5/wasm_smoke
pionc run --target wasm32 packages/json5/wasm_smoke
pionc run --target wasm32 --release packages/json5/wasm_smoke
```

## Head-to-Head Benchmarks

All benchmarks run via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, **mandatory stdout SHA-256 byte-for-byte verification**) on `Darwin arm64` against:
- **Rust**: `json5 =1.3.8` + `serde_json =1.0.140` (`preserve_order`) + `json-patch =4.2.0` (`--release`, LTO)
- **Node.js**: `json5@2.2.3` + `fast-json-patch@3.1.1` (Node v24.22.2)

### Workload 1: Large Commented JSON5 Config Parse (60× 95.6 KB = 5.74 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `181 B` (`sha256:0a2adae864081868...`) | Input: `5738040 B` | Ops: `60`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_json5) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 46.070 | 43.051 | 47.728 | 124.55 | 767840.28 | 2.58 MiB | 0.98x |
| `rust_json5` | 45.344 | 43.230 | 46.249 | 126.54 | 755736.10 | 2.84 MiB | 1.00x (baseline) |
| `node_json5` | 335.266 | 311.695 | 346.727 | 17.11 | 5587772.92 | 71.67 MiB | 0.14x |

_Note: Against the earlier `pest`-based Rust `json5 =0.4.1` (271.919 ms median / 21.10 MB/s), `pion` is **5.48x faster**. Against the rewritten Rust `json5 =1.3.8`, `pion` matches within 2% (0.98x median, faster min) with lower peak RSS (2.58 MiB vs 2.84 MiB) and is **7.28x faster** than Node `json5@2.2.3`._

### Workload 2: JSON5 → Standard JSON Serialization Roundtrip (40× 95.6 KB = 3.83 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `63 B` (`sha256:0c48002fe75458d2...`) | Input: `3825360 B` | Ops: `40`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_json5) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 47.108 | 45.472 | 51.839 | 81.20 | 1177703.12 | 2.84 MiB | 0.84x |
| `rust_json5` | 39.354 | 38.548 | 40.435 | 97.20 | 983857.28 | 3.06 MiB | 1.00x (baseline) |
| `node_json5` | 239.411 | 220.521 | 263.252 | 15.98 | 5985281.25 | 70.34 MiB | 0.16x |

_Honest trade-off: `pion` trails Rust `json5 1.3.8 + serde_json` by ~16% (0.84x) on serialize roundtrip due to its 100% iterative serializer task stack (trading stack-overflow immunity for extra heap task pushes) compared to `serde_json`'s recursive stack serializer, while outperforming Node `json5@2.2.3 + JSON.stringify` by **5.08x** with 25× lower peak RSS._

### Workload 3: RFC 6902 Patch Apply + RFC 6901 Pointer Query (100,000 ops)

50,000 RFC 6901 `pointer_get` queries (including `~0`/`~1` escaped keys and array indices) + 50,000 atomic RFC 6902 `apply_patch` operations (7-op patches covering `test`, `replace`, `add` `/-`, `remove`, `move`, `copy`):

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `95 B` (`sha256:890c0a8943a1b7c0...`) | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs rust_json_patch) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 106.641 | 103.842 | 119.429 | 1066.41 | 2.00 MiB | 1.31x |
| `rust_json_patch` | 140.022 | 134.873 | 148.554 | 1400.22 | 2.14 MiB | 1.00x (baseline) |
| `node_fast_json_patch` | 266.937 | 256.552 | 303.542 | 2669.37 | 52.78 MiB | 0.52x |

_`pion` leads Rust `json-patch =4.2.0` by **1.31x** (1,066 ns/op vs 1,400 ns/op) and Node `fast-json-patch@3.1.1` by **2.50x**, at 2.00 MiB peak RSS._

Reproduce:

```sh
sh packages/json5/bench/run_bench.sh
```
