# `jsonschema` (`v0.1.0`)

Pure Pion **JSON Schema (Draft 2020-12 & Draft-07)** compiler, validator, and Format validation engine — zero C dependencies, zero `World` dependencies, `Send`-safe, and verified on both **Native** and **WebAssembly (`wasm32`)**.

Reuses this monorepo's [`json5`](../json5) (`Json5Value`, `value_eq`, RFC 6901 `JsonPointer`) and [`regex`](../regex) (guaranteed linear-time DFA/PikeVM regex engine).

## Features

- **Draft 2020-12 & Draft-07 Compliance**:
  - **Boolean schemas**: `true`, `false`
  - **Types**: `null`, `boolean`, `integer` (exact IEEE-754 integer check: `1.0`, `-0.0`, `1e20` are integers; `1.5` is not), `number`, `string`, `array`, `object`, and type arrays (`["string", "null"]`)
  - **Value constraints**: `const`, `enum` (deep structural JSON equality: `1 == 1.0`, `true != 1`, object key-order independent, array order dependent)
  - **Numeric constraints**: `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` (exact `Int64` fast path + overflow-safe floating-point precision handling for `0.01`, `0.0001`, `1e308`)
  - **String constraints**: `minLength`, `maxLength` (**Unicode scalar value / codepoint count**, not UTF-8 byte length: `"😀"` = 1, `"中文"` = 2), `pattern` (unanchored substring match via precompiled `packages/regex`)
  - **Array constraints**: `prefixItems`, `items` (Draft 2020-12 boolean/schema & Draft-07 array-tuple + `additionalItems`), `contains` + `minContains` + `maxContains`, `minItems`, `maxItems`, `uniqueItems` (**O(N) open-addressing structural hash table**)
  - **Object constraints**: `properties` (with O(1) `StrIndexMap` for schemas with ≥ 6 properties), `patternProperties`, `additionalProperties`, `propertyNames`, `required`, `minProperties`, `maxProperties`, `dependentRequired`, `dependentSchemas`, `dependencies` (Draft-07 array & schema forms)
  - **Combinators & Conditionals**: `allOf`, `anyOf`, `oneOf`, `not`, `if` / `then` / `else`
  - **References & Scopes**: `$defs` / `definitions`, `$ref` (RFC 6901 `~0`/`~1` escaping + URI percent-decoding `%25`/`%20`), `$anchor`, `$id` local/relative URI scopes, Draft 2020-12 sibling evaluation vs Draft-07 sibling ignoring
  - **Annotations**: `unevaluatedProperties` & `unevaluatedItems` accurately propagating evaluated properties/indices through `allOf`, `anyOf`, `oneOf`, `if`/`then`/`else`, `$ref`, `contains`, `dependentSchemas`, and excluding `not`
  - **Optional Format Validation** (`ValidateOptions { validate_formats: true }`, annotation-only by default): `email`, `uri`, `uuid`, `date`, `time`, `date-time`, `ipv4`, `ipv6`, `hostname`, `json-pointer`, `regex`
  - **Dual Validation Paths**:
    - `is_valid` / `is_valid_with`: zero-allocation fast boolean short-circuit path (skips annotation tracking completely when schema does not use `unevaluated*`)
    - `validate` / `validate_with`: collects all structured `ValidationError { instance_path, schema_path, keyword, message }`
- **Day-1 Security Red-Team Defenses**:
  - Direct (`{"$ref": "#"}`) and indirect (`A -> B -> A`) `$ref` cycles compile cleanly via pre-reserved flat node IDs and terminate at `max_depth` without stack overflow
  - 50,000-level deeply nested JSON / Schema rejected cleanly with `Err` / `false` (0 SIGSEGV on Native, 0 trap on Wasm32)
  - `uniqueItems` on 20,000-element arrays runs in linear O(N) time via structural hashing
  - `pattern` / `patternProperties` run on `packages/regex`'s linear-time engine (immune to catastrophic backtracking ReDoS)
  - Malformed schemas (`minLength: -1`, `required: 123`, `multipleOf: 0`, invalid regex, unresolved `$ref`) fail at compile time with structured `Err(SchemaError)`

## Quick Start

```pion
import "jsonschema"
import "json5"

pub fn check_payload(schema_json : String, payload_json : String) -> Result[Bool, jsonschema::SchemaError] {
  let compiled = match jsonschema::compile_str(schema_json) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  let opts = jsonschema::ValidateOptions::with_formats(true)
  match json5::parse_with_options(payload_json, json5::ParseOptions::strict_json()) {
    Ok(v) => Ok(compiled.is_valid_with(v, opts))
    Err(e) => Err(jsonschema::SchemaError::new(jsonschema::SchemaErrorKind::ParseError, "", e.message))
  }
}
```

## Verification

```sh
pionc fmt --check packages/jsonschema
pionc check --json packages/jsonschema
pionc test --json packages/jsonschema

# Dual-target Native + Wasm32 smoke (4 modes, identical stdout SHA-256)
pionc run packages/jsonschema/wasm_smoke
pionc run --release packages/jsonschema/wasm_smoke
pionc run --target wasm32 packages/jsonschema/wasm_smoke
pionc run --target wasm32 --release packages/jsonschema/wasm_smoke
```

- **Unit & Red-Team Tests**: `26 / 26` passing (`compliance_core_test.pion`, `compliance_struct_test.pion`, `compliance_logic_refs_test.pion`, `compliance_format_test.pion`, `redteam_test.pion`).
- **4-Mode `wasm_smoke`**: Native debug, Native release, Wasm32 debug, and Wasm32 release (executed on `node`) all exit `0` with identical non-empty stdout (`jsonschema_wasm_smoke: OK bad_errs=4`, SHA-256: `41fc2432dc4d48d672a0844649ede5a8a4a24f17c1fb271addfb40d9a0e08f62`).

## Head-to-Head Benchmarks

Measured on `Darwin arm64` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification).

- **Pion**: `packages/jsonschema` compiled with `pionc build --release`
- **Rust**: `jsonschema =0.29.1` (`Cargo.lock` locked, `cargo build --locked --release`)
- **Node.js**: `ajv@8.17.1` (`ajv/dist/2020`)

Reproduce via:
```sh
sh packages/jsonschema/bench/run_bench.sh
```

### Workload 1: OpenAPI / MCP Tool Call Batch Validation (50,000 instances)

Mixed valid (~75%) and invalid (~25%) MCP tool call payloads against a Draft 2020-12 schema with `const`, `enum`, `pattern`, `minimum`/`maximum`, `required`, and `additionalProperties: false`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_jsonschema`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 29.424 | 28.444 | 30.287 | 588.48 | 4.05 MiB | 0.79x |
| `rust_jsonschema` | 23.237 | 20.948 | 24.412 | 464.74 | 34.78 MiB | 1.00x (baseline) |
| `node_ajv` | 95.879 | 84.981 | 97.028 | 1917.58 | 58.17 MiB | 0.24x |

_SHA-256 verified identical across all implementations and rounds: `719e1b73c6d29680f4cc94750bb4c7d57ac15c97b64816a9c1ff6ad0ac58ca52`._

### Workload 2: Complex Manifest / Workflow Schema Batch Validation (20,000 instances)

Nested package manifest / workflow schema with `$defs`, `$ref`, `oneOf`, `pattern`, `uniqueItems`, `required`, and `additionalProperties`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_jsonschema`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 30.169 | 29.111 | 33.723 | 1508.44 | 3.94 MiB | 0.87x |
| `rust_jsonschema` | 26.362 | 25.561 | 29.425 | 1318.11 | 40.70 MiB | 1.00x (baseline) |
| `node_ajv` | 102.672 | 96.019 | 107.059 | 5133.59 | 63.41 MiB | 0.26x |

_SHA-256 verified identical across all implementations and rounds: `2b436286d2983ac3ea005e519e700194e8103095711cad8e1804085f9685c739`._

### Workload 3: Schema Compilation + Validation End-to-End (2,000 schemas)

End-to-end `compile(schema)` + `is_valid(instance)` throughput across 2,000 Draft 2020-12 schemas with `$defs`/`$ref`/`pattern`/`uniqueItems`.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_jsonschema`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 29.761 | 25.881 | 40.244 | 14880.48 | 4.41 MiB | **1.19x** |
| `rust_jsonschema` | 35.405 | 30.321 | 40.834 | 17702.50 | 30.92 MiB | 1.00x (baseline) |
| `node_ajv` | 9892.757 | 7330.484 | 18020.218 | 4946378.46 | 255.78 MiB | 0.00x |

_SHA-256 verified identical across all implementations and rounds: `561dcae363a3428e6f8faa1f26372cf02000f9975d24620d30a3896e7df0031d`._

### Benchmark Takeaways

- **Compile + Validate (Workload 3)**: Pion's flat node-table compiler is **1.19x faster than Rust `jsonschema`** and **~332x faster than Node `ajv`** (which dynamically generates and V8-compiles JS code per schema), while using only **4.41 MiB** RSS vs 30.92 MiB (Rust) and 255.78 MiB (Node).
- **Steady-State Batch Validation (Workloads 1 & 2)**: Pion reaches **0.79x–0.87x of Rust `jsonschema`** and **3.26x–3.40x faster than Node `ajv`** while keeping Peak RSS at **~4 MiB** (8–10x lower than Rust's 35–41 MiB and ~15x lower than Node's 58–63 MiB). Rust `jsonschema` leads slightly on tight batch loops due to specialized per-keyword trait objects and LLVM auto-vectorization over `serde_json::Map`.

## Scope & Intentional Non-Goals

- **Offline / Pure / `World`-free**: Remote HTTP/HTTPS `$ref` fetching is intentionally omitted; all `$ref` targets resolve within the compiled schema document (`$defs`, `definitions`, `$id` local scopes, `$anchor`).
- **Draft 2020-12 `$dynamicRef` / `$dynamicAnchor`**: Not yet implemented in `v0.1.0`.
- **Content vocabulary (`contentEncoding`, `contentMediaType`, `contentSchema`)**: Treated as annotations (no assertion) per Draft 2020-12 default behavior.
