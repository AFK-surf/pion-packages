# `http2` (`v0.1.0`)

Pure Pion, zero-dependency, Sans-IO HTTP/2 (RFC 9113) frame codec, HPACK (RFC 7541) header compression engine, and stream state machine / flow-control window engine (`Native` + `Wasm32`, no `World` dependency, `Send`-safe value types).

Designed alongside Rust [`h2`](https://github.com/hyperium/h2) / `hpack-patched` and Go 1.27 [`golang.org/x/net/http2`](https://pkg.go.dev/golang.org/x/net/http2) (and `hpack`).

## Features

- **RFC 7541 HPACK Header Compression Engine**:
  - Complete 61-entry Static Table (`static_table_get`) with fast first-byte dispatch on encode.
  - $O(1)$ circular-buffer Dynamic FIFO Table with per-entry FNV-1a hashes, automatic eviction, and strict RFC 7541 §4.2 / §6.3 Dynamic Table Size Update validation (must appear only at the start of a header block and must not exceed the negotiated `SETTINGS_HEADER_TABLE_SIZE`).
  - Complete variable-length integer codec (`1..=8`-bit prefixes, `hpack_encode_int` / `hpack_decode_int`) rejecting 64-bit overflow and overlong continuation byte sequences.
  - Complete **256-symbol + EOS Canonical Huffman Codec** (RFC 7541 Appendix B): precomputed 256-state × 16-nibble 4-bit DFA (`4096` entries) decoding 2 lookups/byte while strictly rejecting explicit EOS (`0x3FFFFFFF`), padding > 7 bits, and non-all-1 padding.
  - All 4 header representations: Indexed, Literal with Incremental Indexing, Literal without Indexing, and Literal Never Indexed (`HeaderField.sensitive`).
- **RFC 9113 HTTP/2 Frame Codec**:
  - 9-byte `FrameHeader` + zero-copy `Bytes.slice` payloads for all 10 frame types: `DATA`, `HEADERS`, `PRIORITY`, `RST_STREAM`, `SETTINGS`, `PUSH_PROMISE`, `PING`, `GOAWAY`, `WINDOW_UPDATE`, `CONTINUATION`, plus `Frame::Unknown` extension passthrough.
  - Strict client connection preface (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`, 24 bytes) validation (`validate_client_preface`).
  - Strict per-frame RFC 9113 validation: `stream_id` constraints, exact fixed lengths (`PRIORITY=5`, `RST_STREAM=4`, `PING=8`, `WINDOW_UPDATE=4`, `GOAWAY>=8`, `SETTINGS % 6 == 0`, `SETTINGS ACK == 0`), `SETTINGS` value ranges (`ENABLE_PUSH ∈ {0,1}`, `INITIAL_WINDOW_SIZE <= 2^31-1`, `MAX_FRAME_SIZE ∈ [16384, 16777215]`), self-dependency rejection, `WINDOW_UPDATE` increment `!= 0`, and reserved MSB clearing.
- **RFC 9113 §5.1 Stream State Machine, Flow Control & §8.2 Header Validation**:
  - Full stream lifecycle (`Idle` / `ReservedLocal` / `ReservedRemote` / `Open` / `HalfClosedLocal` / `HalfClosedRemote` / `Closed`).
  - Connection-level and per-stream send/receive flow-control windows with `2^31 - 1` overflow detection (`FlowControlError`) and `SETTINGS_INITIAL_WINDOW_SIZE` delta propagation.
  - Strict HTTP/2 header semantics validation (`validate_request_headers`, `validate_response_headers`, `validate_trailers`): pseudo-header ordering/uniqueness/completeness, lowercase ASCII token names, rejection of connection-specific headers (`connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`, `upgrade`), `te` restricted to `"trailers"`, and rejection of `\r`, `\n`, `\0` in values.

## Security & Day-1 Red-Team Defenses

All malformed frames and adversarial payloads return explicit `Err(H2Error)` with **0 panics** and **0 Wasm32 traps**:

- **CVE-2023-44487 (Rapid Reset)**: `ConnectionConfig.max_rapid_resets` tracks rapid `RST_STREAM` cancellations and returns `EnhanceYourCalm` immediately upon exceeding the threshold.
- **CONTINUATION Flood & Interleaving**: `ConnectionConfig.max_continuation_frames` and `max_header_list_size` bound incomplete header blocks before HPACK decoding; any non-`CONTINUATION` frame or mismatched `stream_id` before `END_HEADERS` immediately returns `ProtocolError`.
- **HPACK Compression Bomb**: Real-time RFC 7541 §4.1 size accounting (`name.len + value.len + 32`) during decoding aborts with `EnhanceYourCalm` the instant `max_header_list_size` is exceeded, preventing OOM.
- **Padding Overflow & Varint / Huffman Abuse**: `pad_len >= payload_len` rejected with `ProtocolError`; 64-bit varint overflow / overlong continuations and Huffman EOS / invalid padding rejected with `CompressionError`.

## Quick Start

```pion
import "http2"

let enc = http2::HpackEncoder::with_huffman(4096, true)
let req_block = enc.encode([
  http2::HeaderField::new(":method", "GET"),
  http2::HeaderField::new(":scheme", "https"),
  http2::HeaderField::new(":authority", "api.example.com"),
  http2::HeaderField::new(":path", "/v1/health"),
])

let wire = match http2::encode_frame(http2::Frame::Headers(1, req_block, true, true, None)) {
  Ok(b) => b
  Err(_) => Bytes::new(0)
}

let conn = http2::Connection::server()
let res = conn.feed(wire)
```

## Verification

- `pionc fmt --check packages/http2`: PASS
- `pionc check --json packages/http2`: PASS (`0` diagnostics)
- `pionc test --json packages/http2`: **20/20 PASS** (`hpack_rfc7541_test.pion`, `frame_rfc9113_test.pion`, `state_and_security_test.pion`)
- `packages/http2/wasm_smoke` 4-mode matrix (all exit `0`, identical non-empty stdout `http2_wasm_smoke ok events=2 huff_len=583 win=65524`, `sha256: 5b5fc5548c1108f60ad754071778d89669d4870d8081f872636391fa5493d95e`):
  - Native debug: exit `0`
  - Native release: exit `0`
  - Wasm32 debug (`pionc run --target wasm32` on Node.js): exit `0`
  - Wasm32 release (`pionc run --target wasm32 --release` on Node.js): exit `0`

## Head-to-Head Benchmarks

Run with `sh packages/http2/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, locked `go.sum` / `Cargo.lock`, mandatory full-content stdout SHA-256 verification) on **Darwin arm64** against:
- **Go 1.27.3** `golang.org/x/net/http2` + `golang.org/x/net/http2/hpack` (`v0.34.0`, `-mod=readonly`)
- **Rust 1.100.0** `hpack-patched 0.3.0` (`--release --locked`)

### 1. HPACK Header Stream Decode (100,000 header blocks, Huffman + Dynamic Table)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `66 B` (`sha256:1612b3b496634b49...`) | Input: `3445400 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_hpack) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 199.231 | 184.947 | 273.511 | 17.29 | 1992.31 | 2.14 MiB | 12.13x |
| `go_x_net_http2` | 166.992 | 163.965 | 203.447 | 20.63 | 1669.92 | 16.64 MiB | 14.47x |
| `rust_hpack` | 2417.143 | 2102.033 | 3804.066 | 1.43 | 24171.43 | 2.36 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `1612b3b496634b49335a3f0368965080d2bd520bc4b686084ac5736acfaf2294`._

### 2. HPACK Batch Header Encode (100,000 header blocks, Huffman + Dynamic Table)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `73 B` (`sha256:d966eddf243ed850...`) | Input: `28562500 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_hpack) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 107.288 | 102.491 | 109.104 | 266.22 | 1072.88 | 3.55 MiB | 0.56x |
| `go_x_net_http2` | 65.926 | 64.824 | 72.478 | 433.25 | 659.26 | 14.03 MiB | 0.91x |
| `rust_hpack` | 59.938 | 58.218 | 63.192 | 476.53 | 599.38 | 3.25 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `d966eddf243ed850ad2685fd406e46937173b02817e5dd9293ddbced9d986693`._

### 3. Mixed HTTP/2 Frame Stream End-to-End (200,000 frames: Deframe + Reassemble + HPACK Decode)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `65 B` (`sha256:6a42ed26aa3e99ac...`) | Input: `5689500 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_hpack) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 140.477 | 138.161 | 148.256 | 40.50 | 702.38 | 2.27 MiB | 7.04x |
| `go_x_net_http2` | 110.504 | 105.138 | 122.215 | 51.49 | 552.52 | 16.92 MiB | 8.94x |
| `rust_hpack` | 988.273 | 914.141 | 1016.396 | 5.76 | 4941.37 | 2.36 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `6a42ed26aa3e99acd22e66140c423d5733689794588d22e9afc592a19594d6c4`._

### Objective Analysis
- **HPACK Decode & Frame Stream**: Pion's 4-bit nibble Huffman DFA delivers **12.13x** higher decode throughput and **7.04x** higher end-to-end frame-stream throughput than Rust `hpack-patched` (which uses a bit-by-bit tree walk), and stays within ~1.2x of Go's `x/net/http2` while using **~7.5x less peak RSS** (`2.14–2.27 MiB` vs `16.64–16.92 MiB`). In Benchmark 3, Pion also executes full RFC 9113 §5.1 stream state machine transitions, flow-control window accounting, and §8.2/§8.3 header semantics validation on every `HEADERS` frame.
- **HPACK Encode**: Pion (`107.3 ms`, `266.22 MB/s`) is slower than Go `x/net/http2` (`65.9 ms`) and Rust `hpack-patched` (`59.9 ms`). Note that `hpack-patched::Encoder` emits un-Huffman-encoded literal strings by default whereas Pion computes Huffman lengths and encodes strings with Huffman compression, and Go's `hpack.Encoder` maintains an explicit `map[string]uint64` hash index for $O(1)$ dynamic table lookups (whereas Pion currently scans its hashed dynamic ring array). Adding an open-addressing hash index to `DynamicTable` is the main remaining optimization opportunity for encode throughput.
