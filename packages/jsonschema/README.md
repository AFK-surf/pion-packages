# `jsonschema` (`v0.1.0`)

Pure Pion **JSON Schema (Draft 2020-12, Draft 2019-09, Draft-07 & Draft-04 auto-detect)** compiler, validator, and Format validation engine — zero C dependencies, zero `World` dependencies, `Send`-safe, and verified on both **Native** and **WebAssembly (`wasm32`)**.

Reuses this monorepo's [`json5`](../json5) (`Json5Value`, `value_eq`, RFC 6901 `JsonPointer`) and [`regex`](../regex) (guaranteed linear-time DFA/PikeVM regex engine).

## Features

- **Multi-Draft Compliance (Draft 2020-12, Draft 2019-09, Draft-07, Draft-04 auto-detect)**:
  - **Boolean schemas**: `true`, `false`
  - **Types**: `null`, `boolean`, `integer` (exact IEEE-754 integer check: `1.0`, `-0.0`, `1e20` are integers; `1.5` is not), `number`, `string`, `array`, `object`, and type arrays (`["string", "null"]`)
  - **Value constraints**: `const`, `enum` (deep structural JSON equality: `1 == 1.0`, `true != 1`, object key-order independent, array order dependent)
  - **Numeric constraints**: `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum` (including Draft-04 boolean forms), `multipleOf` (exact `Int64` fast path, tight ULP-scaled decimal quotient tolerance, and exact IEEE-754 binary mantissa divisibility for quotient overflow such as `1e308 % 0.5` and `2^30 % 2^-1000`)
  - **String constraints**: `minLength`, `maxLength` (**Unicode scalar value / codepoint count**), `pattern` & `patternProperties` with **ECMA-262 semantics** (ASCII `\d`/`\w`/`\s`/`\b`, `\cX`, `\uXXXX`, `\p{...}`) running on `packages/regex`'s linear-time engine for standard patterns and a fuel-bounded backtracking sub-engine for lookaround (`(?=...)`/`(?!...)`/`(?<=...)`/`(?<!...)`) and backreferences (`\1`..`\9`)
  - **Array constraints**: `prefixItems`, `items` (Draft 2020-12 boolean/schema & Draft-07 array-tuple + `additionalItems`), `contains` + `minContains` + `maxContains`, `minItems`, `maxItems`, `uniqueItems` (**100% iterative O(N) open-addressing structural hash table**, no depth-64 saturation)
  - **Object constraints**: `properties` (O(1) `StrIndexMap` for schemas with ≥ 6 properties), `patternProperties`, `additionalProperties`, `propertyNames`, `required` / `dependentRequired` (O(N+R) hashed lookup on wide objects), `minProperties`, `maxProperties`, `dependentSchemas`, `dependencies`
  - **Combinators & Conditionals**: `allOf`, `anyOf`, `oneOf`, `not`, `if` / `then` / `else`
  - **References & Scopes**: `$defs` / `definitions`, `$ref` (RFC 6901 `~0`/`~1` escaping + URI percent-decoding `%25`/`%20` + embedded `$id` scope tracking along JSON Pointers), order-independent two-pass `$id` + `$anchor`, Draft 2020-12 **`$dynamicRef` / `$dynamicAnchor`** and Draft 2019-09 **`$recursiveRef` / `$recursiveAnchor`**, unknown-keyword `$id` isolation, Draft 2020-12 sibling evaluation vs Draft-07 sibling ignoring (including `$id`), offline bundled Draft 2020-12 & Draft-07 meta-schemas
  - **Annotations**: `unevaluatedProperties` & `unevaluatedItems` backed by O(1) hashed `StrSet` / `IntSet` annotation sets (completely skipped in `validate()` when the schema does not use `unevaluated*`)
  - **Optional Format Validation** (`ValidateOptions { validate_formats: true }`, annotation-only by default): all 19 standard formats — `email`, `idn-email`, `uri`, `uri-reference`, `iri`, `iri-reference`, `uri-template`, `uuid`, `date`, `time`, `date-time`, `duration`, `ipv4`, `ipv6`, `hostname`, `idn-hostname` (RFC 5890/5891/5892 + Punycode), `json-pointer`, `relative-json-pointer`, `regex` (ECMA-262)
  - **Dual Validation Paths**:
    - `is_valid` / `is_valid_with`: zero-allocation fast boolean short-circuit path
    - `validate` / `validate_with`: collects all structured `ValidationError { instance_path, schema_path, keyword, message }`
- **Security & Red-Team Defenses**:
  - **Three-valued depth cutoff (fail-closed)**: hitting `max_depth` aborts the entire evaluation (`Aborted`) and is never inverted to `true` by `not`, `if`, `anyOf`, or `oneOf`
  - **Separated data depth & `$ref` tail-looping**: pure `$ref` chains (200+ hops) and direct/indirect `$ref` cycles (`{"$ref": "#"}`, `A -> B -> A`) run with O(1) call stack; legitimate recursive data up to 256 levels validates cleanly
  - **Stack-safe compile limits**: iterative resource collection, worklist-based `$ref` compilation, and a hard compile nesting cap guarantee 0 SIGSEGV on Native and 0 trap on Wasm32 even when `CompileOptions.max_depth` is set to `1_000_000`
  - **O(N) complexity under adversarial inputs**: hashed `EvalAnn`, iterative `uniqueItems` hashing, hashed `required`/`dependentRequired`, and hashed compiler `$id`/`$anchor`/`$defs` tables
  - **ReDoS-resistant regex**: standard patterns run on linear-time `packages/regex`; lookaround/backreference patterns run under a strict step-fuel budget

## Official Compliance (`JSON-Schema-Test-Suite @ 83e866b4`, `refRemote.json` excluded)

| Suite | Cases | Pion | Rust `jsonschema 0.29.1` | Node `ajv 8.17.1` |
| --- | ---: | ---: | ---: | ---: |
| `draft2020-12/*.json` | 1224 | **1210 (98.86%)** | 1206 (98.53%) | 1160 (94.77%) |
| `draft7/*.json` | 890 | **890 (100.00%)** | 890 (100.00%) | 882 (99.10%) |
| `draft2020-12/optional` | 158 | **155 (98.10%)** | 153 (96.84%) | 148 (93.67%) |
| `draft7/optional` | 118 | 112 (94.92%) | 116 (98.31%) | 108 (91.53%) |
| `draft2020-12/optional/format` (assert) | 491 | **491 (100.00%)** | 491 (100.00%) | 443 (90.22%) |
| `draft7/optional/format` (assert) | 434 | **434 (100.00%)** | 434 (100.00%) | 392 (90.32%) |
| Curated red-team corpus (`audit/diff`) | 189 | **189 (100.00%)** | 185 (97.88%) | 169 (89.42%) |

All 14 remaining `draft2020-12/*.json` failures require HTTP remote schemas (`http://localhost:1234/...`) and fail for all three offline engines. `is_valid()` and `validate()` agree on 100% of all 3,511 cases across all 4 build modes (`native/wasm32 × debug/release`, identical verdict SHA-256 `88e735d942074ea8`).

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
sh scripts/verify.sh packages/jsonschema
sh packages/jsonschema/audit/run_audit.sh all

# Dual-target Native + Wasm32 smoke (4 modes, identical stdout SHA-256)
pionc run packages/jsonschema/wasm_smoke
pionc run --release packages/jsonschema/wasm_smoke
pionc run --target wasm32 packages/jsonschema/wasm_smoke
pionc run --target wasm32 --release packages/jsonschema/wasm_smoke
```

- **Unit & Red-Team Tests**: `27 / 27` `jsonschema` unit tests + `25 / 25` `audit/redteam_test.pion` (0/18 red-team failures, 7/7 controls pass).
- **4-Mode `wasm_smoke`**: Native debug, Native release, Wasm32 debug, and Wasm32 release (executed on `node`) all exit `0` with identical stdout (`jsonschema_wasm_smoke: OK bad_errs=4`, SHA-256: `41fc2432dc4d48d672a0844649ede5a8a4a24f17c1fb271addfb40d9a0e08f62`).

## Head-to-Head Benchmarks

Measured on `Darwin arm64` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification).

- **Pion**: `packages/jsonschema` compiled with `pionc build --release`
- **Rust**: `jsonschema =0.29.1` (`Cargo.lock` locked, `cargo build --locked --release`)
- **Node.js**: `ajv@8.17.1` (`ajv/dist/2020`, single reused `Ajv2020` instance in all workloads)

Reproduce via:
```sh
sh packages/jsonschema/bench/run_bench.sh
sh packages/jsonschema/audit/run_audit.sh bench
```

### End-to-End Workloads (`run_bench.sh`, includes process start-up + JSON parse + compile)

| Workload | Pion Median (ms) | Rust Median (ms) | Node `ajv` Median (ms) | Pion RSS | Rust RSS | Pion vs Rust | SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: MCP tool call batch (50,000 ops) | 30.346 | 21.039 | 77.882 | 4.12 MiB | 34.73 MiB | 0.69x | `719e1b73...` |
| **W2**: Manifest / workflow batch (20,000 ops) | 28.730 | 21.832 | 83.605 | 4.03 MiB | 40.70 MiB | 0.76x | `2b436286...` |
| **W3**: Compile + validate E2E (2,000 schemas) | **29.104** | 30.392 | 201.044 | **4.50 MiB** | 30.92 MiB | **1.04x** | `561dcae3...` |

### Steady-State Validation Slope (Fixed Start-up Removed, 2,000 Iterations)

Because short batch runs (20–85 ms) include fixed process start-up, file I/O, JSON parsing, and schema compilation, `audit/bench/steady_state.py` measures the pure validation slope (`ns/op`) between `0` and `2,000` iterations:

| Workload | Pion fixed / steady | Rust fixed / steady | Node `ajv` fixed / steady | Pion steady vs Rust |
| --- | ---: | ---: | ---: | ---: |
| **W1** (MCP tool call) | 4.5 ms / **396 ns/op** | 10.1 ms / 116 ns/op | 68.7 ms / 91 ns/op | 0.29x |
| **W2** (Manifest / workflow) | 3.6 ms / **977 ns/op** | 12.5 ms / 268 ns/op | 68.5 ms / 421 ns/op | 0.27x |

### Adversarial Head-to-Head Benchmarks (`audit/run_audit.sh bench`)

| Workload | Pion Median (ms) | Rust Median (ms) | Node `ajv` Median (ms) | Pion RSS | Rust RSS | Pion vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **a1**: Wide objects (1,000 keys, `additionalProperties`) | 34.108 | 17.558 | 127.740 | 10.83 MiB | 18.25 MiB | 0.51x |
| **a2**: `unevaluatedProperties`, 300-key objects | 45.313 | 36.359 | 103.189 | **5.25 MiB** | 22.47 MiB | 0.80x |
| **a3**: `uniqueItems`, 2,000-element arrays of objects | 67.332 | 41.414 | 22,487.369 | 20.19 MiB | 41.62 MiB | 0.62x |
| **a4**: Recursive `$ref` tree depth 40 | 31.425 | 28.071 | 73.028 | **5.53 MiB** | 21.34 MiB | 0.89x |
| **a5**: W1 MCP schema, 5,000 distinct instances | 57.743 | 33.913 | 85.902 | 14.03 MiB | 45.75 MiB | 0.59x |

### Benchmark Takeaways

- **Compile + Validate (W3)** & **Cold/CLI latency**: Pion leads Rust slightly (`1.04x`) and is `6.9x` faster than reused-instance `ajv` while keeping Peak RSS at **4–5 MiB** (7–10x lower than Rust and 15–19x lower than Node).
- **Steady-state throughput (W1/W2/a1/a5)**: Once start-up is amortized, Rust `jsonschema` (per-keyword compiled trait objects over `serde_json::Map`) and V8-JIT'd `ajv` are ~3–4x faster per call than Pion's interpreter-style node dispatch.
- **Adversarial complexity (`a2`, `a3`, `run_audit.sh dos`)**: All quadratic paths are eliminated (`unevaluatedProperties` 50k keys in 4–6 ms, `uniqueItems` 4k deep-colliding arrays in 4–5 ms, `compile_refs_8000` in 6 ms vs Rust 15 ms, `$ref` DAG 2^22 in 91 ms / 3 MB vs Rust 7.0 s / 15.8 GB).

## Scope, Limitations & Platform Notes

- **Offline / Pure / `World`-free**: Remote HTTP/HTTPS `$ref` fetching is intentionally omitted; standard Draft 2020-12 and Draft-07 meta-schema URIs are bundled offline.
- **IEEE-754 `f64` number precision**: Inherited from `json5::Json5Value::Number(Double)`; integers beyond `2^53` (`9007199254740992`) collapse to `f64` (same as JavaScript / `ajv`, implementation-defined by JSON Schema).
- **Content vocabulary (`contentEncoding`, `contentMediaType`, `contentSchema`)**: Treated as annotations (no assertion) per Draft 2020-12 default behavior (4 Draft-07 optional `content.json` assertion cases are not asserted).
- **Platform note on extremely deep in-memory `Json5Value` drops**: String inputs (`compile_str` / `is_valid_str` / `validate_str`) are strictly protected by parser & compiler depth caps (0 SIGSEGV on Native, 0 trap on Wasm32). However, if a caller manually constructs an in-memory `json5::Json5Value` nested ≥ ~50,000 levels (Native) or ≥ ~2,000 levels (Wasm32), Pion's compiler-generated recursive RC destructor will overflow the call stack when that `Json5Value` is dropped on scope exit, independently of `jsonschema`.
