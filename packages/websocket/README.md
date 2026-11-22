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

Workload: **50,000 masked client frames** (~50.88 MB mixed Text + Binary + cross-fragment UTF-8 Text + interleaved Ping), batch-encoded and stream-decoded with unmasking, fragment reassembly, and strict UTF-8 validation. Verified via `scripts/bench_compare.py --warmup 1 --rounds 5` with **mandatory byte-for-byte stdout SHA-256 verification**.

Platform: `Darwin arm64` | Stdout SHA-256: `7830282bc43598507bfee624e7f55c3bbd01505b2f8e8e4674117ca67e349c92`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_tungstenite`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`packages/websocket`) | **131.212** | 127.738 | 140.728 | **387.77** | 2624.24 | **1.98 MiB** | 0.58x |
| `go_coder_ws` (`v1.8.14`, NEON asm) | 136.798 | 134.678 | 144.166 | 371.93 | 2735.96 | 16.95 MiB | 0.56x |
| `rust_tungstenite` (`0.26.2 --release`) | 76.104 | 72.802 | 77.086 | 668.56 | 1522.08 | 2.23 MiB | 1.00x (baseline) |

**Optimization & Profiling Summary**:
- **1.95x speedup over initial baseline** (`255.9 ms` / `198.8 MB/s` → **`131.2 ms` / `387.8 MB/s`**), **surpassing Go `coder/websocket`** (`136.8 ms` / `371.9 MB/s`, even with Go's hand-written `mask_arm64.s` NEON assembly) while using **8.5x less memory** (`1.98 MiB` vs `16.95 MiB`) and less memory than Rust `tungstenite` (`2.23 MiB`).
- Key optimizations:
  1. **Zero-copy chunk queue in `Decoder::feed`** (eliminated staging copy and 50M per-byte struct-field RC inc/dec ops: `feed` dropped from `79 ms` → `0 ms`).
  2. **Direct-unmask into final reassembled fragment** (eliminated intermediate allocation & copy on final continuation frames) + reusable `queue`/`frag_chunks` buffers via `.clear()`.
  3. **Gated 8-byte ASCII fast path in `validate_utf8_range`** (avoids redundant 8-byte lookaheads on CJK/emoji-heavy UTF-8).
- **Remaining gap vs Rust `tungstenite` (compiler ceiling)**: ARM64 disassembly of `extract_payload_into` shows `pionc 0.1.0` already inlines `Bytes` indexing (`ldrb`/`strb`), but emits ~13 scalar instructions/byte (per-byte `cmp`/`b.hs` bounds check, redundant `mov`/`sxtw`/`and #0xff` before `strb`, and no 64-bit word or NEON `eor.16b` vectorization). Hoisting loop bounds checks and adding 64-bit/SIMD `Bytes` word operations in `pionc` will directly close the remaining gap to Rust.

Run the benchmark locally:

```sh
sh packages/websocket/bench/run_bench.sh
```
