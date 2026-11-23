# `mime` (`v0.1.0`)

Pure Pion, zero-dependency, Native + Wasm32 MIME Media-Type, Content-Disposition, HTTP `Accept` negotiation, `multipart/*` streaming codec, Quoted-Printable / RFC 2047 Encoded-Words, and magic-byte MIME sniffing engine (no `World` dependency).

Designed alongside Go 1.27 `mime` / `mime/multipart` / `mime/quotedprintable` and Rust `mime` / `infer`, covering RFC 2045, 2046, 2047, 2231, 5987, 6266, 7578, 9110, and WHATWG MIME Sniffing.

## Features

- **Media-Type & Parameter Codec (RFC 2045 / 9110 / 2231 / 5987)**:
  - `parse_media_type` / `format_media_type`: ASCII case normalization (`type/subtype` and parameter names lowercased), quoted-string escape handling (`\"`, `\\`), RFC 2231 continuations (`name*0=...; name*1=...`, mixed `*N*` / `*N`), RFC 5987/2231 charset-tagged extended parameters (`filename*=UTF-8''%E4%B8%AD%E6%96%87.txt`, `ISO-8859-1`, `US-ASCII`), strict duplicate-parameter rejection, and canonical sorted formatting.
- **Content-Disposition (RFC 6266 / 5987)**:
  - `parse_content_disposition` / `format_content_disposition`: `inline`, `attachment`, `form-data`, with `filename*` taking precedence over plain `filename` per RFC 6266 §4.3.
  - `ContentDisposition::safe_filename()`: strips Unix/Windows directory traversal (`../`, `/`, `\`) and control bytes (`0x00..0x1F`, `0x7F`), rejecting `.` and `..`.
- **HTTP `Accept` Content Negotiation (RFC 9110 §12.5.1)**:
  - `parse_accept` / `negotiate_media_type`: deterministic integer thousandths quality weights (`q=0..=1000`), strict `q` validation (rejects `q=1.5`, `q=-0.1`, `q=0.1234`, `q=abc`), RFC 9110 specificity ordering (`type/sub;param > type/sub > type/* > */*`), and explicit `q=0` exclusion.
- **Multipart Streaming Reader & Writer (RFC 7578 / 2046)**:
  - `MultipartReader`: Boyer-Moore-Horspool (BMH) 256-entry skip-table linear-time boundary search, zero-copy `Bytes::slice` part bodies, `\r\n` and `\n` line endings, transport padding, preamble/epilogue accessors, nested multipart support, and configurable `MultipartLimits { max_parts, max_headers_per_part, max_header_bytes, max_part_bytes }`.
  - `MultipartWriter`: RFC 2046 §5.1.1 boundary validation (1..=70 chars, valid `bchars`, no trailing space/CR/LF/quotes), CRLF injection defense on all part headers and `write_field` / `write_file` helpers.
- **Quoted-Printable (RFC 2045 §6.7) & RFC 2047 Encoded-Words**:
  - `qp_decode` / `qp_decode_str` / `qp_encode` / `qp_encode_binary`: 256-entry LUT decoding, soft line breaks (`=\r\n`, `=\n`, transport padding), trailing whitespace stripping/encoding, 76-column soft wrapping.
  - `decode_rfc2047` / `decode_rfc2047_word` / `encode_rfc2047_q` / `encode_rfc2047_b`: `=?charset?B/Q?...?=` with built-in zero-dependency Base64, RFC 2047 §6.2 adjacent encoded-word whitespace folding, and UTF-8 character-safe <=75-column splitting.
- **Extension Mapping & Magic-Byte Sniffing**:
  - `mime_from_extension` / `extension_from_mime` / `sniff_mime`: first-byte dispatched magic detection for PNG, JPEG, GIF, WebP, BMP, ICO, AVIF, SVG, PDF, ZIP, GZIP, ZSTD, TAR, WASM, ELF, Mach-O, MP4, WebM, MP3, OGG, FLAC, WAV, WOFF, WOFF2, TTF, OTF, SQLite, HTML, XML, JSON, UTF-8 text, and `application/octet-stream` fallback.

## Security & Day-1 Red-Team Defenses

All malformed inputs return explicit `Err(MimeError)` (or `"application/octet-stream"` for `sniff_mime`) with **0 panics** and **0 Wasm32 traps**:

- **Adversarial Near-Miss Boundary DoS**: BMH skip-table scans a 10 MB payload consisting entirely of `--boundary1234567890` (missing only the final byte) in linear $O(N)$ time.
- **Resource Exhaustion Defense**: 100,000 empty parts bomb immediately fails with `MimeError::TooManyParts`; oversized part headers/bodies fail with `HeaderTooLarge`, `TooManyHeaders`, or `PartTooLarge` without OOM.
- **Header & Boundary Injection**: Rejects CR/LF/NUL in all writer headers and invalid boundaries (>70 chars, empty, CR/LF, quotes, control chars, trailing space).
- **Strict Parsing**: Rejects truncated/invalid `%` escapes in `filename*`, truncated `=A` / invalid hex / unescaped NUL in `qp_decode`, malformed RFC 2047 single words, duplicate parameters, and path traversal in `safe_filename()`.
- **Total Sniffer**: Empty, 1-byte, truncated magic prefixes, and all-zero buffers are bounds-checked with zero panics.

## Quick Start

```pion
import "mime"

// 1. Parse Media-Type & RFC 2231 parameters
let mt = mime::parse_media_type("TEXT/HTML; charset=UTF-8; title*=UTF-8''%E4%B8%AD%E6%96%87")

// 2. Content-Disposition with safe filename extraction
let cd = mime::parse_content_disposition("attachment; filename=\"../../etc/passwd\"; filename*=UTF-8''report.pdf")

// 3. HTTP Accept negotiation
let chosen = mime::negotiate_media_type("text/plain;q=0.5, application/json;q=0.9", ["text/plain", "application/json"])

// 4. Multipart write & zero-copy read
let w = match mime::MultipartWriter::new("my-boundary") { Ok(x) => x, Err(_) => ... }
let _ = w.write_field("user", "alice")
let payload = w.finish()
let r = match mime::MultipartReader::new(payload, "my-boundary") { Ok(x) => x, Err(_) => ... }
let parts = r.read_all()

// 5. Magic-byte sniffing
let kind = mime::sniff_mime(raw_bytes)
```

## Verification

- `pionc fmt --check packages/mime`: PASS
- `pionc check --json packages/mime`: PASS (0 diagnostics)
- `pionc test --json packages/mime`: **23/23 PASS** (`media_type_test.pion`, `multipart_test.pion`, `encoding_test.pion`, `sniff_test.pion`, `security_redteam_test.pion`)
- `packages/mime/wasm_smoke` 4-mode matrix (non-empty stdout, byte-identical SHA-256 `d87d0a45762847bdd06a81cbf7332760579ab2084aed02032ae7202aa74659b2`):
  - Native debug (`pionc run packages/mime/wasm_smoke`): exit `0`
  - Native release (`pionc run --release packages/mime/wasm_smoke`): exit `0`
  - Wasm32 debug (`pionc run --target wasm32 packages/mime/wasm_smoke` on Node.js v24.22.2): exit `0`
  - Wasm32 release (`pionc run --target wasm32 --release packages/mime/wasm_smoke` on Node.js v24.22.2): exit `0`

## Head-to-Head Benchmarks

Run with `sh packages/mime/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, locked `go.sum` / `Cargo.lock`, mandatory stdout SHA-256 verification) on **Darwin arm64** against:
- **Go 1.27.3** stdlib (`mime`, `mime/multipart`, `mime/quotedprintable`, `-mod=readonly`)
- **Rust 1.100.0** (`mime 0.3.18` + `infer 0.16.0`, `--release --locked`)

### 1. 50 MB `multipart/form-data` Parse (10 × 5 MiB binary attachments + 200 form fields)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `63 B` (`sha256:792007fefaba0ec5...`) | Input: `52453980 B`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs go_stdlib) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 29.475 | 29.190 | 29.879 | 1779.61 | 101.86 MiB | 0.89x |
| `go_stdlib` | 26.355 | 26.042 | 26.787 | 1990.28 | 119.95 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `792007fefaba0ec5c328a7a9142c02d667d6ddd0dc58658935440ecc48101e39`._

### 2a. 200k Mixed `Content-Type` / `Content-Disposition` / RFC 2047 Header Parse

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `48 B` (`sha256:549e031f7958ce5e...`) | Input: `11900000 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs go_stdlib) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 89.191 | 87.326 | 91.154 | 133.42 | 445.95 | 2.31 MiB | 0.64x |
| `go_stdlib` | 56.667 | 56.217 | 59.457 | 210.00 | 283.33 | 11.94 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `549e031f7958ce5eb731bb7517877082c7bc83ba1a3de8b1eea76fe6b0f5e55c`._

### 2b. 200k `Content-Type` Media-Type Parse (Pion vs Go 1.27 vs Rust `mime 0.3`)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `46 B` (`sha256:b8e823b81e6f5cca...`) | Input: `6060000 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_mime) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 65.977 | 64.939 | 67.311 | 91.85 | 329.89 | 2.03 MiB | 0.39x |
| `go_stdlib` | 37.113 | 35.673 | 38.979 | 163.28 | 185.57 | 12.50 MiB | 0.70x |
| `rust_mime` | 25.858 | 25.391 | 26.742 | 234.36 | 129.29 | 1.97 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `b8e823b81e6f5cca03be4d98c61a840d24916cdf331841e2cf064cffbc7a7bb6`._

### 3a. 16 MB Quoted-Printable Decode

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `50 B` (`sha256:7680fc8584f4cf31...`) | Input: `16777217 B`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs go_stdlib) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 34.655 | 33.337 | 35.689 | 484.12 | 48.22 MiB | 1.87x |
| `go_stdlib` | 64.770 | 61.739 | 65.602 | 259.03 | 55.47 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `7680fc8584f4cf31ba330eeed449ffca494efff3c06efee79d148707bd1862bd`._

### 3b. 100k Magic-Byte MIME Sniffing (Pion vs Rust `infer 0.16`)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `40 B` (`sha256:58428bd96f470754...`) | Input: `4770000 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_infer) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 15.151 | 14.722 | 16.456 | 314.83 | 151.51 | 1.83 MiB | 1.02x |
| `rust_infer` | 15.490 | 14.516 | 15.906 | 307.94 | 154.90 | 1.80 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `58428bd96f4707549477eb91fc02e793a497fabf19415d34b2c81cabdd3d7526`._

### Honest Performance Analysis

- **Wins**:
  - **Quoted-Printable Decode (16 MB)**: Pion (`484.12 MB/s`) is **1.87x faster** than Go 1.27 `mime/quotedprintable` (`259.03 MB/s`) with lower peak RSS (`48.22 MiB` vs `55.47 MiB`), thanks to single-allocation output sizing and 256-entry hex LUT decoding.
  - **Magic-Byte Sniffing (100k ops)**: Pion (`151.51 ns/op`, `314.83 MB/s`) edges out Rust `infer 0.16` (`154.90 ns/op`, `307.94 MB/s`, **1.02x**) with near-identical ~1.8 MiB peak RSS, using direct first-byte dispatch before signature checks.
  - **50 MB `multipart/form-data` Parse**: Pion (`1,779.61 MB/s`) achieves **0.89x** of Go 1.27's SIMD-accelerated `bytes.Index` (`1,990.28 MB/s`) using pure-Pion Boyer-Moore-Horspool search + zero-copy `Bytes::slice` part bodies, while consuming **15% less peak RSS** (`101.86 MiB` vs `119.95 MiB`).
- **Gaps**:
  - **Short Header Parsing (`headers_full` / `headers_mt`)**: Pion (`329.89 ns/op` on `Content-Type`, `445.95 ns/op` on mixed headers) is **0.64x** of Go 1.27 (`283.33 ns/op`) and **0.39x** of Rust `mime 0.3` (`129.29 ns/op`), though Pion uses **5–6x less peak RSS** than Go (`2.03–2.31 MiB` vs `11.94–12.50 MiB`). Rust `mime` keeps a single backing `String` and stores `(start, end)` byte indices without allocating individual `String`s per type, subtype, and parameter; Pion currently allocates `String` slices for each parsed component.
