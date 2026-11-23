# `email` (`v0.1.0`)

Pure Pion, zero-C-dependency, `World`-free, Native + Wasm32 email parsing, construction, MIME tree extraction, RFC 6376/8301/8463 DKIM signing/verification, and `mbox` engine.

Built directly on in-repo `packages/mime`, `packages/base64`, `packages/time`, and `packages/crypto`, designed alongside Rust `mail-parser`, Go `net/mail`, and `github.com/emersion/go-msgauth`.

## Features

- **RFC 5322 / 6532 / 2047 Headers (`src/header.pion`, `src/charset.pion`)**:
  - `parse_headers`, `unfold_header`, `fold_header_line`, `headers_get`, `headers_get_decoded`, `headers_get_all`.
  - CRLF/LF + WSP folding/unfolding, RFC 5322 §4.5.3 obsolete whitespace before `:`, graceful skipping of malformed header lines without `:`, multi-value headers, case-insensitive lookup, RFC 6532 UTF-8 headers, 78-column soft folding with strict RFC 5322 §2.1.1 `<= 998`-octet physical line enforcement, and strict CR/LF/NUL injection validation.
  - Pure-Pion multi-charset conversion (`decode_charset_to_utf8`) and RFC 2047 decoding (`email_decode_rfc2047`) supporting `UTF-8`, `US-ASCII`, `ISO-8859-1`, `ISO-8859-15`, `Windows-1252`, `KOI8-R`, `GB2312`/`GBK`/`GB18030`, and `Shift_JIS`, with adjacent encoded-word whitespace elision (§6.2) and cross-word multibyte sequence merging.
- **RFC 5322 / 6532 Address Lists (`src/address.pion`)**:
  - `parse_address`, `parse_address_list`, `flatten_addresses`, `format_address_list`, `Mailbox::new`, `Mailbox::format`.
  - Strict RFC 5322 §3.4.1 `addr-spec` validation (rejecting unquoted specials `<>,;:()[]\"`, consecutive dots `..`, and leading/trailing `.`), CFWS around `@` in dot-atoms, IPv4/IPv6 domain literals (`[IPv6:2001:db8::1]`), quoted display names with backslash escapes (protecting `=?...?=` literals), arbitrarily nested parentheses comments `(outer (nested))` (with depth guard), obsolete source routes `<@hop1,@hop2:user@domain>`, named and empty groups, automatic RFC 2047 display-name decoding/encoding, and CR/LF/NUL injection rejection.
- **RFC 5322 Date-Time (`src/date.pion`)**:
  - `parse_date`, `EmailDate::from_timestamp`, `EmailDate::format` (backed by `packages/time`).
  - Weekday consistency validation, optional seconds, leap-second handling, 2/3/4-digit years, numeric offsets (`±HHMM`), `-0000` unknown local offset preservation (`unknown_local_offset`), legacy timezones (`UT`, `GMT`, `UTC`, `EST`, `EDT`, `CST`, `CDT`, `MST`, `MDT`, `PST`, `PDT`), military zones, and CFWS comments.
- **MIME Email Tree & Fluent Builder (`src/message.pion`, `src/builder.pion`)**:
  - `parse_message`, `parse_message_with_limits`: fully iterative (explicit stack, 0 recursion, hard safety depth cap) zero-copy-slice MIME tree parser for `multipart/mixed`, `multipart/alternative`, `multipart/related`, `message/rfc822`, RFC 2045 §6.8 permissive `base64`, and `quoted-printable`, tolerating missing multipart close-delimiters.
  - One-call extractors: `text_body()`, `html_body()` (automatically transcoded to valid UTF-8 via declared `charset`), `attachments()` (including `message/rfc822` parts and RFC 2047-decoded filenames), `inline_parts()`, `part_by_cid()`, with `safe_filename` path-traversal/control/DOS-device sanitization.
  - `EmailBuilder`: injection-safe fluent builder with automatic RFC 2047 chunked folding (`<= 76` chars/line for non-ASCII subjects), RFC 2046 §5.1.1 boundary seed validation, attachment `content_type` validation (rejecting `multipart/*`), Base64 76-column wrapping, and deterministic boundary seeding (`World`-free).
- **RFC 6376 / 8301 / 8463 DKIM & `mbox` (`src/dkim.pion`, `src/rsa_verify.pion`, `src/mbox.pion`)**:
  - `canonicalize_header`, `canonicalize_body`, `parse_dkim_signature`, `dkim_sign_ed25519`, `dkim_verify_ed25519`, `dkim_sign_rsa`, `dkim_verify_rsa`, `dkim_verify_rsa_spki_der`.
  - All four RFC 6376 §3.4 canonicalization modes, constant-time `bh=` SHA-256 verification, bottom-up multi-header selection, multi-`DKIM-Signature` header traversal, duplicate `From:` smuggling rejection (`n_from > h_from`, while preserving valid oversigning `h=from:from`), mandatory `From` coverage in `h=` for both signing and verification, duplicate tag rejection (RFC 6376 §3.2), required tag (`v a b bh d s h`) and `l=`/`t=`/`x=` overflow enforcement.
  - `dkim_verify_rsa_spki_der(raw_email, spki_der)` verifies 1024–4096-bit RSA DKIM keys per RFC 8301 §3.2 (`>= 2048` bits delegated to `packages/crypto`; `1024..2047` bits verified via pure-Pion PKCS#1 v1.5 SHA-256; `< 1024` bits such as 512-bit strictly rejected).
  - `parse_mbox`, `parse_mbox_with_limits`, `format_mbox_entry`, `format_mbox`: `mboxo` and lossless `mboxrd` (`>*From ` escaping/unescaping, including empty messages and messages without trailing newlines) with `From ` line newline-injection rejection and decoupled message-count limits (`>= 1,000,000` messages by default).
- **Resource Limits & Security (`EmailLimits`)**:
  - `max_depth` (16, hard iterative safety cap 256), `max_parts` (1024), `max_headers` (1024), `max_header_bytes` (256 KiB), `max_body_bytes` (64 MiB).

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

// RFC 8301 §3.2 RSA DKIM verification (supports 1024..4096-bit SPKI DER keys, rejects < 1024-bit):
// let verified = email::dkim_verify_rsa_spki_der(signed_email_bytes, spki_der_bytes)
```

## Verification

- `sh scripts/verify.sh packages/email`: **PASS** (`pionc fmt --check`, `pionc check --json`, `pionc test --json`: **14/14 `email` tests PASS**, 392/392 including workspace deps, 0 failures)
- `packages/email/wasm_smoke` 4-mode matrix (all exit `0`, byte-identical stdout SHA-256):
  - Native debug (`pionc build` + run): exit `0`
  - Native release (`pionc build --release` + run): exit `0`
  - Wasm32 debug (`pionc build --target wasm32` + `node pion_wasm_rt.mjs`): exit `0`
  - Wasm32 release (`pionc build --release --target wasm32` + `node pion_wasm_rt.mjs`): exit `0`

## Head-to-Head Benchmarks

Run with `sh packages/email/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, locked `Cargo.lock` / `go.sum`, mandatory stdout SHA-256 verification) on **Darwin arm64** against:
- **Rust** `mail-parser 0.9.4` (`--release --locked`)
- **Go** stdlib `net/mail` + `github.com/emersion/go-msgauth v0.7.0` (`-mod=readonly`)

### W1: 5,000 Multi-Part MIME Emails Parse & Body/Attachment Hash

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `6,345,580 B` | Ops: `5,000` | SHA-256: `38ce7a358e162dc3d24eac354cec116c69bb18e9285ee0bf01e87773ce8a59d4`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_mail_parser) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 48.458 | 48.087 | 50.830 | 130.95 | 9691.67 | 3.23 MiB | 0.52x |
| `rust_mail_parser` | 25.434 | 25.074 | 26.399 | 249.49 | 5086.76 | 2.69 MiB | 1.00x (baseline) |

### W2: 100,000 Complex RFC 5322 Address-List & Date Parses

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Input: `12,492,000 B` | Ops: `100,000` | SHA-256: `1d0df93f8a814b8bdecfc1a80825b48d26caeb67c3cbcdbbc9c5835608d786a6`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs go_net_mail) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 120.999 | 120.128 | 122.108 | 103.24 | 1209.99 | 2.36 MiB | **1.73x** |
| `go_net_mail` | 208.833 | 204.809 | 214.841 | 59.82 | 2088.32 | 17.27 MiB | 1.00x (baseline) |

### W3: 2,000 Email Build + DKIM `relaxed/relaxed` Ed25519 Sign/Verify Roundtrip

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` | Ops: `2,000` | SHA-256: `22223d47651049b1e97bcb09f9a11326f3dc32ac91d74fb790a04d19fabe7eda`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs go_msgauth) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 575.242 | 572.885 | 576.752 | 287620.96 | 2.38 MiB | 0.21x |
| `go_msgauth` | 121.817 | 119.132 | 123.446 | 60908.71 | 16.98 MiB | 1.00x (baseline) |

> **Honest Assessment**: `packages/email` outperforms Go `net/mail` by **1.73x** (with 7.3x lower RSS) on complex RFC 5322 address-list and date parsing (W2), reaches **130.95 MB/s** (0.52x of Rust `mail-parser`, up from 113 MB/s) on full multi-part MIME tree parsing + charset validation + QP/Base64 decoding (W1), and runs at **0.21x** of `github.com/emersion/go-msgauth v0.7.0` (with 7.1x lower RSS) on full end-to-end DKIM sign/re-parse/verify (W3) because `packages/crypto` uses portable pure-Pion Ed25519 curve arithmetic versus Go's assembly implementation.

## Formal Verification (Lean 4)

The RFC 5322 / 6532 limits, header-injection/folding guards, address character classes (`atext`/`dtext`/`qtext`), and date/timezone/Euclidean-epoch arithmetic kernels (`EmailLimits`, `hdr_ascii_lower`, `email_is_ftext`, `email_is_injection_byte`, `email_effective_fold_limit`, `addr_is_atext`, `addr_is_dtext`, `addr_is_qtext_char`, `dt_is_digit`, `dt_lower`, `dt_normalize_year`, `dt_is_valid_offset_seconds`, `dt_numeric_offset_seconds`, `dt_clamp_leap_second`, `dt_epoch_floor_day`, `dt_epoch_rem_sec`) are annotated with `#verify` and formally verified in Lean 4 under `proofs/` (24 `0-sorry` theorems, standard axioms only, 44-case native-vs-Lean differential cross-check):

```bash
bash packages/email/proofs/run_proofs.sh
```
