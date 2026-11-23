# `http_cache` (`v0.1.0`)

100% pure Pion implementation of **RFC 9111 (HTTP Caching)** and **RFC 9110 (HTTP-date & Conditional Requests)** — Sans-IO cache policy engine and bounded LRU in-memory cache store with zero `extern "C"`, zero `World` dependency, explicit `Result[T, CacheError]`, and explicit `CacheLimits` DoS protection. Native and `wasm32` compatible.

## Features

- **RFC 9110 §5.6.7 HTTP-date Parsing & Formatting (`src/date.pion`)**:
  - Parses IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), obsolete RFC 850 (`Sunday, 06-Nov-94 08:49:37 GMT`), and ANSI C `asctime()` (`Sun Nov  6 08:49:37 1994`) into Unix epoch seconds (`Int64`).
  - Strictly validates leap years, per-month day counts, hours (`00..23`), minutes (`00..59`), seconds (`00..59`), weekday/month tokens, and `GMT` suffix.
  - Formats canonical IMF-fixdate via `format_http_date(epoch_secs)` using O(1) civil calendar arithmetic.
- **RFC 9111 §5.2 Full `Cache-Control` Directive Parser (`src/cache_control.pion`)**:
  - Case-insensitive directive names, multi-header merging, quoted-string values with backslash escaping (e.g., `no-cache="Set-Cookie, Authorization"`), strict rejection of negative/non-digit delta-seconds, and RFC 9111 §1.2.2 clamping (`2147483648` = 2^31) against integer overflow.
  - Full request directives: `max-age`, `max-stale` (with or without delta-seconds), `min-fresh`, `no-cache`, `no-store`, `no-transform`, `only-if-cached`.
  - Full response directives: `public`, `private` (with optional field-name list), `no-cache` (with optional field-name list), `no-store`, `must-revalidate`, `proxy-revalidate`, `must-understand`, `max-age`, `s-maxage`, `immutable`, `stale-while-revalidate`, `stale-if-error`, `no-transform`.
- **RFC 9111 Policy Engine (`src/policy.pion`)**:
  - **Shared vs Private Storability (§3)**: `GET`/`HEAD` method checks, heuristically cacheable status codes (`200/203/204/206/300/301/404/405/410/414/501`) vs explicit freshness, strict `no-store` enforcement on either request or response, shared-cache `Authorization` & `private` restrictions, `must-understand`, and `Vary: *` non-reuse.
  - **Freshness & Age (§4.2)**: `s-maxage` (shared only) > `max-age` > `Expires - Date` > configurable heuristic freshness (`(Date - Last-Modified) * pct / 100` capped by `max_heuristic_seconds`); full `apparent_age`, `response_delay`, `corrected_age_value`, `initial_age`, `resident_time`, and overflow-safe `current_age`.
  - **`Vary` Matching (§4.1)**: case-insensitive header names, multi-header joining, OWS trimming, missing-vs-present distinction, and `Vary: *` rejection.
  - **Lookup, Conditional Revalidation & 304 Merging (§4.3 / §3.2)**: returns `Fresh(ttl)`, `StaleWhileRevalidate(headers)`, `StaleNeedsRevalidation(headers)` (`If-None-Match` / `If-Modified-Since`), `Miss`, or `GatewayTimeout504` (`only-if-cached`); merges 304 Not Modified metadata while preserving stored body and untouched headers.
  - **Same-Origin Unsafe Method Invalidation (§4.4)**: returns deduplicated same-origin target URI, `Location`, and `Content-Location` targets on 2xx/3xx responses to unsafe methods, blocking cross-origin cache invalidation attacks.
- **Bounded Sans-IO LRU Memory Cache (`src/store.pion`)**:
  - O(1) LRU promotion and eviction bounded by both `max_entries` and `max_total_bytes`, supporting multiple `Vary` variants per URI, in-place 304 refresh, and automatic unsafe-method invalidation.
- **DoS Protection (`CacheLimits`)**:
  - Enforces `max_header_bytes`, `max_headers`, `max_vary_headers`, `max_directives`, `max_entry_bytes`, `max_entries`, and `max_total_bytes`. Any negative limit is immediately rejected with `CacheError::LimitExceeded`; `0` strictly means 0 allowed.

## Public API

```pion
pub val struct Header { pub name : String, pub value : String }
pub val struct CacheLimits { ... }
pub enum CacheError { LimitExceeded(String), InvalidDate(String), InvalidCacheControl(String), InvalidHeader(String), InvalidUri(String), InvalidRequest(String), InvalidResponse(String) }

// RFC 9110 §5.6.7 HTTP-date
pub fn parse_http_date(s : String) -> Result[Int64, CacheError]
pub fn format_http_date(epoch_secs : Int64) -> String

// RFC 9111 §5.2 Cache-Control
pub fn parse_request_cc_value(value : String) -> Result[RequestCacheControl, CacheError]
pub fn parse_request_cache_control(headers : Array[Header]) -> Result[RequestCacheControl, CacheError]
pub fn parse_request_cache_control_with_limits(headers : Array[Header], limits : CacheLimits) -> Result[RequestCacheControl, CacheError]
pub fn parse_response_cc_value(value : String) -> Result[ResponseCacheControl, CacheError]
pub fn parse_response_cache_control(headers : Array[Header]) -> Result[ResponseCacheControl, CacheError]
pub fn parse_response_cache_control_with_limits(headers : Array[Header], limits : CacheLimits) -> Result[ResponseCacheControl, CacheError]

// RFC 9111 Policy Engine
pub fn is_storable(req : CacheRequest, resp : CacheResponse, is_shared : Bool) -> Result[Bool, CacheError]
pub fn is_storable_with_options(req : CacheRequest, resp : CacheResponse, opts : CachePolicyOptions, limits : CacheLimits) -> Result[Bool, CacheError]
pub fn compute_freshness_lifetime(resp : CacheResponse, response_time : Int64, opts : CachePolicyOptions) -> Result[Int64, CacheError]
pub fn compute_initial_age(resp : CacheResponse, request_time : Int64, response_time : Int64) -> Result[Int64, CacheError]
pub fn compute_current_age(entry : StoredEntry, now : Int64) -> Int64
pub fn vary_matches(stored_req_headers : Array[Header], new_req_headers : Array[Header], vary_headers : Array[String], vary_star : Bool) -> Bool
pub fn build_revalidation_headers(entry : StoredEntry) -> Array[Header]
pub fn create_entry(req : CacheRequest, resp : CacheResponse, body : Bytes, request_time : Int64, response_time : Int64, opts : CachePolicyOptions, limits : CacheLimits) -> Result[Option[StoredEntry], CacheError]
pub fn evaluate_lookup(req : CacheRequest, entry : StoredEntry, now : Int64, opts : CachePolicyOptions, limits : CacheLimits) -> Result[CacheLookup, CacheError]
pub fn merge_304(entry : StoredEntry, resp_304 : CacheResponse, request_time : Int64, response_time : Int64, opts : CachePolicyOptions, limits : CacheLimits) -> Result[StoredEntry, CacheError]
pub fn same_origin(uri_a : String, uri_b : String) -> Bool
pub fn invalidation_targets(req : CacheRequest, resp : CacheResponse) -> Result[Array[String], CacheError]

// Bounded LRU CacheStore
pub fn CacheStore::new(opts : CachePolicyOptions, limits : CacheLimits) -> Result[CacheStore, CacheError]
pub fn CacheStore::lookup(self : CacheStore, req : CacheRequest, now : Int64) -> Result[StoreLookup, CacheError]
pub fn CacheStore::store(self : CacheStore, req : CacheRequest, resp : CacheResponse, body : Bytes, request_time : Int64, response_time : Int64) -> Result[Bool, CacheError]
pub fn CacheStore::update_304(self : CacheStore, req : CacheRequest, resp_304 : CacheResponse, request_time : Int64, response_time : Int64) -> Result[Option[StoredEntry], CacheError]
pub fn CacheStore::invalidate_for_response(self : CacheStore, req : CacheRequest, resp : CacheResponse) -> Result[Int, CacheError]
pub fn CacheStore::invalidate_uri(self : CacheStore, uri : String) -> Int
pub fn CacheStore::entry_count(self : CacheStore) -> Int
pub fn CacheStore::total_bytes(self : CacheStore) -> Int64
pub fn CacheStore::clear(self : CacheStore) -> Unit
```

## Verification

```sh
sh scripts/verify.sh packages/http_cache
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`9f4284d25788877adf8c93cdf4dc2fe3bc0f6f8f69fa522a102c8d2e8aa92271`):

```sh
pionc run packages/http_cache/wasm_smoke
pionc run --release packages/http_cache/wasm_smoke
pionc run --target wasm32 packages/http_cache/wasm_smoke
pionc run --target wasm32 --release packages/http_cache/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/http_cache/bench/run_bench.sh` against pure-Rust **`http-cache-semantics 3.0.0` (`--release`)** on 12 realistic YouTube / Twitter(X) / Cloudflare CDN / GitHub API scenarios (`3,912 B × 5,000 = 60,000` policy + `Vary` + conditional revalidation + 304 merge evaluations), with Rust's `http::Request` / `http::Response` objects **prebuilt once outside the timed loop** for equal-footing comparison. Both implementations verify **100% byte-for-byte SHA-256 identity** across the full canonical decision digest (`381d374237a9503d7bf37d00fce5073ac74741213a17cefb98a1264cc44f229e`):

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `http-cache-semantics 3.0.0` prebuilt) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`--release`) | 65.263 | 63.918 | 70.426 | 299.71 | 1087.72 | 2.05 MiB | **1.14x** |
| `rust_http_cache_semantics_prebuilt` (`3.0.0`, `--release`) | 74.413 | 71.017 | 78.214 | 262.86 | 1240.22 | 2.50 MiB | 1.00x (baseline) |
