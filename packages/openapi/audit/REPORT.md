# Red-team audit: `packages/openapi` v0.1.0 (RT-openapi, Wave 15)

- **Target**: `origin/feat/pkg-openapi` @ `ad06774` (source untouched; this branch only adds `packages/openapi/audit/**`).
- **References**: OpenAPI 3.0.3 / 3.1.0, JSON Schema 2020-12, RFC 3986 / 6901 / 9110, Go `github.com/getkin/kin-openapi v0.131.0`
  (`openapi3` loader + `doc.Validate`, `routers/gorillamux`, `openapi3filter` with `NoopAuthenticationFunc`, `IncludeResponseStatus`).
- **Toolchain**: `pionc` from `AFK-surf/pion@66d2b4b`, `go1.27.3 darwin/arm64` (`-mod=readonly`, modules pinned by `go.sum`), Darwin arm64.
- **Reproduce**: `sh packages/openapi/audit/run_audit.sh` (sections `unit | diff | modes | dos | bench`). Exits **1** today (open defects);
  a fix branch that leaves `audit/` byte-identical exits **0** once every `p*_` test passes, the differential has `PION-WRONG=0`,
  the 4 modes agree and no DoS probe crashes, traps, times out or exceeds 1 GiB RSS. Artifacts go to `/private/tmp/rt-openapi`.

## Summary

| | count | what |
| --- | ---: | --- |
| **P0** | 1 | `$ref` fan-out: under default limits, a 90–179 KB spec makes `Validator::from_doc` take 1.1–7 GB RSS and makes wasm32 trap (also `export_tool`/`export_all_tools`) |
| **P1** | 12 | 7 fail-open validation bypasses, 4 false rejections of valid real-world input, 1 ambiguous MCP export |
| **P2** | 11 | spec divergences and capability gaps, O(n²) `validate()`, benchmark claims |
| controls | 6/6 pass | DAG bombs (2^18, 2^25), YAML alias bombs, 100k-deep JSON/YAML, recursive export, router priority and decoding, RFC 6901 escapes |

Red-team unit tests: **25/25 FAIL** (one or more per finding), **6/6 controls PASS**.
Differential (110 curated cases): `PION-WRONG=23  GO-WRONG=6  DIVERGE=22  AGREE=59`.
4 modes: corpus transcripts and 7 bounded DoS probes are **byte-identical** in `native_dbg / native_rel / wasm_dbg / wasm_rel`; 0 SIGSEGV / 0 SIGABRT.
The only wasm32 trap is the P0 memory exhaustion.

---

## P0

### P0-1 `$ref` fan-out amplification: the expansion budget limits `$ref` hops, not output size

`deref_schema_walk` (`src/ref_resolver.pion:629`) inlines a fresh deep copy of every `$ref` target. The only guards are
`max_ref_expansions` (4096 `$ref` hops, `:647`), `max_ref_depth` and `max_depth`. Nothing limits the size of what gets
copied, and `max_nodes` is checked only by the parser. A schema with ≤ 4096 refs to a wide target therefore expands to
`refs × target size` nodes. `Validator::from_doc` repeats this for every operation (`src/runtime.pion:14`, a new `DerefState` per schema,
no sharing) and keeps every copy (`CompiledSchemaEntry.raw_schema` plus the compiled form).

| probe (default `OpenApiLimits`) | spec | Pion `from_doc` | Pion `export*` | kin-openapi load + router |
| --- | ---: | --- | --- | --- |
| `fanout_4000x50` (A0: 4000 × `$ref` A1, A1: 50 props) | 173 KB | 612k nodes, **295 MB** | 7.7 MB JSON, 73 MB | 24 MB |
| `fanout_4000x200` | 179 KB | 2.4M nodes, **1146 MB** | 31 MB JSON, 265 MB | 24 MB |
| `fanout_ops_20` (20 ops × 2000 × 50) | 90 KB | 4.1M nodes, **2826 MB** | 435 MB | 20 MB |
| `fanout_ops_50` (measured once, not in the default run) | 96 KB | 10.3M nodes, **7059 MB** | 1083 MB | 20 MB |
| `fanout_ops_30`, **wasm32-release** | 92 KB | **trap**: `RangeError: Offset is outside the bounds of the DataView` at 4.36 GB | – | – |

Minimal reproduction: `p0_from_doc_fanout_expansion_exceeds_max_nodes` and `p0_export_tool_fanout_expansion_exceeds_max_nodes`
(2000 × 60: an 87 KB spec becomes 246k nodes, above `max_nodes` = 200k, with no limit tripped) and `run_audit.sh dos` / `modes`.
This hits exactly the advertised use case: build a `Validator`, or export MCP tools, from an untrusted or third-party spec.
**Fix direction**: count produced nodes against `max_nodes` (or a separate output budget) shared across one `from_doc` / `export_all_tools` call.
Better still, keep acyclic refs as shared compiled sub-schemas instead of expanding them (that also fixes P1-11).

---

## P1

| id | finding | root cause | Pion | kin / spec | test |
| --- | --- | --- | --- | --- | --- |
| P1-1 | `readOnly` + `required` rejected in **requests**, `writeOnly` + `required` rejected in **responses** (OAS 3.0.3 §4.7.24: the requirement applies to responses / requests only) | runtime has no request/response schema view, so `readOnly`/`writeOnly` are plain annotations | `missing required property: id` | ok | `p1_readonly_required_property_rejected_in_request`, `p1_writeonly_required_property_rejected_in_response` |
| P1-2 | **Fail-open**: `application/x-www-form-urlencoded`, `text/plain` (any non-JSON) bodies with a schema are never validated | `runtime.pion:450` validates only when `is_json_media_type` | `a=not-an-int` ok, 12-char text with `maxLength: 3` ok | err, err | `p1_non_json_request_bodies_are_never_validated` |
| P1-3 | **Fail-open**: parameters described with `content` (§4.7.12.1) are not validated | `parser.pion:455` reads only `schema` | `?q={"b":1}` ok | err | `p1_parameter_content_schema_is_ignored` |
| P1-4 | **Fail-open** `deepObject` (`?filter[a]=x` is never looked up) and false rejection of `form` objects (`?o=a,1` is never decoded) | `runtime.pion:230` handles only scalars and arrays; query lookup is exact-name (`:330`) | ok / err | err / ok | `p1_object_parameters_deepobject_bypass_and_form_false_reject` |
| P1-5 | **Fail-open**: a dangling parameter `$ref` turns into an unnamed optional *query* parameter. `Validator::from_doc` succeeds and the intended required header is never enforced | `parser.pion:421` `Err(_) => raw_param`; `:434/437` unknown or missing `in` falls back to `Query` | from_doc ok, request ok | load error | `p1_dangling_parameter_ref_silently_dropped_by_validator` |
| P1-6 | Literal data is walked as schema: a `"$ref"` key inside `example`/`default`/`enum`/`const` makes `from_doc` fail (and `validate()` report `DanglingRef`); the 3.0 `nullable` normalizer rewrites `enum` members | `deref_schema_walk` (`:700`) and `validate_refs_walk` recurse into every key | from_doc err; enum value rejected | ok, ok | `p1_ref_key_inside_example_breaks_from_doc`, `p1_nullable_normalizer_rewrites_enum_literals` |
| P1-7 | **Fail-open** (3.1): `$ref` siblings *override* the target instead of applying in addition (2020-12 §8.2.3.1). `{"$ref": A, "required": ["b"]}` drops A's `required: ["a"]` | `merge_ref_siblings` (`:269`) replaces target keys | `{"b":1}` ok | err | `p1_openapi31_ref_siblings_override_instead_of_and` |
| P1-8 | **Fail-open**: hoisted recursive `$defs` are keyed by the sanitized *last pointer token* only, so `a.b` / `a_b` (or `#/components/schemas/Node` and any other `…/Node`) share one definition and one subtree is validated against the other schema | `def_name_from_ref` (`:540`) + first-wins `has_hoisted` (`:694`) | `{"y":{"n":{"i":"str"}}}` ok | err | `p1_hoisted_defs_name_collision_validates_wrong_schema` |
| P1-9 | Router ignores `servers` base paths (§4.7.9: "the path is appended to the URL from the Server Object"). `servers: [{url: /api}]`: `/api/users` → 404, `/users` → matched. Server variables are unsupported | `build_router_impl` (`router.pion:205`) never reads `servers` | 404 / match | match / 404 | `p1_router_ignores_server_base_path`; diff `route.server_*` |
| P1-10 | Router drops empty segments and trailing slashes: `/users/`, `//users`, `/users//42` and `/users/42/` all match. A backend that treats them as distinct paths gets validated against the wrong operation | `split_path_segments` (`router.pion:33`) skips empty segments | match | 404 | `p1_router_collapses_empty_segments_and_trailing_slash` |
| P1-11 | False rejection of ordinary specs: the 4096-hop budget counts every inlined occurrence. An acyclic 7-schema graph (depth 6, 5 ref fields = 5^6 occurrences: any API with expandable sub-resources) fails `from_doc`/`export_tool`. So do 5000 plain `$ref` properties, and a 25-level nested schema fails on `max_depth` because ref hops count as depth | same as P0-1 | `LimitExceeded` | ok | `p1_ordinary_acyclic_schema_graph_rejected_by_expansion_budget`; dos `many_refs_*`, `dag_bomb_25` |
| P1-12 | `export_tool` emits duplicate `properties` keys: same `name` in path and query (legal, uniqueness is per `(name, in)`), or a parameter named `body` next to a JSON body. The JSON is ambiguous and one constraint silently wins | `tool_export.pion:116/142` push without namespacing or dedup | `id` ×2, `body` ×2 | – | `p1_export_tool_duplicate_property_keys` |

## P2

| id | finding | test / evidence |
| --- | --- | --- |
| P2-1 | `allowEmptyValue: true` ignored (`?s=` still checked against `minLength`) | `p2_allow_empty_value_ignored` |
| P2-2 | Path `style: label` / `matrix` not decoded (`/x/.5`, `/x/;id=5` rejected) | `p2_label_and_matrix_path_styles_unsupported` |
| P2-3 | Integer/number params accept surrounding whitespace (`" 5"`, `"5 "`; parsed as JSON text). kin (strconv) rejects them. Other coercion divergences are kin quirks rather than spec: kin accepts `0x1F`, `01`, `1_0`, `True`/`1`/`t` and rejects `1e1`/`1.0` for integer (diff `param.int[*]`, `param.bool[*]`) | `p2_numeric_parameter_accepts_surrounding_whitespace` |
| P2-4 | Unknown `in` (`body`, `formData`, `Header`) silently becomes `query`; `validate()` says nothing | `p2_unknown_parameter_location_silently_becomes_query` |
| P2-5 | `validate()` never inspects Schema Objects (`type: "strin"`, `pattern: "(["` pass; the error surfaces only in `from_doc`) | `p2_validate_does_not_check_schema_objects` |
| P2-6 | 3.0 `nullable: true` + `enum` without `null` rejects `null` (kin accepts; the 3.0.3 wording "adds null to the allowed values" supports kin) | `p2_nullable_enum_rejects_null` |
| P2-7 | `HttpMethod::parse` is case-insensitive (`types.pion:152`), so a raw `get` request line is routed (RFC 9110 §9.1: methods are case-sensitive; gorillamux returns 405) | `p2_lowercase_http_method_is_routed` |
| P2-8 | `readOnly` sent in a request and `writeOnly` returned in a response are accepted (OAS: SHOULD NOT; kin rejects by default) | `p2_readonly_in_request_and_writeonly_in_response_accepted` |
| P2-9 | Tool `name` is the raw `operationId`: violates MCP/OpenAI `^[a-zA-Z0-9_-]{1,64}$` (`tool_export.pion:87`) | `p2_export_tool_name_not_sanitized` |
| P2-10 | `validate()` is O(n²) in distinct `$ref`s (linear `checked` list `validate.pion:88` plus linear key scan per pointer step): 20k refs 1.97 s, 40k refs **9.70 s** (2.9 MB spec, within `max_nodes`); kin 0.97 s | dos `many_refs_*` |
| P2-11 | README / bench claims (see below): W1's "kin Validate does more" explanation is wrong (≈4% of Go's time); `max_nodes` is described as a general DoS limit but only bounds the parser; response `content_type` absent ⇒ assumed `application/json` (`runtime.pion:650`) | bench section |

Smaller divergences, recorded in `diff/` and not filed: the inline template `/files/{name}.{ext}` splits `a.b.c` as `a` + `b.c` (gorilla: `a.b` + `c`); `/a/b/c` with
`/a/{x}/c` and `/a/b/{y}` picks `/a/b/{y}` (gorilla picks the first declared; the spec leaves it undefined); external `$ref` loads (later reported by `validate()`) where kin refuses to load.

**Pion is right where kin is wrong** (`GO-WRONG`, 6): it rejects Swagger 2.0 (kin loads it), flags status key `2X0`, accepts a 3.1 webhooks-only doc and `type: [string, null]` (kin v0.131 is 3.0-only),
falls back to `DELETE /users/{id}` for `/users/me` when the static route lacks the method (gorilla: 405), and does not flag RFC 6901 / UTF-8 percent-encoded pointers.

## Defences that hold (controls)

- 2^18 DAG bomb: `LimitExceeded` (expansion budget) in 0.02 s / 4 MB. 2^25: `LimitExceeded` (max_depth). Both hold for `from_doc` and `export_tool`, in all 4 modes.
- YAML `&a`/`*a` 10^9 bomb, 100k-deep flow YAML, 3k-deep block YAML, 100k-deep JSON: clean errors, 3–11 MB.
- `A → A`, `A → B → A` alias cycles are reported; a 200-hop chain gives `LimitExceeded`. Mutually recursive `N ↔ M` export: self-contained `$defs`, no dangling `$ref`, compiles with `packages/jsonschema` and validates.
- Router: static beats template, backtracking works, `%2F` stays inside the segment and decodes to `/`, `%E4%B8%AD` → `中`, raw UTF-8 with `%20` stays intact, 404 vs 405, query/fragment stripping.
  1000 lookups of a 100k-segment path take 0.63 s; 5000 inline edges at one node take 0.11 s.
- Header names are case-insensitive, media-type parameters and case are handled, response matching is exact > `NXX` > `default`, 3.0 boolean `exclusiveMinimum` works,
  PathItem parameters are inherited with `(name, in)` override, and `~0 ~1 %20 %XX` pointer escapes resolve.

## 4-mode consistency

`diff/four_modes.sh`: the 110-case transcript has sha256 `95974b854d74a46e…` in **native_dbg, native_rel, wasm32_dbg, wasm32_rel** (rc 0 each).
The DoS driver gives identical last lines in all 4 modes for `dag_bomb_18`, `dag_bomb_25`, `recursive_mutual`, `ref_chain_200`, `yaml_laughs_1e9`,
`json_deep_100k` and `fanout_4000x50` (wasm32 RSS 405 MB vs native 295 MB). The only crash in any mode is the P0-1 wasm32 trap.

## Benchmark fairness (`bench/run_fair.sh`, same machine, `--warmup 1 --rounds 5`, SHA-verified where two implementations are compared)

| workload | package claim | re-run today | work-equivalence finding |
| --- | ---: | ---: | --- |
| W1 parse + validate | 6.01× | 5.84× (30.0 vs 174.8 ms) | Go `LoadFromData` alone costs **167.8 ms (96%)**; `doc.Validate` is only ≈7 ms. Go builds typed `Schema` objects and resolves refs, while Pion's `parse` keeps schemas as raw JSON and `validate()` never checks schemas (P2-5). Comparing Pion parse + validate + `Validator::from_doc` (schemas compiled) with Go load + Validate gives **2.63×** (67.3 vs 176.9 ms, same stdout SHA). The README's explanation ("kin's Validate performs additional deep checks") does not hold. |
| W2 routing | 11.76× | 13.60× (23.5 vs 318.9 ms) | `http.NewRequest` + strconv alone is 28.1 ms (≈9% of Go's time), so most of the gap is gorillamux's linear per-route regex matching. The ratio survives. But Pion does less: it ignores `servers`/host/scheme (P1-9) and collapses `//` (P1-10). |
| W3 request validation | 2.98× | 3.53× (29.9 vs 105.3 ms) | Go up to `FindRoute`, without `ValidateRequest`, is **73.4 ms (70%)**, so kin's validation itself is ≈32 ms per 10k (3.2 µs/req). Pion's whole loop, including its own routing, is 29.9 ms. **Validation alone is at rough parity (≈1.1–1.2×)**; the headline ratio is routing plus `net/http` request construction. kin also stops at the first error (`MultiError` = false) while Pion collects all, and Pion skips work kin does (readOnly/writeOnly visitors P1-1/P2-8, form bodies P1-2). |

Machine load was ≈5 during the re-run, so absolute times are above the README's. The ratios are what matter. Conclusion: the
numbers are reproducible, but they are not like-for-like. W1 should be reported as ≈2.6× (with `from_doc`), and W3 should say
that routing and request construction drive the ratio.

## Files

- `redteam_test.pion`: 25 `p0_/p1_/p2_` tests that fail while the defect exists, and 6 `control_*` tests that must pass (`pionc test -p openapi_redteam_audit packages/openapi/audit`).
- `diff/gen_cases.py`, `diff/pion_driver/`, `diff/go_oracle/` (kin-openapi v0.131.0, `go.sum`-pinned), `diff/run_diff.py`, `diff/four_modes.sh`: spec-verdict differential and 4-mode check.
- `dos/gen_dos.py`, `dos/pion_dos/`, `dos/run_dos.py`: DoS probes (Go counterpart via `go_oracle <stage> <file>`).
- `bench/run_fair.sh`, `bench/pion_fair/`, `bench/go_fair/`: re-run of W1–W3 plus work-equivalence variants (copies of the package drivers with extra modes only).
- `run_audit.sh`: one command for all of it.
