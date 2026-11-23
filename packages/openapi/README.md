# `openapi` — Pure-Pion OpenAPI 3.1 / 3.0 Parser, `$ref` Resolver, Router, Validator & AI Tool Exporter

Pure-Pion implementation of **OpenAPI 3.0.x & 3.1.0**, built on top of `packages/yaml`, `packages/json5`, and `packages/jsonschema`, aligned with Go **`github.com/getkin/kin-openapi`**.

- **Zero C dependencies / No `World`**: Pure Pion, runs identically on Native and `wasm32` (4-mode byte-identical across `native_dbg`, `native_rel`, `wasm32_dbg`, `wasm32_rel`).
- **Dual-Format OpenAPI 3.0.x & 3.1.0 Parser (`src/parser.pion`)**:
  - Parses both strict JSON (`parse_json`) and YAML 1.2 (`parse_yaml`, reusing `packages/yaml`), plus auto-detect `parse`.
  - Strict `openapi` semantic version validation (`3.0.x` and `3.1.x`; rejects Swagger 2.0 and unsupported versions).
  - Full document model: `info` (`contact`, `license`, `summary`), `jsonSchemaDialect`, `servers` (with `variables`), `paths`, OpenAPI 3.1 `webhooks`, `components` (`schemas`, `responses`, `parameters`, `examples`, `requestBodies`, `headers`, `securitySchemes`, `links`, `callbacks`, `pathItems`), `security`, `tags`, and `externalDocs`.
  - Automatic path-level parameter inheritance with operation-level `(name, in)` override semantics.
- **Cycle-Safe Internal `$ref` Resolver & DoS Limits (`src/ref_resolver.pion`)**:
  - RFC 6901 JSON Pointer resolution (`~1` → `/`, `~0` → `~`, plus URI `%XX` decoding) against any internal `#/...` target, with O(1) `components/schemas` indexing.
  - **OpenAPI 3.1 sibling semantics**: combines `$ref` validation siblings with `allOf` (JSON Schema 2020-12 §8.2.3.1 AND semantics) while preserving annotation overrides (`summary`/`description`).
  - **Shared `$defs` hoisting & cycle detection**: detects direct (`A -> A`) and mutual (`A -> B -> A`) alias cycles (`OpenApiErrorKind::RefCycle`); hoists repeated and recursive component schemas into local `#/$defs/...` using collision-free injective pointer encoding; leaves literal data blocks (`example`, `examples`, `default`, `enum`, `const`) untouched.
  - **`OpenApiLimits` DoS protection**: enforces stack-safe `max_depth` (hard-clamped at 160), `max_ref_depth`, O(V+E) virtual expansion DAG bomb detection, and a shared `max_nodes` output budget across parsing, `Validator::from_doc`, and `export_all_tools`.
- **Static Structural Validator (`src/validate.pion`)**:
  - Validates required fields (`info.title`, `info.version`, 3.0 `paths` / 3.1 `paths|webhooks|components`), duplicate `operationId`, parameter `in` locations, missing or non-required `in: path` parameter declarations, invalid HTTP methods (allowing `x-*` vendor extensions), dangling or cyclic `$ref`s (O(1) hash-set dedup + O(1) component lookup), Schema Objects (valid `type` and regex `pattern`), invalid response status codes (`100`–`599`, `1XX`–`5XX`, `default`), and **ambiguous path templates** (`/users/{id}` vs `/users/{name}`).
- **RFC 6570 Path Template Trie Router (`src/router.pion`)**:
  - Backtracking trie with strict **static > inline template > whole-segment parameter** priority (`/users/me` always beats `/users/{id}` regardless of declaration order).
  - Supports `servers` base-path prefixes (including server variable enums/defaults), strict empty-segment & trailing-slash distinction (`/users/` ≠ `/users`, `/users//42` ≠ `/users/{id}`), case-sensitive HTTP methods (RFC 9110 §9.1), inline template segments (`/files/{name}.{ext}`), percent-decoding of extracted parameters, query-string stripping, `404 NotFound` vs `405 MethodNotAllowed` (with allowed methods), and schema-driven typed path parameter coercion (`typed_path_params`).
- **Pre-Compiled Request & Response Validator (`src/runtime.pion`)**:
  - Pre-compiles parameter, request body, and response schemas into `packages/jsonschema` (`CompiledSchema`) with dedicated request/response schema views (`readOnly` omitted from request `required` and rejected in requests; `writeOnly` omitted from response `required` and rejected in responses) and OpenAPI 3.0 normalization (`nullable: true` including `enum` + `null`, boolean `exclusiveMinimum`/`exclusiveMaximum`).
  - Validates `path`, `query`, `header` (case-insensitive), and `cookie` parameters with `required`, `allowEmptyValue`, `content`-described parameters, `style` (`form`, `simple`, `pipeDelimited`, `spaceDelimited`, `deepObject`, `label`, `matrix`), and `explode` semantics.
  - Validates `application/json` (and `+json`), `application/x-www-form-urlencoded`, and `text/plain` (and `text/*`) bodies with media-type parameter stripping (`; charset=utf-8`) and wildcard matching (`type/*`, `*/*`), plus responses across exact status codes (`200`), class wildcards (`2XX`, `4XX`), and `default`.
- **AI Agent Tool / MCP Function-Calling Schema Exporter (`src/tool_export.pion`)**:
  - Exports any Operation (`export_tool` / `export_all_tools`) into a self-contained JSON Schema `object` with MCP-safe tool names (`^[a-zA-Z0-9_-]{1,64}$`), collision-free parameter/body property namespacing, **zero dangling `$ref`s** (shared/cyclic refs hoisted into local `$defs`), and MCP/OpenAI-ready JSON output (`ToolSchema::to_json`).

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
| `pion` (`parse` + `validate`) | 21.078 | 20.777 | 21.247 | 2107816.70 | 4.48 MiB | **6.05x** |
| `pion_full` (`parse` + `validate` + `Validator::from_doc`) | 32.626 | 32.514 | 33.926 | 3262595.80 | 6.77 MiB | **3.81x** |
| `go_kin` (`LoadFromData` + `doc.Validate`) | 124.374 | 121.972 | 128.040 | 12437408.30 | 20.84 MiB | 1.00x (baseline) |

> **Work-equivalence breakdown (W1)**: Go `LoadFromData` alone takes **123.118 ms (~96–99%)** of Go's total time (building typed `Schema` objects and resolving refs), while `doc.Validate` is only ~1–4 ms. Comparing equal end-to-end work — Pion `parse` + `validate` + `Validator::from_doc` (which resolves and compiles all schemas with request/response views) against Go `LoadFromData` + `doc.Validate` — gives **3.81x** (32.6 ms vs 124.4 ms, 3.1x lower RSS; previously 2.63x before component schema caching).

### W2: High-Frequency RFC 6570 Routing + Path Parameter Extraction (`50,000` lookups)

Interleaved lookups across static priority routes (`/v1/res{r}/featured` beating `/{id}`), parameterized routes (`GET`/`DELETE /v1/res{r}/{id}`), collection routes (`POST /v1/res{r}`), and 404 misses.
SHA-256: `4c4d7b675f5ca6c383cd5e0d947b3378bdec04f1c58e4aa16971968ed24019d4`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_kin`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 19.483 | 18.690 | 20.010 | 389.66 | 4.50 MiB | **11.44x** |
| `go_kin` | 222.918 | 215.686 | 235.772 | 4458.37 | 23.38 MiB | 1.00x (baseline) |

> **Work-equivalence breakdown (W2)**: Go `http.NewRequest` construction alone accounts for **19.973 ms (~9%)** of Go's 222.9 ms; the remaining ~203 ms is `gorillamux`'s linear per-route regex matching vs Pion's trie router (which supports `servers` base paths and strict empty-segment / trailing-slash matching).

### W3: Request Body + Parameter Validation (`10,000` requests)

Mixed valid and invalid requests exercising path integer coercion, query `limit` bounds, required `X-Api-Key` header checks, and `application/json` body validation (`minLength`, `minimum`, `maximum`, `required`).
SHA-256: `070f4fdacc9fa22f869032c4460aeddb1cd9a7a9ed2d607e4c53b9291e5abbba`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_kin`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 20.895 | 20.357 | 21.542 | 2089.48 | 6.95 MiB | **3.18x** |
| `go_kin` | 66.362 | 63.754 | 68.676 | 6636.23 | 21.47 MiB | 1.00x (baseline) |

> **Work-equivalence breakdown (W3)**: Go `http.NewRequest` + `FindRoute` alone (without `ValidateRequest`) takes **49.028 ms (~74%)** of Go's 66.4 ms, so `kin-openapi`'s pure `ValidateRequest` cost is ~17.3 ms per 10k requests (~1.7 µs/req, stopping on first error), while Pion's full loop (routing + full parameter/body validation collecting all errors) takes 20.9 ms (~2.1 µs/req). Thus **pure validation is at rough parity**, and the 3.18x end-to-end speedup is primarily driven by Pion's faster trie routing and zero-`net/http.Request` overhead.

### Objective Performance & Scope Notes

- **Parse + `$ref` + Static Validation (W1: 6.05x parse+validate / 3.81x work-equivalent with `Validator::from_doc`)**: `packages/openapi` parses directly via `packages/json5` strict JSON, validates Schema Objects and `$ref`s in O(n) via hash-indexed `components/schemas`, and caches compiled component schemas across operations in `Validator::from_doc` (3.1x lower RSS than `go_kin`).
- **RFC 6570 Routing (W2: 11.44x faster, 5.2x lower RSS)**: `packages/openapi`'s trie router matches path segments directly without regular expressions or `net/http.Request` allocation, whereas `kin-openapi/routers/gorillamux` compiles per-route regexes.
- **Request Validation (W3: 3.18x end-to-end, ~parity on pure validation, 3.1x lower RSS)**: `Validator::from_doc` pre-compiles parameter and media-type schemas into `packages/jsonschema` bytecode with fast boolean short-circuiting (`is_valid`); end-to-end speedup is dominated by routing + request-construction overhead in Go.
- **Current Scope**: External file/HTTP `$ref` resolution (`./other.yaml#/...`, `https://...`) is intentionally out of scope for this zero-`World` pure-Pion package; only internal `#/...` JSON Pointer references are resolved.
