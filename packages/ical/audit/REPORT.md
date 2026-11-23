# RT-ical — red-team audit of `packages/ical` @ `df1908b`

Scope: `packages/ical/src/**` (parser, serializer, types, rrule, rruleset, vtimezone) on
`origin/feat/pkg-ical` `df1908b`. Nothing outside `packages/ical/audit/**` was modified.

References used for differential evidence:

| Reference | Version | Role |
| --- | --- | --- |
| python-dateutil `rrule` | 3.0.0 | RRULE semantics (de-facto reference) |
| Rust `rrule` | 0.14.0 (`=0.14.0`) | RRULE semantics, validation |
| python `icalendar` | 6.3.2 | serializer / line-splitting behaviour |
| RFC 5545 / 6868 | — | normative text |

Reproduce everything: `sh packages/ical/audit/run_audit.sh` (steps: `tests`, `diff`, `wasm`, `dos`).
All artifacts land in `/tmp/rt-ical-*`; the worktree stays clean.

## Summary

| Class | Count | Unit tests (`redteam_test.pion`) |
| --- | ---: | --- |
| **P0** silent wrong results on mainstream inputs | **2 defects** | 4 tests, 4 FAIL |
| **P1** wrong results / injection / DoS on realistic inputs | **8 defects** | 12 tests, 12 FAIL (P1-1…P1-6) + 2 DoS defects (P1-7, P1-8) measured by `dos.sh` |
| **P2** validation gaps, interop divergence, robustness | **9 defects** | 8 tests, 8 FAIL (+1 diff-only) |
| **Control / fairness** | — | 14 tests, 14 PASS |

`pionc test --json packages/ical/audit`: 321 total = 283 deps PASS (`time` 262 + `ical` 21, unchanged)
+ 24 findings FAIL + 14 controls PASS. `pionc test packages/ical`: 21/21 still PASS.
`pionc fmt --check` clean for `audit/` and `audit/driver/`.

Three-way RRULE differential (4,000 deterministic rules, seed 5545, 8 attack categories):

| class | rules | % |
| --- | ---: | ---: |
| agree (Pion == dateutil == Rust, byte-identical) | 3017 | 75.4 |
| **consensus_diff** (dateutil == Rust ≠ Pion) | **545** | **13.6** |
| Pion OK, both references reject | 1 | 0.0 |
| Pion ERR, both references expand | 0 | 0.0 |
| ref_split (dateutil ≠ Rust; not counted against Pion) | 437 | 10.9 |

(dateutil gets a 3 s per-rule budget; 26 rules hit `TIMEOUT` in the recorded run. Rules close to the
budget can flip between `TIMEOUT` and a result under machine load, which moves a handful of rules
between `ref_split` and `agree`; the Pion and Rust columns are fully deterministic.)

Root causes of the 545 consensus diffs:

| Root cause | Rules | Finding |
| --- | ---: | --- |
| RC1 `YEARLY`+`BYMONTHDAY` without `BYMONTH` not expanded to every month | 182 | P0-2 |
| RC2 `BYDAY` ordinal dropped when combined with `BYMONTHDAY`/`BYYEARDAY` | 180 | P1-1 |
| RC4 `YEARLY`+`BYWEEKNO`: days of boundary weeks assigned to week-year, not calendar year | 149 | P2-9 (divergence) |
| RC5 `WEEKLY`+`BYSETPOS` first week: dateutil/Rust truncate the first week, Pion uses the full RFC week | 18 | Fairness F-6 (Pion is RFC-correct) |
| RC3 `SECONDLY`/`MINUTELY` premature exhaustion | 14 | P1-2 |
| RC9 `WEEKLY`+`BYMONTHDAY` without `BYDAY` (RFC: N/A combination) | 2 | P2-8 |

Per category (agree / consensus_diff / ref_split): A `YEARLY BYWEEKNO` 351/149/0 · B `YEARLY BYDAY nth`
315/0/84 · C `MONTHLY BYMONTHDAY+BYDAY` 333/167/0 · D `WEEKLY INTERVAL WKST` **500/0/0** · E `BYSETPOS`
372/17/111 · F sub-daily 303/14/183 · G `YEARLY` expand 147/153/0 · H random 696/45/59.

4-mode determinism (native debug / native release / wasm32 debug / wasm32 release, clean
`PION_CACHE_DIR`) over the same 4,000-rule corpus: all four stdout SHA-256 identical
`04ca15b2287be7bbdd7cb119f1bc134990260f4ec4bb31cfcf1dd41ecce30937`. Determinism is fine — the
semantics are what is wrong.

---

## P0

### P0-1 `UNTIL=…Z` compared against local wall-clock time (UTC UNTIL ignored for zoned sets)
`src/rrule.pion:11,286` stores `until_is_utc`, but `RRuleIter::refill` (`src/rrule.pion:1313-1327`)
compares every civil candidate with the civil `until` directly; `RRuleSet` then resolves the candidate
in the set's zone. RFC 5545 §3.3.10 *requires* `UNTIL` in UTC whenever `DTSTART` has a `TZID`, so
**every** bounded recurring event exported by Google/Outlook/Apple in a non-UTC zone hits this.
The error equals the zone offset: UTC−x zones gain a spurious last instance, UTC+x zones lose the last one.

| Test | Input | Expected | Pion |
| --- | --- | --- | --- |
| `p0_utc_until_compared_as_local_wallclock_extra_occurrence` | `DTSTART;TZID=America/New_York:20250101T090000`, `FREQ=DAILY;UNTIL=20250103T120000Z` | 2 (Jan 3 09:00 EST = 14:00Z > UNTIL) | 3 |
| `p0_utc_until_compared_as_local_wallclock_missing_occurrence` | `DTSTART;TZID=Asia/Tokyo:20250101T090000`, `UNTIL=20250103T060000Z` | 3 (Jan 3 09:00 JST = 00:00Z) | 2 |

Control `control_utc_until_in_utc_set` PASSES — the bug is invisible in UTC-only test suites and in
the W3 benchmark (all UTC), which is why it survived.

### P0-2 `FREQ=YEARLY;BYMONTHDAY=…` (no `BYMONTH`) only looks at DTSTART's month
`yearly_candidate_days` (`src/rrule.pion:808-820`) uses `dtstart.date.month` instead of expanding over
all 12 months (RFC 5545 §3.3.10 table: `BYMONTHDAY` is *Expand* for `YEARLY`; dateutil and Rust agree).
182 / 4,000 differential rules.

| Test | Rule | Expected | Pion |
| --- | --- | --- | --- |
| `p0_yearly_bymonthday_without_bymonth_not_expanded` | `FREQ=YEARLY;BYMONTHDAY=1;COUNT=4` from 2025-01-01 | Jan 1, Feb 1, Mar 1, Apr 1 2025 | Jan 1 2025/26/27/28 |
| `p0_yearly_bymonthday_31_from_september_yields_nothing` | `FREQ=YEARLY;BYMONTHDAY=31;COUNT=3` from 2002-09-09 | Oct 31, Dec 31, Jan 31 | **empty** |

Same path also breaks `YEARLY;BYMONTHDAY=-1;BYDAY=TH` (Pion: only January end-of-month Thursdays).

## P1

### P1-1 `BYDAY` ordinals silently dropped next to `BYMONTHDAY`
`monthly_candidate_days` (`src/rrule.pion:906,917`) and `yearly_candidate_days` (`:836,863`) build
candidates from `BYMONTHDAY` and then filter with `byday_contains_wd`, which ignores `NWeekday.n`.
`1MO ∩ BYMONTHDAY=1..14` therefore means "every Monday in 1..14". 180 / 4,000 rules.
Tests: `p1_monthly_bymonthday_with_byday_ordinal_drops_ordinal` (expected Jan 6, Feb 3, Mar 3, Apr 7;
Pion Jan 6, Jan 13, Feb 3, Feb 10), `p1_monthly_bymonthday15_byday_minus2tu_drops_ordinal` (expected
empty; Pion 5 instances).

### P1-2 Sub-daily iterators declare the series finished after 200,000 empty periods
`RRuleIter::refill` (`src/rrule.pion:1089-1095`) gives every non-day frequency `max_empty = 200000`
periods — ≈2.3 days for `SECONDLY`, ≈139 days for `MINUTELY` — then sets `done = true`. Valid future
instances vanish (returns empty, no error). dateutil and Rust both find them.
Tests: `p1_secondly_bymonth_premature_exhaustion` (`FREQ=SECONDLY;BYMONTH=2;COUNT=1` from 2025-03-01 →
2026-02-01T00:00:00; Pion empty), `p1_secondly_bymonthday_premature_exhaustion`,
`p1_minutely_bymonth_premature_exhaustion`. 14 differential rules.

### P1-3 `RRuleSet::from_component` discards `Z` / `TZID` of DTSTART, EXDATE, RDATE
`src/rruleset.pion:83` and `parse_datetime_csv` call `ical_datetime_to_datetime`, which strips the UTC
designator, and everything is re-resolved as wall-clock time in the caller's zone. A UTC `EXDATE` (what
Outlook and many CalDAV servers emit for cancelled instances) never matches → the cancelled meeting
re-appears; a UTC `DTSTART` is shifted by the zone offset.
Tests: `p1_from_component_utc_exdate_never_matches`, `p1_from_component_utc_dtstart_reinterpreted_as_local`
(DTSTART `20250101T140000Z` with NY zone → Pion yields 14:00 EST = 19:00Z).

### P1-4 DST gap: `RRuleSet` emits duplicated, non-ascending instants and leaks EXDATEs
The per-rule iterator is monotone in wall-clock time, not in instants. With `FREQ=MINUTELY;INTERVAL=30`
from 2025-03-09 01:00 America/New_York, wall times 02:00/02:30 (nonexistent) resolve to 07:00Z/07:30Z
and 03:00/03:30 EDT resolve to 07:00Z/07:30Z again. The k-way merger (`RRuleSetMerger::next`,
`src/rruleset.pion:380-430`) only de-duplicates against the last emitted instant and advances the
exclusion cursors monotonically, so:
- `p1_dst_gap_rruleset_non_monotonic_duplicate_instants`: occ[4] = 1741503600 (07:00Z) after occ[3] =
  1741505400 (07:30Z) — violates the documented "ascending instant order / deduplication".
- `p1_dst_gap_exdate_bypassed_by_second_copy`: `EXDATE 03:00 EDT` removes the first 07:00Z copy, the
  second copy is emitted.
`between()` also stops at the first instant past `before`, so later in-window instants can be lost.

### P1-5 `VTimeZone::offset_at` returns the post-transition offset for nonexistent local times
RFC 5545 §3.3.5: a nonexistent local time is interpreted with the offset *before* the gap.
`offset_at(2025-03-09 02:30)` returns −04:00 → 06:30Z, an instant at which New York was still on −05:00.
Test `p1_vtimezone_offset_at_nonexistent_local_time`. (Fold side is correct — see F-9.)

### P1-6 Serializer CRLF/LF injection through property values
`write_property_to` (`src/serializer.pion:146-176`) writes `prop.value` verbatim; folding does not
touch embedded CR/LF. Any user-controlled text that reaches a `Property` value becomes new content
lines on `to_ical()` and is re-parsed as real properties / components:
- `p1_serializer_crlf_injection_in_property_value`: `SUMMARY = "Lunch\r\nATTENDEE:mailto:attacker@…"` →
  the round-tripped event has an attacker `ATTENDEE` (invitation hijack / data exfil to attacker address).
- `p1_serializer_lf_injection_forges_valarm_component`: a bare `\n` in `DESCRIPTION` forges a whole
  `BEGIN:VALARM … ACTION:EMAIL … END:VALARM` sub-component.
python `icalendar` 6.3.2 serialises the same input as `SUMMARY:Lunch\nATTENDEE:mailto:evil` (escaped).
`escape_text` exists and is safe (control F-3) but nothing forces its use and the serializer does not
refuse raw CTLs (RFC 5545 §3.1 grammar forbids CTL in `VALUE`). Parameter values are correctly escaped
(control F-2).

### P1-7 DoS: per-period candidate materialisation (timeset × dayset), 4 GiB for a 300-byte RRULE
`RRuleIter::refill` builds the *entire* period (`days × BYHOUR × BYMINUTE × BYSECOND` `DateTime`s) in
`period_cands` before returning even one instance, regardless of `BYSETPOS`/`COUNT`.
`dos.sh` D1 (macOS arm64, `/usr/bin/time -l`):

| Rule (COUNT=1) | Pion | Rust rrule | dateutil |
| --- | --- | --- | --- |
| D1a `YEARLY;BYDAY=<all>;BYHOUR=0..23;BYMINUTE=0..59;BYSECOND=0..59` | 1.29 s, **4,107 MiB** | 0.01 s, 8.6 MiB | 0.05 s, 15.4 MiB |
| D1b same, `MONTHLY` | 0.11 s, 354 MiB | 0.00 s, 8.6 MiB | 0.04 s, 15.3 MiB |
| D1c D1a + `BYSETPOS=1` | 0.97 s, 3,624 MiB | 0.00 s, 8.6 MiB | 0.04 s, 15.4 MiB |

On **wasm32 release** D1a aborts the instance: `RangeError: WebAssembly.Memory.grow(): Unable to grow
instance memory` (`run_audit.sh wasm`). Any service expanding untrusted `.ics` RRULEs can be crashed
by one line.

### P1-8 DoS: `VTimeZone::offset_at` re-expands each observance RRULE from its DTSTART on every call
`offset_at` (`src/vtimezone.pion:183`) calls `RRule::before(obs.dtstart, dt)` — linear in the number of
recurrences since the observance start — with no frequency or horizon guard. An attacker-supplied
202-byte `VTIMEZONE` with `RRULE:FREQ=SECONDLY` (D3):

| Observance DTSTART | `offset_at(2025-06-01)` |
| --- | --- |
| 2025-01-01 | 1.02 s |
| 2020-01-01 | **15.4 s** (≈2.6 h for the common `16010101` Microsoft DTSTART) |

Normal Microsoft-style `16010101 … FREQ=YEARLY` costs < 1 ms, so legitimate files are fine.

## P2

| # | Finding | Evidence |
| --- | --- | --- |
| P2-1 | Property / parameter / component **names** emitted unvalidated (CR/LF/`:` allowed) → line injection | `p2_serializer_unvalidated_names_allow_injection` |
| P2-2 | Parser treats a **bare CR** as a line break (RFC: CRLF only); python `icalendar` keeps `a\rATTENDEE:…` inside SUMMARY → parser differential / smuggling | `p2_parser_bare_cr_is_treated_as_line_break` |
| P2-3 | `BYSECOND=60` clamped to 59 after dedup → duplicate occurrences (dateutil & Rust reject the rule) | `p2_bysecond_60_emits_duplicate_occurrences` |
| P2-4 | `BYWEEKNO` with non-`YEARLY` FREQ accepted and silently ignored (RFC MUST NOT; Rust rejects; dateutil filters) | `p2_byweekno_with_non_yearly_freq_silently_ignored` |
| P2-5 | Duplicate rule parts accepted, last wins (RFC MUST NOT; Rust rejects) | `p2_duplicate_rule_part_accepted_last_wins` |
| P2-6 | 9-digit integer cap rejects `COUNT=2147483647`, `INTERVAL=1000000` (both references accept) | `p2_count_int32_max_rejected` |
| P2-7 | `UNTIL=<DATE>` round-trips as `UNTIL=<DATE>T235959` (value type changes, breaks all-day events) | `p2_until_date_roundtrip_changes_value_type` |
| P2-8 | `RDATE;VALUE=PERIOD` (RFC §3.8.5.2) fails the whole `from_component`; `WEEKLY;BYMONTHDAY` (RFC N/A) keeps only DTSTART's weekday where dateutil uses all days (2 diff rules) | `p2_rdate_value_period_rejects_whole_event`, diff RC9 |
| P2-9 | `YEARLY`+`BYWEEKNO` boundary weeks: Pion emits days of week N in the *week-year's* period (e.g. 2010-01-02 for `BYWEEKNO=52;BYDAY=SA;WKST=SU` from 2008-12-28), dateutil/Rust restrict to the calendar year. RFC is ambiguous; this is an **interop divergence** (149 rules, mostly with `INTERVAL>1`/`COUNT`), not a proven bug | diff RC4 |

Also noted (not counted): `BYDAY` ordinals such as `-53WE` are accepted with `BYMONTH` (Rust rejects,
dateutil rejects 1 such rule); `DTSTART` is not force-included as the first instance (matches dateutil
and Rust); VTIMEZONE cannot be turned into a `time::TimeZone` for `RRuleSet`, so embedded VTIMEZONEs are
only usable through `offset_at` (feature gap, Rust `rrule` has none either).

## Fairness — what Pion gets right (all `control_*` PASS)

| # | Control | Note |
| --- | --- | --- |
| F-1 | `control_count_and_until_rejected` | RFC MUST NOT enforced; dateutil 3.0.0 and Rust 0.14.0 both accept COUNT+UNTIL |
| F-2 | `control_rfc6868_param_crlf_quote_caret_roundtrip_no_injection` | `^n`/`^'`/`^^` round-trip, CRLF in parameter values cannot inject |
| F-3 | `control_escape_text_neutralises_crlf` | the TEXT escaping helpers are correct |
| F-4 | `control_fold_4byte_emoji_every_alignment` | 75-octet folding never splits UTF-8 at 20 alignments, unfold∘fold = id |
| F-5 | `control_nesting_bomb_and_unmatched_end_rejected` | depth limit + END matching |
| F-6 | `control_weekly_bysetpos_uses_full_week_rfc` | BYSETPOS over the full WKST week; dateutil/Rust truncate the first week (18 diff rules where Pion is the RFC-faithful one) |
| F-7 | `control_minutely_interval_grid_alignment_beats_rust` | Pion == dateutil, Rust emits off-grid `01:03:15` |
| F-8 | `control_unsatisfiable_subdaily_grid_beats_rust` | provably empty 90-min grid: Pion empty, dateutil raises, Rust emits 10 bogus instants |
| F-9 | `control_dst_fold_picks_first_occurrence`, `control_dst_gap_daily_shift_forward` | Fold → first occurrence, gap → +1 h, both in RRuleSet and VTimeZone |
| F-10 | `control_unsatisfiable_rules_terminate`, `control_yearly_nth_weekday_of_year`, `control_weekly_interval_wkst_rfc_example` | `DAILY;BYMONTH=2;BYMONTHDAY=30` returns in < 10 ms (dateutil 2.7 s; `SECONDLY` variant dateutil > 3 s timeout); `20MO`/`-1SU`; WEEKLY+INTERVAL+WKST 500/500 agree |

Other positives: 0 rules where Pion errors while both references expand; 4-mode byte-identical output;
parser is linear (D4: 0.5 MB → 8 MB, 2k → 32k events, 0.00 s → 0.06 s, RSS 4 → 38 MiB). In the
`ref_split` bucket Pion sides with dateutil 249× and with Rust 129×.

## Benchmark fairness (README W1–W3)

The numbers are reproducible and SHA-checked, but the workloads are not representative of the
failure surface found here:
1. **Corpus selection**: W2 is 8 hand-picked rules repeated 10× (`bench/gen_corpus.py:49-61`); W3 is
   one rule pair repeated 200×. None of RC1/RC2/RC3 or P0-1 appear — they *could not*, because the
   SHA-256 gate would fail. "1.37× faster" is measured only on the subset Pion gets right.
2. **All UTC**: every W2/W3 DTSTART/RDATE/EXDATE is `…Z` with a UTC set, so DST resolution, zoned
   `UNTIL` and the P0-1 cost of a correct UTC comparison are never exercised.
3. **Work asymmetry in W1**: Pion keeps values raw and the bench unescapes only SUMMARY/DESCRIPTION;
   Rust `icalendar` parses every property into its typed model. A fair W1 would either unescape all
   TEXT values or compare against Rust's raw-line parser.
4. **Process-level timing**: medians include process start-up (~1–2 ms) and file read; fine for
   ratios ≥ 1.3× but the W2 gap (27 ms vs 37 ms) is within 2× start-up variance across machines.
5. **Missing worst-case rows**: no sub-daily rule, no large timeset, no `between()` far in the future,
   no `VTIMEZONE` evaluation — exactly where P1-2/P1-7/P1-8 show orders-of-magnitude regressions
   (D1a: 4,107 MiB vs 8.6 MiB).

## Files

| File | Purpose |
| --- | --- |
| `pion.toml`, `redteam_test.pion` | audit package: 24 findings (FAIL) + 14 controls (PASS) |
| `driver/` | Pion CLI used by diff / 4-mode / DoS (`rrule`, `time`, `ics`, `vtz` modes) |
| `rust_ref/` | Rust `rrule =0.14.0` reference expander (built in `/tmp`) |
| `diff/gen_rules.py` | deterministic 4,000-rule corpus (8 attack categories) |
| `diff/ref_dateutil.py` | python-dateutil reference (3 s per-rule timeout) |
| `diff/compare.py` | three-way classifier + root-cause buckets |
| `diff/summarize_tests.py` | `pionc test --json` → p0/p1/p2/control tallies |
| `dos.sh` | D1–D4 DoS / complexity probes |
| `run_audit.sh` | one-shot runner (`tests`, `diff`, `wasm`, `dos`, `all`) |
