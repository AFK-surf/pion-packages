# `http1` — Pure Pion Sans-IO RFC 9112 HTTP/1.1 & WHATWG SSE Engine

A zero-dependency, pure Pion implementation of **RFC 9110 / RFC 9112 HTTP/1.1** (request/response incremental parsing & encoding, chunked transfer coding) and **WHATWG HTML §9.2.6 Server-Sent Events (EventSource / SSE)** streaming decoding, modeled on Rust's `httparse` and Go's `net/http`.

Designed with a **Sans-IO** architecture: no `World` dependency, no socket or runtime coupling, explicit `Result[T, HttpError]` error handling, and dual-target verified on **Native (`arm64_apple`)** and **WebAssembly (`wasm32`)**.

## Features

- **Incremental HTTP/1.1 Request & Response Parser** (`src/parser.pion`):
  - `parse_request` / `parse_request_with_limits` / `parse_request_at` and `parse_response` / `parse_response_with_limits` / `parse_response_at` returning `Result[ParseStatus[T], HttpError]` (`Complete(val, consumed)` or `Partial`) for arbitrary TCP fragmentation.
  - Strict RFC 9110 `tchar` token validation, HTTP/1.0 & HTTP/1.x (`>= 1.1` treated as HTTP/1.1 per RFC 9110 §2.5) version checks, bounded leading CRLF tolerance before request-line (RFC 9112 §2.2), 3-digit status codes, optional reason phrases, header OWS trimming, RFC 9110 `obs-text` preservation, and ASCII case-insensitive header lookup (`header(name)` / `headers_named(name)`).
  - Global 256-byte `FixedArray[Int]` lookup tables (`src/lut.pion`, `P53-C` BCE) + 4-byte unrolled window scanning (`while pos <= end - 4`).
- **Day-1 HTTP Request Smuggling & CRLF Injection Defenses**:
  - **Mandatory `Host` validation (RFC 9112 §3.2)**: HTTP/1.1 requests missing `Host`, containing duplicate `Host` headers (case-insensitive), or carrying malformed `Host` authority values return `Err(HttpError::InvalidHost)`.
  - **1xx / 204 / 304 zero-body framing (RFC 9112 §6.3 rule 1)**: Responses with `1xx`, `204`, or `304` status codes always report `Framing::None` regardless of `Content-Length` or `Transfer-Encoding` headers (preventing keep-alive response desync). Note: callers parsing responses to `HEAD` requests should similarly treat the response as having no body.
  - **CL + TE conflict rejection**: Simultaneous `Content-Length` and `Transfer-Encoding` immediately returns `Err(HttpError::AmbiguousFraming)`.
  - **Duplicate / malformed `Content-Length` rejection**: Multiple `Content-Length` headers (even with identical values), comma-separated lists (`"10, 20"`), signs (`+10`, `-5`), whitespace, or `Int64` overflow return `Err(HttpError::InvalidContentLength)`.
  - **`Transfer-Encoding` obfuscation rejection**: Non-final `chunked` (requests), duplicate `chunked`, unknown/parameterized codings (`xchunked`, `chunked; q=1`), empty elements, and HTTP/1.0 `Transfer-Encoding` (both requests and responses, RFC 9112 §6.1) return `Err(HttpError::InvalidTransferEncoding)`.
  - **`obs-fold`, whitespace-before-colon, bare CR/LF, and CTL rejection**: `Host : evil`, continuation lines starting with SP/HTAB (`ObsFold`), bare `\r`/`\n` (`BareCrOrLf`), and NUL/C0/DEL bytes (`InvalidHeaderValue`) are strictly rejected.
  - **Explicit `Int64` `Limits`**: `max_headers`, `max_header_bytes` (enforced even on partial buffers to prevent OOM DoS), `max_uri_bytes`, `max_chunk_size` (streaming-friendly default `0x3FFFFFFFFFFFFFFF`), `max_chunk_ext_bytes`, `max_trailers`, `max_sse_line_bytes`, and `max_sse_event_bytes`.
- **Incremental Chunked Transfer Coding Decoder** (`src/chunked.pion`):
  - `ChunkedDecoder` with O(1) compacting chunk queue, strict hex `chunk-size` capped at 16 hex digits (deterministic across arbitrary TCP segmentation, matching Go `net/http` and `httparse`) with `Int64` overflow checks, RFC 9112 §7.1.1 chunk extension (token & quoted-string) validation, strict `\r\n` terminators, trailer header parsing, pipelined trailing-byte preservation (`remaining_bytes()` / `take_remaining()`), zero-copy full-buffer passthrough, and 1-byte drip equivalence.
- **Smuggling- & CRLF-Safe HTTP/1.1 & Chunked Encoder** (`src/encoder.pion`):
  - `encode_request`, `encode_response`, `encode_chunk`, and `encode_final_chunk` strictly reject CR, LF, and NUL (`Err(HttpError::CrlfInjection)`), untrimmed leading/trailing OWS in header values (RFC 9110 §5.5), CL+TE smuggling, duplicate/malformed `Content-Length`, invalid `Transfer-Encoding`, HTTP/1.0 `Transfer-Encoding`, duplicate/invalid `Host`, and RFC 9110 §6.5.1 forbidden trailer fields (`Content-Length`, `Transfer-Encoding`, `Host`, `Trailer`, etc.).
- **WHATWG HTML §9.2.6 SSE / EventSource Streaming Decoder** (`src/sse.pion`):
  - `SseDecoder::feed(chunk)` & `SseDecoder::finish()` with zero-copy fast-path line scanning, ASCII fast-path + WHATWG maximal-subpart UTF-8 `U+FFFD` replacement for invalid byte sequences, and single-line `data:` fast path (avoiding `StringBuilder` allocation on 90%+ of LLM token events).
  - Full `\r\n`, `\n`, `\r`, and cross-chunk `\r`+`\n` merging; start-of-stream UTF-8 BOM stripping (including 1-byte split BOM); comment lines; single leading space removal after `:`; WHATWG-compliant `last_event_id` (buffered on `id:` and committed only on blank-line dispatch, with NUL rejection); strict ASCII decimal `retry:`; empty-data event suppression; and 1-byte drip equivalence.

## Quick Start

```pion
import "http1"

// 1. Parse an HTTP/1.1 request
let raw = "POST /v1/chat HTTP/1.1\r\nHost: api.example.com\r\nTransfer-Encoding: chunked\r\n\r\n".to_bytes()
match http1::parse_request(raw) {
  Ok(http1::ParseStatus::Complete(req, consumed)) => {
    let _ = (req.method, req.path, req.is_chunked(), consumed)
  }
  Ok(http1::ParseStatus::Partial) => ()
  Err(err) => {
    let _ = http1::http_error_string(err)
  }
}

// 2. Incrementally decode a chunked body
let cdec = http1::ChunkedDecoder::new()
cdec.feed("5\r\nhello\r\n0\r\n\r\n".to_bytes())
match cdec.next() {
  Ok(http1::ChunkStep::Data(chunk)) => {
    let _ = chunk.to_string() // "hello"
  }
  _ => ()
}

// 3. Stream-decode WHATWG Server-Sent Events (LLM token stream)
let sse = http1::SseDecoder::new()
match sse.feed("event: content_block_delta\ndata: {\"text\":\"hi\"}\n\n".to_bytes()) {
  Ok(events) => {
    let _ = events.length() // 1
  }
  Err(_) => ()
}
```

## Verification

- **Native Compliance & Red-Team Suite**: **49 / 49 passing** (`pionc test --json packages/http1`), covering ported Rust `httparse` request/response/partial/chunk-size tests, RFC 9112 §7.1 chunked + 1-byte drip tests, WHATWG HTML §9.2.6 / WPT EventSource SSE tests, and Day-1 HTTP Request Smuggling & CRLF injection tests.
- **Red-Team Audit Suite**: **33 / 33 passing** (`pionc test --json -p http1_redteam_audit packages/http1/audit`) + 200,000-case mutation fuzz (`0` divergences).
- **Formatting & Typecheck**: `pionc fmt --check packages/http1` and `pionc check --json packages/http1` pass with 0 diagnostics.
- **WebAssembly (`wasm32`)**: `pionc build --release --target wasm32 packages/http1/wasm_smoke` builds cleanly and `pionc run --release --target wasm32 packages/http1/wasm_smoke` exits `0` under Node.js.

## Benchmarks

Head-to-head steady-state benchmarks via `sh packages/http1/bench/run_bench.sh` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification) on `Darwin arm64` against **Rust `httparse 1.10.1` (`--release`)** and **Go `net/http` (`go1.27.3`)**:

### 1. HTTP/1.1 Request Parse (200,000 mixed requests, 67.92 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_httparse`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **232.180** | 229.165 | 239.914 | **292.54** | 1160.90 | 34.20 MiB | 0.37x |
| `rust_httparse` | 86.743 | 84.775 | 96.716 | 783.02 | 433.72 | 18.05 MiB | 1.00x (baseline) |
| `go_net_http` | 342.642 | 325.165 | 353.424 | 198.23 | 1713.21 | 47.80 MiB | 0.25x |

_SHA-256 verified identical across all implementations and rounds: `ee568111200158fe227d7ab72523087716ac740d973a453d0bf9816024e0dd1f`._

### 2. HTTP/1.1 Response + Chunked Streaming Decode (100,000 chunked responses, 40.77 MB)

> Pion exercises the full streaming `ChunkedDecoder` state machine (comparable to Go `net/http`'s `ReadResponse` + `Body.Read`), while `rust_httparse` uses its stateless `parse_chunk_size` helper on a contiguous slice.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_httparse`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **174.160** | 165.298 | 178.951 | **234.08** | 1741.60 | 21.27 MiB | 0.53x |
| `rust_httparse` | 92.271 | 90.461 | 92.712 | 441.82 | 922.71 | 11.58 MiB | 1.00x (baseline) |
| `go_net_http` | 219.393 | 217.825 | 228.853 | 185.82 | 2193.93 | 40.91 MiB | 0.42x |

_SHA-256 verified identical across all implementations and rounds: `013527f1383bbe4530655961b0a38850948e52cc635f27671c7c4d65c00da36c`._

### 3. WHATWG SSE Streaming Decode (400,000 LLM token events, 44.21 MB, 4 KiB chunks)

> **Fairness note**: `rust_sse` and `go_sse` in `bench/` are hand-ported reference implementations of the same line-scanning algorithm (without `retry:` parsing or WHATWG `U+FFFD` UTF-8 replacement) rather than third-party SSE libraries, so this table measures Pion's full WHATWG-compliant `SseDecoder` against minimal Rust/Go implementations of the same algorithm.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_sse`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **250.726** | 245.615 | 485.978 | **176.34** | 626.82 | 44.52 MiB | 0.65x |
| `rust_sse` | 161.732 | 159.276 | 169.487 | 273.36 | 404.33 | 22.95 MiB | 1.00x (baseline) |
| `go_sse` | 175.662 | 174.674 | 223.049 | 251.69 | 439.16 | 57.92 MiB | 0.92x |

_SHA-256 verified identical across all implementations and rounds: `cfa251a98ea173c40138cf1f424b54fd6b0df67cddf2b41dc9eff50cde928cb0`._

**Performance notes**:
- On **HTTP/1.1 Request Parse** and **Response + Chunked Streaming Decode**, Pion (`http1`) outperforms Go's standard library `net/http` by **1.48×** and **1.26×** respectively while using less peak RSS (`34.20 vs 47.80 MiB` and `21.27 vs 40.91 MiB`). Note that Go `net/http`'s `ReadRequest` also builds `url.URL` and canonicalizes headers into a `map[string][]string`.
- Compared to Rust `httparse 1.10.1` (`--release`), `httparse` uses SIMD/SWAR (`aarch64` NEON) and writes borrowed zero-copy `&[u8]` spans into a caller-provided stack array without allocating owned `String` values or performing framing/Host/smuggling validation, whereas Pion's `parse_request` / `parse_response` returns owned `Send`-safe `String` fields and enforces full RFC 9112 framing & `Host` validation inline.
- On **WHATWG SSE Streaming Decode**, Pion's direct chunk-slice scanning + ASCII fast path + single-line `first_data` fast path achieves **176.34 MB/s** (`0.65×` of the minimal hand-ported Rust decoder and `0.70×` of the minimal hand-ported Go decoder) while performing full WHATWG UTF-8 `U+FFFD` replacement, `retry:` parsing, commit-on-dispatch `last_event_id`, and materializing owned `SseEvent` structs for every event.
