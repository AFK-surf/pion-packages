# `packages/resp` red-team audit

| | |
| --- | --- |
| Target | `AFK-surf/pion-packages` `packages/resp` @ `origin/feat/pkg-resp` `1afa56a` |
| Toolchain | `pionc 0.1.0 (arm64_apple, self-hosted)`, Node `v24.22.2` (wasm32 runtime), `cargo 1.100.0` |
| Oracles | Redis 7 RESP2/RESP3 spec (redis.io protocol spec, `redis-specifications/protocol/RESP3.md`), Redis 7 `src/sds.c` `sdssplitargs`, Redis 7 `src/cluster.c` (`keyHashSlot`, `clusterRedirectClient`, `addNodeToNodeReply`), Rust `redis-protocol 6.0.0` (`audit/oracle`, `Cargo.lock` locked) |
| Reproduce | `sh packages/resp/audit/run_audit.sh` (about 15 s on an M-series Mac; exits non-zero while any finding is open) |

## 1. Result

**0 × P0, 3 × P1, 9 × P2.** `run_audit.sh` currently reports **1044 checks: 983 PASS, 61 FAIL**. Every FAIL maps to one of the findings below. No check fails without a finding behind it.

| ID | Sev | Finding | Failing checks |
| --- | --- | --- | --- |
| P1-01 | P1 | Int32 overflow in length bounds checks. `RespLimits` near `Int` max causes an out-of-bounds panic (SIGABRT natively, trap on wasm32) | 24 (6 cases × 4 modes) |
| P1-02 | P1 | `StreamDecoder` re-parses the whole pending frame on every `next_frame()`, giving O(n²) CPU for fragmented aggregates and streamed strings | 3 |
| P1-03 | P1 | Inline commands have no length cap: a line without `\n` is buffered up to 64 MiB and rescanned on every feed (O(n²)) | 5 |
| P2-01 | P2 | SimpleString / SimpleError accept an embedded lone `\r` or `\n` | 4 |
| P2-02 | P2 | Double grammar too lenient (`.5`, `1.`, `Inf`, `INF`, `NaN`) | 5 |
| P2-03 | P2 | BigNumber rejects the spec-legal `+` sign (decoder and encoder) | 2 |
| P2-04 | P2 | `decode_inline` diverges from Redis `sdssplitargs` despite the README's claim | 6 |
| P2-05 | P2 | `StreamDecoder::default()` turns an invalid reply line into a command `Array` instead of returning an error | 1 |
| P2-06 | P2 | `MOVED` / `ASK` with an empty endpoint (`:6380`, Redis 7 `unknown-endpoint`) is rejected | 2 |
| P2-07 | P2 | `CLUSTER SLOTS` with a NULL preferred endpoint (Redis 7 `unknown-endpoint`) fails the whole parse | 2 |
| P2-08 | P2 | Overlapping or duplicate slot ranges are accepted silently, and the last range wins depending on order | 2 |
| P2-09 | P2 | Default limits contradict each other: a max-size bulk can't pass the stream buffer, and a max-length array exceeds `max_total_nodes` | 5 |

**Clean areas (all checks green):**

- All 15 frame types, including the RESP2 nulls `$-1` and `*-1`. There are 146 hand-written decode cases.
- Int64 extremes and overflow.
- Bulk length mismatch and missing CRLF.
- Verbatim strings.
- Attributes: chained, nested in aggregates and map values, orphaned, and dangling before `.`.
- Every streamed form, including nested streamed aggregates and `$?` inside them.
- Split-feed consistency: 584 checks (146 cases × 4 modes, each fed in 1/2/3/7/64 B, three random patterns and a `drain_frames` pattern), plus 900k mutation-fuzz iterations with zero mismatches and zero panics.
- RSS stays flat: 100k frames peak at 2.33 MiB and 1M frames at 2.41 MiB. The buffer high-water mark is 8 KiB.
- All pre-allocation bombs (`$2147483647`, `$99999999999999999999`, `*1000000000`, `%500000000`, `$9223372036854775807`, `;9999999999`, negative lengths) are rejected under default limits in under 3 ms.
- 10k-deep nesting of every container kind returns `MaxDepthExceeded` on all 4 modes.
- With depth unlimited, a 100k-deep decode, encode and equality check, plus a 200k-deep encode, run with no stack overflow on wasm32.
- Encoder CRLF/frame injection is rejected in SimpleString, SimpleError, BigNumber, the verbatim tag, nested values, map keys, attribute keys and attribute targets. `PipelineBuilder` rolls back partial bytes.
- `key_slot` agrees three ways (Pion, an independent Python `keyHashSlot` model, and Rust `redis_keyslot`) on 23 edge keys and 20,000 generated tag-heavy keys.
- `MOVED` / `ASK` bounds, IPv6 bracketed and unbracketed.
- `CLUSTER SLOTS` bounds, gaps, ordering and RESP3 metadata.
- Router hot update is atomic when the new ranges are invalid.
- **4-mode check:** `native_rel`, `native_dbg`, `wasm_rel` and `wasm_dbg` stdout is byte-identical for every deterministic mode (decode, inline, keys, redirect, slots, builtin, DoS outcomes).

Severity scale:

- **P0:** remote crash or unbounded resource use under default limits.
- **P1:** remote crash under a legal non-default configuration, or algorithmic DoS under default limits.
- **P2:** spec or interop divergence, or wrong or contradictory behaviour on valid inputs.

## 2. P1 findings

### P1-01 — Int32 overflow in bulk, verbatim and chunk bounds checks: OOB panic

- **Repro:** `RespLimits::new(128, 2147483647, 2147483647, 2147483647, 2147483647)`, i.e. "unlimited". Feed `$2147483646\r\nab` (also `!2147483640\r\nab`, `=2147483646\r\ntxt:ab`, `$?\r\n;2147483646\r\nab`, `$?\r\n;8\r\nAAAAAAAA\r\n;2147483644\r\nab`) to `decode()` or `StreamDecoder::next_frame()`.
- **Expected:** Redis, and `redis-protocol` (`usize`, `nom::take`), report "incomplete", or reject the length.
- **Actual:** `pion panic: index -2147483637 out of bounds (len 15)`. Native exits with SIGABRT (-6). wasm32 traps (`pion_panic_oob`). It reproduces in all 4 modes and is triggered by 15 bytes of remote input.
- **Root cause:** `Int` is 32-bit. `src/decode.pion:606` computes `next_after_line + blen + 2 > end`, which wraps negative, so the incomplete check passes and line 609 indexes `data[next_after_line + blen]`. The same pattern appears in the streamed path at `src/decode.pion:149` (`out.len + chunk_len > max`) and `:152` (`pos + chunk_len + 2 > end`).
- **Why not P0:** the default `max_bulk_len` (64 MiB) keeps the sums below 2³¹. Nothing in the API stops callers from passing `Int` max, and that is the natural spelling of "no limit". Clamp limits in `RespLimits::new`, or do the comparisons in subtraction form (`blen > end - next_after_line - 2`) or in Int64.
- **Checks:** `dos/*:dos_ovf_*`.

### P1-02 — `StreamDecoder` re-parses the whole pending frame on every feed: O(n²)

- **Repro:** `*100000\r\n` followed by 100,000 × `:1\r\n` (400 KB), fed in 1 KiB chunks with `next_frame()` after each feed, which is the normal socket loop.
- **Measured** (native `--release`; the audit's own numbers):

  | Wire | Whole buffer | 1 KiB chunks |
  | --- | ---: | ---: |
  | 400 KB array | 2–4 ms | 470–500 ms (124–236×) |
  | `%?` map, 50k pairs | 4–5 ms | 690–712 ms |
  | `$?` 50k chunks | 1 ms | 314–343 ms |

  Scaling at 1460 B segments is clean O(n²): 100k → 349 ms, 200k → 1.4 s, 400k → 5.4 s. An array of 1,048,575 elements (4 MB, allowed by the default limits) costs about 35 CPU-seconds per frame per connection.
- **Expected:** Redis' own reader is incremental (`processMultibulkBuffer` keeps `multibulklen`/`bulklen` across reads). `redis-protocol`'s codec has the same re-parse design, but the README sells `StreamDecoder` as the long-lived connection decoder.
- **Root cause:** `StreamDecoder::next_frame` (`src/decode.pion:923`) calls `decode_prefix_range(self.buf, self.read_pos, …)` from scratch every time. On `Incomplete` all work is discarded, including the already-built child frames, the `DecodeContainer` stack and the streamed-bulk `ByteBuf` copy. Plain bulk strings are unaffected because the length check is O(1) (`cx_bulk` stays green).
- **Fix direction:** persist the container stack, `pos` and the partial streamed-bulk buffer in `StreamDecoder` between calls. Alternatively, cheaply pre-scan for frame completeness, tracking only counts, before materialising frames.
- **Checks:** `complexity/cx_agg`, `cx_smap`, `cx_sbulk`.

### P1-03 — Inline commands are unbounded and rescanned: O(n²)

- **Repro:** `StreamDecoder::default()` (inline is on by default). Feed 1 MiB of `a` with no `\n` in 4 KiB chunks: every `next_frame()` returns `Ok(None)` and `buffered_len` reaches 1,048,576. A 4 MiB line takes 23 ms whole and 2,073 ms in 1 KiB chunks.
- **Expected:** Redis rejects an inline request over `PROTO_INLINE_MAX_SIZE` (64 KiB) with `Protocol error: too big inline request`.
- **Root cause:** `src/decode.pion:353` scans `data[offset..end]` for `\n` from the frame start on every call. The only bound is `max_buffer_bytes` (64 MiB).
- **Fix direction:** add a 64 KiB `max_inline_len`, and remember the scanned prefix between calls.
- **Checks:** `dos/*:dos_inline_unbounded`, `complexity/cx_inline`.

## 3. P2 findings

| ID | Minimal repro | Spec / Redis 7 / `redis-protocol 6.0.0` | Pion actual | Root cause |
| --- | --- | --- | --- | --- |
| P2-01 | `+a\nb\r\n`, `+a\rb\r\n`, `-ERR\nx\r\n`, `-ERR\rx\r\n` | Spec: simple strings and errors "mustn't contain CR or LF". `redis-protocol` also accepts them (lenient). | `OK +"a\nb"`. The decoder accepts a frame the encoder refuses to produce, so a decode→encode round-trip fails. | `decode.pion:535/538` take everything up to the first `\r\n` (`find_crlf`) with no lone-CR/LF check. |
| P2-02 | `,.5`, `,1.`, `,Inf`, `,INF`, `,NaN` | Spec grammar: `,[<+\|->]<integral>[.<fractional>][<E\|e>[sign]<exponent>]`, plus the exact tokens `inf`, `-inf`, `nan`. `redis-protocol` is lenient too (Rust `f64::from_str`). | All accepted. | `decode.pion:67-75` lists extra case variants. `:80` admits any mix of digits, `.`, `e` and signs, then defers to `String::to_double`. |
| P2-03 | `(+3492890328409238509324850943850943825024385\r\n`; `encode(BigNumber("+12"))` | Spec: `([+\|-]<number>\r\n`. `redis-protocol` accepts. | `ERR InvalidBigNumber` / `EncodeError` | `validate_bignum_slice` (`decode.pion:93`) and `is_valid_bignum_str` (`encode.pion:19`) accept only `-`. |
| P2-04 | `'a\\b'`, `a"b c"`, `key'x y'`, `\x0bPING`, `\x0cPING`, `"a"\x0bb` | `sdssplitargs`: inside single quotes only `\'` is an escape, so `\\` stays two bytes. A quote in mid-token opens a quoted section (`a"b c"` → `ab c`). Leading whitespace and the byte after a closing quote use `isspace()`, which includes `\v` and `\f`. | `a\b` (one backslash). `ERR InvalidInlineQuote` for mid-token quotes. `\x0bPING` is kept as the argument. | `decode.pion:274` (extra `\\` rule), `:295/:301` (reject a quote after a non-empty token), `:212/:259/:280/:292` (whitespace set is only `' ' \t \r \n`). The README's "single-quote (`\'`, `\\`)" claim is wrong. |
| P2-05 | `StreamDecoder::default()` fed `hello world\r\n` | A client reply decoder must reject an invalid type byte. `redis-protocol` returns `DecodeError`. | `OK *[$"hello",$"world"]`: garbage or desynced server bytes are presented as a valid command array. | `decode.pion:834` defaults `allow_inline: true`. Inline is a server-side feature and should be opt-in. |
| P2-06 | `MOVED 3999 :6380`, `ASK 3999 :6380` | Redis 7 `clusterNodePreferredEndpoint()` returns `""` for `cluster-preferred-endpoint-type unknown-endpoint`, and the client must reuse the current host. | `None`: the redirect is lost and the caller treats it as a plain error. | `cluster.pion:148` (`colon <= start` → `None`). |
| P2-07 | `CLUSTER SLOTS` node `[$-1 or _, 6379, "n1"]` | Redis 7 `addNodeToNodeReply()` sends `addReplyNull` as the preferred endpoint for `unknown-endpoint`. | `ERR InvalidClusterReply("node host must be string")`: the whole topology refresh fails. | `cluster.pion:236`: `frame_to_string` rejects `NullBulk` / `Null`. |
| P2-08 | Ranges `0-10000@a` and `5000-16383@b`, or two `0-16383` ranges | A consistent cluster never reports two owners for a slot. An overlap means a corrupt or torn reply and should be rejected. | Accepted. Slots 5000–10000 silently route to whichever range is listed last, and `covered_slots()` still reports 16384. | `ClusterRouter::update_from_slots` (`cluster.pion:374`) overwrites with no conflict check. |
| P2-09 | (a) `StreamDecoder` with `max_bulk_len = max_buffer_bytes = 1024` (the default relation, both 64 MiB) fed `$1024\r\n` + 1024 B + `\r\n`. (b) `*1048576\r\n` + 1,048,576 × `_\r\n` with defaults. | A frame inside the advertised limits must decode. | (a) `MaxBufferBytesExceeded`: a max-size bulk can never stream. (b) `MaxTotalNodesExceeded`: an array of `max_collection_len` elements has `max_collection_len + 1` nodes, one over the default `max_total_nodes`. | `decode.pion:876` counts the frame overhead against a buffer cap equal to the payload cap. `:513` uses the same default (1,048,576) for both limits. |

### Oracle divergences (informational, Pion is the stricter side)

`redis-protocol 6.0.0` disagrees with Pion on 30 decode cases (`run_audit.sh` prints them). In every one of them Pion matches the spec and `redis-protocol` does not:

- It accepts `$3\r\nabcXY`, `_x\r\n`, `=7\r\ntxtXabc` (no `:`), a lone `.\r\n`, `*?\r\n.x\r\n`, `%?` with an odd number of elements, and BigNumbers like `(12a3`, `(`, `(-`.
- It treats `$-1` and `*-1` as *streaming* (`to_isize("-1") == -1 == "?"`).
- It reports `$2147483647` and `*1000000000` as incomplete instead of rejecting them.
- It cannot nest streams or attach an attribute to an attribute.
- It recurses through `nom` (needs a 512 MiB stack in the oracle) and merges duplicate map keys.

None of these are Pion defects.

### Observations (not counted, no failing check)

- `ClusterRouter.nodes` is never pruned by `update_from_slots`, so the node table grows with endpoint churn over a long-lived router. `apply_moved` interns `(host, port, "")`, a different identity from the same node learned from `CLUSTER SLOTS` with its node ID.
- There is no `CLUSTER SHARDS` parser and no classifier for `TRYAGAIN` / `CLUSTERDOWN` / `CROSSSLOT`. `parse_cluster_redirect` correctly returns `None` for these, and the README claims neither.
- After a protocol error, `StreamDecoder` keeps returning the same error until `reset()`. It never skips bytes silently, which is the safe behaviour (`builtin/st_error_sticky_then_reset`).
- Lengths with a leading `+` (`$+3`, `*+1`) are accepted. The spec only defines decimal lengths, so this is harmless leniency.
- Redis `sdssplitargs` stops at a raw NUL byte. Pion keeps NUL bytes, which is binary-safe and arguably better. Not judged.

## 4. Four-mode Wasm32 consistency

The probe is built serially with `pionc build` (debug, `--release`) × (`arm64_apple`, `--target wasm32`, run through `share/pion/pion_wasm_rt.mjs`).

- **Byte-identical across all 4 modes** (`4mode` section, 7/7 PASS): the stdout of `decode`, `inline`, `keys`, `redirect`, `slots` and `builtin`, and the normalised (exit status, result) table of all 32 DoS cases.
- **No trap or crash** in any mode except the P1-01 cases, which panic identically everywhere.
- **wasm32 holds up under deep input:** the 100k-deep decode/encode/equality case and the 200k-deep encode run without a stack trap.

## 5. Benchmark fairness review (`bench/`, README W1–W3)

Fairness numbers come from `run_audit.sh`'s informational section (`oracle w1fair`, `oracle w3split`, `probe w3split`, native `--release`).

- **W1 (README: Pion 1.21× faster): the Rust side is handicapped.** `bench/rust/src/main.rs` builds `let view = buf.clone().freeze()` on every decode attempt. `BytesMut::clone` deep-copies the pending buffer. The idiomatic zero-copy loop (`decode_bytes_mut(&mut buf)`) runs the same corpus in **43 ms instead of 53–55 ms (about 20% faster)**. Re-baselined, W1 is roughly parity, not a 1.21× win. The Pion side also has a small handicap: its harness copies every 137 B chunk byte-by-byte before `feed`.
- **W2 (0.82×): roughly fair, with asymmetric API paths.** Pion encodes through its specialised `PipelineBuilder::push_command` (direct ASCII writes). Rust builds a `Vec<BytesFrame>` per command and goes through the generic `extend_encode`, which handicaps Rust. Pion then pays an extra full copy of each 1000-command batch into the `StreamDecoder` ring buffer, plus an owned allocation per BulkString. Rust decodes zero-copy `Bytes` slices. Both outputs hash-match, so the comparison is valid but not apples-to-apples per component.
- **W3 (0.31×): unfair, and the README explanation is only partly right.**
  - The Rust side does not run an equivalent parser. `parse_moved_rust` returns only `(slot, port)`: it never materialises the host, has no `ASK` branch, and does no host validation. Pion's `parse_cluster_redirect` returns an owned `ClusterRedirect` with a host `String`.
  - Split measurements (2M `key_slot` and 500k MOVED, measured separately):

    | Half | Pion | Rust |
    | --- | ---: | ---: |
    | `key_slot` (2M) | 27–29 ms | 14.5–16.5 ms (about 1.8×) |
    | MOVED parse (500k) | 31–36 ms | 5 ms (about 7×) |

    Of Pion's MOVED time, about 10–12 ms is `String::to_bytes()` alone (`pion_string_to_bytes_500k`). Most of the rest is `slice_bytes(...).to_string()` for the host plus two passes over the message.
  - The 0.31× therefore comes mostly from the redirect half doing more work, not from CRC16. The README's P95 of 376 ms (against a 110 ms median) also shows the run was noisy.
  - **Bottlenecks to fix in the package:**
    - `parse_cluster_redirect` takes a `String` and converts it straight back to `Bytes`. Add a `Bytes` / `RespFrame::SimpleError` fast path, or parse the `String` in place.
    - The host is copied twice (`slice_bytes` then `to_string`).
    - `key_slot` reads a module-level `FixedArray[Int]` CRC table with bounds checks on every byte. Use a `Bytes`/`UInt16` table and do the hash-tag scan in one pass.
  - **Bench fix:** make `parse_moved_rust` return the host as `&str` (or `String`, to match ownership) and handle `ASK`, or make the Pion side return a borrowed slice. Then re-measure.

## 6. Suite layout (immutable; a fix must change no byte under `audit/`)

```text
audit/run_audit.sh        one-shot driver (SCRIPT_DIR/REPO_ROOT relative; all artifacts in $RESP_AUDIT_OUT or mktemp)
audit/cases/*.tsv         expectations: decode (146), inline (26), keys (23 + 20k generated), redirect (30),
                          slots (24), builtin (36), dos (32), complexity (6)
audit/probe/              Pion probe package (path dep on ../..): canonical dump, split-feed checker, fuzzer, DoS,
                          RSS stress, complexity timers
audit/oracle/             Rust redis-protocol 6.0.0 oracle (Cargo.lock locked, built with --locked into $OUT)
audit/tools/prep.py       case tables -> hex inputs; deterministic random key corpus
audit/tools/audit.py      per-mode runner (one process per DoS case, exit status / time / peak RSS via wait4) + judge
```

A fix branch is done when `sh packages/resp/audit/run_audit.sh` prints `AUDIT RESULT: PASS` and exits 0. The script also fails if the run leaves anything behind in the worktree.
