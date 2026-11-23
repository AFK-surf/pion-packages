# Red-team audit: `packages/webvtt` v0.1.0

- Audited revision: `origin/feat/pkg-webvtt` @ `3a49f9a` (Red phase `fc2aac1`)
- Audit branch: `audit/pkg-webvtt`; deliverables live only in `packages/webvtt/audit/`. Nothing in `src/`, the
  package's own tests, benches or the repository root was modified.
- Reproduce everything: `sh packages/webvtt/audit/run_audit.sh` (`--no-bench` skips the timed benchmark).
  It exits non-zero while any finding below is open and prints one `GATE <id> PASS|FAIL` line per check.
  Whoever fixes the package must make it pass **without editing anything under `audit/`**.
- Reference semantics: W3C WebVTT, §6 "Parsing" (<https://www.w3.org/TR/webvtt1/>), and the upstream
  web-platform-tests WebVTT parsing suites vendored byte-for-byte in `audit/wpt/` (wpt `3e4b8e44`). The browser-mode
  entry point `parse_lenient` is held to the §6.1 algorithm; strict `parse` may reject more input, but must never
  silently drop a cue the algorithm produces.
- Platform of record: Darwin arm64 (Apple M5 Max), `pionc 0.1.0`, node 24, Go 1.27.

## Result at `3a49f9a`

| Gate | Result |
| --- | --- |
| Package's own `verify.sh` (fmt/check/13 tests) | PASS |
| Source hygiene: 0 `extern "C"`, 0 `World`, 0 module-level mutable state | PASS |
| `wasm_smoke` in 4 modes (native debug/release, wasm32 debug/release), identical stdout | PASS |
| WPT `file-parsing` (42 pages + 11 invalid signatures, `stylesheets` n/a) | **FAIL 43/52** |
| WPT `cue-text-parsing` (78 trees) | **FAIL 60/78** (plain_text/AST invariant: 0 violations) |
| WPT on wasm32: results byte-identical to native | PASS (same failures) |
| Red-team tests (`redteam_test.pion`): 16 `p1_`/`p2_` + 12 `ctl_` | **16 FAIL** / 12 controls PASS |
| F4 mutation probe, F5 stack probes, F17/F19 complexity gates, F16 dead variant | **FAIL** |
| Benchmark: SHA-256 identical, steady state >= 40 ms, >= 1.0x vs package's `go_ref` | PASS (1.11x) |

## Findings

Severity: **P0** memory unsafety / crash or data corruption on untrusted input with default settings (none found);
**P1** silent cue loss on plausible input, crash through the public API, broken documented complexity contract,
acceptance-process gap; **P2** conformance divergence, numeric precision, bounded DoS amplification, API hygiene.

### P1

#### F1 — STYLE / REGION / NOTE / unknown blocks swallow the next cue when no blank line follows (strict and lenient)

`src/parser.pion:661-704` (NOTE), `:705-743` (STYLE, `aborted` at `:724-726`, dropped at `:735`), `:744-849`
(REGION, `:767-769`, `:821`), `:859-884` (non-cue block without `-->` on line 2).

§6.1 "collect a WebVTT block": a line containing `-->` at line count >= 3 (or at line 2 once an arrow was seen) ends
the current block (`position = previous position; break`) and is re-read as the first line of the next block; the
STYLE/REGION collected so far is still returned. The package instead keeps consuming lines up to the next blank line,
discards the STYLE/REGION ("aborted") and every cue inside that range. This happens with the default strict `parse`
as well, with no error.

```
WEBVTT

STYLE
::cue { color: red }
00:01.000 --> 00:02.000
Hello
```
Spec/browsers: 1 style sheet + 1 cue "Hello". Package: 0 styles, 0 cues, `Ok`. Same for `REGION` + cue,
`NOTE …\n…\n<timing>` and two stray lines followed by a timing line.
Tests: `p1_f1_style_block_then_cue_without_blank_line`, `p1_f1_region_block_then_cue_without_blank_line`,
`p1_f1_note_and_garbage_blocks_do_not_swallow_following_cue`.
Note: the package's own test encodes the wrong behaviour (`webvtt_header_blocks_test.pion:96`, `:111-119` assert the
style is dropped and the cue lost); it must be corrected together with the fix. (By the same §6.1 rule a `-->` on
line 2 of a `NOTE`/`STYLE`/`REGION` block makes that block a cue whose id is the first line; not gated.)

#### F2 — `parse_lenient` loses every cue after an unparsable timing line up to the next blank line

`src/parser.pion:914-933`. §6.1: a failed timing line only nulls its own cue; the next `-->` line (line 2 with
"seen arrow") ends the block and starts a new cue. The package skips to the next blank line.
`WEBVTT\n\n00:01.000 --> xx\n00:02.000 --> 00:03.000\nHi\n` -> 0 cues (spec: 1). WPT `arrows.html`: 0 of 6 cues.
Test: `p1_f2_lenient_recovers_after_bad_timing_line`; gate `WPT-FP`.

#### F4 — mutating `WebVttTrack.cues` makes `active_cues_at` panic or return stale cues

`src/types.pion:200-208` (`pub struct` with a public mutable `Array[Cue]`), `src/timeline.pion:139-144` / `:175-180`
(bounds taken from `track.cues.length()` but the index arrays have the parse-time length), `:155`, `:192`
(only `end_ms` is re-checked, never `start_ms`). After `t.cues.push(c)`: `pion panic: index 2 out of bounds (len 2)`,
process abort (exit 134). After `t.cues[0] = cue_at_10s`: `active_cues_at(500)` returns that 10 s cue.
Fix options: make the cue list immutable (then `audit/mutation` no longer compiles, which `run_audit.sh` accepts as
fixed when `packages/webvtt` itself checks clean), or validate/rebuild the index. Gate `F4` (`audit/mutation/`).

#### F17 — `active_cue_indices_at` / `active_cues_at` are O(N) per query, not O(log N + K)

`src/timeline.pion:150-159`; claims in `README.md:17-19` and `src/types.pion:191`. The `prefix_max_end` scan walks
back until the prefix maximum end drops below `t`; a single early cue that lasts the whole video keeps that maximum
high, so every query scans all earlier cues. Correctness holds (brute-force fuzz `ctl_timeline_matches_bruteforce_fuzz`
never found a miss), the complexity does not:

| 100k cues, 20k queries | per query |
| --- | ---: |
| without a long cue | 0.06 us |
| plus one `00:00:00.000 --> end` banner cue | **376 us** (~6000x; 22 ms per 60 Hz frame budget of 16.7 ms) |

Fix: a real interval structure (centered interval tree, or segment/bucket index), or a per-block suffix of
`prefix_max_end` maxima. Gate `F17` (<= 20 us/query).

#### F18 — upstream conformance tests were not ported (AGENTS.md §1.1)

`webvtt_*_test.pion` are self-written (13 tests); the upstream WPT WebVTT parsing suites (131 cases) were not ported,
so the Red/Green cycle never exercised the spec algorithm and two package tests assert non-conformant behaviour
(F1 above; `webvtt_cues_settings_test.pion:163-166` asserts lenient mode drops inverted cues, see F3). The audit
vendors those suites and runs them on native and wasm32 (gates `WPT-FP`, `WPT-CT`, `WPT-WASM`):

| WPT failure | Finding |
| --- | --- |
| `arrows` (0/6 cues) | F2 |
| `timings-negative` (1/4), `timings-too-short` (0/2) | F3 |
| `nulls` (5/7), `text.dat#2` | F8 |
| `settings-line` (DBL_MAX parsed as 1.7976931348623145e308, 5e-324 as 0, out-of-range kept) | F9 |
| `whitespace-chars` (2/3), `header-regions` cue 10 | F10 |
| `regions-lines` (4294967295 -> 3) | F11 |
| `settings-align` cue 10 | F12 |
| `entities.dat` 12/25 | F6 |
| `tree-building.dat` #5-#7, #9, `tags.dat` #20 | F7 |

### P2

#### F3 — `parse_lenient` drops inverted cues and single-digit hours that the §6 algorithm keeps

`src/parser.pion:914` (`end_ms < start_ms` treated as invalid), `:289` (`first_digits < 2`). §6.3 never compares
start and end; the timestamp algorithm switches to hours for any first field that is not exactly two digits
(`0:00:00.000` valid). Browsers keep both (WPT `timings-negative`, `timings-too-short`). Strict mode may keep
rejecting them (README documents that); `parse_timestamp`'s own behaviour is left to the implementer.
Test `p2_f3_lenient_keeps_inverted_and_single_digit_hour_cues`.

#### F5 — `ParseLimits.max_tag_depth` is dead; payload trees can overflow the stack

`src/types.pion:32`/`:43` (field never read), `:187-189` and `src/payload.pion:189-191` (always 64),
`src/payload.pion:341-359` (`collect_nodes_text` recursion). `parse_with_limits(doc, {max_tag_depth: 2})` still
accepts depth-3 markup; `{max_tag_depth: 200}` still rejects depth 65 in `Cue::parse_payload`. With an explicit
large limit (`parse_cue_payload_with_limits(<b>×N, N+1)`), `nodes_to_plain_text` crashes: native SIGSEGV at
N = 200 000, wasm32 `RangeError: Maximum call stack size exceeded` already at N = 5 000 (the default 64 is safe).
Test `p2_f5_parse_limits_max_tag_depth_is_honoured`; gates `F5-NATIVE` (300 000 levels), `F5-WASM` (20 000 levels):
iterate instead of recursing, or cap the accepted limit.

#### F6 — only 6 named character references are decoded

`src/payload.pion:4-55`. §6.4 uses the HTML "consume a character reference" algorithm: all named references, the
legacy no-semicolon forms (`&amp`, `&not`), and numeric `&#32;`/`&#x20;`. `&quot;`, `&#39;`, `&copy;` (common in
converted subtitles) stay literal. WPT `entities.dat` 12/25 fail. Test `p2_f6_html_character_references`.

#### F7 — end tags close ancestors; `<rt>` opens outside `<ruby>`

`src/payload.pion:229-247` pops up to the nearest matching frame; §6.4 only closes the *current* node (otherwise the
end tag is ignored; `</ruby>` also closes a current `<rt>`). `<b><i>x</b></i>y` -> package `(b (i "x")) "y"`, spec
`(b (i "x") "y")`. `src/payload.pion:265-316`: `<rt>` creates a `RubyText` anywhere; spec only inside a current
`<ruby>`. Plain text is unaffected. Test `p2_f7_end_tag_and_rt_tree_building`.

#### F8 — U+0000 is not replaced by U+FFFD

`src/parser.pion:571-` (no preprocessing). §6.1 step 1 replaces every NUL. WPT `nulls.html`, `text.dat#2`.
Test `p2_f8_nul_replaced_by_u_fffd`.

#### F9 — decimal parsing is not correctly rounded and overflows to `inf`

`src/parser.pion:142-198` accumulates `digit * 0.1^k` and `int * 10`. `position:0.3%` -> `0.30000000000000004`,
`size:0.7%` -> `0.7000000000000001`, `line:9…9` (350 digits) -> `LineNumber(inf)` (spec: number error, setting
ignored), DBL_MAX -> `1.7976931348623145e308`, `5e-324` -> 0. Test
`p2_f9_decimal_parsing_is_correctly_rounded_and_range_checked`; WPT `settings-line`.

#### F10 — U+000C FORM FEED is not whitespace

`src/parser.pion:4-6` (`is_ws` = space/tab) is used for timing lines, cue settings and region settings; §6 uses ASCII
whitespace (TAB, LF, FF, CR, SPACE). A timing line separated by form feeds is rejected (strict: whole file error).
Test `p2_f10_form_feed_is_ascii_whitespace`; WPT `whitespace-chars`, `header-regions`.

#### F11 — region `lines` cannot hold the full unsigned range

`src/types.pion:114` (`lines : Int`), `src/parser.pion:116-139`. `lines:4294967295` (valid, VTTRegion.lines is
`unsigned long`) is silently replaced by the default 3. Test `p2_f11_region_lines_full_unsigned_range`.

#### F12 — `align:middle` is accepted

`src/parser.pion:432-434` maps `middle` to `Center`, so `align:end align:middle` yields `center` instead of `end`
(§6.3 only knows start/center/end/left/right). Test `p2_f12_align_middle_is_ignored`; WPT `settings-align`.

#### F13 — cue `region` is never resolved or nulled

`src/parser.pion:502-503`, `src/types.pion:141`. §6.3: `region:` takes the last region with that id or null, and
`vertical:rl|lr`, a non-auto `line:` or `size:` != 100 set it to null. The package always keeps the raw id, so a
consumer places explicitly positioned or unknown-region cues into a region. Test
`p2_f13_cue_region_resolution_and_nulling`.

#### F14 — active cues are not returned in "text track cue order"

`src/timeline.pion:18` (sort key = start only), `:160-169`. Documented as "in cue order"; HTML text track cue order
is start ascending, then end **descending**, then insertion. Cues with equal start come back in index order
regardless of their end (`[0,1000)` before `[0,5000)`; spec: the longer one first).
Test `p2_f14_active_cues_follow_text_track_cue_order`.

#### F15 — tag annotations: whitespace not collapsed, LF/FF do not end the tag name

`src/payload.pion:258-264`, `:280-283`, `:291-306`. `<v  Bob \t Smith >` -> voice `"Bob \t Smith"` (spec
`"Bob Smith"`); `<v\nBob>` -> unknown tag `v\nBob` (spec voice `Bob`). Test `p2_f15_annotation_whitespace`.

#### F16 — dead Red-phase variant `WebVttError::Unimplemented`

`src/types.pion:10`, `:21`: never produced after the Green phase, but part of the public API and every exhaustive
`match`. Gate `F16`.

#### F19 — REGION upsert is O(regions) per block (bounded DoS amplification)

`src/parser.pion:830-839` scans all regions for every REGION block; duplicates do not count against `max_regions`,
so 16 MB of duplicate-id blocks after 1000 regions parse in 1.38 s vs 0.059 s (x23). Gate `F19` (<= 5x).

#### F20 — benchmark baseline is a handicapped mirror, not an upstream implementation (informational)

`bench/go_bench/main.go` is a hand-written Go mirror of the Pion design, not an upstream parser, and pays costs the
Pion side does not: `strings.Split` of the whole input (`:141`), `strings.Split` + 4x `strconv.ParseInt` per
timestamp (`:50-99`), `strings.Fields` per cue (`:103`) and `strings.Join` per payload (`:286`), while skipping
numeric `line`/`position`/anchor parsing that Pion does (`:113-116`, `:214-234`). The corpus is fully sorted (the
sort path is never timed), has no adversarial timeline and never parses payload trees.
`audit/bench/go_tuned/` keeps go_ref's rules and output (same SHA-256) but uses zero-copy line offsets and payloads,
hand-rolled fixed-width timestamps and manual tokenisation, and additionally parses line/position/anchors like Pion:

| 20x 8000 cues (27.5 MB), warmup 2, 9 rounds | median | min | p95 | peak RSS | vs go_ref |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` | 97.8 ms | 94.0 ms | 108.8 ms | 6.45 MiB | 1.11x |
| `go_ref` (package bench) | 108.8 ms | 104.2 ms | 113.3 ms | 16.1 MiB | 1.00x |
| `go_tuned` (audit) | 94.9 ms | 90.5 ms | 101.6 ms | 18.0 MiB | 1.15x |

Pion is at 0.97x of the tuned mirror (other runs on the same machine: 0.92x-1.03x): the claimed 1.11x lead comes from
the baseline's allocation idioms. The package passes its own gates (identical SHA-256, 97.8 ms >= 40 ms, >= 1.0x vs
`go_ref`); `BENCHMARKS.md` should state the go_tuned comparison and the timeline worst case (F17) honestly.

## Probed and found correct (controls, all PASS)

- Signature: empty, BOM only, `WEBVTTX`, `WEBVTT-`, two BOMs, lower case, `WEBVTT\tTitle`, lone `\r`, mixed
  `\r`/`\r\n`/`\n` normalisation (`ctl_signature_edges`; WPT signature-* pass).
- `NOTES` is a cue id, `NOTE\t…` inline, bare `NOTE` (`ctl_note_variants`); STYLE/REGION after the first cue ignored.
- Malformed REGION parameters (`lines:-1`, `lines:1.5`, `width:150%`, `width:-1%`, `scroll:down`, anchors > 100% or
  without comma) keep defaults; duplicate id: last wins (`ctl_region_malformed_parameters_keep_defaults`).
- Timestamps: minutes/seconds = 60, 2/4-digit ms, `000:00.000`, signs, surrounding whitespace, trailing garbage,
  hours beyond `Int64` (`99999999999999999999:…`, `2562047788016:…`) rejected without overflow; 2.5M hours exact;
  `format_timestamp` of negative clamps (`ctl_timestamp_edges`). Zero-duration cues, `-->` without spaces, header and
  cues without blank lines (`ctl_timing_lines_strict_and_lenient`).
- Cue settings: all valid values, signed line numbers, invalid line forms (`1.`, `.5`, `--`, `1-2`), bad alignments,
  case sensitivity, empty keys/values, duplicate keys (last valid wins); `position:9…9%` (350 digits) rejected by the
  0..100 range (`ctl_cue_settings_values`).
- Payload: unclosed `<` (rest dropped, as §6.4 tag state to EOF), `<c.a<b>`, unknown tags, annotation entities,
  truncated/unknown entities, CJK/emoji, inline timestamp tags, auto-close (`ctl_payload_hostile_markup`); 4000
  random markup strings: `plain_text == nodes_to_plain_text(parse_payload)` always (`ctl_plain_text_matches_ast_fuzz`).
- 5000-deep `<b>` bomb -> `LimitExceeded` with the default limit, `plain_text` linear; negative `ParseLimits`
  (`max_input_bytes`, `max_cues`, `max_notes`, `max_tag_depth = -1`) fail closed.
- 16 MB adversarial payloads (`<`×N, `&am`×N, `<c.....>`, 63 open + 4M unmatched close tags, `<i>a</b>`×N) all
  parse in <= 0.22 s (linear).
- Timeline: 60 random unsorted tracks with long and zero-length cues, 80 queries each incl. `t < 0`, `t == start`,
  `t == end`, `Int64::max`: index sets equal brute force (`ctl_timeline_matches_bruteforce_fuzz`).
- wasm32: the full WPT run on wasm32 is byte-identical to native; `wasm_smoke` passes in 4 modes.

## Other divergences (not gated)

- `LineAlign::Auto` is reported where VTTCue's default is `start` (the WPT runner maps it).
- Duplicate REGION ids replace in place; §6.1 appends (cue lookup is identical, `regions` order differs); a REGION
  without `id` is dropped (spec keeps an unreferenceable region).
- `00:01.000 --> 00:02.000align:start` (settings glued to the end timestamp) is rejected; §6.3 accepts it.

## Layout of `audit/`

| Path | Purpose |
| --- | --- |
| `run_audit.sh` | one-shot runner, all gates |
| `redteam_test.pion`, `pion.toml` | `p1_*`/`p2_*` defect tests + `ctl_*` controls (package `webvtt_audit`) |
| `probe/` | driver: VTTCue-shaped JSON, WPT tree serialisation, timing/stack probes |
| `mutation/` | F4 probe (separate package so an immutability fix cannot break the test build) |
| `wpt/` | vendored WPT suites + runners (`README.md`, `LICENSE.md`) |
| `bench/go_tuned/` | F20 tuned Go baseline |
