# `packages/email` red-team audit

Target: `origin/feat/pkg-email` @ `9be68ec` (RFC 5322/6532/2045/2047 email parsing and building, RFC 6376/8463 DKIM, mbox; `v0.1.0`).
References:
- Rust `mail-parser 0.9.4` (pinned by `oracle/rust/Cargo.lock`), for headers, addresses, dates, RFC 2047 and MIME.
- Go 1.27 `net/mail` (stdlib), for addresses and dates.
- `github.com/emersion/go-msgauth v0.7.0` (pinned by `oracle/go/go.sum`). It is an independent RFC 6376/8463 DKIM implementation built on Go `crypto/ed25519` and `crypto/rsa`, and it signs and verifies the DKIM fixtures.
- The RFC 8463 Appendix A test message, verbatim.

Machine: Apple M5 Max (Darwin arm64), `pionc 0.1.0`, node v24.22.2, go1.27.3, cargo 1.100.0.

Reproduce: `sh packages/email/audit/run_audit.sh`. It takes about 10 s and writes all artifacts to a fresh `$AUDIT_OUT` under `/private/tmp`. Nothing is written inside the repository.

Exit status: `0` when every check passes, `1` when any check fails, and `2` on a harness or toolchain error. The expected values are RFC behaviour and live in `cases/*.tsv` and in `src/main.pion`, never in Pion's current output. A fix branch should therefore turn the run green without changing a byte under `audit/`.

## Verdict

| Severity | Root causes | Failing checks | Summary |
| --- | ---: | ---: | --- |
| **P0**: the security property is broken | **2** | 2 | DKIM accepts a signature that leaves `From` unauthenticated. It does so in two ways: a duplicate `From:` is smuggled in above the signed one, or the signature's `h=` does not cover `From` at all. |
| **P1**: a correctness, interoperability or robustness defect reachable from ordinary mail | **6** | 10 | Body `charset` is ignored. A single bad base64 octet rejects the whole message. 1024-bit RSA DKIM keys (RFC 8301 MUST) are rejected. Only the first `DKIM-Signature` is evaluated. Duplicate DKIM tags are accepted. `Mailbox::new` lets `<>,;:` into the addr-spec, so the builder can smuggle recipients. |
| **P2**: an RFC deviation, hardening gap or edge case | **16** | 32 | See §P2. |

**What holds** (128 checks pass):

DKIM:
- Canonicalization is correct in all four modes, including empty bodies, trailing blank lines and runs of WSP.
- Signatures interoperate with go-msgauth in both directions: 32/32 Go-signed fixtures verify in Pion, and 48/48 Pion-signed messages verify in go-msgauth. Each direction covers ed25519 and rsa-2048, all four canonicalizations, and edge-case bodies and headers.
- The RFC 8463 ed25519 vector verifies, including its oversigned `h=`.
- Pion rejects every tampered variant tested:
  - a 1-byte change to the body or to a header;
  - a truncated, extended or non-base64 `b=`;
  - the wrong key;
  - `a=` confusion between algorithms;
  - 512-bit RSA keys.

Builder:
- Every CR, LF and NUL injection into a builder input is refused.
- Boundary collision is impossible: every part is base64-encoded, so an attacker who embeds `--pion-email-boundary-mix` in a body or attachment cannot forge a part.

Parser:
- Every default-limit DoS probe ends in a graceful `Err` in all four modes, within milliseconds.
- mbox parsing is linear.
- The suite's stdout and the signed bytes are identical across `native_dbg`, `native_rel`, `wasm_dbg` and `wasm_rel`.

---

## P0

### P0-1: duplicate `From:` smuggling passes DKIM, and `EmailMessage::from()` returns the attacker's address

Checks: `dkim_dup_from_smuggling`, `INFO go-msgauth on pion_atk_dup_from`.

```
DKIM-Signature: v=1; a=ed25519-sha256; c=relaxed/relaxed; d=audit.example; s=ed; t=...; h=from:to:subject:date; bh=...; b=<valid>
From: CEO <ceo@good.example>              <- added by the attacker, not signed
From: Alice <alice@good.example>          <- the signed From
To: bob@x.example
...
```

What happens:
- `dkim_verify_ed25519` returns `Ok`.
- `parse_message(..).from()[0]` is `ceo@good.example`.
- `header("From")` returns the first `From` as well.

The reason is that the two code paths pick different `From` headers:
- DKIM selects the bottom-most `From` (RFC 6376 §5.4.2, correct), in `dkim_build_signing_input`, `src/dkim.pion`.
- The message accessors take the first one, in `headers_get`, `src/header.pion:286`, used by `msg_parse_addr_header`.

What the RFCs require:
- RFC 5322 §3.6 allows exactly one `From`.
- RFC 6376 §8.15 describes this attack and asks verifiers to treat it as suspicious.

go-msgauth also returns PASS on this message. That is why the library has to close the gap itself: a caller of `dkim_verify_*` has no way to learn which `From` was authenticated.

Fix direction: make `dkim_verify_*` fail when the message has more `From` fields than `h=` lists `from` entries. Oversigning (`h=from:from`) should stay valid; `dkim_oversign_from` checks that it already blocks the injection. Alternatively, return an error from `EmailMessage::from()` when there are multiple `From` fields.

### P0-2: a signature whose `h=` omits `From` is accepted, so `From` can be replaced freely

Checks: `dkim_h_without_from` (P0), `dkim_sign_requires_from` (P2), `INFO go-msgauth on pion_atk_h_without_from: FAIL dkim: From field not signed`.

Sign with `signed_headers: ["Subject"]`, then replace `From: Alice <alice@good.example>` with `From: Mallory <ceo@good.example>`. `dkim_verify_ed25519` still returns `Ok`.

RFC 6376 §5.4 says "The From header field MUST be signed", and §6.1.1 says a verifier MUST ignore a signature whose `h=` lacks `From`. go-msgauth rejects this message.

Root cause: `parse_dkim_signature` (`src/dkim.pion:397`) only checks that `h=` is non-empty, and the signer (`dkim_prepare_sign_header`, `src/dkim.pion:504`) accepts any header list.

---

## P1

| ID | Check(s) | Minimal reproduction | Expected (reference) | Pion | Root cause |
| --- | --- | --- | --- | --- | --- |
| P1-1 | `mime_m01_latin1_qp`, `mime_m10_gb2312_body` | `Content-Type: text/plain; charset=iso-8859-1` + QP `caf=E9`; `charset=gb2312` base64 body | `café`, `你好世界` (mail-parser; RFC 2045/2046 charset) | `text_body()` returns raw `0xE9` / GB2312 bytes as an **invalid-UTF-8 `String`** | `EmailMessage::text_body/html_body` → `p.body.to_string()` (`src/message.pion:456,470`) ignores `MimePart.charset`; no charset conversion path in `email` |
| P1-2 | `mime_m02_b64_badchar` | attachment `Content-Transfer-Encoding: base64` body `aGVsbG8gd29ybGQ!` | message parses; RFC 2045 §6.8: "characters outside of the base64 alphabet are to be ignored" → `hello world` (mail-parser parses) | **whole `parse_message` → `Err(InvalidEncoding)`**: one stray octet in any leaf hides the entire mail (text body included) from a Pion-based filter while MUAs still render it | `msg_decode_body` uses `base64::decode_loose_bytes` (rejects non-alphabet) and the error is propagated from every leaf (`src/message.pion:68`) |
| P1-3 | `dkim_rfc8463_rsa1024` | RFC 8463 Appendix A `rsa-sha256` signature, 1024-bit key `test._domainkey.football.example.com` | verifies (RFC 8301 §3.2: verifiers **MUST** validate 1024–4096-bit keys; still common in production DNS) | `RsaPublicKey::from_spki_der` → `InvalidKey`; `dkim_verify_rsa` cannot be called | `packages/crypto/src/rsa.pion` floors verification keys at 2048 bits; `email` has no DKIM-specific verifier path |
| P1-4 | `dkim_multisig_rsa_below_ed`, `dkim_multisig_ed_below_rsa` | go-msgauth message with two signatures (ed25519 above rsa-2048, and the reverse) | the requested algorithm's signature verifies (RFC 6376 §6.1: evaluate each signature) | `DkimVerifyFailed: algorithm mismatch` — only the **first** `DKIM-Signature` is ever looked at | `dkim_extract_and_check_body` takes the first matching header and `break`s (`src/dkim.pion:633-646`) |
| P1-5 | `dkim_tag_dup_h`, `dkim_tag_dup_d`, `dkim_tag_dup_v` | `v=1; a=ed25519-sha256; d=audit.example; d=evil.example; s=ed; h=from; h=subject; ...` | RFC 6376 §3.2: duplicate tag ⇒ the entire tag-list is invalid | accepted; `d=` last-wins, `h=` lists are **concatenated** → verifiers disagree on the signing domain / signed set | `parse_dkim_signature` assigns per tag without a seen-set (`src/dkim.pion:333-385`) |
| P1-6 | `bld_addr_spec_smuggling` | `Mailbox::new("Bob", "abc>,<victim@evil.example")`, `Mailbox::new("Bob", "list:victim@evil.example;")` | `Err(InvalidAddress)` (RFC 5322 §3.4.1 addr-spec forbids unquoted specials) | accepted; builder emits `To: Bob <abc>,<victim@evil.example>` / `To: Bob <list:victim@evil.example;>` — lenient parsers (mail-parser) see `victim@evil.example` as an extra recipient | `addr_validate_spec` (`src/address.pion:26-75`) only rejects WSP/CTL and a second unquoted `@`; specials `<>,;:()[]\"` pass |

## P2

| ID | Check(s) | Reproduction → Pion vs expected | Root cause / note |
| --- | --- | --- | --- |
| P2-1 | `addr_a05`, `addr_a06`, `addr_a08`, `addr_a19`, `addr_a20` | `john(comment)@example.com`, `john@(comment)example.com` → ERR (RFC 5322 dot-atom allows CFWS); `user@[IPv6:2001:db8::1]` → ERR (Go accepts); `john..doe@example.com`, `.john@example.com` → accepted (Go rejects, RFC invalid) | `is_addr_delim` treats `:` as delimiter outside angle brackets; atoms/addr-spec are not tokenized per RFC 5322 §3.4.1 |
| P2-2 | `rfc2047_r06,r08,r09,r12,r13` | `=?windows-1252?Q?=80?=`, `=?GB2312?B?…?=`, `=?Shift_JIS?…?=`, `=?ISO-8859-15?…?=`, `=?KOI8-R?…?=` left encoded (mail-parser decodes all) | `mime::decode_charset_bytes` supports only UTF-8 / US-ASCII / ISO-8859-1 |
| P2-3 | `mime_m06_rfc2047_name` | `filename="=?UTF-8?B?5oql5ZGKLnBkZg==?="` → filename stays encoded (Outlook/Gmail/mail-parser decode `报告.pdf`) | no RFC 2047 pass over `filename`/`name` |
| P2-4 | `mime_m07_rfc822_att` | `message/rfc822` part without `Content-Disposition` → `attachments()` is empty (mail-parser lists it) — an attached mail is invisible to an attachment scanner | `attachments()` excludes `message/rfc822` leaves (`src/message.pion:488`); `collect_parts_dfs` does not descend into them either |
| P2-5 | `mime_m09_no_close` | multipart without close-delimiter → whole message `Err(InvalidMime: unexpected end of input)` | `MultipartReader::read_all` error propagated (`src/message.pion:180-184`) |
| P2-6 | `mime_m15_obs_header_ws`, `hdr_garbage_line` | `Subject : x` (RFC 5322 §4.5.3 obs-optional) or one header line without `:` → whole message `Err(InvalidHeader)` (mail-parser parses) | `parse_headers` rejects WSP/garbage in field names (`src/header.pion:262`) instead of skipping the line |
| P2-7 | `dkim_sign_requires_from` | `dkim_sign_*` signs with `signed_headers=[Subject]` | see P0-2 |
| P2-8 | `dkim_tag_missing_b`, `dkim_tag_missing_bh` | tag-lists without `b=` / `bh=` parse OK (verification still fails later, but as `DkimVerifyFailed` not `InvalidDkim` — PERMFAIL vs FAIL distinction lost) | required-tag check covers only `v a d s h` (`src/dkim.pion:397`) |
| P2-9 | `dkim_l_overflow`, `dkim_t_overflow` | `l=4294967301` → `body_length=5`; `t=99999999999999999999999` wraps to `200376420520689663` | `dkim_parse_int64` has no overflow check (`src/dkim.pion:238-250`) and `l` is narrowed with `.to_int()` (`:371`) |
| P2-10 | `bld_seed_quote_space`, `bld_seed_len100`, `bld_seed_semicolon` | `boundary_seed("a\"b c")` / 100 chars / `"a;b=c"` → message whose MIME tree does not round-trip (text_body returns the raw multipart) or boundary > 70 chars | `EmailBuilder::build` only checks CR/LF/NUL on the seed (`src/builder.pion:353`); RFC 2046 §5.1.1 `bchars`, 1..70 |
| P2-11 | `bld_attach_multipart_ct` | `attach(.., "multipart/mixed; boundary=\"zz\"", ..)` → built message no longer parses | attachment `content_type` spliced verbatim (`src/builder.pion:206`) |
| P2-12 | `bld_line_998`, `bld_subject_2047_roundtrip` | 1200-char Subject token → 1209-octet line (RFC 5322 §2.1.1 MUST ≤ 998); long UTF-8 subject → first line 82 chars (RFC 2047 §2 SHOULD ≤ 76) | `fold_header_line` only breaks at WSP after the `Name: ` prefix (`src/header.pion:148-185`) |
| P2-13 | `bld_display_name_2` | `Mailbox::new("=?utf-8?b?Zm9v?=", ..)` is emitted unquoted and read back as `foo` | `addr_format_phrase` (`src/address.pion:145`) does not quote ASCII text that looks like an encoded-word |
| P2-14 | `mbox_rd_no_final_newline`, `mbox_rd_empty` | mboxrd round-trip of `…no newline` gains `\n`; empty message becomes `\n` (README claims "lossless mboxrd") | `format_mbox_entry` appends LF (`src/mbox.pion:216`) and the reader strips only one separator LF |
| P2-15 | `mbox_3000_default_limits` | `parse_mbox` of a 3,000-message mbox → `LimitExceeded` | mbox reuses `max_parts` (1024) as a message cap (`src/mbox.pion:117`) |
| P2-16 | `dos_rfc822_deep_1000_raised_limit`, `dos_rfc822_deep_20000_raised_limit` | with `EmailLimits.max_depth` raised: 1,000 nested `message/rfc822` → native OK but **wasm32 `RangeError: Maximum call stack size exceeded`**; 20,000 → **native SIGSEGV**, wasm RangeError. Default `max_depth = 16` is safe | `parse_part_node` is recursive (module doc says "Iterative"); no hard ceiling on `max_depth` |

### Informational (no verdict)

| ID | Observation |
| --- | --- |
| `date_d07`, `date_d08` | `+2500` and `+0060` are rejected. Go rejects `+2500` and accepts `+0060`. RFC 5322 does not bound these values, so strict rejection is acceptable. |
| `date_d21` | A day-of-week that contradicts the date is rejected (`Mon, 21 Nov 1997`). RFC 5322 §3.3 says it MUST match, but Go and mail-parser ignore the mismatch. Expect interop complaints from real-world mail. |
| `date_d22` | The leap second `23:59:60` is clamped to `:59`, so the timestamp is off by 1 s. That is acceptable. |
| `dkim_l_tag_append` | Text appended after an `l=`-covered body verifies `Ok`, with `body_length=Some(32)`. Callers must compare that against the body size. RFC 6376 §8.2 recommends caution. |
| wasm32 stdout | `io_println` of a `String` containing invalid UTF-8 differs between native (raw bytes) and wasm32 (decoded as U+FFFD by `pion_wasm_rt.mjs`). This belongs to the runtime, not to `email`, but P1-1 hands such strings to callers. The probe escapes invalid bytes as `\xHH` so that the four modes stay comparable. |

---

## Coverage

| Area | Checks | Content |
| --- | ---: | --- |
| Addresses (`cases/addr.tsv`) | 30 | quoted local parts, escapes, nested comments, CFWS inside addr-spec, IPv4/IPv6 literals, obsolete routes, groups (empty, nested, with comments), RFC 2047/6532 names, EAI addr-spec, malformed input |
| Dates (`cases/date.tsv`) | 23 | invalid calendar dates, leap day, 2-digit and 3-digit years (49/50 pivot), out-of-range zones, `-0000`, CFWS inside the time, obsolete and military zones, trailing garbage |
| RFC 2047 (`cases/rfc2047.tsv`) | 15 | adjacent-word whitespace (§6.2), a multibyte character split across words, invalid `Q`/`B` kept literal, 7 non-UTF-8 charsets |
| MIME (`cases/mime/*.eml`) | 16 + 3 | charsets, broken base64, base64 without padding or wrapped, RFC 2231 and RFC 2047 filenames, `message/rfc822`, a boundary-prefix lookalike, missing close-delimiter, raw UTF-8 headers, QP soft breaks, path traversal / `CON` / RLO in `safe_filename`, related + `Content-ID`, QP `=LF` |
| DKIM | 46 + 1 | 8 canonicalization vectors; RFC 8463 ed25519 and rsa-1024; 32 go-msgauth → Pion; 48 Pion → go-msgauth; multi-signature; byte tampering; truncation; non-base64; wrong key; `a=` confusion; 512-bit RSA; oversigning; duplicate `From`; `h=` without `From`; duplicate and missing tags; `rsa-sha1`; `v=2`; `l=`/`t=` overflow; `l=` append |
| Builder | 15 | CR/LF/NUL/bare CR in all 9 inputs; addr-spec specials; boundary collision through text, html, attachment and inline parts; boundary seed; `multipart/*` attachment type; 998-octet lines; folding round-trip; long UTF-8 subject; display names; filenames |
| mbox | 10 + 1 | mboxrd `>*From ` quoting; CRLF and mixed EOL; no final newline; empty message; trailing blank line; mboxo; injection in the `From_` line; 2 entries; 3,000 messages under default limits; 50k→500k linear scaling |
| Headers | 3 | LF-only folding, multi-value order, one malformed line |
| DoS (4 modes each) | 12 | 2,000-deep multipart and `message/rfc822`; 10k headers; 10k parts; a 1 MiB header; 10k nested comments in an address and in a date; a 100k-address list; 6k encoded-words; a 40k-entry `h=`; deep nesting with `max_depth` raised |
| 4-mode consistency | 2 | suite stdout SHA-256, and SHA-256 of the DKIM-signed bytes, across the four modes |

---

## Benchmark fairness (`bench/`, `README.md`)

### W1 (Pion 0.46x of mail-parser)

Fair:
- Pion and mail-parser parse the same 250 synthetic messages 20 times each.
- Both run the same FNV-style checksum over the subject, text, HTML and attachment bytes.
- The stdout SHA-256 values match, and `--locked` is used.

Caveats:
- The corpus is homogeneous: UTF-8 or ASCII only, every message follows one template, and the inputs are cache-warm.
- On any non-UTF-8 corpus the checksums would diverge (P1-1), because mail-parser does charset conversion and Pion does not. W1 therefore measures a path on which Pion does less work.

### W2 (Pion 1.76x of Go `net/mail`)

Fair:
- The input and the checksum (address strings plus Unix timestamps) are the same for both.

Caveats:
- Pion's addr-spec validation is laxer than Go's (P2-1), so the two do not do identical work.
- Go's `ParseDate` tries several `time.Parse` layouts in turn, which inflates its cost on this data.

### W3 (Pion 0.15x of Go): not like-for-like

The two sides do not do the same work:

| Step | Pion | Go side |
| --- | --- | --- |
| Building the message | builds MIME through `EmailBuilder` | concatenates fixed strings |
| Signing | parses headers generically, then signs | canonicalizes 4 hard-coded header values |
| Verifying | re-parses the whole message and re-canonicalizes | takes `b=` out with `strings.Index`, reuses the digest computed while signing, and never re-canonicalizes the headers |

The stdout check only hashes `bh=`, so it does not prove that the two signatures are equivalent.

The cost is dominated by Ed25519. Pion runs portable pure-Pion curve arithmetic; Go uses assembly. The ratio is a crypto comparison more than an email comparison.

A fair W3 would:
- use go-msgauth `dkim.Sign` and `dkim.Verify` (the oracle in this suite);
- hash the full signed message into the checksum.

### Process

`BENCHMARKS.md` at the repository root and `index/email.toml` have no `email` entry yet, which AGENTS.md §1.3 and §1.4 require.

### W1 bottleneck analysis (for the fix phase)

Method: native `--release`, the bench corpus parsed 25,000 times, user time measured for each stage.

| Stage | Time | Share |
| --- | ---: | ---: |
| `parse_headers` (top level) | 0.03 s | ~16% |
| Top-level `MultipartReader::read_all` | +0.04 s | ~20% |
| The rest of `parse_message` | +0.12 s | ~63% |
| Extractors (`subject`, `text_body`, `html_body`, `attachments`) | 0.02 s | ~10% |

"The rest of `parse_message`" covers the nested `multipart/alternative` split, per-part metadata and decoding.

Hot spots:
1. **Multipart bodies are scanned and copied once per nesting level.**
   - Each level builds a new `MultipartReader` with a new two-way searcher over a copied `Bytes` slice of the parent part.
   - Fix: pass `(offset, len)` views into the original buffer and reuse the searcher.
2. **Per-part header work is duplicated.**
   - `Header::new` re-runs `unfold_header` on values that `mime` has already unfolded, allocating a `StringBuilder` per header even when there is nothing to fold (`src/message.pion:191-195`, `src/header.pion:83-118`).
   - `headers_get` is a linear, case-insensitive scan run 4 times per part.
   - `msg_ascii_lower_str` allocates for `charset` and `Content-Transfer-Encoding`.
   - `msg_safe_filename_from_raw` re-formats the header and re-parses `Content-Disposition`.
   - Fix: borrow raw values, fast-path headers that contain no CR/LF, and pick the 4 MIME headers in one pass.
3. **Decoding and extraction copy too much.**
   - `base64::decode_loose_bytes` makes two passes.
   - Each of `text_body`, `html_body` and `attachments` runs `collect_parts_dfs` again and copies the body (`p.body.to_string()`).
   - Fix: walk the tree once and cache the leaf list.

Items 1 and 2 account for most of the time that is not spent in the top-level header parse, so they are where to start.

---

## Reproduction output (`sh packages/email/audit/run_audit.sh`, this commit, exit 1)

```
  native_dbg rc=0   0.29s sha256=3d757ea342d17095 lines=247
  native_rel rc=0   0.30s sha256=3d757ea342d17095 lines=247
  wasm_dbg   rc=0   0.22s sha256=3d757ea342d17095 lines=247
  wasm_rel   rc=0   0.22s sha256=3d757ea342d17095 lines=247
  PASS wasm4_suite_stdout_identical P1 suite stdout byte-identical across native_dbg/native_rel/wasm_dbg/wasm_rel
  PASS wasm4_signed_bytes_identical P1 DKIM-signed output bytes identical across the 4 modes
  PASS dkim_interop_pion_to_go P0 go-msgauth verifies all 48 Pion-signed messages (ed25519 + rsa-2048, 4 canon x 6 bodies)
  INFO go-msgauth on pion_atk_dup_from: PASS
  INFO go-msgauth on pion_atk_h_without_from: FAIL dkim: From field not signed
  [addr] matches RFC expectation: pion 25/30, go net/mail 25/30, rust mail-parser 14/30
  [date] matches RFC expectation: pion 19/19, go net/mail 13/19, rust mail-parser 12/19
  [rfc2047] matches RFC expectation: pion 10/15, rust mail-parser 14/15
  [mime] matches RFC expectation: pion 9/16, rust mail-parser 10/16
  PASS mbox_linear_scaling P1 mbox 50k->500k messages scales linearly (0.015s -> 0.130s, x8.4)
P0: 2 FAIL
P1: 10 FAIL
P2: 32 FAIL
TOTAL: 128 PASS, 44 FAIL, 5 INFO
RESULT: FAIL (exit 1)
```

## Layout

```
audit/
  REPORT.md            this report
  run_audit.sh         entry point: tool checks, oracle builds, 4-mode builds, then driver.py
  driver.py            4-mode run, go-msgauth cross-verification, oracle tables, DoS x 4 modes, mbox scaling, summary/exit code
  pion.toml, src/      Pion probe `email_audit` (all | dos <name> | mbox-scale <n>)
  cases/               addr.tsv, date.tsv, rfc2047.tsv (input + RFC expectation), mime/*.eml + mime_expected.tsv
  oracle/rust/         mail-parser 0.9.4 oracle (Cargo.lock pinned)
  oracle/go/           net/mail + go-msgauth v0.7.0 oracle, DKIM fixture signer/verifier, RFC 8463 vector (go.sum pinned)
```
