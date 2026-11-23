# `mime` (`v0.1.0`)

Pure Pion, zero-dependency, Native + Wasm32 MIME Media-Type, Content-Disposition, HTTP `Accept` negotiation, `multipart/*` streaming codec, Quoted-Printable / RFC 2047 Encoded-Words, and magic-byte MIME sniffing engine (no `World` dependency).

Designed alongside Go 1.27 `mime` / `mime/multipart` / `mime/quotedprintable` and Rust `mime` / `infer`, covering RFC 2045, 2046, 2047, 2231, 5987, 6266, 7578, 9110, and WHATWG MIME Sniffing.

## Features

- **Media-Type & Parameter Codec (RFC 2045 / 9110 / 2231 / 5987)**:
  - `parse_media_type` / `format_media_type`: ASCII case normalization (`type/subtype` and parameter names lowercased), O(n) hash-indexed parameter & RFC 2231 continuation parsing (lazy `StrIndexMap` / `IntIndexMap`), MSIE backslash path preservation (unescaping `\` only before RFC 2045 `tspecials`), RFC 2231 continuations (`name*0=...; name*1=...`, mixed `*N*` / `*N`, empty charset `a*=''...`), RFC 5987/2231 charset-tagged extended parameters (`UTF-8`, `ISO-8859-1`, `US-ASCII`), RFC 6266 §4.3 fault-tolerant fallback (undecodable `filename*` / invalid RFC 2231 sections are skipped without failing the header), benign equal-value duplicate acceptance (`a*` wins over `a*0`), conflicting duplicate rejection, and canonical sorted formatting (rejecting `*` in parameter names so all output round-trips cleanly).
- **Content-Disposition (RFC 6266 / 5987)**:
  - `parse_content_disposition` / `format_content_disposition`: `inline`, `attachment`, `form-data`, with `filename*` taking precedence over plain `filename` per RFC 6266 §4.3 (and preserving `filename` fallback when `filename*` is undecodable).
  - `ContentDisposition::safe_filename()`: strips Unix/Windows path separators (`/` / `\`), C0/DEL/C1 controls (including U+0085 NEL), Unicode bidi override controls (`U+061C`, `U+200E..U+200F`, `U+202A..U+202E`, `U+2066..U+2069`), trailing dots/spaces, rejects NTFS ADS / drive-relative `:`, dotfiles (`.`, `..`, `.htaccess`), whitespace-only names, and Windows reserved DOS device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`, with any extension), and safely truncates to <= 255 bytes on a UTF-8 character boundary.
- **HTTP `Accept` Content Negotiation (RFC 9110 §12.5.1)**:
  - `parse_accept` / `negotiate_media_type`: deterministic integer thousandths quality weights (`q=0..=1000`), strict `q` validation, RFC 9110 specificity ordering (`type/sub;param > type/sub > type/* > */*`), explicit `q=0` exclusion, `accept-ext` handling after `q`, and fault-tolerant skipping of malformed items when other valid media ranges are present.
- **Multipart Streaming Reader & Writer (RFC 7578 / 2046)**:
  - `MultipartReader`: Two-Way (Crochemore-Perrin) + Horspool bad-character fast-skip strictly $O(N)$ worst-case boundary search, zero-copy `Bytes::slice` part bodies, RFC 2046 §5.1.1 EOL mode locking from the first boundary line (CRLF messages ignore bare `\n--boundary` inside bodies), strict closing delimiter validation (rejects `--boundary--garbage`), strict part header NUL/CTL rejection, transport padding, preamble/epilogue accessors, nested multipart support, and configurable `MultipartLimits { max_parts, max_headers_per_part, max_header_bytes, max_part_bytes, max_params_per_header }`.
  - `MultipartWriter`: RFC 2046 §5.1.1 boundary validation (1..=70 chars, valid `bchars`, no trailing space/CR/LF/quotes), `MultipartWriter::from_random_bytes` entropy-based boundary constructor (`World`-free), CRLF/NUL injection defense on all part headers, and body delimiter-injection rejection on `write_part` / `write_field` / `write_file`.
- **Quoted-Printable (RFC 2045 §6.7) & RFC 2047 Encoded-Words**:
  - `qp_decode` / `qp_decode_str` / `qp_encode` / `qp_encode_binary`: 256-entry LUT decoding, soft line breaks (`=\r\n`, `=\n`, trailing `=` at EOF), RFC 2045 §6.7 literal passthrough for malformed `=` sequences, NUL/CTL rejection, trailing whitespace stripping/encoding, 76-column soft wrapping.
  - `decode_rfc2047` / `decode_rfc2047_word` / `encode_rfc2047_q` / `encode_rfc2047_b`: `=?charset?B/Q?...?=` with built-in zero-dependency Base64, RFC 2047 §6.2 adjacent encoded-word whitespace folding, cross-word multi-byte UTF-8 joining for adjacent same-charset words, and UTF-8 character-safe <=75-column splitting.
- **Extension Mapping & Magic-Byte Sniffing**:
  - `mime_from_extension` / `extension_from_mime` / `sniff_mime`: first-byte dispatched magic detection for 40+ formats (PNG, JPEG, GIF, WebP, BMP, ICO, AVIF, HEIF, TIFF, PSD, JXL, PDF, PostScript, RTF, ZIP, GZIP, ZSTD, BZIP2, XZ, 7z, RAR, LZ4, CAB, DEB, TAR, WASM, ELF, Mach-O, Java `.class`, PE, CRX, DICOM, SWF, MP4/ISO-BMFF, M4A, QuickTime, 3GP, WebM, Matroska, AVI, MP3, AAC, OGG, FLAC, WAV, MIDI, WOFF, WOFF2, TTF, OTF, SQLite), WHATWG tag-terminating HTML/XML/JSON, UTF-8/UTF-16 BOM text, and `application/octet-stream` fallback. Never promotes untrusted bytes to scriptable `image/svg+xml`.

## Security & Red-Team Defenses

All malformed inputs return explicit `Err(MimeError)` (or `"application/octet-stream"` for `sniff_mime`) with **0 panics** and **0 Wasm32 traps**:

- **Periodic & Near-Miss Boundary DoS ($O(N)$ worst case)**: Two-Way (Crochemore-Perrin) + Horspool skip guarantees linear-time scanning on both 10 MB near-miss payloads and 8 MiB periodic `a`×70 worst-case boundaries (**16.8 ms vs Go 20.4 ms**).
- **Quadratic Parameter Bomb Defense ($O(n)$)**: Hash-indexed parameter & RFC 2231 continuation assembly eliminates $O(n^2)$ CPU DoS (64 × 60 KiB RFC 2231 headers: **136.4 ms vs Go 184.0 ms**), reinforced by `MultipartLimits::max_params_per_header`.
- **Multipart Smuggling & Writer Injection**: First-boundary EOL mode locking prevents bare-LF part smuggling in CRLF messages; `--boundary--garbage` and part-header NUL/CTLs are rejected; `MultipartWriter` rejects body boundary injection and offers `from_random_bytes`.
- **XSS & Filename Spoofing**: `sniff_mime` never sniffs `image/svg+xml` and enforces WHATWG HTML tag-terminating bytes; `safe_filename()` neutralizes path traversal, Windows DOS devices, trailing dots/spaces, NTFS ADS `:`, bidi overrides, C0/C1 controls, dotfiles, and >255-byte names.
- **Resource Exhaustion Defense**: 100,000 empty parts bomb immediately fails with `MimeError::TooManyParts`; oversized part headers/bodies fail with `HeaderTooLarge`, `TooManyHeaders`, or `PartTooLarge` without OOM.
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
- `pionc test --json packages/mime`: **24/24 PASS** (`media_type_test.pion`, `multipart_test.pion`, `encoding_test.pion`, `sniff_test.pion`, `security_redteam_test.pion`)
- `pionc test --json packages/mime/audit`: **26/26 PASS** (`16/16 redteam_*` + `10/10 control_*`, 0 FAIL)
- `sh packages/mime/audit/run_audit.sh all`: **40,500 differential cases** across 4 modes (Native/Wasm32 × debug/release) with **0 traps / 0 byte differences**
- `packages/mime/wasm_smoke` 4-mode matrix (non-empty stdout, byte-identical SHA-256 `d87d0a45762847bdd06a81cbf7332760579ab2084aed02032ae7202aa74659b2`):
  - Native debug (`pionc build` + run): exit `0`
  - Native release (`pionc build --release` + run): exit `0`
  - Wasm32 debug (`pionc build --target wasm32` + `node`): exit `0`
  - Wasm32 release (`pionc build --release --target wasm32` + `node`): exit `0`

## Formal Verification (Lean 4)

Run `sh packages/mime/proofs/run_proofs.sh` (or `sh scripts/verify-lean.sh mime`) to extract `packages/mime/src/*.pion` via `pionc extract-lean` and machine-check **22 production theorems** (`0 sorry`, `0 admit`, `0 native_decide`, `0 bv_decide`, only `{propext, Classical.choice, Quot.sound}`):

- **Hex, Case Normalization & Quoted-Printable Codec (`MimeProofs/Codec.lean`, 11 theorems)**: `hex_upper_digit` / `hex_nibble_val` 4-bit roundtrip bijection, bounds (`-1` or `0..15`) & case-insensitivity; `ascii_lower_byte` idempotence & uppercase elimination; RFC 2045 §6.7 Quoted-Printable nibble bounds & full 8-bit byte pack/unpack bijection, literal encoder exclusion of `=`/CTLs/DEL/non-ASCII & trailing whitespace before EOL, decoder NUL/C0/DEL rejection, and 76-column soft-wrap bound (`col + width ≤ 75`).
- **RFC Grammars & Filename Security (`MimeProofs/GrammarSecurity.lean`, 11 theorems)**: RFC 5987 `attr-char ⊂ tchar` strict inclusion & exclusion of `'`, `*`, `%`; RFC 9110 `tchar` rejection of CTLs/SP/non-ASCII/`/`/`;`/`=`/`"`; RFC 2046 `bcharsnospace` rejection of CTLs/SP/non-ASCII/`"`/`\`; alphanumeric acceptance across all three grammars; RFC 6266 `safe_filename` path separator, C0/DEL stripping (preserving printable ASCII), UTF-8 C1 (`C2 80..9F`) exact characterization, and Trojan-Source / RLO 3-byte UTF-8 bidi control detection (`U+202E`, `U+202D`, `U+2066`, `U+2069`).
- **Native vs Lean Differential**: `45/45` cases byte-identical (`diff -u` exit `0`).

## Head-to-Head Benchmarks

Run with `sh packages/mime/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, locked `go.sum` / `Cargo.lock`, mandatory stdout SHA-256 verification) on **Darwin arm64** against:
- **Go 1.27.3** stdlib (`mime`, `mime/multipart`, `mime/quotedprintable`, `-mod=readonly`)
- **Rust 1.100.0** (`mime 0.3.18` + `infer 0.16.0`, `--release --locked`)

### 1. 50 MB `multipart/form-data` Parse (10 × 5 MiB binary attachments + 200 form fields)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `63 B` (`sha256:792007fefaba0ec5...`) | Input: `52453980 B`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs go_stdlib) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 39.383 | 38.959 | 41.377 | 1331.88 | 101.88 MiB | 0.89x |
| `go_stdlib` | 34.855 | 32.817 | 37.470 | 1504.94 | 120.06 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `792007fefaba0ec5c328a7a9142c02d667d6ddd0dc58658935440ecc48101e39`._

### 2a. 200k Mixed `Content-Type` / `Content-Disposition` / RFC 2047 Header Parse

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `48 B` (`sha256:549e031f7958ce5e...`) | Input: `11900000 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs go_stdlib) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 124.604 | 117.952 | 125.890 | 95.50 | 623.02 | 2.33 MiB | 0.60x |
| `go_stdlib` | 74.173 | 68.211 | 77.216 | 160.44 | 370.87 | 12.14 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `549e031f7958ce5eb731bb7517877082c7bc83ba1a3de8b1eea76fe6b0f5e55c`._

### 2b. 200k `Content-Type` Media-Type Parse (Pion vs Go 1.27 vs Rust `mime 0.3`)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `46 B` (`sha256:b8e823b81e6f5cca...`) | Input: `6060000 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_mime) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 79.984 | 78.698 | 83.950 | 75.76 | 399.92 | 2.06 MiB | 0.39x |
| `go_stdlib` | 44.954 | 42.894 | 46.320 | 134.80 | 224.77 | 11.98 MiB | 0.69x |
| `rust_mime` | 31.236 | 29.393 | 34.145 | 194.00 | 156.18 | 1.97 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `b8e823b81e6f5cca03be4d98c61a840d24916cdf331841e2cf064cffbc7a7bb6`._

### 3a. 16 MB Quoted-Printable Decode

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `50 B` (`sha256:7680fc8584f4cf31...`) | Input: `16777217 B`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs go_stdlib) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 40.049 | 37.152 | 41.652 | 418.91 | 48.25 MiB | 1.72x |
| `go_stdlib` | 69.042 | 66.728 | 72.467 | 243.00 | 55.42 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `7680fc8584f4cf31ba330eeed449ffca494efff3c06efee79d148707bd1862bd`._

### 3b. 100k Magic-Byte MIME Sniffing (Pion vs Rust `infer 0.16`)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `40 B` (`sha256:58428bd96f470754...`) | Input: `4770000 B` | Ops: `100000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_infer) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 20.325 | 16.584 | 23.947 | 234.68 | 203.25 | 1.86 MiB | 0.83x |
| `rust_infer` | 16.937 | 16.623 | 19.214 | 281.64 | 169.37 | 1.80 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `58428bd96f4707549477eb91fc02e793a497fabf19415d34b2c81cabdd3d7526`._

### 4. Red-Team Adversarial Performance Probes (`sh packages/mime/audit/run_audit.sh perf`)

All probes verified with identical stdout SHA-256 against Go 1.27 (`--warmup 1 --rounds 5`):

| Adversarial Probe | Pion Before | Pion After | Go 1.27 | Pion/Go (After) |
| --- | ---: | ---: | ---: | ---: |
| 8 MiB random body (typical) | 19.7 ms | **13.2 ms** | 19.1 ms | **0.7x** (faster) |
| 8 MiB near-miss (`--boundary1234567890`) | 19.6 ms | **14.5 ms** | 17.1 ms | **0.9x** (faster) |
| **P1-4**: 8 MiB periodic worst case (`a`×70) | 576.7 ms | **16.8 ms** | 20.4 ms | **0.8x** (faster, **34× speedup**) |
| 1000 tiny parts fan-out | — | **10.8 ms** | 14.4 ms | **0.7x** (faster) |
| **P0-1**: 64 × 60 KiB plain-param bomb | 4,646 ms | **75.8 ms** | 50.5 ms | **1.5x** (**61× speedup**) |
| **P0-1**: 64 × 60 KiB RFC 2231 param bomb | 13,171 ms | **136.4 ms** | 184.0 ms | **0.7x** (faster, **96× speedup**) |
| Wasm32 release: `bmh_worst_8.bin` | 2.43 s | **0.09 s** | — | **27× speedup** |
| Wasm32 release: `mp_cont_bomb.bin` | 12.02 s | **0.31 s** | — | **39× speedup** |

### Honest Performance Analysis

- **Wins**:
  - **Quoted-Printable Decode (16 MB)**: Pion (`418.91 MB/s`) is **1.72x faster** than Go 1.27 `mime/quotedprintable` (`243.00 MB/s`) with lower peak RSS (`48.25 MiB` vs `55.42 MiB`).
  - **Adversarial Multipart & RFC 2231 Bombs**: Pion beats Go 1.27 on 8 MiB periodic worst-case boundary search (`0.8x` time), 8 MiB random/near-miss bodies (`0.7–0.9x`), 1000-part fan-out (`0.7x`), and 64 × 60 KiB RFC 2231 parameter bombs (`0.7x`). Note that Go reads multipart through a streaming `io.Reader` and copies part bodies, whereas Pion slices an in-memory `Bytes` buffer.
  - **50 MB `multipart/form-data` Parse**: Pion (`1,331.88 MB/s`) achieves **0.89x** of Go 1.27 (`1,504.94 MB/s`) while consuming **15% less peak RSS** (`101.88 MiB` vs `120.06 MiB`).
- **Gaps**:
  - **Short Header Parsing (`headers_full` / `headers_mt`) & Plain-Param Bomb**: Pion (`399.92 ns/op` on `Content-Type`, `623.02 ns/op` on mixed headers, `1.5x` time on 64 × 60 KiB plain params) trails Go 1.27 (`224.77 / 370.87 ns/op`) and Rust `mime 0.3` (`156.18 ns/op`), though Pion uses **5–6x less peak RSS** than Go (`2.06–2.33 MiB` vs `11.98–12.14 MiB`) because Pion allocates per-component `String` slices instead of keeping a single backing buffer with index spans.
  - **Magic-Byte Sniffing (100k ops)**: After expanding coverage to 40+ formats (matching `infer 0.16`), Pion (`203.25 ns/op`) is **0.83x** of Rust `infer 0.16` (`169.37 ns/op`) with near-identical ~1.8 MiB peak RSS.
