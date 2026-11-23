# `sse` — Pure-Pion WHATWG Server-Sent Events (EventSource) Parser, Safe Encoder & Reconnect Backoff

Pure-Pion, zero-dependency, `World`-free, `Send`-clean (no module-level mutable state) implementation of **WHATWG HTML Living Standard §9.2 (Server-Sent Events / EventSource)** — built for streaming sync and LLM token feeds on both Native and `wasm32`.

## Compliance & Capabilities

- **Zero dependencies / No `World` / `Send`-clean**: Pure Pion, runs identically on Native and `wasm32` (4-mode byte-identical across `native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel`), with no module-level mutable globals.
- **WHATWG HTML §9.2.6 Streaming Parser (`src/parser.pion`)**:
  - `SseParser::new()`, `SseParser::with_limits(limits)`, `SseParser::with_options(limits, utf8_mode)`, `feed_bytes(chunk)`, `feed_str(chunk)`, `finish()`, `last_event_id()`, `retry_ms()`, `reset()`, plus one-shot `parse_bytes` / `parse_str`.
  - **Arbitrary chunk boundaries**: 1-byte drip and multi-size chunked feeding produce identical `SseEvent` sequences to whole-buffer parsing, including splitting 3–4 byte UTF-8 characters (`你好`, `🚀`), leading UTF-8 BOM (`EF BB BF`), or `\r\n` across adjacent `feed_bytes` calls.
  - **Exact WHATWG field & dispatch semantics**:
    - Strips at most **one** leading UTF-8 BOM at stream start (a second BOM is preserved as ordinary text).
    - Handles mixed `CRLF`, `CR`, and `LF` line endings; a trailing `\r` in chunk *N* followed by `\n` in chunk *N+1* merges into a single line break.
    - Ignores `:comment` lines and unknown fields (case-sensitive).
    - Strips at most **one** `U+0020` space after the first `:` (preserving extra spaces and tabs); lines without `:` are treated as `field = line, value = ""`.
    - Joins multiple `data:` lines with `\n`; suppresses dispatch when no `data` field appeared in the block; resets `event_type` to `"message"` after every blank line.
    - Commits `id:` to `last_event_id` on blank-line dispatch (even for data-less blocks per §9.2.6 Step 1), persists across subsequent events, clears on bare `id`, and ignores any `id:` value containing NUL (`U+0000`).
    - Parses `retry:` strictly as non-empty ASCII decimal digits (`0..=Int64::MAX`), ignoring non-digits, signs, spaces, and overflow; retains latest valid value in `parser.retry_ms()` while carrying per-block `retry` on `SseEvent.retry`.
    - Discards incomplete trailing lines/events on `finish()` without overwriting committed `last_event_id`.
  - **Configurable UTF-8 policy (`Utf8Mode`)**:
    - `Utf8Mode::Replace` (default): WHATWG Encoding Standard maximal-subpart `U+FFFD` replacement, with a zero-copy fast path when the slice is already valid UTF-8.
    - `Utf8Mode::Strict`: rejects any ill-formed UTF-8 sequence with `SseError::InvalidUtf8(offset)`.
- **Injection-Safe Encoder (`src/encoder.pion`)**:
  - `format_event(event)`, `format_event_bytes(event)`, and `format_comment(comment)`.
  - Automatically splits multiline `data` (and comments) on `\r\n`, `\n`, and `\r` into separate `data: ` / `: ` lines for lossless round-tripping.
  - Strictly rejects (`Err(SseError::InvalidFieldValue)`) CR (`\r`), LF (`\n`), or NUL (`\0`) in `event_type` or `id`, as well as negative `retry` values, preventing SSE field injection.
- **Sans-IO Reconnect & Deterministic Backoff State Machine (`src/reconnect.pion`)**:
  - `SseReconnectState` tracks `last_event_id`, server-supplied `retry_ms`, consecutive failure `attempt`, and capped exponential backoff with injectable deterministic `seed` / `jitter_ratio_bps` (pure `Int64` arithmetic, `World`-free, bit-identical across Native and `wasm32`).
  - Automatically resets `attempt` to `0` on `on_event` / `on_connect_success`.
  - Provides `last_event_id_header()` (`Last-Event-ID`) and RFC 3986 percent-encoded query cursor helpers (`append_cursor_query` / `append_cursor_query_with`, e.g. `?since=<id>` preserving existing query parameters and `#fragment`).
- **DoS Protection (`SseLimits`)**:
  - `max_line_bytes` (default `1 MiB`), `max_event_bytes` (default `4 MiB`), `max_data_lines` (default `65,536`).
  - Negative limits are rejected with `SseError::InvalidLimits`; oversized lines, events, or blank-line floods remain bounded with zero OOM/trap on Native and `wasm32`.

## Quick Start

```pion
import "sse"

let parser = sse::SseParser::new()
let reconnect = sse::SseReconnectState::new()

match parser.feed_str("event: sync\nid: cur-42\nretry: 2000\ndata: hello\n\n") {
  Ok(events) => {
    let mut i = 0
    while i < events.length() {
      reconnect.on_event(events[i])
      i = i + 1
    }
  }
  Err(e) => {
    let _ = e.message()
  }
}

// Next reconnect delay (ms) and cursor URL:
let delay_ms = reconnect.next_backoff_ms()
let url = reconnect.append_cursor_query_with("https://sync.example/events", "since")
```

## Verification

```sh
sh scripts/verify.sh packages/sse
```

4-mode `wasm_smoke` (each with an isolated `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/private/tmp/w17-sse-smoke-native_dbg pionc run packages/sse/wasm_smoke
PION_CACHE_DIR=/private/tmp/w17-sse-smoke-native_rel pionc run --release packages/sse/wasm_smoke
PION_CACHE_DIR=/private/tmp/w17-sse-smoke-wasm_dbg pionc run --target wasm32 packages/sse/wasm_smoke
PION_CACHE_DIR=/private/tmp/w17-sse-smoke-wasm_rel pionc run --target wasm32 --release packages/sse/wasm_smoke
```

All 4 modes exit `0` with byte-identical stdout:
`sse_wasm_smoke: OK checks=5` (`sha256:47b0f3077f6ce7915ba8c20cb42651dbc566b9fecf7571822b0148e3c6741312`).

## Head-to-Head Benchmarks vs Rust `eventsource-stream` `v0.2.3` (`--release --locked`)

Run with:

```sh
sh packages/sse/bench/run_bench.sh
```

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification across all rounds and implementations):

### W1: High-Throughput Streaming Parse (4 KiB chunks, `10x 2,143,309 B = 21,433,090 B`, `250,000` events)

Realistic multi-station sync & LLM token stream (JSON deltas, CRLF multiline UTF-8 patches, comments, `id:`, `retry:`), fed in 4 KiB chunks.
SHA-256: `f012a70d17b87fc9419cdff2f9a80896744d291c83960346fd087d7026e9225c`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_eventsource_stream`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 161.073 | 158.366 | 162.216 | 133.06 | 644.29 | 5.83 MiB | **1.37x** |
| `rust_eventsource_stream` | 221.381 | 217.030 | 248.828 | 96.82 | 885.53 | 4.64 MiB | 1.00x (baseline) |

### W2: Fragmented 64-Byte Chunked Streaming Parse (`10x 844,017 B = 8,440,170 B`, `100,000` events)

Same realistic mixed stream sliced into 64-byte network fragments that frequently split `\r\n`, field headers, and multibyte UTF-8 characters across chunk boundaries.
SHA-256: `cb0286ac1072ff267779123b7769801325cb8bc4872bf4d5caeb5e5e1ceab586`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_eventsource_stream`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 81.413 | 80.987 | 86.055 | 103.67 | 814.13 | 3.50 MiB | **1.03x** |
| `rust_eventsource_stream` | 83.498 | 80.317 | 85.819 | 101.08 | 834.98 | 3.22 MiB | 1.00x (baseline) |

### W3: Encode + Parse Roundtrip (`8x 844,017 B = 6,752,136 B`, `80,000` events)

Encodes 10,000 parsed events back into wire-format SSE frames and streams them through the parser in 4 KiB chunks (`8` iterations).
SHA-256: `b88c0954b2a2e7b26a57e07e2a700e15fa40ea1984bdb2d1d1300a97e1e51196`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_eventsource_stream`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 85.480 | 83.484 | 94.380 | 78.99 | 1068.50 | 6.53 MiB | **1.03x** |
| `rust_eventsource_stream` | 87.755 | 86.556 | 99.287 | 76.94 | 1096.94 | 6.20 MiB | 1.00x (baseline) |

### Objective Performance & Fairness Notes

- **Zero-copy line scanning vs `String::drain`**: On 4 KiB chunks (W1), `packages/sse` scans complete lines directly on the incoming `Bytes` slice with a 4-byte unrolled newline loop and avoids shifting an internal buffer, achieving **1.37x** throughput over `eventsource-stream` 0.2.3 (`nom` + `String::drain`). Note that W3 feeds re-encoded bytes in 4 KiB chunks to both implementations so `eventsource-stream` does not trigger its O(N²) `String::drain` pathology on single large buffers (while `packages/sse` stays strictly O(N) on whole buffers as well).
- **Peak RSS**: `pion` uses slightly more peak RSS than Rust (+0.28 to +1.19 MiB across W1–W3) due to per-chunk `Array[SseEvent]` return buffers and Pion's runtime heap sizing.
- **No async runtime overhead in Rust baseline**: The Rust benchmark polls `eventsource_stream::EventStream` directly with `std::task::Waker::noop()` (no Tokio/async-std executor overhead) to keep the comparison strictly on SSE parsing/encoding work.
