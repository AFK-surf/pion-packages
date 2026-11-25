# `websocket` — Pure Pion RFC 6455 Sans-IO WebSocket Protocol Stack

A zero-dependency, pure Pion implementation of the RFC 6455 WebSocket protocol, modeled on Go's `coder/websocket` and Rust's `tungstenite-rs`.

Designed with a **Sans-IO** architecture: no `World` dependency, no OS socket or async runtime coupling, and `Send`-safe immutable value types (`Role`, `Opcode`, `CloseFrame`, `Message`, `Frame`). Works identically on **Native** and **Wasm32**.

## Features

- **RFC 6455 HTTP/1.1 Upgrade Handshake** (`src/handshake.pion`):
  - Built-in pure Pion FIPS 180-4 **SHA-1** (`sha1`) and RFC 4648 **Base64** (`base64_encode` / `base64_decode`) with zero external dependencies.
  - `compute_accept_key` verified against the RFC 6455 §1.3 golden vector (`dGhlIHNhbXBsZSBub25jZQ==` → `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`).
  - CRLF/CTL-injection-safe client & server builders (`try_build_client_handshake` / `try_build_server_handshake` returning `Result[String, WsError]`, plus legacy `build_client_handshake` / `build_server_handshake` returning `""` on invalid input).
  - Strict RFC 6455 / RFC 7230 parsers (`parse_client_handshake`, `verify_server_handshake`): rejects duplicate `Sec-WebSocket-Key` / `Sec-WebSocket-Accept` / `Sec-WebSocket-Version` / `Sec-WebSocket-Protocol`, whitespace before `:`, control characters in header values, and unoffered `Sec-WebSocket-Extensions` or `Sec-WebSocket-Protocol`.
- **Frame Encoding & Unrolled XOR Masking** (`src/frame.pion`):
  - Single-allocation `encode_frame` / `encode_message` supporting 7-bit, 16-bit, and 64-bit payload lengths.
  - Unrolled XOR masking (`mask_bytes`) with full alignment-boundary coverage.
- **Streaming Sans-IO Decoder** (`src/decoder.pion`):
  - Bounded O(1) compacting chunk queue (`Decoder::feed` + `Decoder::next_message`) with **direct cross-chunk unmasking** (zero `coalesce()` double-copy on large frames; ~2.0 MiB steady-state RSS over 20,000 × 64 KiB frames even when the producer stays ahead of the consumer).
  - 64-bit `Int64` frame-length and fragment-size arithmetic (prevents 32-bit `Int` overflow when `max_message_size` is near `Int` max).
  - Rejects reserved opcodes (`3..7`, `11..15`), non-zero RSV1/2/3 bits, non-minimal length encodings, and 64-bit lengths with MSB set.
  - Enforces `Role::Server` masked-client and `Role::Client` unmasked-server rules, plus early OOM protection (`max_message_size` checked immediately on frame headers).
  - Multi-frame fragmentation reassembly with interleaved `Ping`/`Pong`/`Close` control frame dispatch; rejects fragmented or >125-byte control frames, orphan continuations, and interrupted data frames.
  - **Incremental fail-fast RFC 3629 UTF-8 validation** (`validate_utf8_step`, Autobahn 6.4.x strict): invalid UTF-8 in any non-final text fragment fails immediately with `InvalidUtf8` (1007) without waiting for `FIN=1`, while still supporting valid multi-byte code points split across fragments.
  - Close state machine: once a valid `Close` frame is delivered, subsequent data frames and duplicate `Close` frames are not delivered until `Decoder::reset()` is called.
  - Strict RFC 6455 §7.4.1 / IANA close status code validation (`is_valid_close_code`).

## Scope & Known Limitations

- **Autobahn coverage**: Hand-ported subset of **Autobahn §1–§7** (115 `autobahn_*` cases across framing, masking, RSV/opcodes, fragmentation, strict UTF-8 including §6.4.x fail-fast, and close codes), plus SHA-1/Base64/handshake/streaming/red-team regression tests (**186 unit tests**). It does not run the full 517-case `wstest` harness, and does not include §9/§10 performance/misc suites.
- **Extensions**: **`permessage-deflate` (RFC 7692, Autobahn §12/§13) is not implemented**; there is no extension negotiation API, and unoffered `Sec-WebSocket-Extensions` responses are rejected per RFC 6455 §4.1.
- **Layer**: Sans-IO framing/handshake library only (no socket I/O, streaming chunked message reader, or fragmenting writer).

## Quick Start

```pion
import "websocket"

// 1. Handshake
let key = "dGhlIHNhbXBsZSBub25jZQ=="
let req = match websocket::try_build_client_handshake("example.com", "/ws", key, ["chat"]) {
  Ok(r) => r
  Err(_) => ""
}
let parsed = websocket::parse_client_handshake(req)
let resp = match websocket::try_build_server_handshake(key, Some("chat")) {
  Ok(r) => r
  Err(_) => ""
}
let verified = websocket::verify_server_handshake(resp, key, ["chat"])

// 2. Encode & stream-decode frames
let wire = websocket::encode_frame(
  websocket::Frame::text("Hello, WebSocket!", Some(0x37FA213DU)),
)
let decoder = websocket::Decoder::new(websocket::Role::Server, 65536)
decoder.feed(wire)
match decoder.next_message() {
  Ok(Some(websocket::Message::Text(msg))) => () // "Hello, WebSocket!"
  _ => ()
}
```

## Verification

- **Unit & Compliance Tests**: **187 / 187 passing** (`pionc test --json packages/websocket`), covering RFC 6455 handshake, SHA-1/Base64, hand-ported Autobahn §1–§7 framing/fragmentation/fail-fast UTF-8/close codes, streaming chunk boundaries, and red-team regressions.
- **Red-Team Audit Suite**: **22 / 23 passing** (`pionc test --json -p websocket_redteam_audit packages/websocket/audit`); all 18 P0/P1/P2 findings and 4 negative controls pass, with the single remaining item being the documented RFC 7692 `permessage-deflate` extension gap (`gap_rfc7692_permessage_deflate_hello`).
- **Wasm32 Target**: 4-mode `wasm_smoke` (Native debug/release + Wasm32 debug/release) builds and runs with identical stdout SHA-256 (`e3b0c44298fc1c14...`).

## Benchmarks

### 1. Adversarial Streaming Benchmark (Small & Large Frames)

Verified via `sh packages/websocket/audit/run_audit.sh bench` and strictly interleaved baseline (`01ef1b7e`) vs optimized vs Rust `tungstenite 0.26.2 (--release)` runs (mandatory byte-for-byte stdout SHA-256 verification) on `Linux x86_64`:

| Workload | Pion Baseline (MB/s) | Pion Optimized (MB/s) | Rust `tungstenite` (MB/s) | Opt vs Base | Opt vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| `big_64k` 64 KiB frames | 247.82 | 206.50 | 1,804.87 | 0.83× (scalar ceiling) | 0.11× |
| `big_1m` 1 MiB frames | 124.10 | 92.38 (min 136.5) | 307.97 | 1.03× (min) | 0.30× |
| `big_16m` 16 MiB frames | 154.81 | 95.67 (min 195.3) | 15.47 | 1.24× (min) | **6.19×** |
| `text_1m` UTF-8 1 MiB frames | 54.91 | **66.42** | 114.99 | **1.21×** | 0.58× |
| `big_1m_c4k` 1 MiB, 4 KiB reads | 211.11 | 151.16 (min 225.5) | 40.39 | 1.03× (min) | **3.74×** |
| `frag_storm` 1,000 × 10,000 × 10 B | 37.61 | **165.22** (min 283.3) | 87.06 | **4.39×** | **1.90×** |
| `tiny_1m` 5M × 16 B frames | 60.89 (361.3 ns/op) | **99.57** (221.0 ns/op) | 150.06 (146.6 ns/op) | **1.64×** | 0.66× |
| `drip_20k` 1-byte reads, 100k frames | 1.94 | **3.14** | 0.32 | **1.62×** | **9.76×** |

**Performance notes**:
- **Zero-COW-check fresh-`Bytes` unmasking & encoding**: Allocating immutable `let out = Bytes::new(...)` directly inside `unmask_fresh`, `unmask_text_fresh`, `read_payload_fresh`, `read_text_payload_fresh`, `finish_frag_single_fresh`, `mask_bytes`, and `encode_frame` allows `pionc` to elide all per-byte `Bytes.flags` COW checks (verified via `objdump`), while unmasked frames use native `Bytes::slice` / `Bytes::concat` (`memcpy`).
- **Continuation burst & geometric `frag_buf`**: Replacing per-fragment `Array[Bytes]` allocations with a geometrically growing `frag_buf` and a tight `drain_bin_cont_burst` loop lifted `frag_storm` **4.39×** (reaching **1.90× Rust `tungstenite`**).
- **Lean single-chunk fast path**: Splitting `Decoder::next_message` into a lean single-chunk 7-bit/16-bit fast path (with inline ≤32 B unmasking) lifted `tiny_1m` **1.64×** (`0.41×` → `0.66×` Rust) and `drip_20k` **1.62×** (`9.76×` Rust).
- **Cache-hot UTF-8 validation with ASCII fast skip**: Tracking high-bit masks during unmasking skips UTF-8 validation completely on pure-ASCII payloads and validates multi-byte UTF-8 per 64 KiB chunk while L2-hot, lifting `text_1m` **1.21×**.
- **Remaining compiler/ISA ceilings (`objdump`-verified)**:
  - Large-frame unmasking (`big_64k` / `big_1m`): `unmask_fresh` and `read_payload_fresh` compile to zero COW checks and zero register spills, leaving 10 instructions/byte (2 bounds checks + scalar 1-byte load/XOR/store) due to no 64-bit word `Bytes` load/store or SIMD vectorization in `pionc 0.1.0`.
  - Tiny frames (`tiny_1m`): each `next_message()` returning `Result[Option[Message], WsError]` performs 3 heap allocations (`pion_bytes_new` + 2× `pion_alloc_uninit`) plus RC teardown, whereas Rust returns `Result<Message, Error>` by value on the stack.

### 2. Mixed Small-Frame Benchmark

Workload: **50,000 masked client frames** (~50.88 MB mixed Text + Binary + cross-fragment UTF-8 Text + interleaved Ping), verified via `sh packages/websocket/bench/run_bench.sh` (`--warmup 1 --rounds 5`, `Linux x86_64`, stdout SHA-256 `7830282bc4359850...`):

| Implementation | Median (ms) | Min (ms) | Throughput (MB/s) | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: |
| `pion` (optimized) | **520.857** | **349.941** | **97.69** | **0.58×** (**2.77×** Go) |
| `rust_tungstenite` | 302.503 | 149.703 | 168.20 | 1.00× (baseline) |
| `go_coder_ws` | 1,441.860 | 1,284.676 | 35.29 | 0.21× |
