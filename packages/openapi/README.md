# `openapi` — Pure-Pion OpenAPI 3.1 / 3.0 Parser, `$ref` Resolver, Router, Validator & AI Tool Exporter

Pure-Pion implementation of **OpenAPI 3.0.x & 3.1.0**, built on top of `packages/yaml`, `packages/json5`, and `packages/jsonschema`, aligned with Go **`github.com/getkin/kin-openapi`**.

- **Zero C dependencies / No `World`**: Pure Pion, runs identically on Native and `wasm32` (4-mode byte-identical across `native_dbg`, `native_rel`, `wasm32_dbg`, `wasm32_rel`).
- **Dual-Format OpenAPI 3.0.x & 3.1.0 Parser (`src/parser.pion`)**:
  - Parses both strict JSON (`parse_json`) and YAML 1.2 (`parse_yaml`, reusing `packages/yaml`), plus auto-detect `parse`.
  - Strict `openapi` semantic version validation (`3.0.x` and `3.1.x`; rejects Swagger 2.0 and unsupported versions).
  - Full document model: `info` (`contact`, `license`, `summary`), `jsonSchemaDialect`, `servers` (with `variables`), `paths`, OpenAPI 3.1 `webhooks`, `components` (`schemas`, `responses`, `parameters`, `examples`, `requestBodies`, `headers`, `securitySchemes`, `links`, `callbacks`, `pathItems`), `security`, `tags`, and `externalDocs`.
  - Automatic path-level parameter inheritance with operation-level `(name, in)` override semantics.
- **Cycle-Safe Internal `$ref` Resolver & DoS Limits (`src/ref_resolver.pion`)**:
  - RFC 6901 JSON Pointer resolution (`~1` → `/`, `~0` → `~`, plus URI `%XX` decoding) against any internal `#/...` target.
  - **OpenAPI 3.1 sibling preservation**: preserves sibling `summary`, `description`, and schema keywords on `$ref` objects.
  - **Cycle detection & recursive schema hoisting**: detects direct (`A -> A`) and mutual (`A -> B -> A`) alias cycles (`OpenApiErrorKind::RefCycle`); handles recursive data structures (`TreeNode.children -> TreeNode`) safely by hoisting cyclic definitions into local `#/$defs/...`.
  - **`OpenApiLimits` DoS protection**: enforces stack-safe `max_depth` (hard-clamped at 160), `max_ref_depth`, `max_ref_expansions` (defeats exponential `$ref` expansion bombs), `max_nodes`, `max_paths`, and `max_operations`.
- **Static Structural Validator (`src/validate.pion`)**:
  - Validates required fields (`info.title`, `info.version`, 3.0 `paths` / 3.1 `paths|webhooks|components`), duplicate `operationId`, missing or non-required `in: path` parameter declarations, invalid HTTP methods (allowing `x-*` vendor extensions), dangling or cyclic `$ref`s, invalid response status codes (`100`–`599`, `1XX`–`5XX`, `default`), and **ambiguous path templates** (`/users/{id}` vs `/users/{name}`).
- **RFC 6570 Path Template Trie Router (`src/router.pion`)**:
  - Backtracking trie with strict **static > inline template > whole-segment parameter** priority (`/users/me` always beats `/users/{id}` regardless of declaration order).
  - Supports inline template segments (`/files/{name}.{ext}`), percent-decoding of extracted parameters, query-string stripping, `404 NotFound` vs `405 MethodNotAllowed` (with allowed methods), and schema-driven typed path parameter coercion (`typed_path_params`).
- **Pre-Compiled Request & Response Validator (`src/runtime.pion`)**:
  - Pre-compiles parameter, request body, and response schemas into `packages/jsonschema` (`CompiledSchema`), normalizing OpenAPI 3.0 `nullable: true` and boolean `exclusiveMinimum`/`exclusiveMaximum` to Draft 2020-12.
  - Validates `path`, `query`, `header` (case-insensitive), and `cookie` parameters with `required`, `style` (`form`, `simple`, `pipeDelimited`, `spaceDelimited`), and `explode` semantics.
  - Validates `application/json` (and `+json`) request bodies with media-type parameter stripping (`; charset=utf-8`) and wildcard matching (`type/*`, `*/*`), plus responses across exact status codes (`200`), class wildcards (`2XX`, `4XX`), and `default`.
- **AI Agent Tool / MCP Function-Calling Schema Exporter (`src/tool_export.pion`)**:
  - Flattens any Operation (`export_tool` / `export_all_tools`) into a self-contained JSON Schema `object` combining parameters and JSON `requestBody`, with **zero dangling `$ref`s** (non-cyclic refs inlined; recursive cycles hoisted into local `$defs`) and MCP/OpenAI-ready JSON output (`ToolSchema::to_json`).

## Quick Start

```pion
import "openapi"

let doc = match openapi::parse(spec_src) {
  Ok(d) => d
  Err(e) => ...
}
let issues = doc.validate()
let router = doc.build_router()
let matched = router.find(openapi::HttpMethod::Get, "/users/42")

let validator = match openapi::Validator::from_doc(doc) {
  Ok(v) => v
  Err(e) => ...
}
let req_errs = validator.validate_request(req)
let tool = doc.export_tool("captureCharge")
```

## Verification

```sh
sh scripts/verify.sh packages/openapi
```

4-mode `wasm_smoke` (each with a clean `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/private/tmp/w15-openapi-smoke-nd pionc run packages/openapi/wasm_smoke
PION_CACHE_DIR=/private/tmp/w15-openapi-smoke-nr pionc run --release packages/openapi/wasm_smoke
PION_CACHE_DIR=/private/tmp/w15-openapi-smoke-wd pionc run --target wasm32 packages/openapi/wasm_smoke
PION_CACHE_DIR=/private/tmp/w15-openapi-smoke-wr pionc run --target wasm32 --release packages/openapi/wasm_smoke
```

All 4 modes exit `0` with byte-identical stdout:
`openapi_wasm_smoke: OK checks=6` (`sha256:959520cb76825b90f41ba1fa1946b2cb0c4eff9241f5ac4b6f0f65228760d202`).

## Head-to-Head Benchmarks vs Go `github.com/getkin/kin-openapi` (`v0.131.0`)

Run with:

```sh
sh packages/openapi/bench/run_bench.sh
```

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, Go built with `-mod=readonly`, mandatory stdout SHA-256 verification across all rounds and implementations):

### W1: Large OpenAPI 3.0.3 Spec (`150` paths / `250` operations / dense `$ref`) Parse + `$ref` Check + Static Validate (`10x`)

50 resources × 5 operations (`GET`/`POST /v1/res{i}`, `GET /v1/res{i}/featured`, `GET`/`DELETE /v1/res{i}/{id}`) with dense `#/components/schemas/*`, `#/components/parameters/*`, and `#/components/responses/*` references.
SHA-256: `6aa62f1fcd5b40de848ffca707fda394157ce0e43ca2db340ac929bccbdc9dbf`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_kin`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 20.044 | 19.595 | 20.650 | 2004454.20 | 4.36 MiB | **6.01x** |
| `go_kin` | 120.520 | 118.296 | 125.015 | 12051995.80 | 20.80 MiB | 1.00x (baseline) |

### W2: High-Frequency RFC 6570 Routing + Path Parameter Extraction (`50,000` lookups)

Interleaved lookups across static priority routes (`/v1/res{r}/featured` beating `/{id}`), parameterized routes (`GET`/`DELETE /v1/res{r}/{id}`), collection routes (`POST /v1/res{r}`), and 404 misses.
SHA-256: `4c4d7b675f5ca6c383cd5e0d947b3378bdec04f1c58e4aa16971968ed24019d4`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_kin`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 18.041 | 17.521 | 18.480 | 360.81 | 4.42 MiB | **11.76x** |
| `go_kin` | 212.167 | 205.323 | 215.449 | 4243.35 | 22.95 MiB | 1.00x (baseline) |

### W3: Request Body + Parameter Validation (`10,000` requests)

Mixed valid and invalid requests exercising path integer coercion, query `limit` bounds, required `X-Api-Key` header checks, and `application/json` body validation (`minLength`, `minimum`, `maximum`, `required`).
SHA-256: `070f4fdacc9fa22f869032c4460aeddb1cd9a7a9ed2d607e4c53b9291e5abbba`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_kin`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 21.222 | 20.668 | 22.229 | 2122.20 | 8.08 MiB | **2.98x** |
| `go_kin` | 63.224 | 60.370 | 71.875 | 6322.45 | 22.27 MiB | 1.00x (baseline) |

### Objective Performance & Scope Notes

- **Parse + `$ref` + Static Validation (W1, 6.01x faster, 4.8x lower RSS)**: `packages/openapi` parses directly via `packages/json5` strict JSON and deduplicates `$ref` pointer checks across the document. Note that `kin-openapi`'s `doc.Validate(ctx)` performs additional deep OpenAPI 3.0 meta-checks (e.g. example validation and reflection-based JSON unmarshaling via `easyjson`/`yaml`), which accounts for part of its higher cost.
- **RFC 6570 Routing (W2, 11.76x faster, 5.2x lower RSS)**: `packages/openapi`'s trie router matches path segments directly without regular expressions or `net/http.Request` allocation, whereas `kin-openapi/routers/gorillamux` compiles per-route regexes and requires constructing `*http.Request` per lookup.
- **Request Validation (W3, 2.98x faster, 2.8x lower RSS)**: `Validator::from_doc` pre-compiles all parameter and media-type schemas into flat `packages/jsonschema` bytecode and uses fast boolean short-circuiting (`is_valid`) before collecting detailed diagnostics, avoiding `kin-openapi`'s per-request `map[string]any` reflection overhead.
- **Current Scope**: External file/HTTP `$ref` resolution (`./other.yaml#/...`, `https://...`) is intentionally out of scope for this zero-`World` pure-Pion package; only internal `#/...` JSON Pointer references are resolved.
