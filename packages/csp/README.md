# `csp` (`v0.1.0`)

100% pure Pion implementation of **W3C Content Security Policy Level 3 (CSP3)** and **WHATWG Fetch Standard CORS** — zero external dependencies, zero `extern "C"`, zero `World` dependency, full Native & `wasm32` compatibility.

## Features

- **Defensive `ParseLimits` & Typed `CspError`**:
  - Explicit `ParseLimits { max_header_bytes, max_policies, max_directives_per_policy, max_sources_per_directive }` (defaults: `65536`, `32`, `64`, `256`) to prevent oversized header, directive-flood, and source-list allocation bombs.
  - Any negative limit is immediately rejected with `CspError::InvalidLimits`.
  - `0` strictly means 0 allowed (never unlimited).
  - Control bytes (`\0`, `\r`, `\n`, C0 controls, DEL) and non-ASCII bytes are rejected with `CspError::InvalidHeader`.
- **W3C Content Security Policy Level 3 (CSP3)**:
  - Full strongly-typed `SourceExpression` (`NoneExpr`, `SelfExpr`, `UnsafeInline`, `UnsafeEval`, `StrictDynamic`, `UnsafeHashes`, `WasmUnsafeEval`, `ReportSample`, `Nonce(String)`, `Hash(String, String)`, `Scheme(String)`, `Host(Option[String], String, Option[Int], Bool, String)`).
  - Preserves base64 case sensitivity in `'nonce-...'` and `'sha256/384/512-...'` while normalizing directive names, schemes, and hosts to lowercase.
  - W3C CSP3 §2.2.1 duplicate-directive first-wins semantics, multi-policy comma splitting, and strict intersection evaluation (`check_source_all`).
  - Complete fallback chains:
    - `script-src-elem` / `script-src-attr` → `script-src` → `default-src`
    - `style-src-elem` / `style-src-attr` → `style-src` → `default-src`
    - `worker-src` → `child-src` → `script-src` → `default-src`
    - `frame-src` → `child-src` → `default-src`
    - `base-uri`, `form-action`, `frame-ancestors`, `sandbox` **never** fall back to `default-src`.
  - Strict security semantics:
    - `'unsafe-inline'` is strictly ignored when any nonce, hash, or `'strict-dynamic'` is present.
    - `'strict-dynamic'` ignores host/scheme/`'self'` allowlists for parser-inserted scripts while permitting dynamically created scripts.
    - Inline event-handler/style attributes reject nonces and require `'unsafe-hashes'` for hash matching.
    - Bare `*` never matches `data:`, `blob:`, `filesystem:`, `javascript:`, or `about:` (CSP3 §6.7.2.5).
    - `*.example.com` matches subdomains (`sub.example.com`) and rejects bare `example.com` and suffix spoofs (`evilexample.com`).
    - Default port normalization (`http`/`ws` 80, `https`/`wss` 443, `ftp` 21), wildcard port `:*`, IPv6 bracketed hosts `[::1]`, trailing-`/` prefix path matching vs exact file matching, and `..` / `%2e%2e` / `%2f` / `\` path-traversal rejection.
    - Scheme upgrade matching (`http` → `https`, `ws` → `wss`) with strict no-downgrade enforcement (`https` never matches `http`).
    - Distinct `check_eval` (`'unsafe-eval'`) and `check_wasm_eval` (`'wasm-unsafe-eval'` or `'unsafe-eval'`).
- **WHATWG Fetch Standard CORS**:
  - `is_cors_safelisted_method` (`GET`, `HEAD`, `POST`) and `is_cors_safelisted_request_header` (enforces `<= 128 B`, CORS-unsafe request-header bytes, and `Content-Type` MIME essence `application/x-www-form-urlencoded` / `multipart/form-data` / `text/plain`).
  - `parse_origin`, `origin_equals`, `format_origin` with default-port normalization, IPv6 support, and spec-compliant opaque origin (`null`) inequality (never equals any origin, including itself).
  - `check_cors_response` (rejects multi-value `Access-Control-Allow-Origin`; `CredentialsMode::Include` forbids `*`, requires exact `Access-Control-Allow-Credentials: true`, and does not expand `*` in `Access-Control-Expose-Headers`).
  - `check_cors_preflight` (Fetch §4.9: validates origin/credentials, `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers` where `*` **never** covers `Authorization`, and `Access-Control-Max-Age`).

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
pub fn parse_origin(url : String) -> Origin
pub fn origin_equals(a : Origin, b : Origin) -> Bool
pub fn format_origin(origin : Origin) -> String
pub fn check_cors_response(request_origin : String, credentials_mode : CredentialsMode, allow_origin : Option[String], allow_credentials : Option[String], expose_headers : Option[String]) -> CorsResponseDecision
pub fn check_cors_preflight(request_origin : String, credentials_mode : CredentialsMode, request_method : String, request_headers : Array[String], allow_origin : Option[String], allow_credentials : Option[String], allow_methods : Option[String], allow_headers : Option[String], max_age : Option[String]) -> CorsPreflightDecision
```

## Verification

```sh
sh scripts/verify.sh packages/csp
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`6d59bf6807b2cc6fc9f0c714e3390db16d12b0a43ee0db8245117737d0ac1032`):

```sh
pionc run packages/csp/wasm_smoke
pionc run --release packages/csp/wasm_smoke
pionc run --target wasm32 packages/csp/wasm_smoke
pionc run --target wasm32 --release packages/csp/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/csp/bench/run_bench.sh` against an idiomatic zero-dependency Rust W3C CSP3 + WHATWG Fetch CORS reference implementation (`packages/csp/bench/rust`, `cargo build --release`, strictly equivalent parsing and policy evaluation semantics).

- **CSP3 workload**: 10,000 full policy parses + 100,000 policy evaluations across 5 real-world complex CSP3 headers (Twitter/X, YouTube, GitHub, Google Meet, Figma), covering fallback chains, nonce/hash/`'strict-dynamic'`, `'wasm-unsafe-eval'`, path traversal rejection, wildcard scheme boundaries, and inline/eval checks.
- **CORS workload**: 200,000 WHATWG Fetch CORS operations covering `parse_origin` / `origin_equals` (including opaque `null`), safelisted methods/headers, `check_cors_response` (credentials/wildcard/multi-value ACAO/expose-headers), and `check_cors_preflight` (`Authorization` wildcard rejection, credentials mode, `max_age`).

All decision summaries and checksums are verified **100% byte-for-byte identical** via SHA-256:

| Workload | `pion` Median (`ns/op`) | `rust_csp` Median (`ns/op`) | `pion` Min / P95 (ms) | `rust_csp` Min / P95 (ms) | `pion` Peak RSS | `rust_csp` Peak RSS | `pion` vs `rust_csp` | Stdout SHA-256 (Identical) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Real-World CSP3 Parse + Eval (10k policies + 100k checks) | 83.293 ms (`832.93 ns/op`) | 82.303 ms (`823.03 ns/op`) | 78.553 / 101.210 | 63.029 / 92.115 | 1.84 MiB | 2.17 MiB | **0.99x** | `4770c1bfd0888acf...` |
| WHATWG Fetch CORS Preflight + Response + Origin (200k ops) | 65.260 ms (`326.30 ns/op`) | 66.592 ms (`332.96 ns/op`) | 49.692 / 118.140 | 38.248 / 80.580 | 1.80 MiB | 1.97 MiB | **1.02x** | `347ed2751f269e63...` |
