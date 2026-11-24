# Red-team audit: `packages/hls` v0.1.0

Target: `origin/feat/pkg-hls @ 37d0821098dfed86313b82307a9d750552712e5c` (pure Pion RFC 8216 + LL-HLS parser,
validator, resolver and formatter). Specification used: RFC 8216 and its successor draft
`draft-pantos-hls-rfc8216bis-17` (cited as "bis §x"). Everything in this directory is new; nothing outside
`packages/hls/audit/` was changed.

```sh
sh packages/hls/audit/run_audit.sh            # exit 1 while a P0 reproduces, OPEN P1/P2 listed
STRICT=1 sh packages/hls/audit/run_audit.sh   # exit 1 while anything is OPEN
sh packages/hls/audit/run_audit.sh <section>  # build static unit cases determinism oracles dos smoke bench inject
```

## Summary

| Severity | Count | Findings |
| --- | ---: | --- |
| **P0** | **1** | P0-1 variable expansion has no aggregate budget: a 1.2 MB playlist makes the parser allocate 4.5 GB (wasm32: `pion panic: wasm32 out of memory`; native: 4.4 GB RSS, 6.5 GB at the default limits) |
| **P1** | **6** | P1-1 decimal overflow wraps (negative EXTINF, TIME-OFFSET sign flip) · P1-2 MSN / DSN / timeline wrap around Int64 · P1-3 quadratic EXT-X-DEFINE CPU DoS (7.3 MB → 24 s native / 42 s wasm32) · P1-4 multi-KEYFORMAT keys (multi-DRM) silently dropped · P1-5 EXT-X-SKIP ignored when numbering segments · P1-6 formatter tag / attribute injection through `CustomTag` and DATERANGE client-attribute names |
| **P2** | **13** | variable-reference recognition, substitution scope, IMPORT/QUERYPARAM, round trip re-expands variables, formatter returns Ok for unparsable text, lost tag positions, missing MUST cross-tag checks, METHOD=NONE / MAP BYTERANGE, ISO 8601 zones, lexical/type rules, PART implicit offsets, parse results not `Send`, README claims |

What holds up (verified, with control cases and the 5/5 bug-injection gate guarding it): duplicate AttributeName
rejection, the attribute-list grammar, `#EXT-X-BYTERANGE` implicit-offset rules (previous segment only, same URI,
first-segment rejection, 64-bit overflow, MAP byte ranges isolated), Master/Media tag mixing, I-FRAME-STREAM-INF not
consuming a line, dangling STREAM-INF/EXTINF at EOF, bare CR / NUL rejection, the Gregorian calendar check, all
`HlsLimits` (negative → `Err`, `0` → 0 items), CR/LF/NUL/`"` guards on every quoted and URI field of the formatter,
`select_variant` codec matching on a `.` boundary, the absence of exponential (billion-laughs) expansion, and
**byte-identical output in all four build modes** (native debug / release, wasm32 debug / release) on 4,280 corpus
inputs, the API sweep, 14 DoS bombs and `wasm_smoke` (SHA-256 matches README.md).

Static red lines: `license = "MIT"`, 0 dependencies, 0 `extern "C"`, 0 `World`, 0 imports, 0 module-level
bindings (`let`/`let mut`), 0 `Double`/`Float` (so no `Double::to_string`), no internal machine names in README.md.

## Method

* **Canonical dump** (`src/dump.pion`): every field of the public data model, the resolved timeline
  (`resolve_media_sequence`, `total_duration_*`) and a formatter line (`format_playlist` → `parse_playlist` →
  same dump?) per input, escaped to printable ASCII.
* **Independent reference model** (`diff/model.py`, ~900 lines of Python written from the RFC text, not from the Pion
  sources) prints the same dump. Where the specification leaves a representation choice open it follows the
  behaviour the package documents (list under "Accepted design choices"); everywhere else it follows the
  specification. Every rule where the specification and the package differ is tagged with a finding id; when such
  a rule fires the model prints `FLAGS|<id>`, and `diff/compare.py` attributes a divergence on that input to it.
  A divergence without a flag is a P0 failure of the run. Result on the current code: **0 unexplained divergences**
  on 260 named edge cases and 4,020 seeded mutations (20 seeds + 4,000 structural / semantic mutations); 240
  inputs diverge, each on an input where a finding's rule fires. Inputs on which a *fix* would legitimately
  change the dump are flagged too (several keys P1-4, per-segment unknown tags P2-6, part offsets P2-11;
  formatter-only ids on an `FFLAGS` line for P1-6 / P2-4 / P2-5), so a fix branch does not trip the gate; whether
  a finding is still open is decided by its red-team case, not by the model diff.
* **Rust `m3u8-rs =6.0.1`** (`diff/rust`, `cargo --locked`): accept sets and the field subset m3u8-rs exposes.
  m3u8-rs is a lenient parser, not a validator, so this oracle is informational (see "m3u8-rs differential").
* **Red-team cases** (`src/cases.pion`, `redteam_test.pion`): one per finding, through the public API only. Each
  accepts every reasonable fix (reject the input, or return a correct value) and builds values with record-update
  syntax from parsed playlists, so a fix that adds fields to public types still compiles. They decide whether a
  finding is OPEN. **Control cases** (`control_test.pion`, 9 cases) cover what the package gets right and must
  keep passing.
* **Bug injection** (`diff/inject.py`): 5 real bug classes are injected into a copy of `src/` (duplicate-attribute
  check removed; implicit BYTERANGE same-URI rule removed; formatter quote guard dropped; 400-year leap rule
  broken; codec prefix match without `.` boundary); the control cases catch **5/5**. A mutation whose target text
  no longer exists (code rewritten by a fix) is reported SKIP, never failed: nothing asserts the pre-fix source.
* **DoS bombs** (`diff/dos.py`, 18 bombs, default `HlsLimits`), native `--release` and wasm32 `--release`, with
  time budgets (2 s native, 3 s wasm32), a 1 GiB RSS budget and a native == wasm32 output check.
* **README numbers** (`diff/readme.py`) are parsed at run time: wasm_smoke SHA-256 and sizes, differential
  counts, benchmark SHA-256, speedup, throughput. Nothing is hard-coded in `run_audit.sh`.

## P0

### P0-1 Variable expansion has no aggregate budget (memory amplification, wasm32 OOM panic)

`substitute_vars` (`src/attrs.pion:123-199`) bounds each *single* expanded value by `max_line_bytes` (64 KiB), but
nothing bounds the total. One `#EXT-X-DEFINE` with a 65,000-byte VALUE plus N tiny reference lines makes the
parser retain N × 65,000 bytes; `EXT-X-PART` URIs are not even bounded by `max_segments` (`src/parser.pion:1601`).

```
#EXTM3U
#EXT-X-TARGETDURATION:1
#EXT-X-DEFINE:NAME="a",VALUE="xxxx…65000 bytes…"
#EXTINF:1,
{$a}
… (the two lines above × 70,000)
```

| bomb | input | native `--release` | wasm32 `--release` |
| --- | ---: | --- | --- |
| `b00_expand_segments` (70k × `{$a}` URI lines) | 1.18 MB | Ok, 4.55 GB retained, RSS 4,407 MiB | `pion panic: wasm32 out of memory` |
| `b01_expand_parts` (70k × `#EXT-X-PART:…URI="{$a}"`) | 2.4 MB | Ok, RSS 4,402 MiB | `pion panic: wasm32 out of memory` |

At the default limits (99,999 segments fit `max_lines`) the same 1.7 MB input needs 6.5 GB natively: an attacker
who can serve one playlist to a player, CDN proxy or packager crashes the wasm32 build and OOM-kills small native
hosts. Amplification ≈ 3,800×. This is P0 under this audit's rule "crash / trap / OOM on any input".

Fix: keep a running total of expanded bytes for the whole parse and fail with `LimitExceeded` when it exceeds a
budget (e.g. a new `HlsLimits.max_expanded_bytes`, default ≤ `max_input_bytes`); count EXT-X-PART / PRELOAD-HINT /
RENDITION-REPORT / DATERANGE / EXT-X-MEDIA entries against a limit as well.
Gate: `redteam_p0_1_expansion_amplification` (an 83 KB input must not retain > 64 MiB), bombs b00/b01.

## P1

### P1-1 Decimal values just above Int64 microseconds wrap around

`parse_decimal_scaled` (`src/decimal.pion:115-162`) allows `whole == Int64::MAX / 10^6` and then computes
`whole * scale + frac` without checking the fractional part: for µs the head-room is 775,807, so any fraction above
`.775807` overflows and wraps to a large negative number. The README's "rejects negative/NaN/Inf durations" is
bypassed; signed values flip sign.

| input | parsed |
| --- | --- |
| `#EXTINF:9223372036854.999999,` | `duration_us = -9223372036854551617` (accepted) |
| `#EXT-X-START:TIME-OFFSET=-9223372036854.999999` | `time_offset_us = +9223372036854551617` (sign flipped) |
| `HOLD-BACK=…`, `#EXT-X-PART:DURATION=…`, `SCORE`, `CAN-SKIP-UNTIL`, DATERANGE `DURATION` | negative |

`format_playlist` then writes `#EXTINF:-9223372036854.551617,`, which `parse_playlist` rejects. (FRAME-RATE has the
same wrap but is caught by its positivity check.) Fix: reject when `whole == max_whole && frac (+ rounding) >
MAX % scale`, i.e. compute the total with a checked add. Gate: `redteam_p1_1_decimal_wrap`.

### P1-2 Media sequence, discontinuity sequence and timeline arithmetic wrap around Int64

`resolve_media_sequence` (`src/utils.pion:1191-1233`) and `total_duration_us` (`:1171`) use unchecked `+`.

* `#EXT-X-MEDIA-SEQUENCE:9223372036854775807` + 2 segments → MSNs `9223372036854775807, -9223372036854775808`.
* `#EXT-X-DISCONTINUITY-SEQUENCE:9223372036854775807` + one `#EXT-X-DISCONTINUITY` → DSN `-9223372036854775808`.
* two `#EXTINF:9000000000000,` → `total_duration_us = -446744073709551616`, `end_us < start_us`.

MSN is also the default AES-128 IV (bis §5.2), so a wrapped MSN produces a wrong IV. Fix: reject at parse time
when `MEDIA-SEQUENCE + segment count`, `DISCONTINUITY-SEQUENCE + discontinuities` or the summed duration exceed
Int64 (or saturate and document it). Gate: `redteam_p1_2_sequence_timeline_wrap`.

### P1-3 Quadratic EXT-X-DEFINE declaration and lookup (CPU DoS)

`parse_define_attrs` scans all previous defines for duplicates (`src/parser.pion:128-134`) and `substitute_vars`
scans all defines for every reference (`src/attrs.pion:164-176`); there is no limit on the number of defines.

| input (default limits) | native `--release` | wasm32 `--release` |
| --- | ---: | ---: |
| 190,000 distinct `#EXT-X-DEFINE` (7.3 MB) | 24.1 s | 42.4 s |
| 20,000 defines + 200 lines × 7,000 `{$v19999}` (13.4 MB) | 38.7 s | – |
| run_audit bombs b03 (80k defines, 3 MB) / b04 (210k references, 2.6 MB) | 4.6 s / 6.4 s | 6.8 s / 5.8 s |

A linear parser handles the same inputs in tens of milliseconds (the 16 MB attribute-list bomb takes 0.4 s).
Fix: a hash map (or sorted array + binary search) for variable names, plus a `max_defines` limit.
Gate: `redteam_p1_3_define_quadratic` (4× the variables must not cost > 8× the time and > 50 ms), bombs b03/b04.

### P1-4 Several EXT-X-KEY tags with different KEYFORMATs: all but the last are lost

bis §4.4.4.4: a KEY "applies to every Media Segment … between it and the next EXT-X-KEY tag in the Playlist file
with the same KEYFORMAT attribute or a METHOD of NONE … Two or more EXT-X-KEY tags with different KEYFORMAT
attributes MAY apply to the same Media Segment". This is how multi-DRM (FairPlay + Widevine + PlayReady) CMAF HLS is
written. The parser keeps one pending key (`src/parser.pion:1497`), the resolver one active key
(`src/utils.pion:1203-1211`):

```
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://fp",KEYFORMAT="com.apple.streamingkeydelivery"
#EXT-X-KEY:METHOD=SAMPLE-AES,URI="data:wv",KEYFORMAT="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"
#EXTINF:4,
a.ts
```

→ `segments[0].key` is the Widevine key only; the FairPlay key is gone from the parse result, the resolved
timeline and the formatter output (`format_playlist` silently drops a key). A key of one KEYFORMAT also stops
applying as soon as a key of another KEYFORMAT appears. Fix: keep `keys : Array[EncryptionKey]` per segment (keep
`key` for compatibility), resolve per KEYFORMAT (`identity` when absent; METHOD=NONE clears all), format all.
Gate: `redteam_p1_4_multi_keyformat` (formatted output must contain both keys).

### P1-5 EXT-X-SKIP is ignored when numbering segments

bis §4.4.5.2 / §6.2.5.1: a Playlist Delta Update replaces the first SKIPPED-SEGMENTS segments by EXT-X-SKIP while
EXT-X-MEDIA-SEQUENCE still numbers the first (skipped) segment. `resolve_media_sequence` starts at
`media.media_sequence` (`src/utils.pion:1191`) and never reads `media.skip`:

```
#EXT-X-MEDIA-SEQUENCE:100
#EXT-X-SKIP:SKIPPED-SEGMENTS=10
#EXTINF:4,
x110.ts          -> resolved media_sequence 100, correct 110
```

Every segment of every LL-HLS delta update is numbered SKIPPED-SEGMENTS too low, so a client merging the update
into its previous playlist duplicates or skips media, and AES-128 segments without IV get the wrong IV.
Fix: start at `media_sequence + skipped_segments` (timeline start is then unknown: document or expose it).
Gate: `redteam_p1_5_skip_msn`.

### P1-6 Formatter tag / attribute injection through `CustomTag` and DATERANGE client-attribute names

README: "deterministic injection-safe serializer". `format_custom_tags` (`src/utils.pion:186-214`) only rejects
CR/LF/NUL in `CustomTag.name` / `.value`, and DATERANGE client attributes (`:1040-1062`) only check that the key is
a "safe token" (no `X-` prefix check). A playlist rewriter that copies foreign data into these fields (or a parsed
playlist edited by an application) emits real tags:

| value given to `format_playlist` | re-parsed as |
| --- | --- |
| `CustomTag{name: "#EXT-X-I-FRAME-STREAM-INF", value: "BANDWIDTH=1,URI=\"https://evil.test/i.m3u8\""}` | a new I-frame variant |
| `CustomTag{name: "#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"https://evil.test/k\"", value: None}` | a new session key |
| `CustomTag{name: "#EXT-X-MEDIA", …}` / `"#EXT-X-SESSION-DATA"` | a new rendition / session data |
| `CustomTag{name: "#EXT-X-ENDLIST"}` in a live Media Playlist | `end_list = true` (live stream ends) |
| DATERANGE `AttrPair{key: "END-DATE", value: "2030-01-01T00:00:00Z"}` | the range's real END-DATE |

Fix: a custom tag name must start with `#EXT`, contain only `[A-Z0-9-]` after `#EXT`, no `:`, and must not be a tag
the package knows; a client-attribute key must match `X-[A-Z0-9-]+`; an unquoted client value must be a
hexadecimal-sequence or decimal-floating-point. Gate: `redteam_p1_6_format_injection` (any of: format `Err`, or the
re-parse has the original shape).

## P2

| id | finding | evidence (input → behaviour) | spec | fix |
| --- | --- | --- | --- | --- |
| P2-1 | Variable Reference recognition | `{$undef}` with **no** EXT-X-DEFINE is accepted unexpanded (`attrs.pion:129`); `v.m3u8?q={$}` / `{$ x}` (not a reference) fail the playlist when a DEFINE exists (`:153-161`) | bis §6.3.1 "MUST trigger a parsing error"; §4.3 reference = `{$`Name`}` | always scan; treat a `{$` that is not `{$[A-Za-z0-9_-]+}` as text |
| P2-2 | substitution scope incomplete | `LANGUAGE="{$l}"` stays `{$l}`; same for ASSOC-LANGUAGE, INSTREAM-ID, CHARACTERISTICS, CHANNELS, DATA-ID, SESSION-DATA LANGUAGE, all DATERANGE values (ID, CLASS, dates, `X-*`), RECENTLY-REMOVED-DATERANGES, MAP/PART BYTERANGE, IV, SCTE35-* | bis §4.3: all quoted-string and hexadecimal-sequence values | substitute in one place for every quoted / hex value |
| P2-3 | IMPORT / QUERYPARAM | declarations accepted, every use fails as "undefined variable", no API to supply the Multivariant variables / query parameters; `#EXT-X-DEFINE:IMPORT=…` accepted in a Multivariant Playlist | bis §4.4.2.3 (IMPORT MUST NOT occur in Multivariant; unresolvable → MUST fail) | reject IMPORT in Multivariant; add `parse_playlist_with_context(vars, query)` or fail at declaration |
| P2-4 | round trip re-expands | DEFINE b=`evil`, a=`{$b}`, URI `{$a}.m3u8` → parsed `{$b}.m3u8`; `format_playlist` writes the DEFINEs **and** the expanded URI → re-parse gives `evil.m3u8` (or `InvalidVariable`) | bis §6.3.1 "replacements … NOT subject to variable substitution" | do not emit NAME/VALUE DEFINEs next to expanded values (or keep raw text) |
| P2-5 | formatter `Ok` for unparsable text | segment URI `#EXT-X-ENDLIST`, variant URI `#…`, empty URI after substitution (`{$e}` with `e=""`), `media_sequence = -5`, `duration_us = -1` → `Ok(text)` that `parse_playlist` rejects | – | validate every field the parser validates (URI must not start with `#` or be empty, integers ≥ 0) |
| P2-6 | positions lost by the formatter | unknown tags are stored per playlist and written after the last segment: `#EXT-X-CUE-OUT:30` / `#EXT-X-CUE-IN` (SCTE-35 ad markers) move to the end; a MAP that follows a KEY (so is encrypted by it) is written before the KEY | bis §4.4.4.4 (KEY applies to MAPs after it) | keep unknown tags per segment (m3u8-rs keeps `unknown_tags` per segment); write KEY before MAP |
| P2-7 | MUST-level cross-tag rules not validated (README: "strict specification validator") | accepted: rounded EXTINF > TARGETDURATION; duplicate ENDLIST / I-FRAMES-ONLY / INDEPENDENT-SEGMENTS / SKIP (silently last-wins); MEDIA-SEQUENCE / DISCONTINUITY-SEQUENCE after the first segment; AUDIO/VIDEO/SUBTITLES/CLOSED-CAPTIONS group without matching EXT-X-MEDIA; CLOSED-CAPTIONS=NONE on some variants only; duplicate NAME in a group; FORCED on non-SUBTITLES, INSTREAM-ID on non-CC, CHANNELS on non-AUDIO; EXT-X-PART without PART-INF, part > PART-TARGET; PART-INF without PART-HOLD-BACK (≥ 2 × PART-TARGET); CAN-SKIP-UNTIL < 6 TD, HOLD-BACK < 3 TD, CAN-SKIP-DATERANGES without CAN-SKIP-UNTIL; END-ON-NEXT=YES with DURATION/END-DATE. (`wasm_smoke`'s own LL-HLS playlist has CAN-SKIP-UNTIL=24 with TARGETDURATION 6.) | bis §4.4.2, §4.4.3, §4.4.3.1, §4.4.3.7-8, §4.4.4.9, §4.4.5.1-2, §4.4.6.1-2; §6.3.1 "Clients MUST ensure that loaded Playlists comply with Section 4" | post-parse validation pass |
| P2-8 | key / map value rules | `#EXT-X-KEY:METHOD=NONE,URI="k"` (or `IV`, `KEYFORMAT`) accepted (`attrs.pion:373-385`); `#EXT-X-MAP:…,BYTERANGE="720"` accepted (`parser.pion:645-652`) | bis §4.4.4.4 "other attributes MUST NOT be present"; §4.4.4.5 MAP offset is REQUIRED | reject |
| P2-9 | ISO 8601 zones | `#EXT-X-PROGRAM-DATE-TIME:2010-02-19T14:54:23.031` (no zone) and `…+0000` / `…+08` (basic / hour offsets) fail the **whole** playlist (`decimal.pion:375,386`) | bis §4.4.4.6: ISO/IEC 8601, zone SHOULD be present | accept them (store as given) |
| P2-10 | lexical / value-type rules | ESC, DEL, C1 and other control characters accepted (`parser.pion:1836` only rejects CR/NUL); CR without LF at EOF accepted (`:1823`); quoted enumerated / integer values accepted (`DEFAULT="YES"`, `END-ON-NEXT`, `SKIPPED-SEGMENTS="3"`, `HOLD-BACK="30"`, `PART DURATION`, `TYPE="PART"`, quoted SCTE35); unquoted client values that are neither hex nor decimal, `HDCP-LEVEL=A=B`, `FORMAT=a b` accepted although the formatter then refuses them | bis §4.1 (no control chars), §4.2 (types) | enforce quoting per type; reject control characters |
| P2-11 | EXT-X-PART implicit offset | `BYTERANGE="100@0"` then `BYTERANGE="100"` on the next part → `offset = None` (unlike segments) | bis §4.4.4.9 "begins at the next byte following the … previous Partial Segment" | resolve like segment byte ranges |
| P2-12 | parse results are not `Send` | `Playlist`, `MasterPlaylist`, `MediaPlaylist`, `MediaSegment`, `DateRange` fail a spawn-boundary probe (`E_NOT_SEND`, `pub struct` with `Array` fields, `types.pion:210-329`); README says "Send-safe"; AGENTS.md asks for immutable `Send` values | – | `val struct` / immutable arrays, or correct README |
| P2-13 | README claims | (a) wasm32 sizes: README 182,272 / 179,748 B, measured 182,232 / 179,728 B (toolchain `1e609a5`); (b) headline 1.71x / 284 MB/s comes from one synthetic corpus: on a second corpus (`diff/altbench.py`: long URLs, PDT per segment, key rotation, byte ranges) Pion is **1.15x** and uses **2× the peak RSS** of m3u8-rs (27 vs 14 MiB); (c) the "0 / 2,350 deviations" differential only covers 200 valid generated playlists and the Rust harness computes implicit byte-range offsets itself (`bench/rust_bench/src/main.rs`), so it does not compare m3u8-rs's semantics | AGENTS.md §1.3 (no favourable inputs only) | re-measure; document the second corpus (mention `altbench`) and the differential scope |

Re-run of the package's own benchmark (machine load ≈ 8-11): 1.63x-1.69x, 230-268 MB/s, stdout SHA-256
`79b0e9cd…` identical to README.md, so the headline numbers are real for that corpus (not skipped parsing: both
programs parse every playlist each iteration and their totals match).

## m3u8-rs 6.0.1 differential (informational)

On the 4,280 audit inputs: both parsers accept 1,813; equal on the shared field subset for 1,566. m3u8-rs accepts
2,341 inputs Pion rejects (the reference model rejects all of them except 5 P2-1 cases): m3u8-rs is not a
validator. Pion accepts 2 inputs m3u8-rs rejects (UTF-8 BOM). Differences where both accept are explained by
m3u8-rs: no variable substitution (142), silently drops an EXT-X-MEDIA with FORCED on a non-SUBTITLES rendition or a
STREAM-INF with `CODECS=""` (89), stores durations as `f32` (3), represents `METHOD=NONE` as no key (4), trims URI
whitespace (1), and treats a tag line after EXT-X-PART as a segment URI; plus 8 inputs where Pion's duration is
negative (P1-1). No m3u8-rs panic.

## Accepted design choices (not findings)

The model mirrors these documented behaviours: a UTF-8 BOM is skipped (bis: SHOULD fail) and invalid UTF-8 is not
checked (SHOULD); decimal-integers are limited to Int64 (spec allows up to 2^64-1); unknown METHOD / TYPE / PRELOAD
TYPE values fail the playlist instead of the tag being ignored (safer for keys); unrecognised HDCP-LEVEL tokens are
kept; DEFINE VALUEs are not themselves substituted (which makes exponential expansion impossible: bomb b02 with a
30-level doubling chain parses in 10 ms); tags between EXT-X-STREAM-INF and its URI are tolerated;
`TARGETDURATION:0`, `BANDWIDTH=0`, `RESOLUTION=0x0` are rejected; empty quoted strings are accepted;
EXT-X-BITRATE / EXT-X-CONTENT-STEERING are kept as unknown tags; `max_segments` (100,000) cannot be reached under
`max_lines` (200,000) because a segment needs two lines.

## Files

| file | purpose |
| --- | --- |
| `run_audit.sh` | the whole audit; sections `build static unit cases determinism oracles dos smoke bench inject` |
| `src/dump.pion`, `src/main.pion` | canonical dump and CLI (`dump`, `bomb`, `time`, `api`, `list`, `case`) |
| `src/cases.pion`, `redteam_test.pion`, `control_test.pion` | 18 red-team + 9 control cases (also run under `pionc test`) |
| `diff/model.py` | independent RFC 8216bis reference model |
| `diff/gen.py` | 260 named edge cases + seeded mutator (`FUZZ_N`, default 4,000) |
| `diff/compare.py` | 4-mode identity, model comparison with finding attribution, m3u8-rs comparison |
| `diff/rust/` | m3u8-rs 6.0.1 dumper (`Cargo.lock` pinned) |
| `diff/dos.py` | 18 DoS bombs with time / RSS budgets, native and wasm32 |
| `diff/inject.py` | 5 bug injections |
| `diff/readme.py`, `diff/altbench.py` | README.md claim parser, second benchmark corpus |
