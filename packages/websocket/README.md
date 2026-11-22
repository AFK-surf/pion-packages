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

- **Unit & Compliance Tests**: **186 / 186 passing** (`pionc test --json packages/websocket`), covering RFC 6455 handshake, SHA-1/Base64, hand-ported Autobahn §1–§7 framing/fragmentation/fail-fast UTF-8/close codes, streaming chunk boundaries, and red-team regressions.
- **Red-Team Audit Suite**: **22 / 23 passing** (`pionc test --json -p websocket_redteam_audit packages/websocket/audit`); all 18 P0/P1/P2 findings and 4 negative controls pass, with the single remaining item being the documented RFC 7692 `permessage-deflate` extension gap (`gap_rfc7692_permessage_deflate_hello`).
- **Wasm32 Target**: `pionc build --target wasm32 packages/websocket/wasm_smoke` builds cleanly with zero errors.

## Benchmarks

### 1. Adversarial Streaming Benchmark (Small & Large Frames)

Verified via `sh packages/websocket/audit/run_audit.sh bench` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification) on `Darwin arm64` against Rust `tungstenite 0.26.2 (--release)` and Go `coder/websocket v1.8.14` (arm64 NEON `mask_arm64.s`, with `utf8.Valid` added for `text_1m`):

| Workload (bytes processed) | Pion (MB/s) | Rust `tungstenite` (MB/s) | Go `coder/websocket` (MB/s) | Pion vs Rust | Pion vs Go |
| --- | ---: | ---: | ---: | ---: | ---: |
| `big_64k` 64 KiB × 16,384 (1.07 GB) | **1,631.20** | 10,718.96 | 4,285.67 | 0.15× | 0.38× |
| `big_1m` 1 MiB × 1,024 (1.07 GB) | **1,633.69** | 5,956.56 | 7,427.15 | 0.27× | 0.22× |
| `big_16m` 16 MiB × 64 (1.07 GB) | **1,554.29** | 601.66 | 7,642.51 | **2.58×** | 0.20× |
| `text_1m` UTF-8 1 MiB × 1,024 (1.07 GB) | **868.21** | 1,971.18 | 1,753.87 | 0.44× | 0.50× |
| `big_1m_c4k` 1 MiB, 4 KiB reads (537 MB) | **1,553.56** | 576.97 | 5,556.40 | **2.69×** | 0.28× |
| `frag_storm` 1,000 × 10,000 × 10 B (160 MB) | **321.70** | 825.31 | 54.14 | 0.39× | **5.94×** |
| `tiny_1m` 5M × 16 B frames (110 MB) | **382.60** (57.5 ns/op) | 914.78 (24.1 ns/op) | 45.46 (484.0 ns/op) | 0.42× | **8.42×** |
| `drip_20k` 1-byte reads, 100k frames (2.2 MB) | **16.87** | 2.70 | 25.62 | **6.25×** | 0.66× |

**Performance notes**:
- Eliminating `coalesce()` via direct cross-chunk unmasking + 16-byte unrolling lifted large-frame throughput **2.9×–5.1×** (`big_64k`: 317 → 1,631 MB/s; `big_1m`: 513 → 1,634 MB/s; `big_16m`: 530 → 1,554 MB/s; `text_1m`: 279 → 868 MB/s).
- Pion leads Rust `tungstenite` on chunked large frames (`big_16m`: 2.58×, `big_1m_c4k`: 2.69×) and 1-byte drips (`drip_20k`: 6.25×), and leads Go `coder/websocket` by **6×–8×** on tiny frames and fragment storms (`tiny_1m`, `frag_storm`).
- **Remaining large-frame gap (compiler ceiling)**: On 64 KiB–16 MiB frames, Pion's ~1.6 GB/s throughput is bounded by `pionc 0.1.0` scalar byte-at-a-time `Bytes` indexing (per-byte bounds checks, no 64-bit word XOR or NEON `eor.16b` vectorization), whereas Rust uses word-wise XOR and Go uses hand-written arm64 NEON assembly.

### 2. Mixed Small-Frame Benchmark

Workload: **50,000 masked client frames** (~50.88 MB mixed Text + Binary + cross-fragment UTF-8 Text + interleaved Ping):

```sh
sh packages/websocket/bench/run_bench.sh
```
