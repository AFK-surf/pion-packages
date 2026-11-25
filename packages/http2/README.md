# `http2` (`v0.1.0`)

Pure Pion, zero-dependency, Sans-IO HTTP/2 (RFC 9113) frame codec, HPACK (RFC 7541) header compression engine, and stream state machine / flow-control window engine (`Native` + `Wasm32`, no `World` dependency, `Send`-safe value types).

Designed and differentially verified alongside Rust [`h2` 0.4.20](https://github.com/hyperium/h2) and Go 1.27 [`golang.org/x/net` v0.62.0](https://pkg.go.dev/golang.org/x/net/http2) (`http2.Framer`, `http2.Server`, `http2/hpack`).

## Features

- **RFC 7541 HPACK Header Compression Engine**:
  - Complete 61-entry Static Table (`static_table_get`) with `FixedArray`-backed precomputed lengths/sizes and fast first-byte dispatch on encode.
  - $O(1)$ circular-buffer Dynamic FIFO Table (`FixedArray`-backed) with 512-slot (<50% load) $O(1)$ open-addressing `(name, value)` and `name` hash indices on encode, zero-boxing cursor decoding, single-pass speculative Huffman string encoding, reusable Huffman decode scratch buffer, automatic eviction, and strict RFC 7541 §4.2 / §6.3 Dynamic Table Size Update validation (deferred `set_max_table_size` upper bound; size updates must appear only at the start of a header block and must not exceed the negotiated `SETTINGS_HEADER_TABLE_SIZE`).
  - Complete variable-length integer codec (`1..=8`-bit prefixes, `hpack_encode_int` / `hpack_decode_int`) rejecting 64-bit overflow, overlong continuation sequences, and 64-bit index truncation/aliasing before narrowing.
  - Complete **256-symbol + EOS Canonical Huffman Codec** (RFC 7541 Appendix B): 64-bit MSB-aligned bit buffer + 12-bit dual-symbol L1 lookup table (`4096` entries, 16 KiB, decoding 1–2 symbols per lookup with 2× unrolled loop) + exact binary-trie fallback for 13..30-bit codes, and 64-bit 4-byte bulk-flush encoder, strictly rejecting explicit EOS (`0x3FFFFFFF`), padding > 7 bits, and non-all-1 padding.
  - All 4 header representations: Indexed, Literal with Incremental Indexing, Literal without Indexing, and Literal Never Indexed (`HeaderField.sensitive`).
- **RFC 9113 HTTP/2 Frame Codec**:
  - 9-byte `FrameHeader` + `Bytes.slice` payloads for all 10 frame types: `DATA`, `HEADERS`, `PRIORITY`, `RST_STREAM`, `SETTINGS`, `PUSH_PROMISE`, `PING`, `GOAWAY`, `WINDOW_UPDATE`, `CONTINUATION`, plus `Frame::Unknown` extension passthrough.
  - Strict client connection preface (`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`, 24 bytes) validation (`validate_client_preface`).
  - Strict per-frame RFC 9113 & RFC 8441 validation: `stream_id` constraints, exact fixed lengths (`PRIORITY=5`, `RST_STREAM=4`, `PING=8`, `WINDOW_UPDATE=4`, `GOAWAY>=8`, `SETTINGS % 6 == 0`, `SETTINGS ACK == 0`), `SETTINGS` value ranges (`ENABLE_PUSH ∈ {0,1}`, `INITIAL_WINDOW_SIZE <= 2^31-1`, `MAX_FRAME_SIZE ∈ [16384, 16777215]`, `ENABLE_CONNECT_PROTOCOL ∈ {0,1}`), self-dependency rejection, `WINDOW_UPDATE` increment `!= 0`, and reserved MSB clearing.
- **RFC 9113 §5.1 Stream State Machine, Flow Control & §8.2 Header Validation**:
  - $O(1)$ open-addressing active stream table with automatic closed-stream reclamation (constant ~2.1 MiB RSS across 1,000,000+ sequential streams), strict stream ID parity/monotonicity checks, `max_concurrent_streams` enforcement, `PUSH_PROMISE` role & promised-ID validation, `GOAWAY` new-stream refusal, and server `SETTINGS_ENABLE_PUSH=1` rejection on clients.
  - Connection-level (fixed initial 65,535 per RFC 9113 §6.9.2) and per-stream send/receive flow-control windows with full `DATA` wire-payload accounting (including `Pad Length` and `Padding` bytes per §6.9.1), `consume_recv_window` / `send_window_update` replenishment APIs, `2^31 - 1` overflow detection (`FlowControlError`), and `SETTINGS_INITIAL_WINDOW_SIZE` delta propagation.
  - Strict HTTP/2 header semantics validation (`validate_request_headers`, `validate_response_headers`, `validate_trailers`): pseudo-header ordering/uniqueness/completeness, RFC 8441 `:protocol` restricted to Extended `CONNECT`, `:path` origin-form (`/`..., rejecting `//`...) and `*` restricted to `OPTIONS`, strict `content-length` parsing/conflict/DATA-length verification (§8.1.1), lowercase ASCII token names, rejection of connection-specific headers (`connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`, `upgrade`), `te` restricted to `"trailers"`, and rejection of CTL bytes (`0x00..0x08`, `0x0A..0x1F`, `0x7F`) and leading/trailing SP/HTAB (§8.2.1).
  - Stream-level malformed-header isolation (emits `ConnectionEvent::RstStream(sid, err_protocol_error)` without terminating healthy sibling streams) and non-destructive `Connection::feed` partial event delivery on subsequent frame errors.

## Security & Red-Team Defenses

All malformed frames and adversarial payloads return explicit `Err(H2Error)` or stream-level `RstStream` with **0 panics** and **0 Wasm32 traps**:

- **HPACK 64-bit Index Bounds**: All indexed / literal-name / never-indexed index lookups validate `1 <= idx64 <= 61 + dyn_table.len` in 64-bit arithmetic before narrowing, eliminating 32-bit wrap-around aborts (`0xFFFFFFFF → -1`) and index aliasing (`2^32 + k`).
- **CVE-2023-44487 (Rapid Reset)**: `ConnectionConfig.max_rapid_resets` tracks concurrent `RST_STREAM` bursts with decay on normal stream completion, triggering `EnhanceYourCalm` on rapid-reset floods without false-positiving long-lived sequential cancellations.
- **CONTINUATION Flood & Interleaving**: `ConnectionConfig.max_continuation_frames` and `max_header_list_size` bound incomplete header blocks before HPACK decoding; any non-`CONTINUATION` frame or mismatched `stream_id` before `END_HEADERS` immediately returns `ProtocolError`.
- **HPACK Compression Bomb**: Real-time RFC 7541 §4.1 size accounting (`name.len + value.len + 32`) during decoding aborts with `EnhanceYourCalm` the instant `max_header_list_size` is exceeded, preventing OOM.
- **Padding Overflow & Varint / Huffman Abuse**: `pad_len >= payload_len` rejected with `ProtocolError`; full padded `DATA` payloads charged to flow control; 64-bit varint overflow / overlong continuations and Huffman EOS / invalid padding rejected with `CompressionError`.

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

- `sh scripts/verify.sh packages/http2`: PASS (`pionc fmt --check`, `pionc check --json` 0 diagnostics, `pionc test --json` **23/23 PASS**)
- `pionc test --json packages/http2/audit`: **50/50 PASS** (`4/4` P0, `16/16` P1, `12/12` P2, `18/18` control, **0 FAIL**)
- `sh packages/http2/audit/run_audit.sh`:
  - 3-way HPACK differential (5,382 cases vs Go `x/net v0.62.0` + Rust `h2 0.4.20`): **0 crashes, 0 value mismatches**
  - Frame differential (3,119 cases vs Go `Framer.ReadFrame`): **0 crashes, 0 value mismatches**
  - 4-mode Wasm32 consistency (Native debug/release + Wasm32 debug/release on Node.js across all 8,528 cases): **0 aborts, byte-identical SHA-256**
  - Stream-table memory/CPU probe: `1,000,000` finished streams + `100` `SETTINGS` frames completes in `0.43s` at **2.08 MiB** peak RSS
- `packages/http2/wasm_smoke` 4-mode matrix (Native debug/release + Wasm32 debug/release on Node.js): all exit `0`, identical stdout `http2_wasm_smoke ok events=2 huff_len=583 win=65524` (`sha256: 5b5fc5548c1108f60ad754071778d89669d4870d8081f872636391fa5493d95e`).

## Formal Verification (Lean 4)

Run `sh packages/http2/proofs/run_proofs.sh` (or `sh scripts/verify-lean.sh http2`) to extract `packages/http2/src/*.pion` via `pionc extract-lean` and machine-check **26 production theorems** (`0 sorry`, `0 admit`, `0 native_decide`, `0 bv_decide`, only `{propext, Classical.choice, Quot.sound}`):

- **Core & Stream State Machine (`Http2Proofs/Core.lean`, 6 theorems)**: RFC 7541 §4.1 HPACK dynamic entry size (`name_len + value_len + 32 ≥ 32`), RFC 9113 §5.1 `StreamState` exact decidable equality, §5.1.1 server/client stream ID parity partition, §6.9.1 flow-control window addition overflow immunity (`cur + inc ≤ 2^31 - 1`), §5.1 DATA receive permission classification & `END_STREAM` closure invariant.
- **Frame Wire Codec & Priority/Flags (`Http2Proofs/Frame.lean`, 10 theorems)**: RFC 9113 §4.1 24-bit frame length pack/unpack roundtrip & byte bounds, 31-bit stream ID pack/unpack roundtrip, reserved R-bit (`0x80`) ignore invariant & non-negativity, §6.2/§6.3 priority dependency word bijection (exclusive bit + 31-bit dependency), §6.2 `HEADERS` flags packing (`PADDED=0`), §6.9 `WINDOW_UPDATE` increment range `[1, 2^31 - 1]`.
- **SETTINGS & Header Semantics (`Http2Proofs/SettingsHeaders.lean`, 10 theorems)**: RFC 9113 §6.5.2 & RFC 8441 `SETTINGS` validation (`ENABLE_PUSH`, `INITIAL_WINDOW_SIZE`, `MAX_FRAME_SIZE`, `ENABLE_CONNECT_PROTOCOL`, unknown ID ignore), RFC 9113 §8.2.1 header name uppercase/CTL/space rejection & lowercase/digit acceptance, header value CTL classification (HTAB + printable allowed, `0..8`/`10..31`/`127` rejected), ASCII digit vs edge-whitespace disjointness.
- **Native vs Lean Differential**: `50/50` cases byte-identical (`diff -u` exit `0`).

## Head-to-Head Benchmarks

Run with `sh packages/http2/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, locked `go.sum` / `Cargo.lock`, mandatory full-content stdout SHA-256 verification) on **Linux x86_64** against modern production HTTP/2 engines:
- **Go** `golang.org/x/net` **v0.62.0** (`http2.Framer` + `ReadMetaHeaders` + `http2/hpack`, `-mod=readonly`)
- **Rust** **`h2` 0.4.20** (its own `hpack` engine + `h2::Codec`, `--release --locked`, Huffman ON)

### 1. HPACK Header Stream Decode (100,000 header blocks, Huffman + Dynamic Table)

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `66 B` (`sha256:1612b3b496634b49...`) | Input: `3445400 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Speedup (vs rust_h2_0.4.20) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 167.889 | 151.105 | 191.216 | 20.52 | 1678.89 | **1.31x** |
| `go_x_net_v0.62` | 428.630 | 389.119 | 611.351 | 8.04 | 4286.30 | 0.51x |
| `rust_h2_0.4.20` | 219.293 | 209.641 | 235.187 | 15.71 | 2192.93 | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `1612b3b496634b49335a3f0368965080d2bd520bc4b686084ac5736acfaf2294`._

### 2. HPACK Batch Header Encode (100,000 header blocks, Huffman ON + Dynamic Table)

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `73 B` (`sha256:d966eddf243ed850...`) | Input: `28562500 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Speedup (vs rust_h2_0.4.20) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 118.212 | 115.705 | 159.561 | 241.62 | 1182.12 | **1.07x** |
| `go_x_net_v0.62` | 182.881 | 163.580 | 284.228 | 156.18 | 1828.82 | 0.69x |
| `rust_h2_0.4.20` | 126.790 | 106.747 | 137.087 | 225.27 | 1267.90 | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `d966eddf243ed850ad2685fd406e46937173b02817e5dd9293ddbced9d986693`._

### 3. Mixed HTTP/2 Frame Engine (200,000 frames: Deframe + CONTINUATION + HPACK)

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `59 B` (`sha256:e96a6c442cacb947...`) | Input: `5689500 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Speedup (vs rust_h2_0.4.20) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 137.648 | 115.469 | 151.801 | 41.33 | 688.24 | **1.05x** |
| `go_x_net_v0.62` | 358.146 | 300.498 | 806.483 | 15.89 | 1790.73 | 0.40x |
| `rust_h2_0.4.20` | 144.096 | 136.831 | 189.925 | 39.48 | 720.48 | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `e96a6c442cacb947bdf20398303b9c673a6c0d0b90c43b0bc60b5bb80bfd910c`._

### Objective Analysis
- **HPACK Decode (100k blocks)**: With the 64-bit bit-buffer + 12-bit dual-symbol Huffman LUT, zero-boxing decode cursor, hoisted `FixedArray` static/dynamic tables, and split register-resident indexed loop, Pion (`167.9 ms`, `20.5 MB/s`) runs **1.31× faster than Rust `h2 0.4.20 --release`** (`219.3 ms`) and **2.55× faster than Go `x/net v0.62.0`** (`428.6 ms`).
- **HPACK Encode (Huffman ON, 100k blocks)**: With direct `HeaderField` field reads (zero `val struct` boxing), 512-slot (<50% load) open-addressing dynamic index, single-pass speculative 64-bit Huffman string writer, and fast static-exact dispatch, Pion (`118.2 ms`, `241.6 MB/s`) runs **1.07× faster than Rust `h2 0.4.20 --release`** (`126.8 ms`) and **1.55× faster than Go `x/net v0.62.0`** (`182.9 ms`).
- **Frame Engine (200k frames)**: With inlined 9-byte `FrameHeader` parsing, hot/rare frame dispatch splitting, and the accelerated HPACK decoder, Pion (`137.6 ms`, `41.3 MB/s`) runs **1.05× faster than Rust `h2::Codec`** (`144.1 ms`) and **2.60× faster than Go `x/net v0.62.0` `Framer + ReadMetaHeaders`** (`358.1 ms`).
