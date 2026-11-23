# `email` (`v0.1.0`)

Pure Pion, zero-C-dependency, `World`-free, Native + Wasm32 email parsing, construction, MIME tree extraction, RFC 6376 DKIM signing/verification, and `mbox` engine.

Built directly on in-repo `packages/mime`, `packages/base64`, `packages/time`, and `packages/crypto`, designed alongside Rust `mail-parser` and Go `net/mail` + `emersion/go-message`.

## Features

- **RFC 5322 / 6532 / 2047 Headers (`src/header.pion`)**:
  - `parse_headers`, `unfold_header`, `fold_header_line`, `headers_get`, `headers_get_decoded`, `headers_get_all`.
  - CRLF/LF + WSP folding/unfolding, multi-value headers, case-insensitive lookup, automatic RFC 2047 Encoded-Word decoding (via `packages/mime`), RFC 6532 UTF-8 headers, 78-column soft folding, and strict CR/LF/NUL injection validation.
- **RFC 5322 / 6532 Address Lists (`src/address.pion`)**:
  - `parse_address`, `parse_address_list`, `flatten_addresses`, `format_address_list`, `Mailbox::new`, `Mailbox::format`.
  - Quoted display names with backslash escapes, arbitrarily nested parentheses comments `(outer (nested))` (with depth guard), angle/route addresses `<a@b>`, obsolete source routes `<@hop1,@hop2:user@domain>`, named and empty groups (`Team: a@x, b@y;`, `Undisclosed:;`), automatic RFC 2047 display-name decoding/encoding, and CR/LF/NUL injection rejection.
- **RFC 5322 Date-Time (`src/date.pion`)**:
  - `parse_date`, `EmailDate::from_timestamp`, `EmailDate::format` (backed by `packages/time`).
  - Weekday consistency validation, optional seconds, leap-second handling, 2/3/4-digit years, numeric offsets (`±HHMM`), `-0000` unknown local offset preservation (`unknown_local_offset`), legacy timezones (`UT`, `GMT`, `UTC`, `EST`, `EDT`, `CST`, `CDT`, `MST`, `MDT`, `PST`, `PDT`), military zones, and CFWS comments.
- **MIME Email Tree & Fluent Builder (`src/message.pion`, `src/builder.pion`)**:
  - `parse_message`, `parse_message_with_limits`: bounded-depth MIME tree parser for `multipart/mixed`, `multipart/alternative`, `multipart/related`, `message/rfc822`, `base64`, and `quoted-printable`.
  - One-call extractors: `text_body()`, `html_body()`, `attachments()`, `inline_parts()`, `part_by_cid()`, with `safe_filename` path-traversal/control/DOS-device sanitization from `packages/mime`.
  - `EmailBuilder`: injection-safe fluent builder with automatic RFC 2047 non-ASCII encoding, 78-column header folding, Base64 76-column attachment wrapping, and deterministic boundary seeding (`World`-free).
- **RFC 6376 DKIM & `mbox` (`src/dkim.pion`, `src/mbox.pion`)**:
  - `canonicalize_header`, `canonicalize_body`, `parse_dkim_signature`, `dkim_sign_ed25519`, `dkim_verify_ed25519`, `dkim_sign_rsa`, `dkim_verify_rsa`.
  - All four RFC 6376 §3.4 canonicalization modes (`simple/simple`, `relaxed/simple`, `simple/relaxed`, `relaxed/relaxed`), constant-time `bh=` SHA-256 body hash verification, bottom-up multi-header selection, `ed25519-sha256` (RFC 8463) and `rsa-sha256` (RSA-2048+ via `packages/crypto`).
  - `parse_mbox`, `parse_mbox_with_limits`, `format_mbox_entry`, `format_mbox`: `mboxo` and lossless `mboxrd` (`>*From ` escaping/unescaping) with `From ` line newline-injection rejection.
- **Resource Limits & Security (`EmailLimits`)**:
  - `max_depth` (16), `max_parts` (1024), `max_headers` (1024), `max_header_bytes` (256 KiB), `max_body_bytes` (64 MiB).

## Quick Start

```pion
import "email"

let from_mb = match email::Mailbox::new("张三", "zs@example.com") { Ok(m) => m, Err(_) => ... }
let to_mb = match email::Mailbox::new("Bob", "bob@example.com") { Ok(m) => m, Err(_) => ... }
let raw = match email::EmailBuilder::new()
  .from(from_mb)
  .to(to_mb)
  .subject("季度报告")
  .text_body("Hello 世界")
  .html_body("<p>Hello <b>世界</b></p>")
  .attach("report.pdf", "application/pdf", "%PDF-1.4".to_bytes())
  .build() { Ok(b) => b, Err(_) => ... }

let msg = match email::parse_message(raw) { Ok(m) => m, Err(_) => ... }
let subject = msg.subject()
let text = msg.text_body()
let atts = msg.attachments()
```

## Verification

- `sh scripts/verify.sh packages/email`: **PASS** (`pionc fmt --check`, `pionc check --json`, `pionc test --json`: **13/13 `email` tests PASS**, 391/391 including workspace deps, 0 failures)
- `packages/email/wasm_smoke` 4-mode matrix (all exit `0`, byte-identical stdout SHA-256 `91fcc77f98975ceb3bad38cfc72c046af51f0587fe8252bbcbec4bf5f29bb315`):
  - Native debug (`pionc build` + run): exit `0`
  - Native release (`pionc build --release` + run): exit `0`
  - Wasm32 debug (`pionc build --target wasm32` + `node pion_wasm_rt.mjs`): exit `0`
  - Wasm32 release (`pionc build --release --target wasm32` + `node pion_wasm_rt.mjs`): exit `0`

## Head-to-Head Benchmarks

Run with `sh packages/email/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, locked `Cargo.lock` / `go.mod`, mandatory stdout SHA-256 verification) on **Darwin arm64** against:
- **Rust** `mail-parser 0.9.4` (`--release --locked`)
- **Go** stdlib `net/mail` + `crypto/ed25519` + `crypto/sha256` (`-mod=readonly`)

### W1: 5,000 Multi-Part MIME Emails Parse & Body/Attachment Hash

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `6,345,580 B` | Ops: `5,000` | SHA-256: `38ce7a358e162dc3d24eac354cec116c69bb18e9285ee0bf01e87773ce8a59d4`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_mail_parser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 56.108 | 55.200 | 56.613 | 113.09 | 11221.69 | 3.17 MiB | 0.46x |
| `rust_mail_parser` | 25.703 | 25.205 | 26.039 | 246.88 | 5140.71 | 2.69 MiB | 1.00x (baseline) |

### W2: 100,000 Complex RFC 5322 Address-List & Date Parses

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `12,492,000 B` | Ops: `100,000` | SHA-256: `1d0df93f8a814b8bdecfc1a80825b48d26caeb67c3cbcdbbc9c5835608d786a6`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs go_net_mail) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 114.918 | 114.263 | 115.231 | 108.70 | 1149.18 | 2.34 MiB | **1.76x** |
| `go_net_mail` | 202.196 | 196.642 | 207.076 | 61.78 | 2021.96 | 12.86 MiB | 1.00x (baseline) |

### W3: 2,000 Email Build + DKIM `relaxed/relaxed` Ed25519 Sign/Verify Roundtrip

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Ops: `2,000` | SHA-256: `517d732c94066ea022759a0512237f68552e37c262b7f0a4efedbc0cc9424d00`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs go_stdlib) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 575.805 | 574.153 | 578.322 | 287902.42 | 2.33 MiB | 0.15x |
| `go_stdlib` | 86.743 | 85.799 | 90.183 | 43371.38 | 10.38 MiB | 1.00x (baseline) |

> **Honest Assessment**: `packages/email` outperforms Go `net/mail` by **1.76x** (with 5.5x lower RSS) on complex RFC 5322 address-list and date parsing (W2), reaches **113 MB/s** (0.46x of Rust `mail-parser`) on full multi-part MIME tree parsing + QP/Base64 decoding (W1), and trails Go's assembly-accelerated `crypto/ed25519` on W3 (0.15x) because `packages/crypto` uses portable pure-Pion curve arithmetic.
