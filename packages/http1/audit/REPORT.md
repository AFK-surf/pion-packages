# Red-team audit: `packages/http1`

Target: `origin/feat/pkg-http1` @ `cde5f71` (the pure-Pion Sans-IO HTTP/1.1, chunked and WHATWG SSE engine).
References: Rust `httparse` 1.10.1 (`--release`), Go `net/http` (go1.27.3), RFC 9110 / RFC 9112, and WHATWG HTML §9.2.6.
Machine: Apple M5 Max (`Darwin arm64`).

I only read `packages/http1/src/**`. Everything in this audit lives in `packages/http1/audit/`.

## How to reproduce

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
sh packages/http1/audit/run_audit.sh            # everything (about 20 s plus builds)
sh packages/http1/audit/run_audit.sh tests      # pionc test of audit/tests (FAIL = evidence)
sh packages/http1/audit/run_audit.sh diff       # 101-case three-way differential
sh packages/http1/audit/run_audit.sh probe      # queue / drip / O(n^2) probes
sh packages/http1/audit/run_audit.sh fuzz       # 200k-case mutation fuzz
sh packages/http1/audit/run_audit.sh bench      # adversarial head-to-head (scripts/bench_compare.py)
# A single test, directly:
pionc test --json -p http1_redteam_audit packages/http1/audit
```

Build output, Cargo lockfiles, corpora and logs go to `$AUDIT_OUT` (default `$TMPDIR/pion-http1-audit`). `git status --porcelain --ignored` stays clean.

| Path | What it is |
|---|---|
| `tests/redteam_test.pion` | 33 tests. 21 `p1_*`/`p2_*` tests assert the correct behaviour and **currently FAIL**. 12 `control_*` tests must PASS. |
| `diff/` | Corpus generator plus Go and Rust runners. The Pion runner is `probe diff`. `compare.py` joins the three outputs. |
| `probe/` | Mutation fuzz, `ChunkedDecoder` queue retention, 1-byte drip cost, and Sans-IO O(n²) re-parse. |
| `bench/` | Adversarial corpora and three runners for `scripts/bench_compare.py`. SHA-256 is verified identical across implementations. |

**Current result:** `total=33 passed=12 failed=21`. The 21 failures are the findings below. All 12 controls pass. The differential shows Pion disagreeing with at least one reference on 56 of 101 cases. Most of those are Pion being deliberately stricter; the table under "Differential summary" separates the defects from that.

---

## P0

**None found.** The fuzz ran 200,000 mutated requests, responses, chunked bodies and SSE streams (seed 1, also re-run with seed 7). Each case checks four things: no panic, every strict prefix of an accepted message returns `Partial`, and both `ChunkedDecoder` and `SseDecoder` give the same result whole and in random 1–7-byte splits. **0 divergences.** I found no out-of-bounds access, integer overflow or memory blow-up.

## P1: protocol/security defects with a concrete exploit path

### P1-1 Missing, duplicate and invalid `Host` headers are accepted (RFC 9112 §3.2)
- Tests: `p1_rfc9112_3_2_http11_request_without_host_rejected`, `…duplicate_host_rejected`, `…duplicate_host_case_variant_rejected`, `…invalid_host_value_rejected`.
- Counterexamples (all give `Complete(ok)`):
  - `GET / HTTP/1.1\r\nAccept: */*\r\n\r\n`
  - `Host: public.example\r\nHost: internal.admin`
  - `Host: a\r\nhOsT: b`
  - `Host: a.example b.example`
  - `Host: a.example/evil`
- RFC 9112 §3.2 says a server **MUST** respond 400 to an HTTP/1.1 request with no Host, more than one Host line, or an invalid Host value. The Go net/http server rejects all of these: `missing required Host header`, `too many Host headers` and `malformed Host header` (diff rows `host_*`).
- Impact: `Request::header("host")` returns the **first** Host line, while many proxies route on the last one. That is a host-confusion / cache-poisoning primitive. Pion already does all the other framing hardening at this layer, so callers will reasonably assume Host is checked too.
- Fix: in `parse_headers_block`, when `is_request`, count Host lines. Reject more than one. Reject zero when the version is 1.1. Validate the value against the RFC 3986 `authority` grammar, or at least Go's `validHostByte` set. Add an `HttpError::InvalidHost`.

### P1-2 1xx / 204 / 304 responses report a body (RFC 9112 §6.3 rule 1)
- Tests: `p1_rfc9112_6_3_204_with_content_length_has_no_body`, `…304_with_content_length…`, `…1xx_with_transfer_encoding…`, `…204_with_chunked…`.
- Counterexample: `HTTP/1.1 204 No Content\r\nContent-Length: 38\r\n\r\n` gives `Framing::ContentLength(38)`. `100 Continue` / `204` with `Transfer-Encoding: chunked` gives `Framing::Chunked`.
- Go returns `http.NoBody` for all five diff rows (`r204_cl`, `r204_chunked`, `r304_cl`, `r100_te`, `r101_cl`).
- Impact: a keep-alive client that obeys the returned `framing` swallows 38 bytes of the **next** pipelined response, or tries to chunk-decode it. That is response desync: a malicious or buggy upstream can splice content into another request's response.
- Fix: in `parse_response_at`, force `Framing::None` (no body) when `status < 200 || status == 204 || status == 304`. Document that HEAD responses need the same treatment from the caller, or add a `parse_response_for(method)` variant.

### P1-3 The encoder produces the classic CL.TE / TE.CL smuggling payload
- Tests: `p1_encoder_rejects_content_length_plus_transfer_encoding`, `p1_encoder_rejects_conflicting_or_invalid_content_length`.
- Counterexamples:
  - `encode_request("POST", "/", Http11, [Host, Content-Length: 4, Transfer-Encoding: chunked])` returns `Ok`. Pion's own parser then rejects those bytes with `AmbiguousFraming`.
  - Two different `Content-Length` values, `Content-Length: -1`, and `Transfer-Encoding: chunked, gzip` are also emitted.
  - The same happens in `encode_response`.
- RFC 9112 §6.2: a sender **MUST NOT** send `Content-Length` in a message that has `Transfer-Encoding`. Go's `Request.Write` excludes user-supplied CL/TE and derives framing from the body, so net/http cannot produce these bytes.
- Fix: in `encode_request` / `encode_response`, run the same `validate_te_value` / `parse_strict_u63_decimal` / duplicate checks the parser uses. Reject CL+TE, more than one CL, a malformed CL, a TE whose final coding is not `chunked` (requests), and TE on HTTP/1.0 (see P2-9).

## P2: spec divergences, interoperability, robustness

| # | Test | Counterexample → Pion | Reference behaviour |
|---|---|---|---|
| P2-1 | `p2_chunk_size_leading_zero_flood_segmentation_independent` | `"0"×5000 + "5\r\nhello\r\n0\r\n\r\n"`: fed **whole** it decodes `ok`; fed in 4096-byte **splits** it fails with `InvalidChunkExtension`. The fast path (`parse_chunk_size_with_limits` on `cur`) has no digit or line bound. The slow path (`read_crlf_line`, bounded at `max_chunk_ext_bytes+64`) has one. | Go `header line too long` / `http chunk length too large`; httparse `InvalidChunkSize`. Both are deterministic. The verdict must not depend on TCP segmentation. |
| P2-2 | `p2_chunk_size_more_than_16_hex_digits_rejected_like_go_and_httparse` | `00000000000000000005` (20 digits) is accepted. | Go and httparse reject more than 16 hex digits (diff rows `c_17_digits`, `c_20_digits`, `c_5000_zeros`). Pion is the odd one out in a proxy chain. |
| P2-3 | `p2_large_single_chunk_streamed_not_rejected` | An `80 MiB` single chunk (`5000000\r\n`) fails immediately with `ChunkTooLarge`, although `ChunkedDecoder` streams `Data` slices and never buffers a whole chunk. | Go and httparse stream it (diff `c_80mib`: PARTIAL vs Pion ERR). The 64 MiB `max_chunk_size` default buys no memory safety and breaks large downloads. Make it `Int64` max by default, or remove it. |
| P2-4 | `p2_rfc9110_2_5_higher_minor_version_processed_as_1_1` | `HTTP/1.2` gives `InvalidVersion`. | RFC 9110 §2.5 SHOULD process it as 1.1. Go accepts it. httparse rejects it, like Pion. |
| P2-5 | `p2_rfc9112_2_2_leading_crlf_before_request_line_ignored` | `\r\nGET / …` gives `InvalidMethod`. | RFC 9112 §2.2 SHOULD ignore at least one leading CRLF, which a client sends after a POST body. httparse skips leading empty lines; Go rejects them. |
| P2-6 | `p2_whatwg_sse_invalid_utf8_replaced_with_u_fffd` | `data: a\xFFb` gives raw `0xFF` in `SseEvent.data`. A truncated `F0 9F 8E` and an overlong `C0 AF` in `event:` also pass through. Pion `String` holds raw bytes, so events can carry invalid UTF-8. | WHATWG requires "UTF-8 decode" (U+FFFD replacement), which every browser `EventSource` does. Note: multi-byte characters split across `feed()` calls are **not** torn. `data: 你好🎉` dripped 1 byte at a time is identical to whole (control passes). |
| P2-7 | `p2_whatwg_sse_last_event_id_only_committed_on_dispatch` | Feed `id: 1 … data: a\n\n id: 2\ndata: b\n`, then the connection drops: `last_event_id()` returns `"2"`. | WHATWG dispatch step 1 commits the buffer to the source's last event ID **only on the blank line**, so a browser reconnects with `Last-Event-ID: 1`. Pion's reconnect would skip event 2, which was never delivered (message loss). Fix: keep a separate `id_buffer` and commit it at dispatch. |
| P2-8 | `p2_encode_final_chunk_rejects_framing_and_routing_trailers` | `encode_final_chunk([Content-Length: 1])`, and likewise `Transfer-Encoding`, `Host`, `Trailer`, are all `Ok`. | RFC 9110 §6.5.1. Go's `badTrailer` refuses these keys. |
| P2-9 | `p2_encoder_rejects_transfer_encoding_on_http10_request` | An HTTP/1.0 request with `TE: chunked` is encoded. Pion's own parser rejects it. | RFC 9112 §6.1 says a client MUST NOT send it. |
| P2-10 | `p2_encoder_rejects_or_trims_leading_trailing_whitespace_in_values` | `X-Sig: " v "` is emitted as `X-Sig:  v \r\n`. | RFC 9110 §5.5: a field value has no leading or trailing whitespace, and parsers strip it. The encoded and parsed values then differ (signature / canonicalisation mismatch). Go trims. |
| P2-11 | `p2_rfc9112_6_1_http10_response_with_te_is_faulty_framing` | `HTTP/1.0 200 OK` + `Transfer-Encoding: chunked` gives `Framing::Chunked` with no signal to close. Requests in the same situation are rejected. | RFC 9112 §6.1: treat as faulty framing and close. Go ignores TE on 1.0 and reads to close. |
| P2-12 | `probe hdr_drip`, bench `drip` | Sans-IO `parse_request` cannot resume. A slow client dripping a request one byte at a time makes a server that re-parses on every read do O(n²) work: about 1.2 s of CPU for 1000 headers / 24.8 KB (`hdr_drip 1000`), and 191 ms vs httparse 33 ms vs Go 15 ms for a 16 KiB value ×4 (bench below). Within the default 64 KiB `max_header_bytes`, that is roughly 0.8 s of CPU per malicious connection. | httparse has the same complexity class but is about 6× faster per rescan (SIMD). Go's bufio parser is linear. Fix: expose a resumable state (`parse_request_resume(buf, hint_pos)`), or document "only re-parse after `\r\n\r\n` is seen" and provide a cheap `find_header_end`. |

## Controls (expected PASS; attack surface probed and found sound)

`control_te_cl_obfuscation_matrix` covers 34 reject cases and 6 accept cases:
- VT/FF "whitespace" around CL/TE; NBSP and full-width digits in CL; space before the colon; NUL; bare CR/LF; obs-fold.
- CL+TE in both orders and mixed case; `identity`; `chunked` twice; `chunked, gzip`; duplicate CL (same value); `0x5`; `+5`.
- Request-line abuse: double SP, SP or CTL in the target, empty method, `HTTP/0.9`, `HTTP/2.0`, lowercase `http/`, trailing SP, HTAB separator, `(` in the method, bare LF.
- Accepted correctly: `\tchunked\t`, `gzip` + `chunked` on two lines, `CHUNKED`, `007`, trailing OWS, `Transfer_Encoding` (not a framing field).

The other controls:
- `control_header_block_limits_enforced_on_partial_input`: 70 KB value, method or URI with no CRLF yet; 101 headers. All are rejected before the message completes, so there is no OOM.
- `control_every_prefix_of_valid_request_is_partial`, for both request and response.
- `control_response_framing_basics`: response with TE but no `chunked` reads to close; `HTTP/1.1 200\r\n` and `HTTP/1.1 200 \r\n` are accepted; CL+TE, 2- and 4-digit status, and NUL in the reason are rejected.
- `control_encoder_injection_defenses`: illegal tchar in header names, CTL/DEL/VT/CRLF in values and trailers, SP/CRLF in path or method, CRLF in the reason, status 99.
- `control_chunked_overflow_and_syntax_matrix`, each case both whole and dripped:
  - `FFFFFFFFFFFFFFFF`, `10000000000000000` and `7FFF…` are rejected as overflow or limit.
  - `+5`, `-5`, `0x5`, a leading SP, bare LF after the size or the data, a wrong terminator, an unclosed quote, CR inside a quoted value, an empty ext name or value, an ext of 5000 bytes.
  - Trailers with obs-fold, bare LF, SP before the colon, or NUL; a final bare LF.
- `control_chunked_drip_and_random_split_equivalence`: splits of 1–7 bytes give the same result; quoted-pair extensions work; trailers work; the 22 pipelined bytes are preserved by `remaining_bytes()`.
- `control_chunked_100k_tiny_chunks_streaming_is_linear`: 100k feeds queued before draining.
- `control_whatwg_sse_field_semantics`: 15 vectors, each × 8 segmentations:
  - `data:` with two spaces strips one; `data` with no colon; empty data lines.
  - `event:` without data is not dispatched; `id`/`retry` without data are not dispatched.
  - Bare `id` clears the ID; `id` containing NUL is ignored; comments.
  - Field names are case-sensitive; CR, CRLF and LF mixed; BOM, and a double BOM (the second one is kept); CJK and emoji; an unterminated event is dropped.
- `control_whatwg_sse_retry_parsing`: `0`, `010`, `+10`, `10 `, `-1`, empty, `1e3`; side effects persist without data; overflow keeps the old value.
- `control_whatwg_sse_cross_chunk_bom_and_crlf`: `EF|BB|BF|…\r|\n|\r|\n`.
- `control_whatwg_sse_100k_line_event_linear`.

Probes (`run_audit.sh probe`):

| Probe | Result |
|---|---|
| `ChunkedDecoder.queue`, 100k feeds, producer 1 ahead | 7 ms, 1.9 MB RSS |
| `ChunkedDecoder.queue`, 100k feeds, producer 100k ahead | 7 ms, 3.2 MB RSS |
| `ChunkedDecoder.queue`, 1M feeds, producer 1M ahead | 74 ms, 16 MB RSS |
| 1-byte drip vs 64 KiB bulk, `ChunkedDecoder` (1 MiB body) | about 45 ns/B vs under 1 ns/B; 4.2 MB RSS |
| 1-byte drip vs 4 KiB bulk, `SseDecoder` | about 45 ns/B vs 3–4 ns/B; 4.2 MB RSS |

The queue compaction (`queue_head >= 16 && 2*head >= len`) holds, so there is **no RT-websocket-style 1.65 GB retention**: memory is proportional to unconsumed input only. Drip costs are linear.

## Differential summary (`run_audit.sh diff`; full table in `$AUDIT_OUT/diff.md`)

Pion disagrees with at least one reference on 56 of 101 cases. Grouped:

- **Defects** (counted above): `host_*` (P1-1), `r204_*` / `r304_cl` / `r100_te` / `r101_cl` (P1-2), `c_17_digits` / `c_20_digits` / `c_5000_zeros` (P2-1/2), `c_80mib` (P2-3), `ver_1_2` (P2-4), `leading_crlf` (P2-5), `r200_http10_te` (P2-11).
- **Pion stricter than one reference, and RFC-defensible** (not counted):
  - Duplicate identical `Content-Length` lines are rejected. Go merges them; RFC 9110 §8.6 allows either.
  - Response CL+TE is rejected. Go prefers TE; RFC 9112 §6.3 allows rejecting.
  - Bare LF line endings are rejected; RFC 9112 §2.2 MAY.
  - Chunk-ext syntax (`5;`, unclosed quote) is validated. Go and httparse ignore extensions.
  - UTF-8 in the request-target is rejected (RFC 3986), as is trailer obs-fold.
  - Everything httparse "accepts" in the CL/TE rows is only because httparse does no framing.
- **Pion more lenient than Go, and RFC-allowed** (not counted): `Transfer-Encoding: gzip, chunked` and `gzip` + `chunked` on separate lines are accepted as chunked (Go 501s anything but a single `chunked`). Callers then receive gzip bytes framed as chunked; document that the codings must be inspected. A `gzip`-only response reads to close; Go errors.

## Performance (`run_audit.sh bench`, `--warmup 1 --rounds 5`, strictly interleaved, stdout SHA-256 identical)

| Adversarial input | Pion median | httparse median | Go median | Pion vs httparse | Pion vs Go |
|---|---:|---:|---:|---:|---:|
| `req64`: 20k requests × 64 short headers, ×4 rounds | 404–502 ms | 103 ms | 556–653 ms | **0.21–0.25×** | 1.3× faster |
| `chunk1m`: 16 responses × 4 × 1 MiB chunks, ×16, streamed through `ChunkedDecoder` with 64 KiB feeds | 128 ms | 23 ms | 64–68 ms | **0.18×** | 0.5× |
| `sse_multiline`: 4000 events × 64 `data:` lines, 4 KiB feeds, ×2 | 144–155 ms | 112–122 ms (hand port) | 127–141 ms (hand port) | 0.78× | 0.88× |
| `drip`: 16 KiB header value re-parsed per byte, ×4 | 191–208 ms | 33 ms | 13–15 ms (bufio, linear) | **0.17×** | 0.07× |

Ranges come from two full runs on a shared, noisy machine.

Observations:
- With many headers, Pion falls from the README's 0.37× to 0.21–0.25× of httparse. It allocates two `String`s per header (`buf.slice(..).to_string()` for name and value) where httparse is zero-copy.
- `chunk1m` peak RSS is 130 MiB vs 66 MiB, and that is entirely the input read: `fs_read_bytes` alone peaks at 136 MB on the 64 MiB file. It is not `ChunkedDecoder`.

### Fairness review of the package's own `bench/` (README numbers reproduce within 2%)

1. **The SSE "references" are not upstream implementations.**
   - `bench/rust` and `bench/go` are line-for-line hand ports of Pion's own algorithm. They have no `retry`, no U+FFFD, and Rust does `from_utf8(..).unwrap()`, which panics on invalid input.
   - The table labels them `rust_sse` / `go_sse` without that caveat. "0.67× of Rust" measures Pion's codegen against the same algorithm, not against a real SSE library such as `eventsource-stream` or `r3labs/sse`.
2. **The `resp_chunked` bench never exercises `ChunkedDecoder`.**
   - The Pion and Rust sides call the stateless `parse_chunk_size` on one contiguous buffer. Go goes through the full streaming `ReadResponse` + body reader (bufio, copying into a 4 KiB buffer, trailer handling).
   - The README's "Pion beats Go 1.48×" is therefore Pion's stateless helper vs Go's full streaming stack. Measured like for like with `ChunkedDecoder` (`chunk1m` above), Pion is **0.5× Go**.
3. **The `req` bench compares different amounts of work against Go.** Go builds `url.URL`, canonicalises keys into a `map[string][]string` and moves Host. Pion builds `Array[Header]` of `String`s. "1.38× faster than Go" is real, but Go does strictly more.
4. **The inputs are benign only:**
   - 9 ASCII headers, no long values, 3 × ~70-byte chunks, single-line SSE `data:` and 4 KiB feeds;
   - none of the adversarial shapes above (many headers, MiB chunks, multi-line events, drips).
5. The Pion bench reads its input with `fs_read(..).to_bytes()` (String then copy), so its RSS includes about 2× the corpus. That favours no one in time, but the Peak RSS column is not comparable.
