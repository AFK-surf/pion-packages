# Red-team audit: `packages/http2` (Wave 10 · RT-http2)

- **Target**: `origin/feat/pkg-http2` @ `10811e1` (`src/{hpack,huffman,frame,headers,connection,types}.pion`), read-only.
- **References**: Go 1.27.3 `golang.org/x/net` **v0.62.0** (`http2.Framer`, `http2.Server`, `http2/hpack`) and
  Rust **h2 0.4.20** (its own `src/hpack` engine, vendored verbatim at build time, plus `h2::Codec` through the
  `unstable` feature). The shipped bench's `hpack-patched 0.3.0` and x/net v0.34.0 are re-measured for the fairness review.
- **Toolchain**: `pionc 0.1.0` (AFK-surf/pion@c375cee), go 1.27.3, cargo 1.100.0, node v24.22.2, Darwin arm64.
- **Reproduce everything**: `sh packages/http2/audit/run_audit.sh` (sub-steps: `build tests hpack frames conn wasm probe bench`).
  All artefacts go to `$AUDIT_OUT` (default `/private/tmp/rt-http2`); the worktree stays clean.

## Summary

| severity | findings | unit tests (FAIL while the defect exists) |
|---|---:|---:|
| **P0** remotely triggerable process abort | 1 (3 code paths) | 4 |
| **P1** protocol / smuggling / DoS / flow-control defects | 10 | 16 |
| **P2** strictness gaps, false positives, API defects | 12 | 12 |
| controls (correct today, must stay green) | — | 18 PASS |

`pionc test packages/http2/audit` → 50 audit tests: 32 FAIL (= evidence), 18 `control_*` PASS; the 20 upstream tests of
`packages/http2` still pass. Differential totals: **5,382 HPACK cases** (3-way), **3,119 single frames**, **27 connection
scenarios** against a live Go `http2.Server`; **4-mode** (native debug/release, wasm32 debug/release) outputs identical.

Headline: the frame codec and the HPACK/Huffman core are solid (0 value mismatches against Go in 5,382 + 3,119 cases,
every Huffman padding/EOS edge identical), but **one 5-byte HPACK block aborts the process**, the stream state machine
lacks most RFC 9113 §5.1 / §8.1 server-side checks Go and h2 perform, and the shipped benchmark's "12.13× faster than
Rust" comes from an abandoned Rust crate: against modern **h2** Pion is **0.74× (decode), 0.41× (encode), 0.84× (frame
engine)**.

---

## P0

### P0-1 HPACK index truncated to 32 bits → negative array index → process abort (DoS, 5-byte payload)

`src/hpack.pion:776-778` (indexed), `:820-822` (literal w/ incremental indexing, name index),
`:888-890` (without-indexing / never-indexed, name index):

```pion
let idx = idx64.to_int()          // Int64 -> 32-bit Int, silently wraps
if idx <= static_table_len {      // -1 <= 61
  let name = static_names[idx]    // index -1 -> pion panic, whole process dies
```

`hpack_decode_int` returns values up to 2^63, `idx64 <= 0` is checked only on the 64-bit value, the 32-bit result is not.
Index `0xFFFFFFFF` (→ -1) or `2^31` (→ -2^31) passes `idx <= 61`. Reachable from the network through `Connection::feed`
with a single `HEADERS` frame (`00 00 05 01 05 00 00 00 01 | ff 80 fe ff 0f`).

| evidence | result |
|---|---|
| `p0_hpack_indexed_index_2pow32_minus1_aborts`, `p0_hpack_literal_name_index_negative_aborts`, `p0_hpack_never_indexed_name_index_negative_aborts`, `p0_connection_feed_hpack_index_abort` | `pion panic: index -1 out of bounds (len 62)` |
| HPACK diff `int_*` family | 8 cases abort Pion; Go: `invalid indexed representation index N`; h2: `IntegerOverflow` |
| conn diff `hpack_index_2pow32_minus1_abort` | Pion aborts; Go server: `GOAWAY(COMPRESSION_ERROR)` |
| 4-mode | the same 9 inputs abort in native debug/release **and** wasm32 debug/release (`pion_panic_oob`) |

Fix: reject `idx64 > static_table_len + dyn_table.count` while still in `Int64` (before any narrowing), in all three paths.

---

## P1

### P1-1 HPACK index aliasing (2^32 + k decodes as index k)

Same root cause as P0-1 for indices whose low 32 bits are a valid index: `2^32+2` decodes as `:method: GET`,
`2^32+62` as the newest dynamic entry. A front-end/back-end pair where only one side is Pion sees **different header
lists for the same bytes** (header smuggling); Go and h2 reject. Tests `p1_hpack_index_2pow32_plus2_aliases_static`,
`p1_hpack_index_alias_dynamic_entry`; HPACK diff: 8 `int_idx_2^32+k` cases Pion=OK vs Go/h2=ERR; conn diff
`hpack_index_2pow32_plus2_alias`: Pion emits a GET request, Go `GOAWAY(COMPRESSION_ERROR)`.

### P1-2 Stream identifiers not validated (RFC 9113 §5.1.1)

`finish_header_block` (`connection.pion:216`) opens any idle id: no parity check (server accepts even client ids;
client accepts server-initiated ids without PUSH_PROMISE), no monotonicity (`HEADERS 5` then `HEADERS 3` opens 3 —
every id below `last_remote_stream_id` that was never used is re-openable). Go: `GOAWAY(PROTOCOL_ERROR)` for both
(server.go:1883 `id%2 != 1`, :1911 `id <= sc.maxClientStreamID`). Tests `p1_server_accepts_even_client_stream_id`,
`p1_server_accepts_decreasing_stream_id`; conn diff rows `even_client_stream_id`, `decreasing_stream_id`.

### P1-3 `max_concurrent_streams` never enforced; finished streams never freed (memory + CPU amplification)

`ConnectionConfig.max_concurrent_streams` (`types.pion:240`) is read nowhere. Streams are appended to `streams`
(`connection.pion:126`) and never removed; every `SETTINGS_INITIAL_WINDOW_SIZE` walks the whole array (`:394`).

| `probe streams <n> <settings>` (native release) | wall | peak RSS |
|---|---:|---:|
| 0 streams, 1,000 SETTINGS | 0.00 s | 1.9 MiB |
| 100,000 finished streams | 0.05 s | 9.1 MiB |
| 100,000 finished streams + 1,000 SETTINGS | 1.05 s | 9.1 MiB |
| 1,000,000 finished streams | 0.43 s | 71 MiB |
| 1,000,000 finished streams + 100 SETTINGS | 1.28 s | 71 MiB |

≈75 B retained per finished stream, unbounded per connection, and ~9 ms of CPU per 15-byte SETTINGS frame at 1 M
streams. Go deletes closed streams and refuses streams over the limit (conn diff `max_concurrent_6_of_4`: Go
`RST(9) RST(11)`, Pion accepts all 6). Test `p1_max_concurrent_streams_not_enforced`.

### P1-4 A second request on the same stream (RFC 9113 §8.1)

`is_trailer = headers_received && end_stream` (`connection.pion:194`): a second `HEADERS` *without* END_STREAM on an
open request stream is validated as a fresh request and emitted as a second `Headers` event (e.g. `/public` then
`/admin` on stream 1). Go: `RST_STREAM(1, PROTOCOL_ERROR)` (trailers must end the stream). Test
`p1_second_request_headers_on_same_stream`; conn diff `second_request_headers_same_stream`.

### P1-5 PUSH_PROMISE: accepted by servers, promised id never validated by clients

`receive_frame` (`connection.pion:318`) has no role check (RFC 9113 §8.4: a server MUST treat PUSH_PROMISE as connection
error) and `finish_header_block` overwrites the promised stream's state without checking it is idle/even/new: a server
can promise the id of a request the client already opened and flip it to `ReservedRemote`, hijacking the client's
own request stream. Tests `p1_server_accepts_push_promise`, `p1_push_promise_hijacks_open_client_stream`; conn diff
`push_promise_to_server` (Go `GOAWAY(PROTOCOL_ERROR)`).

### P1-6 Stream lookup shortcut loses live streams

`find_stream_idx` (`connection.pion:83-98`) assumes the array is sorted by id when its last two entries are, and then
scans only the last 4 entries. Client: open 1 and 15, receive 4 pushes (2,4,6,8) → stream 15 is reported `Idle`,
`send_data(15)` fails, and a response `HEADERS` on 15 would create a *duplicate* entry. With 3 pushes it still works.
Test `p1_stream_lookup_loses_client_stream_after_pushes`.

### P1-7 Padding excluded from flow control (RFC 9113 §6.9.1)

`decode_frame` strips padding and `receive_frame` charges `data.length()` (`connection.pion:350`). RFC: "the entire DATA
frame payload is included in flow control, including the Pad Length and Padding fields". Consequences: (a) a peer may
send unlimited padding-only DATA without credit (300 × 256-byte padded frames = 76,800 B accepted on a 65,535 window);
(b) the peer's and Pion's window views diverge by every padding byte, so an application that refunds delivered bytes
leaks the peer's window until it stalls. Go charges `f.Length` and immediately refunds the padding with WINDOW_UPDATE.
Tests `p1_padded_data_bypasses_flow_control_accounting` (window drops by 10 instead of 111),
`p1_padding_only_data_exceeds_window_without_error`.

### P1-8 Receive windows can never be replenished (64 KiB per connection, lifetime)

There is no API to credit `conn_recv_win` / `recv_window` (no `send_window_update`/`release_capacity`), so after 65,535
bytes the connection rejects all further DATA with FLOW_CONTROL_ERROR even if the application has written WINDOW_UPDATE
frames. Go adds to `inflow` when it sends WINDOW_UPDATE; h2 has `FlowControl::release_capacity`. The shipped
`frame_stream` bench corpus stays under this limit (~16 KiB DATA per round). Test `p1_recv_window_can_never_be_replenished`.

### P1-9 `content-length` not enforced (RFC 9113 §8.1.1)

No content-length tracking at all: `content-length: 5` with 23 DATA bytes, two different values (`5` and `50`), and
`5, 6` are all accepted. On an HTTP/2 → HTTP/1.1 hop this is the classic CL desync. Go `RST_STREAM(PROTOCOL_ERROR)`
(server.go:1761 `declBodyBytes`). Tests `p1_content_length_mismatch_accepted`, `p1_conflicting_content_length_accepted`,
`p1_non_numeric_content_length_accepted`; conn diff `content_length_mismatch`, `conflicting_content_length`.

### P1-10 `:path` not validated (RFC 9113 §8.3.1)

`validate_request_headers` only rejects an empty `:path` (`headers.pion:124`). `foo`, `?q=1`, `http://evil.example/x` and
`//evil.example/x` are accepted and handed to the application as request targets (absolute-form / authority confusion
when forwarded). Go `validPseudoPath` → `RST_STREAM(PROTOCOL_ERROR)`. Test `p1_non_origin_form_path_accepted`; conn diff
`path_not_origin_form`, `path_relative`.

---

## P2

| id | finding | where | reference behaviour | test |
|---|---|---|---|---|
| P2-1 | CTL bytes 0x01-0x08, 0x0B-0x1F, 0x7F accepted in field values (only NUL/CR/LF rejected) | `headers.pion:57-62` | Go `httpguts.ValidHeaderFieldValue` and h2 `HeaderValue` reject → `RST(PROTOCOL_ERROR)` | `p2_header_value_ctl_bytes_accepted` |
| P2-2 | leading/trailing SP/HTAB in values accepted (RFC 9113 §8.2.1 "MUST NOT") | `headers.pion:57` | Go and h2 equally lenient: strict-RFC gap, not a regression | `p2_header_value_leading_trailing_whitespace_accepted` |
| P2-3 | `:protocol` accepted on non-CONNECT requests (RFC 8441 §4) | `headers.pion:132,156` | Go `RST(PROTOCOL_ERROR)` | `p2_protocol_pseudo_header_on_get_accepted` |
| P2-4 | `:path: *` accepted for GET (asterisk-form is OPTIONS-only) | `headers.pion:124` | Go also accepts: strict-RFC gap | `p2_asterisk_path_for_get_accepted` |
| P2-5 | rapid-reset counter is lifetime-cumulative and counts every RST_STREAM: 150 *sequential* request+cancel exchanges (concurrency 1) kill the connection with ENHANCE_YOUR_CALM | `connection.pion:370` | Go serves all 150 (conn diff `sequential_cancel_x150`); h2 counts only resets of not-yet-accepted streams | `p2_rapid_reset_counter_never_decays_false_positive` |
| P2-6 | connection receive window initialised from `initial_window_size` (`conn_recv_win: init_win`) instead of the fixed 65,535: with 16,384, 4 legal streams × 16,383 B fail | `connection.pion:49` | RFC 9113 §6.9.2 | `p2_conn_window_initialised_from_stream_setting` |
| P2-7 | `HpackDecoder::set_max_table_size` evicts immediately; blocks the peer encoded before seeing SETTINGS fail with COMPRESSION_ERROR | `hpack.pion:672-679` | Go `SetAllowedMaxDynamicTableSize` only caps the next size update (RFC 7541 §4.2) | `p2_decoder_set_max_table_size_evicts_before_size_update` |
| P2-8 | `feed()` returns `Err` and drops the events of frames it already applied (state mutated, events lost) | `connection.pion:465-470` | — (API) | `p2_feed_error_discards_applied_events` |
| P2-9 | a malformed request is connection-fatal: `H2Error` carries no stream id, so callers cannot send RST_STREAM for that stream only | `types.pion` / `connection.pion:200-210` | Go: `RST(3)` and stream 1 still served (conn diff `malformed_stream3_keeps_stream1`) | `p2_malformed_request_is_connection_fatal` |
| P2-10 | GOAWAY is recorded nowhere: `open_stream` still succeeds after `GOAWAY(last_stream_id=0)` (RFC 9113 §6.8) | `connection.pion:442` | — | `p2_open_stream_after_goaway_allowed` |
| P2-11 | client accepts `SETTINGS_ENABLE_PUSH=1` from a server (RFC 9113 §6.5.2 MUST PROTOCOL_ERROR) | `frame.pion:245` | — | `p2_client_accepts_enable_push_1_from_server` |
| P2-12 | `SETTINGS_ENABLE_CONNECT_PROTOCOL` (0x8) value 2 accepted (RFC 8441 §3) | `frame.pion:245` | Go `GOAWAY(PROTOCOL_ERROR)` (frame diff `settings_ecp_2`, conn diff) | `p2_settings_enable_connect_protocol_2_accepted` |

Withdrawn during verification (not defects): Huffman string budget checked on the encoded length
(`hpack.pion:737`) — Go applies the same bound (`hpack.go:487`); Bytes→String loss of obs-text — Pion strings are byte
strings, entry sizes stay in sync (`control_obs_text_byte_exact_and_size_sync`); encoder scratch-buffer aliasing —
`Bytes::slice` copies (`control_encoder_output_not_aliased`).

---

## Controls (Pion correct; several equal to or stronger than the references)

| control | what it shows |
|---|---|
| `control_hpack_compression_bomb_cut_off_in_flight` | 4 KB entry × 10,000 refs (10 KB block → 40 MB) rejected after the 17th reference, in-flight, no allocation of the expansion. Go answers 431 + RST. |
| `control_continuation_zero_length_flood` | 10,000 zero-length CONTINUATIONs → ENHANCE_YOUR_CALM after 8. **Pion stronger**: Go's server reads them all without error (conn diff `ctl_continuation_flood_zero_len`). |
| `control_huffman_padding_and_eos` + HPACK diff `huff_*`/`hpad_*` | all 256 symbols, 1-7 bit all-1 padding accepted; non-1 padding, ≥8 bit padding, explicit EOS at every bit offset, truncated 28/30-bit codes rejected — **318/318 identical to Go**; h2 agrees except where it refuses the decoded CTL byte as a header value (HTTP semantics, not HPACK). |
| `control_hpack_index_zero_rejected`, `control_hpack_index_out_of_range_rejected` | index 0 and 61+len+1 rejected |
| `control_hpack_size_update_rules` | size update after a field / above SETTINGS rejected; `0` then `4096` evicts (index 62 invalid afterwards) |
| `control_hpack_integer_overflow_rejected` | 2^84 and endless `0x80` continuations rejected (no OOM, no hang) |
| `control_sensitive_never_indexed` | sensitive fields emitted as `0001xxxx`, never enter either dynamic table; flag survives decode |
| `control_dynamic_table_hash_collision_safe` | two values with identical 31-bit `str_hash` (`v-i6pf`/`v-uIta`, `diff/fnv_collide.py`) stay distinct: the hash is only a prefilter before a full compare, and the table is a ≤128-entry linear ring, so HashDoS has nothing to degrade |
| `control_settings_unknown_duplicates_negative_window` | unknown ids ignored, duplicates applied in order, INITIAL_WINDOW_SIZE drives a send window to −59,000 (legal), WINDOW_UPDATE past 2^31−1 → FLOW_CONTROL_ERROR |
| `control_settings_initial_window_too_large` | INITIAL_WINDOW_SIZE > 2^31−1 → FLOW_CONTROL_ERROR |
| `control_header_block_interleaving` | PING / DATA / other-stream CONTINUATION inside a header block and orphan CONTINUATION rejected |
| `control_frame_padding_priority_bounds` | pad_len ≥ len, PADDED with empty payload, PRIORITY < 5, PADDED+PRIORITY overflow, > MAX_FRAME_SIZE rejected |
| `control_idle_and_closed_stream_frames` | DATA/RST_STREAM/WINDOW_UPDATE on idle, DATA/HEADERS on half-closed(remote) rejected |
| `control_pseudo_header_rules` | `:status` in requests, `:method` in responses, CONNECT rules (§8.5), empty `:path`, pseudo in trailers, bad names, `te: trailers, chunked` rejected |
| `control_obs_text_byte_exact_and_size_sync`, `control_encoder_output_not_aliased` | see "withdrawn" above |
| `control_drip_feed_equals_bulk` + `probe drip 60` | 1-byte drip with caller-kept tail == bulk (61/61 events, 0 leftover); `feed` keeps no internal receive buffer, so there is nothing to leak or compact |

Also better than Go: oversize frames are reported as `FRAME_SIZE_ERROR` (RFC 9113 §4.2) where Go's server sends
`PROTOCOL_ERROR`; Pion rejects self-dependent PRIORITY/HEADERS and PUSH_PROMISE with promised id 0 at frame level.

---

## Differential evidence

### HPACK: 5,382 cases, Pion vs Go x/net v0.62.0 `hpack` vs Rust h2 0.4.20 `hpack`

Corpus (`diff/gen_hpack_corpus.py`, seed fixed): 3,000 random legal multi-block cases from an independent Python
encoder (all representations, Huffman on/off, eviction, size updates, overlong-but-legal integers), 2,000 mutations,
257 Huffman symbol cases, 61 padding/EOS cases, 46 integer edge cases, 10 size-update attacks.

| class | cases |
|---|---:|
| Pion == Go (byte-identical header lists or both error) | **5,069** |
| Pion aborts (P0-1) | 8 |
| Pion accepts, Go rejects | 291 |
| Pion rejects, Go accepts | 14 |
| both OK, different headers | **0** |

Every divergence is explained by a root-cause cluster (`reports/hpack_diff.md`):

| cases | cause | verdict |
|---:|---|---|
| 272 | Go rejects a *second* dynamic table size update in one block when the table is non-empty (`hpack.go:414`, `!firstField && size > 0`); RFC 7541 §4.2 explicitly allows "smallest, then final". h2 agrees with Pion whenever h2 has no unrelated semantic objection (119 cases P=H≠G) | Go non-RFC; Pion correct |
| 11 | Go *accepts* a size update after a field when the table happens to be empty; Pion and h2 reject (RFC 7541 §4.2: must be at block start) | Go lax; Pion correct |
| 8 + 8 | index ≥ 2^31: abort (P0-1) / alias (P1-1) | **Pion defect** |
| 11 + 3 | both reject, but in different blocks, because of the two size-update rules above | follows from the rows above |

Pion == Go but h2 differs (1,714): all are h2 fusing HTTP semantics into HPACK (`InvalidStatusCode` 1,275,
`InvalidUtf8` in pseudo-headers 439) — not HPACK disagreements. (h2 also does not report the never-indexed flag on
decode; it is ignored for the 3-way comparison.)

### Frames: 3,119 single frames, Pion `decode_frame` vs Go `Framer.ReadFrame` (+ `Setting.Valid`)

3,007 identical (type, stream id, flags, payload after padding, settings list); 0 value mismatches. Divergences:
66 orphan CONTINUATION (Go's Framer enforces frame order; Pion leaves it to `Connection`, which rejects — control),
19 + 4 self-dependency and 17 promised-id-0 (Pion rejects at frame level; RFC-correct), 6 `ENABLE_CONNECT_PROTOCOL=2`
(P2-12).

### Connection: 27 scenarios vs a live Go `http2.Server` (MaxConcurrentStreams = 4)

`conn/gen_scenarios.py` → same bytes to Pion `Connection::feed` and to Go over `net.Pipe` (chunks 20 ms apart).

| scenario | Pion | Go x/net/http2 Server |
|---|---|---|
| even_client_stream_id | ACCEPTED (HEADERS 2) | GOAWAY(PROTOCOL_ERROR) |
| decreasing_stream_id | ACCEPTED (5 then 3) | GOAWAY(PROTOCOL_ERROR) |
| max_concurrent_6_of_4 | ACCEPTED 6 streams | RST(9) RST(11) PROTOCOL_ERROR |
| second_request_headers_same_stream | ACCEPTED 2 requests on stream 1 | RST(1:PROTOCOL_ERROR) |
| push_promise_to_server | ACCEPTED (PUSH 2) | GOAWAY(PROTOCOL_ERROR) |
| content_length_mismatch / conflicting_content_length | ACCEPTED | RST(1:PROTOCOL_ERROR) |
| path_not_origin_form / path_relative | ACCEPTED | RST(1:PROTOCOL_ERROR) |
| ctl_byte_in_value / del_byte_in_value | ACCEPTED | RST(1:PROTOCOL_ERROR) |
| protocol_on_get | ACCEPTED | RST(1:PROTOCOL_ERROR) |
| settings_enable_connect_protocol_2 | ACCEPTED | GOAWAY(PROTOCOL_ERROR) |
| hpack_index_2pow32_plus2_alias | ACCEPTED (aliased GET) | GOAWAY(COMPRESSION_ERROR) |
| hpack_index_2pow32_minus1_abort | **process abort** | GOAWAY(COMPRESSION_ERROR) |
| malformed_stream3_keeps_stream1 | CONN_ERROR (whole connection) | RST(3) + 200 on stream 1 |
| sequential_cancel_x150 | CONN_ERROR ENHANCE_YOUR_CALM | serves all |
| path_asterisk_get / leading_space_value / padding_only_data_76800B / settings_unknown_id_ignored | ACCEPTED | ACCEPTED (Go refunds padding at once) |
| ctl_continuation_flood_zero_len | ENHANCE_YOUR_CALM | accepted (Pion stronger) |
| ctl_hpack_bomb_4k_x10000 | ENHANCE_YOUR_CALM | 431 + RST |
| ctl_data_on_idle_stream / ctl_ping_inside_header_block / ctl_conn_window_overflow / ctl_oversize_frame | CONN_ERROR (correct codes) | GOAWAY |

### 4-mode Wasm32 consistency

`diff/four_modes.py`: the probe built as native debug, native release, wasm32 debug, wasm32 release (node) over all
three corpora (8,528 cases) — per-case output SHA-256 identical in all four modes (hpack `7d743527…`, frames
`cb5d32d5…`, conn `9b16d352…`), and the **same 9 inputs abort in every mode** (native `pion panic`, wasm32
`pion_panic_oob`). So: 0 behavioural differences, but not "0 traps" — the 9 traps are P0-1.
(Harness note: an aborting node process can lose buffered stdout under heavy load; `compare.run_pion` therefore
re-runs the suspected case alone before recording an abort.)

---

## Benchmark fairness and real performance

### Problems in `packages/http2/bench/` and the README/BENCHMARKS claims

1. **Rust baseline is not modern Rust HTTP/2.** `hpack-patched 0.3.0` (bit-by-bit Huffman tree) is **19×** slower than
   h2 0.4.20's HPACK on the same corpus (2,557 ms vs 133 ms). The "Pion 12.13× / 7.04× faster than Rust" headlines are
   artefacts of that choice. Against h2, Pion is **0.74×** in decode.
2. **Bench 2 mixes Huffman modes**: hpack-patched never Huffman-codes while Pion does. Split now into B2 (Huffman on:
   Pion vs Go vs h2) and B3 (off: Pion vs hpack-patched).
3. **Bench 3's Rust side is not a frame engine**: a hand-rolled loop (no padding/priority parsing, no validation,
   `unwrap`) + hpack-patched. B4 uses `h2::Codec` (frame parsing, CONTINUATION, HPACK, field validation).
4. **Go pinned to x/net v0.34.0**; v0.62.0 is ~11 % faster in decode (160 vs 180 ms).
5. **Pion bench hashes each field via `to_bytes()` copies**, inflating Pion's decode time by ~14 % (206 → 178 ms with
   in-place hashing; same checksum).
6. **"~7.5× less RSS than Go"** is the Go runtime baseline (~14-17 MiB for any Go program), not HPACK; h2 uses the
   same 2.2 MiB as Pion.
7. **The frame corpus fits under P1-8**: ~16 KiB DATA per round; a corpus with > 64 KiB DATA per connection cannot run
   on Pion at all.

### Re-measured (scripts/bench_compare.py, 5 interleaved rounds + warmup, SHA-256-identical stdout, Darwin arm64)

Same corpora as `packages/http2/bench/gen_corpus.py`. The machine was shared (load average 22-60), so absolute numbers
are noisy; ratios were stable across two full runs (±5 %).

| bench | Pion | Go x/net v0.62.0 | Rust h2 0.4.20 | other |
|---|---:|---:|---:|---|
| B1 HPACK decode, 100k blocks (median ms) | 178.1 (0.74×) | 159.6 (0.83×) | **132.6 (1.00×)** | hpack-patched 2,556.8 (0.05×); shipped Pion bench 206.2; Go v0.34 179.8 |
| B2 HPACK encode, Huffman on | 119.6 (0.41×) | 70.1 (0.70×) | **49.1 (1.00×)** | shipped Pion bench 122.7 |
| B3 HPACK encode, Huffman off | 127.2 (0.56×) | — (no switch) | — (always Huffman) | **hpack-patched 70.9 (1.00×)** |
| B4 frame engine, 200k frames (deframe + CONTINUATION + HPACK) | 104.9 codec (0.84×) / 132.2 with `Connection` (0.67×) | 107.1 Framer+MetaHeaders (0.82×) | **88.2 Codec (1.00×)** | — |
| peak RSS | 2.2-3.6 MiB | 13.9-17.2 MiB | 2.2-5.3 MiB | — |

Pion leads nothing but is level with Go on the frame engine (0.84× vs 0.82×) and within 1.1× of Go in decode.

### Where the time goes (optimisation space)

- **Encode (2.4× behind h2)**: Huffman is not the bottleneck (Huffman off is *not* faster: 127 vs 120 ms). Per field the
  encoder runs `static_table_find` string compares, two full `str_hash` passes, a linear `find_hashed` scan of the whole
  dynamic table, and copies name and value with `to_bytes()` (`hpack.pion` `HpackEncoder::encode`). Go keeps
  `map[string]` / `map[pairNameValue]` indices, h2 a Robin-Hood hash index; an open-addressing index keyed by the
  already computed hash, and hashing/copying each string once, is the main lever.
- **Decode (1.34× behind h2)**: each literal string is copied up to three times (`data.slice` copy → Huffman into a
  `max_out` buffer → `slice(0, opos)` copy → `to_string()`); h2 decodes into one reusable `BytesMut`.
- **Frames**: `decode_frame` copies every payload with `Bytes::slice` (DATA bodies included), `pending_buf.to_bytes()`
  copies the reassembled block again, and the `Connection` layer adds ~26 % (linear stream array, per-HEADERS
  validation).

---

## Reproduction

```sh
sh packages/http2/audit/run_audit.sh            # everything (a few minutes), reports in /private/tmp/rt-http2/reports
sh packages/http2/audit/run_audit.sh tests      # 50 audit unit tests (32 FAIL = findings, 18 control PASS)
sh packages/http2/audit/run_audit.sh hpack      # 3-way HPACK differential (+ root-cause clusters)
sh packages/http2/audit/run_audit.sh frames     # frame differential vs Go Framer
sh packages/http2/audit/run_audit.sh conn       # 27 scenarios vs live Go http2.Server
sh packages/http2/audit/run_audit.sh wasm       # 4-mode consistency
sh packages/http2/audit/run_audit.sh probe      # stream-table memory/CPU, drip feed
sh packages/http2/audit/run_audit.sh bench      # B1-B4 (BENCH_ROUNDS=7 default)
```

| path | content |
|---|---|
| `pion.toml`, `redteam_test.pion` | audit package: p0_/p1_/p2_ (FAIL) and control_ (PASS) tests |
| `probe/` | Pion probe: `hpack`, `frames`, `conn` differential output, `streams`, `drip` |
| `diff/gen_hpack_corpus.py`, `diff/gen_frame_corpus.py`, `diff/compare.py`, `diff/four_modes.py`, `diff/fnv_collide.py` | corpora, 3-way comparison with abort isolation and root-cause clustering, 4-mode check |
| `diff/go/` | Go x/net v0.62.0 HPACK/frame runner |
| `diff/rust/` (+ `vendor_h2_hpack.sh`) | h2 0.4.20 HPACK runner and HPACK bench (h2's private `src/hpack` copied at build time into `$AUDIT_OUT`) |
| `conn/gen_scenarios.py`, `conn/go/`, `conn/compare_conn.py` | connection scenarios, live Go `http2.Server` harness, side-by-side table |
| `bench/pion_fair/`, `bench/go/`, `bench/rust_h2codec/` | fair benches (identical corpora, rounds and checksums) |
