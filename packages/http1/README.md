# `http1` — Pure Pion Sans-IO RFC 9112 HTTP/1.1 & WHATWG SSE Engine

A zero-dependency, pure Pion implementation of **RFC 9110 / RFC 9112 HTTP/1.1** (request/response incremental parsing & encoding, chunked transfer coding) and **WHATWG HTML §9.2.6 Server-Sent Events (EventSource / SSE)** streaming decoding, modeled on Rust's `httparse` and Go's `net/http`.

Designed with a **Sans-IO** architecture: no `World` dependency, no socket or runtime coupling, explicit `Result[T, HttpError]` error handling, and dual-target verified on **Native (`arm64_apple`)** and **WebAssembly (`wasm32`)**.

## Features

- **Incremental HTTP/1.1 Request & Response Parser** (`src/parser.pion`):
  - `parse_request` / `parse_request_with_limits` / `parse_request_at` and `parse_response` / `parse_response_with_limits` / `parse_response_at` returning `Result[ParseStatus[T], HttpError]` (`Complete(val, consumed)` or `Partial`) for arbitrary TCP fragmentation.
  - Strict RFC 9110 `tchar` token validation, HTTP/1.0 & HTTP/1.1 version checks, 3-digit status codes, optional reason phrases, header OWS trimming, RFC 9110 `obs-text` preservation, and ASCII case-insensitive header lookup (`header(name)` / `headers_named(name)`).
  - Global 256-byte `FixedArray[Int]` lookup tables (`src/lut.pion`, `P53-C` BCE) + 4-byte unrolled window scanning (`while pos <= end - 4`).
- **Day-1 HTTP Request Smuggling & CRLF Injection Defenses**:
  - **CL + TE conflict rejection**: Simultaneous `Content-Length` and `Transfer-Encoding` immediately returns `Err(HttpError::AmbiguousFraming)`.
  - **Duplicate / malformed `Content-Length` rejection**: Multiple `Content-Length` headers (even with identical values), comma-separated lists (`"10, 20"`), signs (`+10`, `-5`), whitespace, or `Int64` overflow return `Err(HttpError::InvalidContentLength)`.
  - **`Transfer-Encoding` obfuscation rejection**: Non-final `chunked`, duplicate `chunked`, unknown/parameterized codings (`xchunked`, `chunked; q=1`), empty elements, and HTTP/1.0 `Transfer-Encoding` return `Err(HttpError::InvalidTransferEncoding)`.
  - **`obs-fold`, whitespace-before-colon, bare CR/LF, and CTL rejection**: `Host : evil`, continuation lines starting with SP/HTAB (`ObsFold`), bare `\r`/`\n` (`BareCrOrLf`), and NUL/C0/DEL bytes (`InvalidHeaderValue`) are strictly rejected.
  - **Explicit `Int64` `Limits`**: `max_headers`, `max_header_bytes` (enforced even on partial buffers to prevent OOM DoS), `max_uri_bytes`, `max_chunk_size`, `max_chunk_ext_bytes`, `max_trailers`, `max_sse_line_bytes`, and `max_sse_event_bytes`.
- **Incremental Chunked Transfer Coding Decoder** (`src/chunked.pion`):
  - `ChunkedDecoder` with O(1) compacting chunk queue, strict hex `chunk-size` with `Int64` overflow checks, RFC 9112 §7.1.1 chunk extension (token & quoted-string) validation, strict `\r\n` terminators, trailer header parsing, pipelined trailing-byte preservation (`remaining_bytes()` / `take_remaining()`), and 1-byte drip equivalence.
- **CRLF-Safe HTTP/1.1 & Chunked Encoder** (`src/encoder.pion`):
  - `encode_request`, `encode_response`, `encode_chunk`, and `encode_final_chunk` strictly reject CR, LF, and NUL (`Err(HttpError::CrlfInjection)`) in methods, request targets, reason phrases, header names, header values, and trailers.
- **WHATWG HTML §9.2.6 SSE / EventSource Streaming Decoder** (`src/sse.pion`):
  - `SseDecoder::feed(chunk)` & `SseDecoder::finish()` with zero-copy fast-path line scanning and single-line `data:` fast path (avoiding `StringBuilder` allocation on 90%+ of LLM token events).
  - Full `\r\n`, `\n`, `\r`, and cross-chunk `\r`+`\n` merging; start-of-stream UTF-8 BOM stripping (including 1-byte split BOM); comment lines; single leading space removal after `:`; persistent `last_event_id` with NUL rejection; strict ASCII decimal `retry:`; empty-data event suppression; and 1-byte drip equivalence.

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

- **Native Compliance & Red-Team Suite**: **45 / 45 passing** (`pionc test --json packages/http1`), covering ported Rust `httparse` request/response/partial/chunk-size tests, RFC 9112 §7.1 chunked + 1-byte drip tests, WHATWG HTML §9.2.6 / WPT EventSource SSE tests, and Day-1 HTTP Request Smuggling & CRLF injection tests.
- **Formatting & Typecheck**: `pionc fmt --check packages/http1` and `pionc check --json packages/http1` pass with 0 diagnostics.
- **WebAssembly (`wasm32`)**: `pionc build --release --target wasm32 packages/http1/wasm_smoke` builds cleanly (`62 KiB` `.wasm`) and `pionc run --release --target wasm32 packages/http1/wasm_smoke` exits `0` under Node.js.

## Benchmarks

Head-to-head steady-state benchmarks via `sh packages/http1/bench/run_bench.sh` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification) on `Darwin arm64` against **Rust `httparse 1.10.1` (`--release`)** and **Go `net/http` (`go1.27.3`)**:

### 1. HTTP/1.1 Request Parse (200,000 mixed requests, 67.92 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_httparse`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **244.708** | 214.325 | 256.411 | **277.56** | 1223.54 | 34.17 MiB | 0.37x |
| `rust_httparse` | 90.226 | 84.171 | 93.085 | 752.79 | 451.13 | 18.05 MiB | 1.00x (baseline) |
| `go_net_http` | 337.740 | 323.714 | 404.546 | 201.10 | 1688.70 | 47.69 MiB | 0.27x |

_SHA-256 verified identical across all implementations and rounds: `ee568111200158fe227d7ab72523087716ac740d973a453d0bf9816024e0dd1f`._

### 2. HTTP/1.1 Response + Chunked Parse (100,000 chunked responses, 40.77 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_httparse`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **153.287** | 151.439 | 166.360 | **265.95** | 1532.87 | 21.23 MiB | 0.61x |
| `rust_httparse` | 94.107 | 92.622 | 109.878 | 433.20 | 941.07 | 11.58 MiB | 1.00x (baseline) |
| `go_net_http` | 226.480 | 221.255 | 236.593 | 180.00 | 2264.80 | 35.91 MiB | 0.42x |

_SHA-256 verified identical across all implementations and rounds: `013527f1383bbe4530655961b0a38850948e52cc635f27671c7c4d65c00da36c`._

### 3. WHATWG SSE Streaming Decode (400,000 LLM token events, 44.21 MB, 4 KiB chunks)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_sse`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **241.927** | 234.729 | 257.712 | **182.75** | 604.82 | 44.48 MiB | 0.67x |
| `rust_sse` | 161.792 | 160.906 | 163.827 | 273.26 | 404.48 | 22.95 MiB | 1.00x (baseline) |
| `go_sse` | 176.832 | 175.445 | 185.953 | 250.02 | 442.08 | 54.70 MiB | 0.92x |

_SHA-256 verified identical across all implementations and rounds: `cfa251a98ea173c40138cf1f424b54fd6b0df67cddf2b41dc9eff50cde928cb0`._

**Performance notes**:
- On **HTTP/1.1 Request Parse** and **Response + Chunked Parse**, Pion (`http1`) outperforms Go's standard library `net/http` by **1.38×** and **1.48×** respectively while using ~30–40% less peak RSS (`34.17 vs 47.69 MiB` and `21.23 vs 35.91 MiB`).
- Compared to Rust `httparse 1.10.1` (`--release`), `httparse` uses SIMD/SWAR (`aarch64` NEON) and writes borrowed zero-copy `&[u8]` spans into a caller-provided stack array without allocating owned `String` values or performing framing/smuggling validation, whereas Pion's `parse_request` / `parse_response` returns owned `Send`-safe `String` fields and enforces full Day-1 CL/TE smuggling validation inline.
- On **WHATWG SSE Streaming Decode**, Pion's direct chunk-slice scanning + single-line `first_data` fast path achieves **182.75 MB/s** (`0.67×` of Rust's borrowed-buffer decoder and `0.73×` of Go's streaming decoder) while materializing owned `SseEvent` structs for every event and using less peak RSS than Go (`44.48 vs 54.70 MiB`).
