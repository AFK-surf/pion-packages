# `time` — Pure Pion Date & Time Library

Pure Pion, zero-`World`, `Send`-safe date and time library ported from Rust [`BurntSushi/jiff`](https://github.com/BurntSushi/jiff).

## Features

- **Value-type core (`pub val struct`)**: compact value types for `Date`, `Time`, `DateTime`, `Offset`, `Timestamp`, `SignedDuration`, `IsoWeekDate`, `FixedDateTime`, and `IsoDuration`.
- **Full proleptic Gregorian calendar (`-9999-01-01` to `9999-12-31`)**:
  - Branchless O(1) Neri-Schneider `Date::to_epoch_days` / `Date::from_epoch_days` with exact multiply-shift reciprocals (verified byte-identical to `jiff 0.2.46` across all 7,304,484 days)
  - Unboxed packed civil calendar APIs with sentinel validation (`epoch_days_to_packed_date`, `packed_date_to_epoch_days`, `packed_date_add_days`, `packed_date_to_packed_iso_week`)
  - Leap years, `days_in_month`, `day_of_year`, `day_of_year_no_leap`, `Weekday`, `IsoWeekDate`, calendar arithmetic (`add_days`, `sub_days`, `add_months`, `add_years`, `until`, `since`, `start_of_day`, `end_of_day`)
- **Unix `Timestamp`, `Offset` & `SignedDuration`**:
  - Normalized non-negative nanoseconds (`0..=999_999_999`), same-sign `(secs, nanos)` `SignedDuration` with safe `i64::MIN` ISO formatting & parsing round-trip
  - Rounding (`TimeUnit`, `RoundMode`: `Ceil`/`Floor`/`Expand`/`Trunc`/`HalfCeil`/`HalfFloor`/`HalfExpand`/`HalfTrunc`/`HalfEven`) for `Timestamp::round`, `DateTime::round`, `Time::round`, and `SignedDuration::round`
- **Time Zones & Zone-Aware Datetimes (`TimeZone`, `Zoned`, `Disambiguation`)**:
  - Fixed offsets (`TimeZone::utc`, `TimeZone::fixed`), POSIX TZ strings (`TimeZone::posix`, IEEE 1003.1 `Mm.w.d` / `Jn` / `n` rules including southern hemisphere DST), and RFC 8536 TZif v1/v2/v3/v4 binary parsing from `Bytes` (`TimeZone::from_tzif`)
  - DST gap/fold detection and disambiguation (`Disambiguation::Compatible`, `Earlier`, `Later`, `Reject`), civil `Zoned::add_days` across DST transitions, and RFC 9557 offset-conflict validation (`Zoned::parse_with_tz`)
- **Parsing & Formatting**:
  - **RFC 3339 / ISO 8601 / RFC 9557**: 4-digit and signed 6-digit extended years (`-009999..=+009999`), basic & reduced-precision forms, `.`/`,` fractional seconds (1–9 digits), leap second `:60` clamping, `±25:59:59` offsets, RFC 9557 `[tz][k=v]` annotations (`parse_rfc9557_tz_name`), zero-copy slice parsers (`Timestamp::parse_rfc3339_slice`, `FixedDateTime::parse_rfc3339_slice`, `parse_rfc3339_slice_raw`), and reusable buffer formatters (`Timestamp::write_rfc3339`, `Timestamp::write_rfc3339_with_offset`, `Timestamp::write_rfc3339_bytes`, `format_rfc3339_raw_bytes`)
  - **RFC 2822** & **RFC 9110 §5.6.7 HTTP-date** (all three required formats: IMF-fixdate, obsolete RFC 850, and ANSI C `asctime()`)
  - **ISO 8601 Duration** (`SignedDuration::parse_iso`, `IsoDuration::parse` with `jiff` range validation & fractional normalization)
  - **`strftime` / `strptime`** (`strftime`, `strftime_fixed`, `strftime_zoned`, `strptime`, `strptime_fixed`)
- **Dual target**: Native + `wasm32` (`packages/time/wasm_smoke`).

## Verification

```sh
pionc fmt --check packages/time
pionc check --json packages/time
pionc test --json packages/time
pionc build --target wasm32 -o /tmp/time_wasm_smoke.wasm packages/time/wasm_smoke
```

## Formal Verification (Lean 4)

The pure calendar, duration, and ordering kernels in `packages/time/src/{types,civil,timestamp}.pion` are annotated with `#verify`, extracted to Lean 4 via `pionc extract-lean` (`Time.Funs`), and machine-checked in `packages/time/proofs/`:

- **`packages/time/proofs/TimeProofs.lean`** — end-to-end proofs with **0 `sorry`, 0 `admit`, 0 `native_decide`, 0 `bv_decide`**:
  - **Gregorian leap year & month lengths**: `is_leap_year_spec` (full `Int32` equivalence to `(y % 4 = 0 ∧ y % 100 ≠ 0) ∨ y % 400 = 0`, including negative BCE years and `1900`/`2000`/`2100`/`2400`/`0`/`-100`/`-400` corollaries), `days_in_month_of_spec` (`1 ≤ m ≤ 12 → 28 ≤ days_in_month_of y m ≤ 31`), `days_in_month_of_feb`.
  - **Proleptic Gregorian calendar ↔ Unix epoch days bijection (`-9999-01-01 ..= 9999-12-31`)**: `to_epoch_days_spec`, `from_epoch_days_spec`, `from_epoch_days_out_of_range`, `from_epoch_days_to_epoch_days` (forward roundtrip), `to_epoch_days_from_epoch_days` (inverse roundtrip + output validity), `to_epoch_days_strict_mono` (strict order preservation `Date.cmp d1 d2 = -1 ↔ to_epoch_days d1 < to_epoch_days d2`).
  - **`SignedDuration` normalization & overflow-free checked arithmetic**: `signed_duration_{zero,min,max}_valid`, `checked_add_i64_spec`, `checked_sub_i64_spec`, `signed_duration_new_sound`, `signed_duration_checked_neg_sound`, `signed_duration_checked_add_sound`, `signed_duration_checked_sub_sound` (exact iff soundness over all `Int64` boundaries including `INT64_MIN`/`INT64_MAX`, preserving same-sign nanosecond normalization and exact `totalNanos`), and `signed_duration_cmp_{spec,refl,antisymm,trans_lt}`.
  - **`Date` / `Time` / `DateTime` / `Timestamp` strict total orders**: `date_cmp_*`, `time_to_second_of_day_spec`, `time_cmp_*`, `datetime_cmp_*`, `timestamp_cmp_*`.
- **`packages/time/proofs/CheckAxioms.lean`** — `#print axioms` audit confirming all 47 verified theorems depend **only** on standard Lean 4 axioms (`propext`, `Classical.choice`, `Quot.sound`).
- **`packages/time/proofs/EvalDiff.lean`** — `#guard` + `#eval` differential suite (31 boundary/overflow cases including `-9999-01-01`, `0000-02-29`, `1970-01-01`, `2000-02-29`, `9999-12-31`, `SignedDuration::min`/`max`) cross-checked via `diff -u` against native Pion execution.
- **`packages/time/proofs/run_proofs.sh`** — one-command verification gate (builds in `/private/tmp/pion-lean-time` with zero git worktree pollution):

```sh
sh packages/time/proofs/run_proofs.sh
```

## Head-to-Head Benchmarks (`Darwin arm64`, `--warmup 1 --rounds 5`)

Measured via `sh packages/time/audit/run_audit.sh` (strictly interleaved rounds, SHA-256 verified byte-identical stdout across all implementations). Both idiomatic typed APIs and specialized raw/packed APIs are reported side-by-side:

### W1: RFC 3339 Parse + Offset Shift (+09:00) + Format (200,000 timestamps)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_jiff`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_raw` (`parse_rfc3339_slice_raw` + `format_rfc3339_raw_bytes`) | 42.316 | 38.830 | 43.380 | 148.29 | 211.58 | 13.70 MiB | 1.04x |
| `pion_typed_slice` (`Timestamp::parse_rfc3339_slice` + `write_rfc3339_with_offset`) | 53.546 | 50.739 | 55.898 | 117.19 | 267.73 | 13.70 MiB | 0.82x |
| `pion_typed_split` (`split("\n")` + `Timestamp::parse_rfc3339`) | 53.789 | 53.093 | 69.044 | 116.66 | 268.94 | 22.88 MiB | 0.81x |
| `rust_jiff` (`jiff 0.2.46`) | 43.817 | 41.957 | 53.435 | 143.21 | 219.09 | 7.83 MiB | 1.00x (baseline) |
| `go_time` | 52.451 | 50.471 | 53.906 | 119.64 | 262.25 | 24.72 MiB | 0.84x |

_SHA-256 verified identical: `1172c1540ed9d0bc5f41ddce8a7b6253977063fa640aedc9e5eb82000585685f`._

### W2: Civil Calendar & Epoch Computation (2,000,000 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_jiff`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_packed` (`epoch_days_to_packed_date` / `packed_date_*`) | 65.160 | 64.206 | 69.283 | 32.58 | 1.69 MiB | 0.69x |
| `pion_typed` (`Date::from_epoch_days` / `iso_week_date` / `add_days`) | 90.471 | 87.129 | 92.142 | 45.24 | 1.69 MiB | 0.50x |
| `rust_jiff` (calendar `Span`) | 45.257 | 41.739 | 46.963 | 22.63 | 1.75 MiB | 1.00x (baseline) |
| `rust_jiff_sd` (`SignedDuration` days) | 42.219 | 39.172 | 44.832 | 21.11 | 1.75 MiB | 1.07x |
| `go_time` | 77.737 | 72.275 | 79.909 | 38.87 | 4.34 MiB | 0.58x |

_SHA-256 verified identical: `65a54274c38cb0392b001c91e26123de1ddcff28bddec4044e2e9beb72fc5024`._

### W3–W5: Additional Idiomatic Workloads (Duration ISO / HTTP-date / Checked Arithmetic)

| Workload | `pion` Median (ms) | `rust_jiff` Median (ms) | `go_time` Median (ms) | `pion` vs `rust_jiff` | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | --- |
| W3: ISO 8601 `SignedDuration` (200k) | 56.097 | 37.605 | N/A | 0.67x | `6a27f572…` |
| W4: HTTP-date IMF-fixdate (200k) | 63.576 | 43.511 | 71.347 | 0.68x | `651bbb31…` |
| W5: `SignedDuration` + `Timestamp` checked ops (5M) | 577.868 | 74.558 | 70.838 | 0.13x | `6fed3af8…` |
