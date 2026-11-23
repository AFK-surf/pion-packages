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

### Adversarial Benchmarks (A1–A8, `packages/json5/audit`)

Measured on `Darwin arm64` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) against Rust `json5 =1.3.8` + `serde_json =1.0.140` (`preserve_order`) + `json-patch =4.2.0` and Node `json5@2.2.3` + `fast-json-patch@3.1.1`:

| Workload | Pion (Before) | Pion (After) | Rust | Node | Pion vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| **A1** Parse 5.5 MB JSON5, 240k non-ASCII keys | 0.83x | **78.1 ms** | 72.4 ms | 649.3 ms | **0.93x** (8.3x faster than Node) |
| **A2** Parse 6.9 MB, 300k 17-digit doubles | 0.49x | **59.9 ms** | 36.6 ms | 395.9 ms | **0.61x** (6.6x faster than Node) |
| **A3** RFC 6902 `test`: 50k-key object vs itself | 5,545 ms | **52.1 ms** | 28.9 ms | 116.4 ms | **0.55x** (106x speedup; 2.2x faster than Node) |
| **A4** `diff()`: 50k-key objects, 1 value changed | 16,594 ms | **48.6 ms** | 24.0 ms | 89.8 ms | **0.49x** (341x speedup; 1.85x faster than Node) |
| **A5** `diff()`: 100-level spine, 5k-int pad/level | — | **94.8 ms** | 56.3 ms | 76.4 ms | **0.59x** |
| **A6** 50k `pointer_get` on 50k-key `Array` object | 5,022 ms | 6,114 ms | 23.4 ms | 84.3 ms | O(k) linear scan (use `ObjectIndex` for O(1)) |
| **A7** 200 single-op atomic patches on 2.5 MB doc | 1,193 ms | **36.8 ms** | 28.4 ms | 59.3 ms | **0.77x** (32.4x speedup; 1.61x faster than Node) |
| **A8** 18,000-op add/move nesting 6,000 levels | 4,009 ms | **31.0 ms**\* | 25.6 ms | throws | **0.82x** (129x speedup)\* |

_\*Default `apply_patch` enforces `max_depth: 512` and safely rejects the 6,000-level nesting DoS (0 Wasm32 crash on `patchgrow` 1,890 rounds). The A8 timing above uses `apply_patch_with_options(PatchOptions::{ max_depth: 8192, max_nodes: 1_000_000 })` with SHA-256-verified identical output against Rust._

## Design Boundaries & Known Limitations

- **Recursive RC drop ceiling (compiler limitation)**: All library algorithms (`parse`, `serialize`, `value_eq`, `clone_value`, `diff`, `apply_patch`) are 100% iterative (verified up to 35,000 levels natively for `diff` with 0 SIGSEGV). However, the Pion compiler currently generates a recursive RC destructor for recursive enums (`Json5Value`), which limits safe teardown depth on `wasm32` to ~1,400–1,600 levels. On `wasm32`, keep document nesting depth `<= 512` (enforced by default in `ParseOptions::default().max_depth = 128` and `PatchOptions::default().max_depth = 512`).
- **IEEE-754 `Double` numeric representation**: To preserve full API compatibility for `Json5Value::Number(Double)` (matching ECMAScript 5.1, Node `json5`, and `fast-json-patch`), integers outside `[-2^53, 2^53]` round to the nearest binary64 `Double` (so `9007199254740993` and `9007199254740992` compare equal in RFC 6902 `test` and round-trip as `9007199254740992`). This accounts for the 2 remaining `>2^53` tests in `packages/json5/audit/redteam_test.pion` (`13/15 PASS`).
- **Single `get` / `pointer_get` on wide objects**: `Json5Value::Object(Array[(String, Json5Value)])` preserves insertion order and public enum compatibility, so a single `get` or `pointer_get` scans entries linearly (A6). For repeated lookups on wide objects, build an `ObjectIndex` once via `ObjectIndex::from_value(obj)` and query in O(1) via `idx.get(key)`.

Reproduce:

```sh
sh packages/json5/bench/run_bench.sh
```

## Formal Verification (Lean 4)

24 machine-checked, 0-`sorry` Lean 4 theorems (standard axioms only: `[propext, Classical.choice, Quot.sound]`, verified via `pionc extract-lean` + Aeneas) cover 17 production `#verify` kernels in `packages/json5/src/`:
- **Unicode & RFC 3629 UTF-8 (`proofs/Json5Proofs/UnicodeAndUtf8.lean`, 12 theorems)**: UTF-16 high/low surrogate disjointness, `decode_surrogate_pair` bounds (`[0x10000, 0x10FFFF]`) & injectivity, `pack_hex2`/`pack_hex4` bit-width bounds, JSON5 Unicode whitespace (`U+2028`/`U+2029`/`U+FEFF` & ASCII disjointness), and RFC 3629 3-/4-byte overlong, surrogate, `> U+10FFFF`, and continuation-byte rejection.
- **HashIndex, RFC 6901 Pointer & Syntax (`proofs/Json5Proofs/HashPointerAndSyntax.lean`, 12 theorems)**: SplitMix64 & `hash_ensure_nonzero` non-zero/idempotence, open-addressing 62.5% load-factor empty-slot termination guarantee, `hash_next_slot` memory-safe bounds `[0, mask]`, RFC 6901 `~0 ↔ ~` / `~1 ↔ /` escape-unescape bijection, RFC 8259 control-char escaping, and 7-bit `ascii_lut_flags` bounds.
- **Differential Cross-Check**: `proofs/EvalDiff.lean` + native Pion harness (`diff -u` 44/44 cases identical).

```sh
LEAN_NUM_THREADS=2 LEAN_MEM_LIMIT=8192 bash packages/json5/proofs/run_proofs.sh
```
