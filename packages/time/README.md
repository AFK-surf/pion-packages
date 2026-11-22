# `time` — Pure Pion Date & Time Library

Pure Pion, zero-`World`, `Send`-safe date and time library ported from Rust [`BurntSushi/jiff`](https://github.com/BurntSushi/jiff).

## Features

- **Value-type core (`pub val struct`)**: zero heap allocation, zero RC overhead for `Date`, `Time`, `DateTime`, `Offset`, `Timestamp`, `SignedDuration`, `IsoWeekDate`, `FixedDateTime`, and `IsoDuration`.
- **Full proleptic Gregorian calendar (`-9999-01-01` to `9999-12-31`)**:
  - Branchless O(1) Neri-Schneider `Date::to_epoch_days` / `Date::from_epoch_days`
  - Leap years (including 1900, 2000, 2100, 2400, year 0, negative years), `days_in_month`, `day_of_year`, `day_of_year_no_leap`
  - `Weekday` (Monday/Sunday 0-based & 1-based offsets, wrapping arithmetic)
  - `IsoWeekDate` with exact cross-year week boundaries (`2020-12-31 = 2020-W53-4`, `2021-01-01 = 2020-W53-5`, `2019-12-30 = 2020-W01-1`)
  - Calendar arithmetic (`add_days`, `sub_days`, `add_months` with end-of-month clamping, `add_years`, `until`, `since`, `start_of_day`, `end_of_day`)
- **Unix `Timestamp` & `Offset`**:
  - Normalized non-negative nanoseconds (`0..=999_999_999`), e.g. `-0.1s` is `secs = -1, nanos = 900_000_000`
  - Infallible `Timestamp::to_datetime(offset)` across the full supported range
- **`SignedDuration`**:
  - Same-sign `(secs, nanos)` normalization, checked `add`/`sub`/`mul`/`div`/`neg`/`abs`, truncation, and rounding
- **Strict zero-allocation parsing & `StringBuilder` formatting**:
  - **RFC 3339 / ISO 8601**: 1–9 digit fractional seconds, `Z`/`z`/`+HH:MM`/`-HH:MM`, strict rejection of invalid dates, leap seconds (`:60`), out-of-range offsets, and trailing garbage
  - **RFC 2822** & **RFC 9110 HTTP-date (IMF-fixdate)**
  - **ISO 8601 Duration** (`PT1H30M45.5S`, `P1Y2M3DT4H5M6S`, negative durations)
- **Dual target**: Native + `wasm32` (`packages/time/wasm_smoke`).

## Verification

```sh
pionc fmt --check packages/time
pionc check --json packages/time
pionc test --json packages/time
pionc build --target wasm32 -o /tmp/time_wasm_smoke.wasm packages/time/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `--warmup 1 --rounds 5`)

Run via:

```sh
sh packages/time/bench/run_bench.sh
```

### Workload 1: RFC 3339 Batch Parse + Offset Shift (+09:00) + Format (200,000 timestamps)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_jiff`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 70.775 | 66.448 | 73.976 | 88.66 | 353.87 | 22.81 MiB | 0.64x |
| `rust_jiff` | 45.161 | 42.689 | 45.385 | 138.95 | 225.80 | 7.83 MiB | 1.00x (baseline) |
| `go_time` | 54.308 | 51.015 | 59.045 | 115.54 | 271.54 | 24.83 MiB | 0.83x |

_SHA-256 verified identical across all implementations and rounds: `1172c1540ed9d0bc5f41ddce8a7b6253977063fa640aedc9e5eb82000585685f`._

### Workload 2: Civil Calendar & Epoch Intensive Computation (2,000,000 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_jiff`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 114.697 | 105.852 | 122.772 | 57.35 | 1.69 MiB | 0.40x |
| `rust_jiff` | 45.971 | 43.239 | 49.788 | 22.99 | 1.73 MiB | 1.00x (baseline) |
| `go_time` | 80.517 | 76.596 | 84.090 | 40.26 | 4.38 MiB | 0.57x |

_SHA-256 verified identical across all implementations and rounds: `65a54274c38cb0392b001c91e26123de1ddcff28bddec4044e2e9beb72fc5024`._
