# Red-team audit: `packages/sse` v0.1.0 (`feat/pkg-sse` @ `5a09109`)

Auditor: RT-sse (independent adversarial review). Reference: WHATWG HTML Living Standard §9.2.6
"Interpreting an event stream", WHATWG Encoding §4 (UTF-8 decode), Rust `eventsource-stream =0.2.3`.
Toolchain: `pionc 0.1.0` (`AFK-surf/pion@66d2b4b`), arm64 macOS.

```sh
sh packages/sse/audit/run_audit.sh          # full (~1 min + bench), exit 1 while any finding reproduces
QUICK=1 sh packages/sse/audit/run_audit.sh  # 500 random cases, small DoS sizes, no bench
```

Nothing in `packages/sse` outside `audit/` was changed. All builds, corpora and logs go to
`$AUDIT_OUT` (default `/private/tmp/rt-sse-audit-$USER`); the Rust oracle builds `--locked`.
Every `redteam_*` test accepts any reasonable fix, so a fix branch re-runs this directory unchanged
and gets `exit 0` once the findings are fixed.

## Verdict

The **parser core is correct**: on 3,087 streams (87 hand-written WHATWG edge cases + 3,000
random adversarial streams) × 6 chunkings (whole, 1 B, 2 B, 3 B, 7 B, random 1–17 B) Pion matches
a literal §9.2.6 oracle **3087/3087**, Strict mode **3087/3087**, and the outputs are
**byte-identical in native dbg/rel and wasm32 dbg/rel**. BOM split as `[EF][BB][BF…]`, U+FEFF
later in the stream, 2/3/4-byte UTF-8 split anywhere, ill-formed UTF-8 (`80`, `C0 AF`, `E4 B8 41`,
`ED A0 80`, `F4 90 80 80`, truncated at EOF) → U+FFFD maximal subparts, `\r\n` across chunks,
`data: a\r\r\n`, CR-only, no dispatch at EOF, bare `data`, two spaces after `:`, `id` with NUL,
bare `id`, event reset by a data-less block, `retry: +100 / -100 / 100ms /  100 / 2^63` — all
right. The encoder round-trips 3,000 adversarial CR-free events byte-for-byte and blocks every
field-injection attempt (`id: evil` inside data, leading space `" foo"` → `data:  foo`). No
overflow in backoff (1,000 failures, `Int64::MAX` cap), no crash, no wasm trap, line limit
rejects before buffering.

The defects are at the edges: **what happens after an error**, **the reconnect policy**, and
**the reconnect helpers**. No P0. **3 × P1, 5 × P2**, plus 4 non-gating notes.

| ID | Sev | Finding | Gate (`audit/redteam_test.pion`) |
|----|-----|---------|------|
| F-01 | **P1** | `feed_bytes` Err drops events already dispatched in the same chunk, but their `id` is already committed to `last_event_id()` → resume skips them forever | `redteam_error_does_not_drop_committed_events_{line_limit,strict_utf8}` |
| F-03 | **P1** | server `retry: 0` turns exponential backoff into 0 ms forever (reconnect storm) | `redteam_backoff_server_retry_zero_still_backs_off` |
| F-04 | **P1** | jitter is clipped away at the cap (every client waits exactly `max_backoff_ms`), and the default seed is the same in every process | `redteam_jitter_survives_at_cap` |
| F-02 | P2 | errors are not sticky; parser resynchronises mid-line → payload tail parsed as fields, bytes cut out of a line, a rejected event dispatched truncated | `redteam_after_line_too_large_*`, `redteam_after_too_many_data_lines_no_truncated_dispatch` |
| F-05 | P2 | reusing the parser after `finish()` (the only way to keep `last_event_id` across a reconnect) does not re-arm BOM stripping and keeps a partial BOM | `redteam_finish_then_next_response_bom_stripped`, `redteam_finish_discards_partial_bom` |
| F-06 | P2 | cursor URL helper appends a duplicate `since=` and does not encode the parameter name | `redteam_cursor_query_replaces_existing_param`, `redteam_cursor_query_param_name_encoded` |
| F-07 | P2 | `last_event_id_header()` returns CR/LF from `set_last_event_id` verbatim (header injection) | `redteam_last_event_id_header_rejects_crlf` |
| F-08 | P2 | `max_event_bytes` counts raw bytes before U+FFFD expansion (0xFF payload → 3× the limit) | `redteam_max_event_bytes_bounds_decoded_data` |

13 `redteam_*` tests fail on `5a09109`; 9 `control_*` tests pass (attacks it survived).

---

## P1

### F-01 — Err discards dispatched events whose id is already committed

`src/parser.pion:567-705` (`feed_bytes`) collects events in a local `out` and on any error
returns `Err(e)` (lines 599/610/614/660/665/671/689), discarding `out`. Dispatch (line 413,
`self.last_id = self.id_buf`) has already advanced the parser's cursor for those events.

```
limits(max_line_bytes=16); feed("id: 1\ndata: a\n\ndata: xxxxxxxx…(32)\n")
→ Err(LineTooLarge); event {id:1,data:"a"} never returned; parser.last_event_id() == "1"
Strict: feed("id: 7\ndata: ok\n\ndata: \xFF\n\n") → Err(InvalidUtf8); event 7 lost, last_event_id()=="7"
```
Under 1-byte feeding the same streams return the event (`control_error_prefix_events_delivered_under_1byte_feeding`),
so the result depends on TCP segmentation. A client that reconnects with `parser.last_event_id()`
(the documented accessor) asks the server for events *after* 1/7 and loses them permanently — silent
data loss in a sync protocol. Fix options: return the prefix events together with the error
(e.g. `Ok` + pending error / `Err` carrying events), or roll the committed id back.

### F-03 — `retry: 0` disables backoff

`src/reconnect.pion:93-131`: `base = retry_ms` when the server sent one, doubling `0` stays `0`,
and jitter needs `delay > 0`. Probe (`misc`): `server_retry0: 0 0 0 0 0 0 0 0 0 0 0 0`
(`base0` config identical). One misconfigured or compromised server line `retry: 0` makes every
client reconnect in a hot loop for as long as the endpoint fails — the exact multi-station storm
backoff exists to prevent. `retry: 1` still grows (1, 2, 4, … 2078 ms) so a floor
(`max(retry, base_backoff_ms)` once `attempt > 1`, or a minimum of e.g. 100 ms) is enough.

### F-04 — no jitter in the steady state; identical default seed

`src/reconnect.pion:115-123`: jitter is purely additive and `if delta >= cap - delay { delay = cap }`.
Once `delay == cap`, `cap - delay == 0` so **every** delay is exactly `max_backoff_ms`
(probe: `default: 1057 2216 4355 9442 16307 30000 30000 30000 …`). In addition
`SseReconnectConfig::default()` (`src/types.pion:152`) uses one fixed seed, so all clients created
with `SseReconnectState::new()` produce the *same* sequence even before the cap. After a server
restart all stations retry in lock-step: a thundering herd. Fix: subtractive / "full" or
"equal" jitter inside `[cap·(1-r), cap]`; document (or require) a per-instance seed — the
package is World-free, so the caller must supply entropy.

## P2

### F-02 — errors are not sticky; resync at an arbitrary byte

After an error the parser keeps going from wherever the early return left it
(`append_line_slice` `:349-362` leaves `line_len`; `feed_bytes` drops the rest of the chunk).
Three reproductions:
1. `max_line_bytes=32`: chunk 1 = `data: ` + 40×`A` (Err), chunk 2 = `id: evil\ndata: next\n\n`.
   The tail of the rejected line is parsed as a fresh line → `last_event_id() == "evil"`
   (payload text becomes an `id:` field).
2. chunks `data: `+20×`A` | 10×`B` (Err) | `C\n\n` → event `"AAAA…AC"` delivered with the 10 `B`
   silently cut out of the middle.
3. `max_data_lines=2`: `data: a\ndata: b\ndata: c\n` (Err) then `\n` → event `"a\nb"` dispatched,
   third line silently lost (DoS probe `datalines`: 1,000,000 `data\n` lines with **no** blank line
   produce 7 events of 65,535 lines, because a dropped chunk tail makes the next `\n` look like a
   blank line).
P2 because a careful caller drops the connection on Err; but nothing documents that, and
"log and continue" turns it into field injection. Fix: make the parser poisoned after an Err
(every later call returns the same error until `reset()`), or skip to the next line terminator and
discard the whole event.

### F-05 — `finish()` + reuse does not start a clean stream

`finish()` (`:706-736`) resets line/event state but not `bom_state`. Reusing the parser for the
next response is the only way to keep `last_event_id` across a reconnect (`reset()` at `:75`
wipes it; a new parser cannot be seeded; `SseReconnectState::on_event` then overwrites the cursor
with the fresh parser's `""` on the first id-less event). With reuse:
`"id: 5\ndata: a\n\n"`, `finish()`, `EF BB BF "data: b\n\n"` → event `b` **dropped** (line
`﻿data` is an unknown field); and a truncated previous response ending in `EF BB` prepends
those bytes to the next stream's first line. Fix: re-arm `bom_state = 0` in `finish()` (or add a
`restart()` that keeps `last_event_id`/`retry_ms`), and document the reconnect recipe.

### F-06 — cursor URL helper: duplicate parameter, unencoded name

`src/reconnect.pion:244-279`: `https://h/e?since=0&x=1` → `…?since=0&x=1&since=42`. Servers that
take the first value (Go `url.Values.Get`, many routers) resume from 0 every time; callers that
feed the result back grow the URL on every reconnect. The parameter name is written raw
(`since&admin=1` → `?since&admin=1=1`). Fix: replace an existing `param=` pair; percent-encode
the name (or reject non-unreserved names).

### F-07 — `Last-Event-ID` header carries CR/LF

`set_last_event_id` (`:147`) accepts anything and `last_event_id_header` (`:168`) returns it
verbatim: `"1\r\nX-Injected: yes"` → header value with CRLF. Ids coming from the parser cannot
contain CR/LF, but the setter exists for "persisted storage". Fix: reject/strip CR, LF, NUL in the
setter or return `None`.

### F-08 — `max_event_bytes` counted before U+FFFD replacement

`:497-505` adds `vlen` (raw bytes) and then decodes with `decode_utf8_lossy`, which maps each
ill-formed byte to 3 bytes. `max_event_bytes=1024`, `data: ` + 1000×`0xFF` → 3,000-byte event;
with defaults a 1 MiB `0xFF` line yields a 3,144,000-byte event (probe `ff`). Bounded (3×), so
P2. Fix: account the decoded length, or document "raw bytes".

## Non-gating notes

- **N-1 (doc)** README says the encoder splits on CR/LF "for lossless round-tripping". SSE cannot
  carry CR inside data, so `"a\r\nb\rc"` comes back as `"a\nb\nc"` (fuzz: 1,023/3,000 CR-containing
  payloads change; 3,000/3,000 CR-free payloads are exact). Either reject CR or document the
  normalisation.
- **N-2 (design)** `format_event` omits `id:` when `id == ""`. Parsed events carry the sticky id, so
  re-encoding a sequence `[id "1", id ""]` (a server clearing the id) loses the clear: the second
  event comes back with id `"1"`.
- **N-3** `total_bytes_seen` (`Int`, 32-bit, unused) wraps after 2 GiB and `fail_attempt` after 2³¹
  failures; Pion integers wrap silently in all 4 modes (verified), so no trap — harmless today,
  remove or widen.
- **N-4 benchmark fairness.** Re-run of `bench/run_bench.sh` (SHA-256 identical, as claimed):
  quiet machine W1 **1.32×**, W2 1.05×, W3 0.96×; under load W1 1.38×, W2 0.92×, W3 1.34×. The W1
  lead is real and stable; it comes from upstream `parse_event` doing `buffer.split_off` per line
  (O(remaining buffer) copy, i.e. O(chunk) per line), which is a genuine upstream cost but not
  parsing speed. **W2/W3 are within noise** — README's "1.03×" wins for W2/W3 should read "parity".
  The corpora must avoid a leading BOM and ill-formed UTF-8, otherwise the baseline panics/stalls
  (U-4/U-5 below); that is a limitation of the baseline, not cherry-picking, but should be stated.

## Upstream `eventsource-stream 0.2.3` quirks (catalogued, not Pion defects)

The differential requires Rust to equal the oracle *with exactly these quirks modelled*; anything
else is reported as UNEXPLAINED (none on 3,087 cases × 3 chunkings).

| ID | Quirk | Cases |
|----|-------|------:|
| U-1/U-2 | `retry:` parsed with `str::parse::<u64>()`: accepts `+100` and values up to `u64::MAX` (spec: ASCII digits only) | 14 |
| U-3 | a CR that is the last byte of the stream is never treated as a line end (nom `Incomplete`) | 106 |
| U-4 | ill-formed UTF-8: `Utf8Stream` keeps the bad byte at the head of its buffer, yields nothing more and buffers the rest of the stream unboundedly, then `Err(Utf8)` at EOF | 502 |
| U-5 | **panic** on any stream starting with a BOM: `&string[1..]` slices inside the 3-byte U+FEFF (`event_stream.rs:271`) | 591 |

## What the audit runs

1. `pionc test audit` — 22 tests (13 `redteam_*` findings, 9 `control_*`), upstream 15/15.
2. `oracle/whatwg_sse.py` — corpus generator + §9.2.6 oracle + differential (Pion 6 chunkings +
   Strict whole/1 B; Rust `rust_oracle/` whole/1 B/random with quirk model).
3. `probe misc` — backoff sequences (12 configs, 1,000 failures, `Int64::MAX`), cursor URL matrix,
   header, encoder vectors and 2 × 3,000-event encoder fuzz.
4. 4-mode: corpus (24,696 lines), misc and the package's `wasm_smoke` — SHA-256 identical in
   native dbg/rel and wasm32 dbg/rel (corpus `ed04eb5736b05de7…`, wasm_smoke `47b0f3077f6ce791…`
   = README).
5. DoS (native `--release` and wasm32 `--release`): 256 MiB unterminated line in one chunk / 4 KiB
   chunks (rejected, parser memory constant; RSS is the generated input), 100 M blank lines (1.8 s),
   5 M comments, 5 M tiny events, 1 M data lines, 1 MiB `0xFF` line, 8 MB 1-byte drip — all return,
   no SIGSEGV / wasm trap.
6. Package bench re-run (fairness, N-4).
