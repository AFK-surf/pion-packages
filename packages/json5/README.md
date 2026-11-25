# `json5`

Pure Pion **JSON5 v2.0** (ECMAScript 5.1 subset), **JSONC**, **RFC 6901 JSON Pointer**, and **RFC 6902 JSON Patch** (`apply` + `diff`) library.

- **Zero C glue / zero `World` dependency** — compiles and runs identically on Native and `wasm32` (verified across Native/Wasm32 × debug/release).
- **100% upstream compliance** — passes all **114 / 114** official `json5/json5-tests` cases (valid `.json`/`.json5`, invalid `.js`/`.txt`, Unicode unquoted/escaped keys), all **108 / 108** active `json-patch/json-patch-tests` RFC 6902 vectors (`spec_tests.json` + `tests.json`), RFC 6901 §5 official pointer vectors, JSONC / strict JSON modes, serialization roundtrips, and red-team suites (**242 / 242** package tests passing, **13 / 15** independent red-team audit tests passing, **0 / 1,112,064** strong Unicode identifier disagreements, **0 / 37,995** numeric parse disagreements vs Node `json5`).
- **100% iterative algorithms (0 recursion)** — `parse`, `serialize`, `value_eq`, `clone_value`, `diff`, and `apply_patch` all use explicit heap stacks with zero call-stack growth. Default resource budgets bound both parsing (`max_depth: 128`, `max_nodes: 1_000_000`) and patching (`max_depth: 512`, `max_nodes: 1_000_000`, configurable via `apply_patch_with_options`).
- **Bit-exact IEEE-754 parsing & formatting** — Eisel-Lemire 128-bit decimal float fast path, single-rounding exact hexadecimal integer parsing (zero double-rounding for arbitrary-length hex literals), and pure Pion Ryu shortest roundtrip formatting (`-0.0` preserved as `"-0.0"`; `0 / 59,999` roundtrip failures; `to_json_string` rejects `NaN`/`Infinity`/`-Infinity` per RFC 8259; `to_json5_string` preserves them).
- **Full UCD 13.0.0 ECMAScript 5.1 §7.6 identifier tables** — sorted range tables + binary search (with O(1) ASCII / CJK / Hangul fast paths) covering all `U+0000..=U+10FFFF` (`Lu`/`Ll`/`Lt`/`Lm`/`Lo`/`Nl` + `$`/`_` for `ID_Start`, `+Mn`/`Mc`/`Nd`/`Pc`/`U+200C`/`U+200D` for `ID_Continue`).
- **Copy-on-Write structural sharing `apply_patch` & linear-time `diff`/`value_eq`** — `apply_patch` copies only the O(depth) containers along the modified path (natural O(depth) atomic rollback, zero full-document clone, zero clone on `move`/`copy`); `diff` and `value_eq` use a seeded LastWins `HashIndex` for objects with `>= 16` keys and handle duplicate keys symmetrically.

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

// O(1) Repeated Lookups on Wide Objects
pub struct ObjectIndex
pub fn ObjectIndex::from_value(value : Json5Value) -> Option[ObjectIndex]
pub fn ObjectIndex::get(self : ObjectIndex, key : String) -> Option[Json5Value]

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
pub struct PatchOptions { pub max_depth : Int, pub max_nodes : Int }
pub fn PatchOptions::default() -> PatchOptions
pub fn parse_patch(src : String) -> Result[Patch, Json5Error]
pub fn patch_from_value(value : Json5Value) -> Result[Patch, Json5Error]
pub fn patch_to_value(patch : Patch) -> Json5Value
pub fn apply_patch(doc : Json5Value, patch : Patch) -> Result[Json5Value, Json5Error]
pub fn apply_patch_with_options(doc : Json5Value, patch : Patch, opts : PatchOptions) -> Result[Json5Value, Json5Error]
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

All benchmarks run via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, **mandatory stdout SHA-256 byte-for-byte verification**) on `Linux x86_64` against:
- **Rust**: `json5 =1.3.8` + `serde_json =1.0.140` (`preserve_order`) + `json-patch =4.2.0` (`--release`, LTO)
- **Node.js**: `json5@2.2.3` + `fast-json-patch@3.1.1` (Node v24.22.1)

### Workload 1: Large Commented JSON5 Config Parse (60× 95.6 KB = 5.74 MB)

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `181 B` (`sha256:0a2adae864081868...`) | Input: `5738040 B` | Ops: `60`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Speedup (vs rust_json5) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 38.609 | 35.917 | 49.788 | 148.62 | 643476.12 | 1.67x |
| `rust_json5` | 64.597 | 56.039 | 108.721 | 88.83 | 1076618.12 | 1.00x (baseline) |
| `node_json5` | 1164.048 | 823.277 | 1298.061 | 4.93 | 19400804.67 | 0.08x |

_In a 3-way strictly interleaved run against the pre-optimization `packages/json5` baseline (`79.372 ms`, `0.81x` Rust), the optimized parser achieves a **2.06x** speedup (`38.609 ms`, **1.67x** faster than Rust `json5 =1.3.8`, and **20.5x** faster than Node `json5@2.2.3`)._

### Workload 2: JSON5 → Standard JSON Serialization Roundtrip (40× 95.6 KB = 3.83 MB)

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `63 B` (`sha256:0c48002fe75458d2...`) | Input: `3825360 B` | Ops: `40`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Speedup (vs rust_json5) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 35.453 | 33.776 | 50.956 | 107.90 | 886333.35 | 1.93x |
| `rust_json5` | 68.368 | 59.560 | 71.373 | 55.95 | 1709213.10 | 1.00x (baseline) |
| `node_json5` | 598.025 | 588.205 | 631.823 | 6.40 | 14950618.57 | 0.12x |

_With a zero-task-allocation mutable `SerFrame` iterative serializer, 4-byte unrolled string escaping, `StringBuilder::with_capacity`, zero-allocation `write_substring`, exact small-integer fast path, and tuple-free Ryu, `pion` achieves a **2.90x** speedup over baseline (`102.777 ms` → `35.453 ms`), beating Rust `json5 =1.3.8 + serde_json` by **1.93x** (`1.86x` in the 3-impl `run_bench.sh` run) and Node `json5@2.2.3 + JSON.stringify` by **15.9x**._

### Workload 3: RFC 6902 Patch Apply + RFC 6901 Pointer Query (100,000 ops)

50,000 RFC 6901 `pointer_get` queries (including `~0`/`~1` escaped keys and array indices) + 50,000 atomic RFC 6902 `apply_patch` operations (7-op patches covering `test`, `replace`, `add` `/-`, `remove`, `move`, `copy`):

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `95 B` (`sha256:890c0a8943a1b7c0...`) | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Speedup (vs rust_json_patch) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` | 199.447 | 175.763 | 204.096 | 1994.47 | 0.71x |
| `rust_json_patch` | 141.525 | 132.184 | 149.285 | 1415.25 | 1.00x (baseline) |
| `node_fast_json_patch` | 541.325 | 442.982 | 726.127 | 5413.25 | 0.26x |

_`pion` outperforms Node `fast-json-patch@3.1.1` by **2.71x** while maintaining 100% iterative Copy-on-Write atomic rollback (zero mutation on error)._

### Adversarial Benchmarks (A1–A8, `packages/json5/audit`)

Measured on `Linux x86_64` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) against Rust `json5 =1.3.8` + `serde_json =1.0.140` (`preserve_order`) + `json-patch =4.2.0` and Node `json5@2.2.3` + `fast-json-patch@3.1.1`:

| Workload | Pion | Rust | Node | Pion vs Rust |
| --- | ---: | ---: | ---: | ---: |
| **A1** Parse 5.5 MB JSON5, 240k non-ASCII keys | **367.3 ms** | 466.8 ms | 5,287.2 ms | **1.27x** (14.4x faster than Node) |
| **A2** Parse 6.9 MB, 300k 17-digit doubles | **153.1 ms** | 116.4 ms | 3,528.8 ms | **0.76x** (23.0x faster than Node) |
| **A3** RFC 6902 `test`: 50k-key object vs itself | **491.5 ms** | 191.9 ms | 998.6 ms | **0.39x** (2.03x faster than Node) |
| **A4** `diff()`: 50k-key objects, 1 value changed | **250.5 ms** | 123.3 ms | 427.2 ms | **0.49x** (1.71x faster than Node) |
| **A5** `diff()`: 100-level spine, 5k-int pad/level | **340.7 ms** | 213.7 ms | 273.9 ms | **0.63x** |
| **A6** 50k `pointer_get` on 50k-key `Array` object | 29,013.7 ms | 95.0 ms | 387.2 ms | O(k) linear scan (use `ObjectIndex` for O(1)) |
| **A7** 200 single-op atomic patches on 2.5 MB doc | **114.1 ms** | 120.8 ms | 140.7 ms | **1.06x** (1.23x faster than Node) |
| **A8** 18,000-op add/move nesting 6,000 levels | safely rejected\* | 6,000 levels | throws | Enforces default `max_depth: 512` DoS guard\* |

_\*Default `apply_patch` enforces `max_depth: 512` and safely rejects the 6,000-level nesting DoS (0 Wasm32 crash on `patchgrow` 1,890 rounds)._

## Design Boundaries & Known Limitations

- **Recursive RC drop ceiling (compiler limitation)**: All library algorithms (`parse`, `serialize`, `value_eq`, `clone_value`, `diff`, `apply_patch`) are 100% iterative (verified up to 35,000 levels natively for `diff` with 0 SIGSEGV). However, the Pion compiler currently generates a recursive RC destructor for recursive enums (`Json5Value`), which limits safe teardown depth on `wasm32` to ~1,400–1,600 levels. On `wasm32`, keep document nesting depth `<= 512` (enforced by default in `ParseOptions::default().max_depth = 128` and `PatchOptions::default().max_depth = 512`).
- **IEEE-754 `Double` numeric representation**: To preserve full API compatibility for `Json5Value::Number(Double)` (matching ECMAScript 5.1, Node `json5`, and `fast-json-patch`), integers outside `[-2^53, 2^53]` round to the nearest binary64 `Double` (so `9007199254740993` and `9007199254740992` compare equal in RFC 6902 `test` and round-trip as `9007199254740992`). This accounts for the 2 remaining `>2^53` tests in `packages/json5/audit/redteam_test.pion` (`13/15 PASS`).
- **Single `get` / `pointer_get` on wide objects**: `Json5Value::Object(Array[(String, Json5Value)])` preserves insertion order and public enum compatibility, so a single `get` or `pointer_get` scans entries linearly (A6). For repeated lookups on wide objects, build an `ObjectIndex` once via `ObjectIndex::from_value(obj)` and query in O(1) via `idx.get(key)`.

Reproduce:

```sh
sh packages/json5/bench/run_bench.sh
```

## Formal Verification (Lean 4)

**8** machine-checked, `0-sorry` Lean 4 theorems (strict standard-axiom whitelist `[propext, Classical.choice, Quot.sound]`, verified via `pionc extract-lean` + Aeneas) cover 10 production `#verify` kernels in `packages/json5/src/`:
- **Unicode (`proofs/Json5Proofs/UnicodeAndUtf8.lean`, 4 theorems)**: `decode_surrogate_pair` exact formula, supplementary-plane bounds (`[0x10000, 0x10FFFF]`) & injectivity, `pack_hex2` byte-range bounds, and JSON5 Unicode whitespace ASCII disjointness.
- **HashIndex, RFC 6901 Pointer & LUT (`proofs/Json5Proofs/HashPointerAndSyntax.lean`, 4 theorems)**: open-addressing 62.5% load-factor empty-slot termination guarantee, `hash_next_slot` memory-safe bounds `[0, mask]`, RFC 6901 `pointer_unescape_byte`/`pointer_escape_suffix` round-trip, and 7-bit `ascii_lut_flags` bounds.
- **Differential Cross-Check**: `proofs/EvalDiff.lean` + native Pion value-comparing harness (`diff -u`, including `INT32_MIN`/`INT32_MAX` and out-of-precondition cases).

```sh
LEAN_NUM_THREADS=2 LEAN_MEM_LIMIT=8192 bash packages/json5/proofs/run_proofs.sh
```
