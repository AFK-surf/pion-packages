# Red-Team Audit: `packages/websocket` vs `coder/websocket` and `tungstenite`

Target: `AFK-surf/pion-packages` `origin/main` `7a40e8f`, `packages/websocket` (unchanged by this audit).
References: Rust `tungstenite` **0.26.2** (`--release`, LTO) and Go `coder/websocket` **v1.8.14** (Go 1.27.3, arm64 NEON mask asm).
Platform: Darwin arm64 (Apple M5 Max, 18 cores), `pionc 0.1.0`. **The host was busy during the run (load average 46–50).** Timings are therefore noisy, but each benchmark interleaves all three implementations, and the gaps reported below (10–30×) are far larger than the noise.

Reproduce everything:

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
sh packages/websocket/audit/run_audit.sh            # all targets
sh packages/websocket/audit/run_audit.sh tests      # or: diff | handshake | probe | fuzz | bench
pionc test --json -p websocket_redteam_audit packages/websocket/audit
```

Artefacts go to `$AUDIT_OUT` (default `$TMPDIR/pion-ws-audit`). The git tree stays clean.

## Verdict summary

| # | Sev | Finding | Pion | tungstenite | coder/websocket | Evidence |
|---|---|---|---|---|---|---|
| 1 | **P0** | Chunk queue is never compacted when the producer feeds ahead of the drain, so memory grows without bound | **1.65 GB RSS** for 20 000 × 64 KiB frames, while `buffered_len` = 131 KB | bounded (owns its read buffer) | bounded | `run_audit.sh probe` |
| 2 | **P0** | 32-bit `frame_total` overflow causes a remote panic (process abort) from 30 wire bytes when `max_message_size` ≥ `Int max − 14` | `index 14 out of bounds` → abort | n/a (usize) | n/a (int64) | `p0_*` tests, `probe overflow_len64` |
| 3 | **P1** | Large-frame throughput is 10–30× behind both references. The README's "0.58× / beats Go" holds only for its own mixed small-frame workload | 317–530 MB/s | up to 10 GB/s | 4–7.6 GB/s | `run_audit.sh bench` |
| 4 | **P1** | UTF-8 does not fail fast (Autobahn 6.4.x strict). An invalid first fragment is buffered up to `max_message_size` until FIN | waits (END) | ERR 1007 at once | does not validate at all (excludes `6.*`) | 6 `p1_utf8_*` tests, diff |
| 5 | **P1** | CRLF header injection / response splitting in `build_client_handshake` (host, path, subprotocol) and `build_server_handshake` (protocol) | injected verbatim | `http::HeaderValue` rejects | `net/http` rejects | 3 `p1_build_*` tests, `builder_crlf_subprotocol` |
| 6 | P2 | No close state machine: data frames and a second Close are delivered after Close | `C1000 T5 …` | `C1000 END` | `C1000 END` | `p2_no_data_delivered_after_close`, `p2_second_close_not_delivered` |
| 7 | P2 | Header parsing is laxer than both references: duplicate `Sec-WebSocket-Accept` (last wins), duplicate `Sec-WebSocket-Key`, control characters in values, whitespace before the colon | accepts | rejects (3 of 4) | rejects (3 of 4) | `p2_parse_*`, `p2_verify_*`, handshake diff |
| 8 | P2 | An unrequested `Sec-WebSocket-Extensions` in the 101 response is accepted (RFC 6455 §4.1 rule 5 MUST fail) | accepts | accepts | rejects | `p2_verify_server_handshake_rejects_unoffered_extension` |
| 9 | GAP | No permessage-deflate (RFC 7692; Autobahn §12/§13 = 216 cases) and no extension API | none | none | yes | `gap_rfc7692_permessage_deflate_hello` |
| 10 | GAP | API surface is a decoder only: no streaming reader for large messages, no fragmenting writer, no close/ping state machine, no 426 Upgrade-Required builder | — | full `WebSocket` | full `Conn` | source review |

`pionc test --json -p websocket_redteam_audit packages/websocket/audit` gives **23 tests, 19 FAIL, 4 PASS**. Every FAIL is evidence. The four PASS tests are the negative controls (`control_*`), which mark surfaces that were attacked and held up.

---

## P0-1 Unbounded memory: `Decoder.queue` is never cleared

`src/decoder.pion` `Decoder::advance_chunk` clears `queue` only when `queue_head == queue.length()`, which means only when the drain has caught up with the very last fed chunk. Consider a normal network loop where the socket delivers data faster than the application drains it: two or more whole frames are always queued ahead. In that case `queue_head` stays at `len − 2` forever. Every consumed chunk then stays referenced by `queue` and is never freed. `coalesce()` would clear the queue, but it runs only when a frame straddles a chunk boundary, and frame-aligned chunks never trigger it. As a result, `buffered_len()` looks small while RSS grows linearly with connection lifetime.

```text
$ probe_pion queue_drain 20000        # drain after each feed
queue_drain: rounds=20000 msgs=20000 buffered_len=0
             2048000  maximum resident set size        (2.0 MB)
$ probe_pion queue_retention 20000    # producer two 64 KiB frames ahead
queue_retention: rounds=20000 msgs=20000 buffered_len=131100
          1648082944  maximum resident set size        (1.65 GB)
```

Both runs process the same bytes and messages. The only difference is the feed/drain interleaving. Any long-lived connection hits this, and so does any attacker who sends frames faster than the server handles them. tungstenite and coder/websocket own a bounded read buffer, so this failure mode cannot happen in either. This also contradicts the README's claim of an "amortized O(1) compacting byte buffer".

Repro: `sh packages/websocket/audit/run_audit.sh probe` (source: `audit/probe/src/main.pion`).

## P0-2 Remote panic: `frame_total = mask_end + payload_len` overflows `Int` (32-bit)

`Int` is 32-bit and wraps; the test `probe_int_width` confirmed `2147483647 + 14 < 0`. With `max_message_size = 2147483647`, the "unlimited" setting a user is likely to choose, a 64-bit length header for `0x7FFFFFF8` passes the `len64 > max` check. `frame_total` then wraps negative, and `pending_total < frame_total` becomes false. The decoder proceeds to unmask 2 GiB out of a 30-byte buffer and aborts:

```text
$ probe_pion overflow_len64
pion panic: index 14 out of bounds (len 14)        exit 134 (SIGABRT)
```

The same happens in the client role (`10 + 0x7FFFFFFD`). The bounds check prevents memory corruption, but one unauthenticated 30-byte message still kills the process. Any `max_message_size ≥ 2147483634` is exploitable. Tests: `p0_int_max_limit_len64_overflow_must_not_panic_server` / `_client`.

## P1-3 Throughput: large frames are 10–30× slower than both references

The workload is masked client→server binary or text frames read from disk, fed 64 KiB at a time (one socket read) and fully drained. Pion is driven through `Decoder::feed` + `next_message`, tungstenite through `WebSocket::read` on a chunked `Read`, and coder/websocket through `Conn.Read` on a chunked `net.Conn`. coder/websocket does not validate UTF-8, so `utf8.Valid` is applied to its text messages to match the RFC 6455 §8.1 behaviour that the other two have. The stdout SHA-256 was identical across all implementations and rounds for every workload. Settings: `--warmup 1 --rounds 5`, strictly interleaved.

| Workload (bytes processed) | Pion MB/s | tungstenite MB/s | coder MB/s | Pion vs Rust | Pion vs Go |
|---|---:|---:|---:|---:|---:|
| `big_64k` 64 KiB × 16 384 (1.07 GB) | **317** | 10 026 | 4 091 | **0.03×** | **0.08×** |
| `big_1m` 1 MiB × 1 024 (1.07 GB) | **513** | 5 782 | 6 761 | **0.09×** | **0.08×** |
| `big_16m` 16 MiB × 64 (1.07 GB) | 530 | 339 ¹ | 7 590 | 1.56× | **0.07×** |
| `text_1m` UTF-8 1 MiB × 1 024 (1.07 GB) | **279** | 1 242 | 1 664 | **0.22×** | **0.17×** |
| `big_1m_c4k` 1 MiB, 4 KiB reads (537 MB) | 822 | 461 ¹ | 4 932 | 1.78× | **0.17×** |
| `frag_storm` 1 000 msgs × 10 000 × 10 B fragments (160 MB) | 311 | 721 | 50 | 0.43× | 6.2× |
| `tiny_1m` 5 M × 16 B frames (110 MB) | 257 (85.5 ns/op) | 869 (25.3 ns/op) | 42 (528 ns/op) | 0.30× | 6.2× |
| `drip_20k` 1-byte reads, 100 k frames (2.2 MB) | 20.7 | 0.99 ¹ | 24.2 | 21× | 0.86× |

¹ tungstenite slows down badly when a single frame is much larger than its read chunk (16 MiB with 64 KiB reads, 1 MiB with 4 KiB reads, 1-byte reads). This is a tungstenite weakness, and Pion wins those rows.

What this shows:
- The README's headline ("surpassing Go `coder/websocket`, 0.58× Rust") comes from one mixed workload of 1–2.5 KB frames. As soon as frames reach 64 KiB, Go's NEON `mask_arm64.s` and Rust's word-wise unmask beat Pion by 12–31×. Pion is stuck at roughly 300–500 MB/s, the per-byte `ldrb`/`eor`/`strb` loop that the README itself identifies as about 13 instructions per byte.
- `big_64k` is slower than `big_1m` because each 65 550-byte frame straddles a 64 KiB read. `coalesce()` therefore copies the frame once more before unmasking, which adds a second full copy per frame.
- Where Pion wins: tiny frames and fragment storms, where per-message overhead dominates (Pion beats Go by 6×, and reassembly shows no O(N²)), and tungstenite's large-frame/small-read pathology.
- Peak RSS: Pion's large-frame runs peak at 258 MiB against tungstenite's 130 MiB for the same 134 MB input file. The decoder alone stays bounded (`queue_drain`: 2 MB), so the extra 124 MiB comes from the runner's `fs_read_bytes` / `slice` path. It is reported but not attributed to `packages/websocket`.

Raw tables: `$AUDIT_OUT/bench_*.md` / `.json`.

## P1-4 UTF-8 is not fail-fast (Autobahn 6.4.1–6.4.4 "strict")

`next_message` validates fragmented text only after the FIN continuation arrives (`validate_utf8(full)` in the `fin` branch). tungstenite validates each fragment incrementally and fails with 1007 at once. Differential results (chunk sizes whole, 1 and 3 give the same result):

| case | Pion | tungstenite | coder/websocket |
|---|---|---|---|
| `utf8_6_4_1_failfast_no_final` (κόσμε \| F4 90 80 80 \| …) | `END` (waiting) | `ERR1007` | `END` (no validation) |
| `utf8_6_4_2_failfast_no_final` | `END` | `ERR1007` | `END` |
| `utf8_firstfrag_ff_no_final` (`abc FF`) | `END` | `ERR1007` | `END` |
| `utf8_firstfrag_overlong_no_final` (`C0 80`) | `END` | `ERR1007` | `END` |
| `utf8_firstfrag_surrogate_no_final` (`ED A0 80`) | `END` | `ERR1007` | `END` |
| `utf8_firstfrag_bad_prefix_no_final` (`61 F4 90`) | `END` | `ERR1007` | `END` |

The impact goes beyond Autobahn's "NON-STRICT" grade. An attacker can open a text message with one invalid byte and make the server buffer up to `max_message_size` (and spend that much CPU on reassembly and validation) of data already known to be garbage, on every connection. The test `p1_utf8_failfast_bounds_garbage_buffering` shows 1000 fragments accepted after a leading `0xFF`.

coder/websocket deliberately skips UTF-8 entirely (`autobahn_test.go`: `excludedAutobahnCases = {"6.*", "7.5.1", …}`), so on UTF-8 Pion is stricter than Go and weaker than Rust.

## P1-5 CRLF injection in the handshake builders

`build_client_handshake(host, path, key, protocols)` and `build_server_handshake(key, protocol)` concatenate their arguments into the header block without validation:

```text
build_client_handshake("example.com\r\nCookie: stolen=1", "/ws", key, [])   -> injected Cookie header
build_client_handshake("example.com", "/ws HTTP/1.1\r\nX-Evil: 1\r\nX-Pad:", key, [])
build_client_handshake(..., ["chat\r\nX-Evil: 1"])                          -> injected X-Evil header
build_server_handshake(key, Some("chat\r\nSet-Cookie: session=attacker"))   -> response splitting
```

Servers commonly echo back the client's requested subprotocol, which makes `build_server_handshake` a direct response-splitting primitive. Go (`websocket.Dial` → `net/http: invalid header field value`) and Rust (`HeaderValue` parse error) both reject the same input (`builder_crlf_subprotocol` line of `run_audit.sh handshake`). Because the builders return `String`, not `Result`, the API cannot even report the error.

## P2-6 Frames after Close are delivered

| case | Pion | tungstenite | coder/websocket |
|---|---|---|---|
| `data_after_close` (Close 1000, Text "after") | `C1000 T5 END` | `C1000 END` | `C1000 END` |
| `close_after_close` (Close 1000, Close 1001) | `C1000 C1001 END` | `C1000 END` | `C1000 END` |

A sans-IO decoder may leave enforcement to the caller. However, the package offers no connection-state type for that, the README claims "Full Autobahn" compliance, and both references enforce the rule (RFC 6455 §1.4 / §5.5.1).

## P2-7 / P2-8 Handshake parsing differential (23 cases)

| case | Pion | tungstenite | coder | comment |
|---|---|---|---|---|
| `resp_duplicate_accept_bad_first` | **OK** | ERR | ERR | the last `Sec-WebSocket-Accept` wins |
| `req_ctl_in_value` (`X-Evil: a\x01b`) | **OK** | ERR | ERR | RFC 7230 §3.2 field-value |
| `req_duplicate_key` | **OK (last key)** | OK (**first** key) | ERR | Pion and Rust choose different keys, so a proxy and a backend can compute different Accept values |
| `req_space_before_colon` (`Host : x`) | **OK** | ERR | OK | RFC 7230 §3.2.4 MUST 400 (smuggling vector) |
| `resp_unoffered_extension` | **OK** | OK | ERR | RFC 6455 §4.1 rule 5 MUST fail |
| `builder_crlf_subprotocol` | **INJECTED** | REJECTED | REJECTED | see P1-5 |
| `req_key_not_base64`, `req_key_15_bytes` | ERR | OK | ERR | Pion is stricter (correct per §4.2.1) |
| `req_missing_host`, `req_duplicate_version_13_8` | ERR | OK | OK | Pion is stricter (correct) |
| `req_lf_only` | ERR | OK | OK | Pion is stricter. RFC 7230 §3.5 *allows* lenient LF; interop, not a bug |
| `req_obs_fold` | ERR | ERR | OK | Pion matches Rust |

The remaining 11 cases agree across all three implementations.

## Frame differential: all 22 divergent cases (154 cases = 52 scenarios × chunk sizes, 0 chunk-dependent)

Beyond P1-4 and P2-6 above:

| case | Pion | tungstenite | coder | verdict |
|---|---|---|---|---|
| `len64_msb_set` | ERR1002 | ERR1009 | ERR (no close) | all reject |
| `len64_max_positive`, `len64_4gb`, `limit_header_only_huge` | **ERR1009 on the header** | ERR1009 | **END (waits for the payload)** | Pion is better than Go here: fail-fast OOM guard |
| `len16_nonminimal_5`, `len64_nonminimal_5` | ERR1002 | accepts | accepts | Pion is stricter (§5.2 "MUST be minimal"). Autobahn does not test this, so it is an interop risk only |
| `masked_from_server` (client role) | ERR1002 | ERR1002 | **accepts** | coder violates §5.1 |
| `unmasked_from_client` | ERR1002 | ERR1002 | ERR (no close frame) | all reject |
| `close_1005/1006/2999` | ERR1002 | `Close(1002)` | ERR1002 | equivalent (tungstenite reports the protocol close as a Close message) |
| `utf8_6_4_1_full`, `utf8_valid_prefix_incomplete_at_fin`, `close_reason_bad_utf8` | ERR1007 | ERR1007 | accepts | coder does not validate UTF-8 |

The full table is in `$AUDIT_OUT/diff.md`. Every case gives the same answer whole, in 1-byte drips and in 3-byte chunks (1-byte drip of 2/4/10/14-byte headers, mask keys and payloads, with Ping/Pong/Close interleaved inside fragmented messages). This was a surface the audit aimed at, and it held up.

## Fuzz (2000 mutated streams, seed 1, `max_message_size` ∈ {64 KiB, 1 MiB, Int max}, chunk ∈ {whole, 1, 7, 4096})

- Pion crashes: **0**. Random mutation never hit the P0-2 overflow window; the targeted probe did.
- Verdict mismatches against tungstenite: **76** (events compared up to the first Close). I looked at a sample. Most mismatches are Pion failing *earlier* than tungstenite (tungstenite reads the whole payload before checking RSV or control-frame bits). The rest are the UTF-8 fail-fast class from P1-4 (for example `fz259` and `fz445`: a FIN=0 text fragment with invalid UTF-8 and then truncated input).
- Verdict mismatches against coder: 694 (dominated by its missing UTF-8 validation and lazy limit checks).

## Autobahn coverage claim

The README says "180 / 180" and "full Autobahn Testsuite core protocol compliance". Of the 180 tests, 115 carry an `autobahn_*` name: §1 11, §2 5, §3 7, §4 10, §5 20, §6 31, §7 31. The rest are SHA-1/Base64/handshake/stream unit tests.

The real fuzzingclient suite has roughly 517 cases. Section 6 alone (UTF-8) has about 145, of which the package ports 31. Section 9 (performance, about 54) and §10 are absent. §12/§13 (permessage-deflate, 216 cases) cannot run at all. None of the 180 tests drives the actual Autobahn `wstest` harness.

I could not run `wstest` here (no Docker or Python 2 wstest on this host), so these counts come from the public suite layout and are not a measured pass rate. The claim should read "a hand-ported subset of Autobahn §1–§7", not "full compliance".

## Optimisation review (`1003816`: 8× unrolled mask, UTF-8 fast path, chunk queue)

- 8× unrolled mask and UTF-8 range checks: all alignment and tail lengths roundtrip (existing tests). The 1/3/7-byte and random-chunk differential runs and the 2000-case fuzz produced no out-of-bounds access and no mis-decode.
- Chunk queue: P0-1, a leak. The queue is never compacted while the producer stays ahead.
- `coalesce()` merges *all* pending chunks, not just the current frame. This is linear in total, but it adds a full extra copy for every frame that straddles a read boundary, which is why `big_64k` runs at 317 MB/s.
- Reassembly is linear (`frag_storm`: 10 000 fragments, no O(N²)).

## Files

| path | purpose |
|---|---|
| `tests/redteam_test.pion` | 19 failing evidence tests and 4 passing controls (`pionc test --json -p websocket_redteam_audit packages/websocket/audit`) |
| `diff/gen_corpus.py`, `diff/gen_handshake.py` | shared frame and handshake corpora |
| `diff/pion`, `diff/rust/src/diff.rs`, `diff/go/cmd/diff_go` | canonical frame-differential runners |
| `diff/rust/src/hs.rs`, `diff/go/cmd/hs_go` | handshake-differential runners (Pion: `diff_pion hs`) |
| `diff/compare.py`, `diff/fuzz.py` | differential table and mutation fuzz |
| `probe/` | process-isolated P0 probes (overflow panic, queue retention RSS) |
| `bench/gen_bench.py`, `bench/pion_adv`, `diff/rust/src/adv.rs`, `diff/go/cmd/adv_go` | adversarial benchmarks via `scripts/bench_compare.py` with SHA-256 verification |
| `run_audit.sh` | one-command runner |
