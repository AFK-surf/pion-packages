# `ical`

Pure Pion implementation of **RFC 5545** (iCalendar), **RFC 5546** (iTIP), **RFC 6868** (Parameter Value Encoding), and **RFC 7529** (`RSCALE`/`SKIP` RRULE extensions) — parser, canonical serializer, `VTIMEZONE` observance resolver, and streaming `RRULE` / `RRuleSet` recurrence expansion engine.

Built directly on `packages/time` (`Date`, `DateTime`, `Timestamp`, `TimeZone`, `Zoned`, `Disambiguation`), with **zero C dependencies**, **no `World`**, and full **Native + Wasm32** support.

## Features

- **Content-Line Lexer & Component Parser (`Calendar::parse` / `Calendar::parse_with_limits`)**
  - Streaming RFC 5545 §3.1 line unfolding (`CRLF`/`LF` + `SP`/`HTAB`) with zero extra full-input copy.
  - Quoted parameter values, multi-value parameters (`MEMBER="a","b"`), case-insensitive property/parameter normalization, and **RFC 6868** parameter unescaping (`^n`, `^'`, `^^`).
  - RFC 5545 §3.3.11 TEXT escaping/unescaping (`\n`/`\N`, `\,`, `\;`, `\\`).
  - Arbitrary component trees (`VCALENDAR`, `VEVENT`, `VTODO`, `VJOURNAL`, `VALARM`, `VTIMEZONE`, `STANDARD`, `DAYLIGHT`, `VFREEBUSY`, `X-*`).
  - Hardened `ParseLimits` (`max_depth`, `max_lines`, `max_components`, `max_properties_per_component`, `max_line_bytes`) to prevent nesting and memory DoS bombs.
- **Canonical Serializer (`Calendar::to_ical`, `fold_line`)**
  - CRLF (`\r\n`) output with RFC 6868 parameter quoting/escaping.
  - **75-octet UTF-8-safe line folding** that never splits multi-byte UTF-8 sequences (CJK, 4-byte emoji).
- **RRULE & RRuleSet Engine (`RRule`, `RRuleIter`, `RRuleSet`)**
  - All 7 RFC 5545 frequencies: `YEARLY`, `MONTHLY`, `WEEKLY`, `DAILY`, `HOURLY`, `MINUTELY`, `SECONDLY`.
  - Full support for `INTERVAL`, `COUNT`, `UNTIL`, `WKST`, `BYSETPOS`, `BYMONTH`, `BYMONTHDAY` (positive & negative), `BYYEARDAY` (positive & negative), `BYWEEKNO` (ISO/WKST-relative, positive & negative), `BYDAY` (with positive & negative ordinals like `2MO`, `-1FR`, `20MO`), `BYHOUR`, `BYMINUTE`, `BYSECOND`, and RFC 7529 `RSCALE`/`SKIP` parsing.
  - Leap-year Feb 29 handling (including century non-leap years like 2100) and month-end 31st skipping.
  - Streaming `RRuleIter` plus `all(limit)`, `between(after, before, inclusive)`, `after(dt, inclusive)`, and `before(dt, inclusive)`.
  - Built-in **unsatisfiable RRULE DoS guard**: impossible rules such as `FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30` terminate safely without looping.
  - `RRuleSet`: streaming k-way merge of multiple `RRULE`s + `RDATE`s with deduplication, `EXDATE`/`EXRULE` exclusion, `RRuleSet::from_component`, and `time::TimeZone` **DST gap/fold disambiguation** (`Disambiguation::Compatible` per RFC 5545 §3.3.5).
- **`VTIMEZONE` Observance Model (`VTimeZone`, `parse_utc_offset`)**
  - Parses `STANDARD` / `DAYLIGHT` observances with `DTSTART`, `TZOFFSETFROM`, `TZOFFSETTO`, `RRULE`, `RDATE` and resolves active UTC offsets via `VTimeZone::offset_at`.

## Quick Start

```pion
import "ical"
import "time"

fn example() -> Result[Unit, ical::IcalError] {
  // 1. Parse an iCalendar stream and roundtrip-serialize with 75-octet UTF-8 folding
  let cal = match ical::Calendar::parse(ics_text) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  let canonical = cal.to_ical()

  // 2. Expand a complex RRULE (2nd-to-last weekday of each month)
  let rule = match ical::RRule::parse("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2;COUNT=6") {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  let start = time::DateTime::new(2025, 1, 1, 9, 0, 0, 0) // unwrap in real code
  let dates = rule.all(start, 100)

  // 3. Timezone-aware RRuleSet with DST spring-forward gap & fall-back fold handling
  let ny = time::TimeZone::posix("EST5EDT,M3.2.0,M11.1.0")
  let rset = ical::RRuleSet::from_component(cal.events()[0], ny)
  Ok(())
}
```

## Verification

- **Unit & compliance tests**: `sh scripts/verify.sh packages/ical` — **23/23 `ical` tests** (285/285 including `time`) covering RFC 5545 §3.8.5.3 official examples, `rrule.js`/`dateutil` edge cases, RFC 6868, UTF-8 3-byte/4-byte folding, DST gaps/folds, `VTIMEZONE`, security/injection regressions, and DoS limits.
- **Red-team audit suite (`packages/ical/audit`)**:
  - **38/38 PASS (0 FAIL)** — all 24 red-team defect tests (2 P0 / 4 tests, 6 P1 / 12 tests, 8 P2 / 8 tests) + 14/14 fairness control tests pass.
  - **4,000-rule three-way differential** (`python-dateutil 3.0.0` + Rust `rrule 0.14.0`, seed 5545): `agree` improved from **3,017 (75.4%) → 3,505 (87.6%)**; `consensus_diff` dropped from **545 (13.6%) → 54 (1.4%)**, with **0** remaining real bugs (the 54 diffs are 17 RFC-faithful `WEEKLY+BYSETPOS` full-first-week rules where `dateutil`/Rust truncate the first week, plus 37 `YEARLY+BYWEEKNO` boundary rules caused by `dateutil`'s `self.yearlen` typo in `lnumweeks` copied by Rust `rrule`).
  - **DoS cliff remediation (`packages/ical/audit/dos.sh`)**:
    - `D1a` (`YEARLY` full timeset `COUNT=1`): **4,107 MiB / 1.29s → 2.8 MiB / 0.01s** (**1,467× RSS reduction**; Wasm32 `--release` exits `0` instead of OOM crash).
    - `D1b` (`MONTHLY` full timeset `COUNT=1`): **354 MiB / 0.11s → 2.8 MiB / 0.00s**.
    - `D1c` (`YEARLY` full timeset + `BYSETPOS=1`): **3,624 MiB / 0.97s → 2.8 MiB / 0.00s**.
    - `D2a`–`D2c` (unsatisfiable / sparse sub-daily rules): **0.00s / 1.9 MiB** (`dateutil` times out at 3.17s on `D2a`).
    - `D3` (`VTIMEZONE` `FREQ=SECONDLY` 5-year `offset_at` DoS): **15.4s → 0.00s / 1.9 MiB**.
  - **4-mode determinism** (`run_audit.sh wasm`, 4,000-rule corpus, clean `PION_CACHE_DIR`): all 4 modes identical SHA-256 `5bc10b0aae0075378b0eb9258210825cf56a0334d2c916790a869d0f490d31af`.
- **4-Mode `wasm_smoke`** (Native debug, Native release, Wasm32 debug, Wasm32 release) with clean `PION_CACHE_DIR`:
  - All 4 modes exit `0` with byte-identical stdout SHA-256:
    `c3578280c103a1c71e96726e26bec2682ac90a92337c0986a99764e562269a5d`

## Formal Verification (Lean 4)

The core RFC 5545 calendar/RRULE arithmetic kernels and content-line syntax/token predicates in `packages/ical/src/` (`epoch_day_weekday_mon0`, `doy_of`, `neg_ordinal_day`, `floor_div_86400`, `week1_start_of`, `jump_grid_to`, `ascii_upper_byte`, `is_ical_name_byte`, `clamp_leap_second`, `parse_weekday_2_bytes`, `ParseLimits`, `ParseLimits::default`) are annotated with `#verify`, extracted directly into Lean 4 via `pionc extract-lean`, and mechanically proved in `packages/ical/proofs/` (**22 theorems, 0 `sorry` / `admit` / `bv_decide` / `native_decide`, standard axioms only**):

- **`IcalProofs/RRuleCalendar.lean` (12 theorems)**: `epoch_day_weekday_mon0` exact `(ed + 3) mod 7` bounds, Unix epoch Thursday anchor, 7-day periodicity, and `+1 (mod 7)` step; `doy_of` `[1, 366]` bounds; `neg_ordinal_day` bijection into `[-total, -1]`; exact signed Euclidean floor division `floor_div_86400` and day bracketing; RFC 5545 §3.3.10 `week1_start_of` (`±3` days of Jan 1, ≥4 days in year, exact `WKST` weekday alignment); and sub-daily recurrence grid fast-forward `jump_grid_to` (strict progress, exact minimality, and exact `step` grid alignment).
- **`IcalProofs/SyntaxAndTokens.lean` (10 theorems)**: `ascii_upper_byte` idempotence & lowercase elimination; RFC 5545 §3.1 `is_ical_name_byte` exact character set, uppercase closure, and rejection of content-line injection delimiters (`\r`, `\n`, `:`, `;`, space); leap-second clamping `[0, 60] → [0, 59]` and idempotence; `parse_weekday_2_bytes` range `[-1, 6]` and all 7 RFC 5545 weekdays (`MO`..`SU`, case-insensitive); and strictly positive `ParseLimits::default` DoS bounds.
- **Differential Cross-Check**: `packages/ical/proofs/EvalDiff.lean` cross-checks 31 cases between Native Pion execution and Lean 4 `#eval` (`diff -u` exit `0`). Run `sh packages/ical/proofs/run_proofs.sh` to reproduce end-to-end.

## Head-to-Head Benchmarks (`pion --release` vs Rust `rrule 0.14.0` + `icalendar 0.16.17 --release --locked`)

Run via `sh packages/ical/bench/run_bench.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 equality check, Platform: `Linux x86_64`):

| Workload | Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput / Latency | Peak RSS | Speedup | Stdout SHA-256 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: 4,000-VEVENT `.ics` Parse + Serialize Roundtrip (`1.93 MB`, folded + UTF-8, all TEXT props unescaped) | **`pion`** | **85.06** | 73.10 | 119.53 | **22.65 MB/s** | **15.84 MiB** | **3.27x** | `e4e48bf0c572404c…` |
| | `rust_icalendar` (`0.16.17`) | 278.14 | 185.56 | 696.48 | 6.93 MB/s | 37.21 MiB | 1.00x | `e4e48bf0c572404c…` |
| **W2**: Complex `RRULE` Expansion (80 rules: `BYDAY` ordinals, `BYSETPOS`, `WKST`, leap, `58,000` occs) | **`pion`** | **48.32** | 26.89 | 58.52 | **833.06 ns/op** | **2.57 MiB** | **2.59x** | `8a01a8a0a03b5cbc…` |
| | `rust_rrule` (`0.14.0`) | 125.03 | 69.48 | 181.91 | 2155.67 ns/op | 5.11 MiB | 1.00x | `8a01a8a0a03b5cbc…` |
| **W3**: `RRuleSet` Window Query Batch (`200` sets × 2 `RRULE`s + 4 `RDATE`s + 6 `EXDATE`s, 2y window, `72,200` occs) | **`pion`** | **26.28** | 25.58 | 42.80 | **131.38 µs/set** | **2.61 MiB** | **2.51x** | `f79e28a0fac65a54…` |
| | `rust_rrule` (`0.14.0`) | 65.88 | 53.05 | 93.95 | 329.38 µs/set | 5.05 MiB | 1.00x | `f79e28a0fac65a54…` |

### Honest Analysis

- **W1 (`.ics` Parse + Roundtrip, 3.27x faster, 2.35x lower RSS)**: `ical`'s zero-copy unfolded-line slice parser, common RFC 5545 name interning, 4-byte unrolled newline/CRLF scanning, direct `NAME:VAL` UTF-8-safe folding without intermediate line buffers, and pre-sized `StringBuilder` output avoid both `nom` combinator backtracking and per-component `BTreeMap` allocations. For fairness, W1 unescapes and hashes every VEVENT TEXT property (`SUMMARY`, `DESCRIPTION`, `LOCATION`) in Pion to match Rust `icalendar`'s eager TEXT unescaping; note that Rust `icalendar` still eagerly builds typed property maps for non-TEXT properties.
- **W2 (`RRULE` Expansion, 2.59x faster, 1.99x lower RSS)**: Precomputed weekday/month bitmasks, reusable per-period day buffers, precomputed `timeset` `Time` values, sorted-order un-numbered `BYDAY` emission without sorting, and O(1) single-index `BYSETPOS` selection keep expansion allocation-light on top of `packages/time`'s branchless Neri-Schneider calendar math.
- **W3 (`RRuleSet` Window Query, 2.51x faster, 1.93x lower RSS)**: For whole-second UTC recurrence sets, `RRuleSet::between` fast-forwards `COUNT`-less rules directly to the query window in O(1), merges streams directly as `Int64` epoch seconds with single-pointer `EXDATE` skipping and cached time-of-day, and constructs `time::Zoned` directly without per-occurrence timezone-table lookups. Non-UTC / DST / UTC-`UNTIL` paths remain handled by the full `ZonedRuleStream` with 4-hour spring-forward lookahead and are verified by the unit and red-team suites.
- **Scope tradeoff**: Rust `rrule` bundles the entire IANA `chrono-tz` database in the binary; `packages/ical` stays lean and `wasm32`-friendly by delegating timezone definitions to `packages/time::TimeZone` (POSIX TZ strings & TZif binary blobs) and parsed `VTIMEZONE` components.
