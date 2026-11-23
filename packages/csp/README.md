# `csp` (`v0.1.0`)

100% pure Pion implementation of **W3C Content Security Policy Level 3 (CSP3)** and **WHATWG Fetch Standard CORS** — backed by pure-Pion [`packages/url`](../url) (`v0.1.1`) for full WHATWG URL Standard parsing, origin extraction, dot-segment normalization, and percent-decoding. Zero `extern "C"`, zero `World` dependency, full Native & `wasm32` compatibility.

## Features

- **Defensive `ParseLimits` & Typed `CspError`**:
  - Explicit `ParseLimits { max_header_bytes, max_policies, max_directives_per_policy, max_sources_per_directive }` (defaults: `65536`, `32`, `64`, `1024`) to prevent oversized header, directive-flood, and source-list allocation bombs.
  - Any negative limit is immediately rejected with `CspError::InvalidLimits`; `0` strictly means 0 allowed (never unlimited).
  - HTTP header-injection control bytes (`\0`, `\r`, `\n`, VT, C0 controls, DEL) are rejected with `CspError::InvalidHeader`.
  - Per W3C CSP3 §2.2.1 step 2.1, non-ASCII tokens (`> 0x7F`) are skipped individually without discarding valid policies or directives.
  - O(1) `Map`-backed directive deduplication scales linearly even when limits are raised (`20,000` directives in ~4 ms).
- **W3C Content Security Policy Level 3 (CSP3)**:
  - Full strongly-typed `SourceExpression` (`NoneExpr`, `SelfExpr`, `UnsafeInline`, `UnsafeEval`, `StrictDynamic`, `UnsafeHashes`, `WasmUnsafeEval`, `ReportSample`, `Nonce(String)`, `Hash(String, String)`, `Scheme(String)`, `Host(Option[String], String, Option[Int], Bool, String)`).
  - Strict host-source grammar validation; `parse_csp` parses only the first policy segment when a comma `,` is present so combined headers are never merged into a union (use `parse_csp_list` for multi-policy intersection).
  - Preserves base64 case sensitivity in `'nonce-...'` and `'sha256/384/512-...'` while normalizing directive names, schemes, and hosts to lowercase.
  - Complete fallback chains (fail-closed):
    - `script-src-elem` / `script-src-attr` → `script-src` → `default-src`
    - `style-src-elem` / `style-src-attr` → `style-src` → `default-src`
    - `worker-src` → `child-src` → `script-src` → `default-src`
    - `fenced-frame-src` → `frame-src` → `child-src` → `default-src`
    - `frame-src` → `child-src` → `default-src`
    - Unknown/future fetch directives fall back to `default-src` (fail-closed); non-fetch directives (`base-uri`, `form-action`, `frame-ancestors`, `sandbox`, `navigate-to`, etc.) **never** fall back to `default-src`.
  - Strict security semantics:
    - `'unsafe-inline'` is ignored when any nonce or hash is present (and when `'strict-dynamic'` is present for scripts, never styles per CSP3 §6.7.3.3).
    - `'strict-dynamic'` ignores host/scheme/`'self'` allowlists for parser-inserted scripts while permitting dynamically created scripts.
    - Inline event-handler/style attributes reject nonces and require `'unsafe-hashes'` for hash matching.
    - Target URLs and page origins are parsed with `packages/url` (WHATWG URL Standard): eliminates backslash authority confusion, multi-`@` userinfo spoofing, silent port fallback, leading-zero / tab port bypasses, and tab/LF/CR dot-segment traversal.
    - Opaque/empty page origins (`null`) never match scheme-less host-sources (CSP3 §6.7.2.8).
    - Bare `*` never matches `data:`, `blob:`, `filesystem:`, `javascript:`, or `about:` (CSP3 §6.7.2.5).
    - `*.example.com` matches subdomains (`sub.example.com`) and rejects bare `example.com` and suffix spoofs (`evilexample.com`).
    - Exact CSP3 §6.7.2.6 scheme-part matching (`http` → `https`, `ws` → `wss`/`http`/`https`, `wss` → `https`, never downgrade) and `'self'` WebSocket matching (`https://app.com` allows `wss://app.com`).
    - Exact CSP3 §6.7.2.8 port-part matching (empty port matches only `url.port == None`, so schemes without default ports never match arbitrary ports) and CSP3 §6.7.2.9 percent-decoded path segment matching (with encoded slash `%2f`/`\` rejection).
    - Injection-safe `serialize_csp`: drops directive names or tokens containing CR/LF/controls/`;`/`,`/whitespace so programmatically constructed policies cannot inject headers or directives.
    - Distinct `check_eval` (`'unsafe-eval'`) and `check_wasm_eval` (`'wasm-unsafe-eval'` or `'unsafe-eval'`).
- **WHATWG Fetch Standard CORS**:
  - `is_cors_safelisted_method` (`GET`, `HEAD`, `POST`) and `is_cors_safelisted_request_header` (enforces `<= 128 B`, CORS-unsafe request-header bytes, and `Content-Type` MIME essence `application/x-www-form-urlencoded` / `multipart/form-data` / `text/plain`).
  - `parse_origin`, `origin_equals`, `format_origin` backed by `packages/url`: properly resolves `blob:` inner origins, port `0`, IPv6, IDNA/lowercase hosts, backslash authority rules, and opaque origin (`null`) inequality (never equals any origin, including itself).
  - `check_cors_response` (rejects multi-value `Access-Control-Allow-Origin`; `CredentialsMode::Include` forbids `*`, requires exact `Access-Control-Allow-Credentials: true`, and does not expand `*` in `Access-Control-Expose-Headers`).
  - `check_cors_preflight` (Fetch §4.9: validates origin/credentials, `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers` where `*` **never** covers `Authorization`, and caps `Access-Control-Max-Age` at `86400` s).

## Public API Summary

```pion
// Limits & errors
pub val struct ParseLimits { max_header_bytes, max_policies, max_directives_per_policy, max_sources_per_directive }
pub fn ParseLimits::default() -> ParseLimits
pub fn ParseLimits::new(max_header_bytes : Int, max_policies : Int, max_directives_per_policy : Int, max_sources_per_directive : Int) -> ParseLimits
pub fn csp_error_message(err : CspError) -> String

// W3C CSP Level 3
pub fn parse_csp(header : String) -> Result[CspPolicy, CspError]
pub fn parse_csp_with_limits(header : String, limits : ParseLimits) -> Result[CspPolicy, CspError]
pub fn parse_csp_list(headers : Array[String]) -> Result[Array[CspPolicy], CspError]
pub fn parse_csp_list_with_limits(headers : Array[String], limits : ParseLimits) -> Result[Array[CspPolicy], CspError]
pub fn serialize_csp(policy : CspPolicy) -> String
pub fn format_source_expression(expr : SourceExpression) -> String
pub fn check_source(policy : CspPolicy, directive : String, page_origin : String, target_url : String, nonce : String, hashes : Array[(String, String)], is_parser_inserted : Bool) -> CspDecision
pub fn check_source_all(policies : Array[CspPolicy], directive : String, page_origin : String, target_url : String, nonce : String, hashes : Array[(String, String)], is_parser_inserted : Bool) -> CspDecision
pub fn check_inline_script(policy : CspPolicy, nonce : String, hashes : Array[(String, String)], is_attribute : Bool) -> CspDecision
pub fn check_inline_style(policy : CspPolicy, nonce : String, hashes : Array[(String, String)], is_attribute : Bool) -> CspDecision
pub fn check_eval(policy : CspPolicy) -> CspDecision
pub fn check_wasm_eval(policy : CspPolicy) -> CspDecision

// WHATWG Fetch CORS
pub fn is_cors_safelisted_method(method : String) -> Bool
pub fn is_cors_safelisted_request_header(name : String, value : String) -> Bool
pub fn parse_origin(raw_url : String) -> Origin
pub fn origin_equals(a : Origin, b : Origin) -> Bool
pub fn format_origin(origin : Origin) -> String
pub fn check_cors_response(request_origin : String, credentials_mode : CredentialsMode, allow_origin : Option[String], allow_credentials : Option[String], expose_headers : Option[String]) -> CorsResponseDecision
pub fn check_cors_preflight(request_origin : String, credentials_mode : CredentialsMode, request_method : String, request_headers : Array[String], allow_origin : Option[String], allow_credentials : Option[String], allow_methods : Option[String], allow_headers : Option[String], max_age : Option[String]) -> CorsPreflightDecision
```

## Verification & Red-Team Audit

```sh
sh scripts/verify.sh packages/csp
sh packages/csp/audit/run_audit.sh all
```

- **Unit tests**: `18/18` (`csp_test.pion`) PASS
- **Red-team audit (`packages/csp/audit`)**:
  - `control_test.pion`: **12/12 PASS**
  - `redteam_test.pion`: **20/20 PASS** (all 2 P0 + 6 P1 + 10 P2 findings resolved)
  - Differential vs independent Node WHATWG `URL` + CSP3 §6.7.2 reference (`diff/cspref.mjs`): **88,856 / 88,856 (100.0%) exact agreement** (`0` bypasses, `0` over-blocks, `0` origin mismatches)
  - Fuzz (`3` seeds × `10,000` inputs × 4 modes): `0` panics / `0` traps, all 4 modes byte-identical, `0` serialization fixpoint/decision drift
  - DoS: linear scaling (`20,000` directives in `4 ms`, `100,000` duplicates in `5 ms`, `100,000` sources in `26 ms`)

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`6d59bf6807b2cc6fc9f0c714e3390db16d12b0a43ee0db8245117737d0ac1032`):

```sh
pionc run packages/csp/wasm_smoke
pionc run --release packages/csp/wasm_smoke
pionc run --target wasm32 packages/csp/wasm_smoke
pionc run --target wasm32 --release packages/csp/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=11`)

Run via `sh packages/csp/bench/run_bench.sh` against an independent Rust W3C CSP3 + WHATWG Fetch CORS implementation (`packages/csp/bench/rust`, `cargo build --release`) backed by **`servo/rust-url` (`url = 2.5.9`)** and **`percent-encoding = 2.3.2`**.

Every decision field (`allowed`, `violated_directive`, `effective_directive`, `matched_source`, `exposed_headers`, `format_origin`, `max_age`) is hashed byte-for-byte with FNV-1a 64-bit and verified **100% identical** via SHA-256 across all rounds:

- **CSP3 workload** (`--ops 100000`, end-to-end wall time including 10,000 full policy parses + 100,000 evaluations): 5 real-world complex CSP3 headers (Twitter/X, YouTube, GitHub, Google Meet, Figma) with realistic and adversarial URLs (`\`, `.\t.`, `%61`, `wss:`, `data:`, nonces, hashes, `'strict-dynamic'`, `'wasm-unsafe-eval'`).
- **CORS workload** (`--ops 200000`, end-to-end wall time): `parse_origin` / `origin_equals` (including `blob:` and `\` authority), safelisted methods/headers, `check_cors_response`, and `check_cors_preflight` (`Authorization` wildcard rejection, credentials mode, `86400` s `max_age` cap).

| Workload | `pion` Median (`ns/op`) | `rust_csp` Median (`ns/op`) | `pion` Min / P95 (ms) | `rust_csp` Min / P95 (ms) | `pion` Peak RSS | `rust_csp` Peak RSS | `pion` vs `rust_csp` | Stdout SHA-256 (Identical) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Real-World CSP3 Parse + Eval (10k policies + 100k checks) | 96.534 ms (`965.34 ns/op`) | 65.204 ms (`652.04 ns/op`) | 95.560 / 104.051 | 64.188 / 69.148 | 2.80 MiB | 2.31 MiB | **0.68x** | `0c6bda1f51bef097...` |
| WHATWG Fetch CORS Preflight + Response + Origin (200k ops) | 67.541 ms (`337.71 ns/op`) | 42.427 ms (`212.13 ns/op`) | 66.518 / 84.032 | 41.177 / 47.698 | 2.73 MiB | 2.16 MiB | **0.63x** | `f78bb5cbd9976a46...` |

## Formal Verification (Lean 4)

The core W3C CSP3 header-injection / serialization / port-matching guards, `ParseLimits` DoS validator, and WHATWG Fetch CORS safety / `Access-Control-Max-Age` clamping kernels (`src/types.pion`, `src/csp.pion`, `src/cors.pion`) are annotated with `#verify`, extracted directly via `pionc extract-lean` (`2` types, `16` functions, `0` externals), and formally verified in Lean 4 with **24 theorems**, **0 `sorry`**, **0 `admit`**, **0 custom `axiom`**, **0 `bv_decide`**, **0 `native_decide`**, and **44/44** native-vs-Lean differential cross-checks:

- `proofs/CspProofs/HeaderAndPort.lean` (12 theorems): `ParseLimits::default` / zero-limit validity and 4-field `parse_limits_all_nonneg` iff; `csp_is_illegal_header_byte` injection rejection (NUL/LF/VT/CR/DEL) and CSP3 §2.2.1 legality of HTAB/FF/printable/non-ASCII; `csp_is_safe_serialized_byte` delimiter rejection (`;`, `,`, SP, controls) and implication of legal header byte; `csp_is_safe_directive_byte` ⊆ safe serialized byte; `csp_is_alpha` / `csp_is_digit` disjointness; overflow-free `[0, 65535]` `csp_port_step` accumulation; CSP3 §6.7.2.8 `csp_explicit_port_matches` 80→443 secure upgrade iff and no-downgrade (`443` never matches `80`).
- `proofs/CspProofs/CorsAndSafety.lean` (12 theorems): `cors_is_include` iff; `cors_clamp_max_age` exact `[0, 86400]` formula, bounds, monotonicity, and idempotency across all `Int32`; Fetch §2.2.2 `cors_is_unsafe_request_header_byte` C0/DEL and 13-punctuation rejection + HTAB/alnum safety; `cors_is_language_byte` ⊆ CORS-safe printable ASCII `[32, 122]`; `cors_is_http_ws` & `csp_is_ws` exact characterizations and legality.
- `proofs/CheckAxioms.lean`: verifies all 24 theorems depend only on Lean's standard axioms (`propext`, `Classical.choice`, `Quot.sound`).
- `proofs/EvalDiff.lean`: 44-case Lean vs native Pion differential cross-check (`diff -u` zero differences).

```sh
LEAN_NUM_THREADS=2 LEAN_MEM_LIMIT=8192 bash packages/csp/proofs/run_proofs.sh
```
