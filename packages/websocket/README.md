# `websocket` — Pure Pion RFC 6455 Sans-IO WebSocket Protocol Stack

A zero-dependency, pure Pion implementation of the RFC 6455 WebSocket protocol, modeled on Go's `coder/websocket` and Rust's `tungstenite-rs`.

Designed with a **Sans-IO** architecture: no `World` dependency, no OS socket or async runtime coupling, and `Send`-safe immutable value types (`Role`, `Opcode`, `CloseFrame`, `Message`, `Frame`). Works identically on **Native** and **Wasm32**.

## Features

- **RFC 6455 HTTP/1.1 Upgrade Handshake** (`src/handshake.pion`):
  - Built-in pure Pion FIPS 180-4 **SHA-1** (`sha1`) and RFC 4648 **Base64** (`base64_encode` / `base64_decode`) with zero external dependencies.
  - `compute_accept_key` verified against the RFC 6455 §1.3 golden vector (`dGhlIHNhbXBsZSBub25jZQ==` → `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`).
  - Client request builder & strict parser (`build_client_handshake`, `parse_client_handshake`) and server response builder & verifier (`build_server_handshake`, `verify_server_handshake`) with case-insensitive header parsing and `Sec-WebSocket-Protocol` subprotocol negotiation.
- **Frame Encoding & 8-Byte Batch XOR Masking** (`src/frame.pion`):
  - Single-allocation `encode_frame` / `encode_message` supporting 7-bit, 16-bit, and 64-bit payload lengths.
  - 8-byte unrolled XOR masking (`mask_bytes`) with full alignment-boundary coverage.
- **Streaming Sans-IO Decoder** (`src/decoder.pion`):
  - Amortized O(1) compacting byte buffer (`Decoder::feed` + `Decoder::next_message`), handling arbitrary half-packet and coalesced-packet boundaries.
  - Full Autobahn Testsuite core protocol compliance:
    - Rejects reserved opcodes (`3..7`, `11..15`), non-zero RSV1/2/3 bits, non-minimal length encodings, and 64-bit lengths with MSB set.
    - Enforces `Role::Server` masked-client and `Role::Client` unmasked-server rules.
    - Early OOM protection (`max_message_size` enforced immediately on frame headers before buffering payloads).
    - Full multi-frame fragmentation reassembly with interleaved `Ping`/`Pong`/`Close` control frame dispatch; rejects fragmented or >125-byte control frames, orphan continuations, and interrupted data frames.
    - Strict RFC 3629 UTF-8 validation (`validate_utf8`) with 8-byte ASCII fast path, including multi-byte sequences split across WebSocket fragment boundaries and in `Close` reason strings.
    - Strict RFC 6455 §7.4.1 / IANA close status code validation (`is_valid_close_code`).

## Quick Start

```pion
import "websocket"

// 1. Handshake
let key = "dGhlIHNhbXBsZSBub25jZQ=="
let req = websocket::build_client_handshake("example.com", "/ws", key, ["chat"])
let parsed = websocket::parse_client_handshake(req)
let resp = websocket::build_server_handshake(key, Some("chat"))
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

- **Compliance Test Suite**: **180 / 180 tests passing** (`pionc test --json packages/websocket`), covering RFC 6455 handshake, SHA-1/Base64, Autobahn §1–§4 framing/masking/length/RSV/opcodes, §5 fragmentation & interleaved control frames, §6 strict UTF-8 (including cross-fragment multi-byte splits), §7 close codes, and 1/3/7/random-byte streaming chunk tests.
- **Wasm32 Target**: `pionc build --target wasm32 packages/websocket/wasm_smoke` builds cleanly with zero errors.

## Head-to-Head Benchmark

Workload: **50,000 masked client frames** (~50.8 MB mixed Text + Binary + cross-fragment UTF-8 Text + interleaved Ping), batch-encoded and stream-decoded with unmasking, fragment reassembly, and strict UTF-8 validation. Verified via `scripts/bench_compare.py --warmup 1 --rounds 5` with **mandatory byte-for-byte stdout SHA-256 verification**.

Platform: `Darwin arm64` | Stdout SHA-256: `7830282bc43598507bfee624e7f55c3bbd01505b2f8e8e4674117ca67e349c92`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_tungstenite`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`packages/websocket`) | 255.914 | 222.350 | 284.604 | 198.82 | 5118.28 | 2.02 MiB | 0.29x |
| `rust_tungstenite` (`0.26.2 --release`) | 74.330 | 72.295 | 75.673 | 684.52 | 1486.60 | 2.22 MiB | 1.00x (baseline) |
| `go_coder_ws` (`v1.8.14`) | 129.358 | 115.856 | 134.806 | 393.33 | 2587.16 | 17.23 MiB | 0.57x |

**Analysis**:
- Pion Native achieves **~199 MB/s** sustained encode+mask+stream-decode+UTF-8 throughput with the **lowest Peak RSS (2.02 MiB)** — lower than Rust `tungstenite` (2.22 MiB) and **8.5x lower** than Go `coder/websocket` (17.23 MiB).
- Rust `tungstenite` (685 MB/s) and Go `coder/websocket` (393 MB/s, using ARM64 NEON assembly in `mask_arm64.s`) lead in raw throughput because Pion's current `Bytes` indexing lowers to per-byte runtime calls (`pion_bytes_get` / `pion_bytes_set`) rather than inline word/SIMD loads. Once Pion adds inline `Bytes` load/store or 64-bit word intrinsics, the 8-byte unrolled masking and UTF-8 fast paths will scale directly with hardware memory bandwidth.

Run the benchmark locally:

```sh
sh packages/websocket/bench/run_bench.sh
```
