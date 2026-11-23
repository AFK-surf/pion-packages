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

- **Unit & compliance tests**: `sh scripts/verify.sh packages/ical` — **21/21 `ical` tests** (283/283 including `time`) covering RFC 5545 §3.8.5.3 official examples, `rrule.js`/`dateutil` edge cases, RFC 6868, UTF-8 3-byte/4-byte folding, DST gaps/folds, `VTIMEZONE`, and DoS limits.
- **4-Mode `wasm_smoke`** (Native debug, Native release, Wasm32 debug, Wasm32 release) with clean `PION_CACHE_DIR`:
  - All 4 modes exit `0` with byte-identical stdout SHA-256:
    `c3578280c103a1c71e96726e26bec2682ac90a92337c0986a99764e562269a5d`

## Head-to-Head Benchmarks (`pion --release` vs Rust `rrule 0.14.0` + `icalendar 0.16.17 --release --locked`)

Run via `sh packages/ical/bench/run_bench.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 equality check, Platform: `Darwin arm64`):

| Workload | Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput / Latency | Peak RSS | Speedup | Stdout SHA-256 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| **W1**: 4,000-VEVENT `.ics` Parse + Serialize Roundtrip (`1.93 MB`, folded + UTF-8) | **`pion`** | **76.85** | 60.41 | 97.50 | **25.07 MB/s** | **15.72 MiB** | **2.33x** | `a9ed4a3fbc0e51ca…` |
| | `rust_icalendar` (`0.16.17`) | 179.27 | 122.53 | 183.25 | 10.75 MB/s | 51.34 MiB | 1.00x | `a9ed4a3fbc0e51ca…` |
| **W2**: Complex `RRULE` Expansion (80 rules: `BYDAY` ordinals, `BYSETPOS`, `WKST`, leap, `58,000` occs) | **`pion`** | **27.11** | 20.94 | 29.02 | **467.49 ns/op** | **2.22 MiB** | **1.37x** | `8a01a8a0a03b5cbc…` |
| | `rust_rrule` (`0.14.0`) | 37.17 | 34.63 | 42.82 | 640.77 ns/op | 7.75 MiB | 1.00x | `8a01a8a0a03b5cbc…` |
| **W3**: `RRuleSet` Window Query Batch (`200` sets × 2 `RRULE`s + 4 `RDATE`s + 6 `EXDATE`s, 2y window, `72,200` occs) | **`pion`** | **36.67** | 33.17 | 49.91 | **183.36 µs/set** | **2.36 MiB** | **1.48x** | `f79e28a0fac65a54…` |
| | `rust_rrule` (`0.14.0`) | 54.33 | 42.66 | 63.86 | 271.65 µs/set | 7.78 MiB | 1.00x | `f79e28a0fac65a54…` |

### Honest Analysis

- **W1 (`.ics` Parse + Roundtrip, 2.33x faster, 3.27x lower RSS)**: `ical`'s single-pass streaming unfolder + flat `Array[Property]` avoids `nom` combinator backtracking and per-component `BTreeMap` allocations that Rust `icalendar` constructs eagerly. Note that `ical` keeps property values raw until `unescape_text` is called (W1 explicitly calls `unescape_text` on `SUMMARY` and `DESCRIPTION` to match Rust `icalendar`'s output byte-for-byte).
- **W2 & W3 (`RRULE` & `RRuleSet`, 1.37x–1.48x faster, 3.3x–3.5x lower RSS)**: Direct epoch-day integer arithmetic (backed by `packages/time`'s branchless Neri-Schneider calendar math) and streaming k-way merge avoid per-year lookup-table allocations and `chrono-tz` binary size overhead.
- **Scope tradeoff**: Rust `rrule` bundles the entire IANA `chrono-tz` database in the binary; `packages/ical` stays lean and `wasm32`-friendly by delegating timezone definitions to `packages/time::TimeZone` (POSIX TZ strings & TZif binary blobs) and parsed `VTIMEZONE` components.
