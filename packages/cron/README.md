# `cron` — Pure Pion Cron Schedule Engine

Pure Pion, zero-`World`, zero-dependency, `Send`-safe cron expression parser and calendar scheduler modeled after Rust [`croner`](https://github.com/Hexagon/croner-rust) and Go [`robfig/cron/v3`](https://github.com/robfig/cron).

## Features

- **5 / 6 / 7-field & macro support**:
  - Standard 5-field (`min hour dom month dow`, seconds fixed to `0`)
  - 6-field with seconds (`sec min hour dom month dow`)
  - 7-field with seconds and years (`sec min hour dom month dow year`, Gregorian `1..=9999`)
  - Predefined case-insensitive macros: `@yearly`, `@annually`, `@monthly`, `@weekly`, `@daily`, `@midnight`, `@hourly`
- **Full field syntax**:
  - Wildcards (`*`, `?`), steps (`*/5`, `5/15`), ranges (`1-10`), stepped ranges (`1-10/2`), lists (`1,3,5`), and wrap-around ranges (`22-2`, `22-2/2`, `NOV-FEB`, `FRI-MON`, `5-7`, `7-2`)
  - Case-insensitive month (`JAN`–`DEC`) and weekday (`SUN`–`SAT`) aliases; both `0` and `7` represent Sunday
  - Standard Vixie cron **DOM/DOW OR semantics** when both DOM and DOW are restricted, **AND semantics** when either is `*`/`?`, plus opt-in strict `dom_and_dow: true` (`ParseOptions`) for expressions like Friday the 13th (`0 0 13 * 5`)
- **Quartz extensions**:
  - DOM: `L` (last day of month), `L-n` (`1..=30` days before month end), `LW` (last weekday Mon–Fri of month), `<d>W` (nearest weekday within the same month)
  - DOW: `<d>L` (last weekday `<d>` of month), `<d>#<n>` (`n`-th weekday `<d>` of month, `1..=5`), `?`
- **O(1) bitmask calendar stepping & safety**:
  - Zero-allocation `pub val struct Cron` with 64-bit field bitmasks (`seconds_mask`, `minutes_mask`, `hours_mask`, `dom_mask`, `months_mask`, `dow_mask`), De Bruijn `ctz64` / binary-search `msb64`, and loop-free 7-bit rotated month DOW expansion
  - `next_after` (strict `>`), `next_after_inclusive` (`>=`), `prev_before` (strict `<`), `prev_before_inclusive` (`<=`), Unix-second helpers (`matches_unix`, `next_after_unix`, `prev_before_unix`), `iter_after`, `iter_before`, `take_after`, and `describe`
  - Exact proleptic Gregorian calendar (`is_leap_year`, `days_in_month`, `weekday_of`, Howard Hinnant O(1) civil/epoch conversions) across century leap boundaries (`2000`, `2100`, `2400`)
  - Bounded 400-year Gregorian cycle termination guarantees impossible dates (`0 0 31 2 *`, `0 0 30 2 *`, `0 0 31 4 *`, `0 0 0 29 2 * 2023`, `0 0 0 29 2 * 2100`, `0 0 L-29 2 *`) immediately return `None` without infinite loops
- **Dual target**: Native + `wasm32` (`packages/cron/wasm_smoke`).

## Verification

```sh
pionc fmt --check packages/cron
pionc check --json packages/cron
pionc test --json packages/cron
pionc build -o /private/tmp/cron-smoke/smoke_debug packages/cron/wasm_smoke
pionc build --release -o /private/tmp/cron-smoke/smoke_release packages/cron/wasm_smoke
pionc build --target wasm32 -o /private/tmp/cron-smoke/smoke_debug.wasm packages/cron/wasm_smoke
pionc build --target wasm32 --release -o /private/tmp/cron-smoke/smoke_release.wasm packages/cron/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `--warmup 1 --rounds 5`)

Measured via `sh packages/cron/bench/run_bench.sh` using `scripts/bench_compare.py` (strictly interleaved rounds, mandatory byte-identical stdout SHA-256 verification across all implementations):

- **Pion**: `packages/cron` (`pionc build --release`)
- **Rust**: `croner = "=2.1.0"` + `chrono = "=0.4.39"` (`cargo build --release`)
- **Go**: `github.com/robfig/cron/v3 v3.0.1` (`go build`)

### W1: Parse 100 Production Cron Expressions × 1,000 Rounds (100,000 parse ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 26.328 | 24.887 | 27.458 | 263.28 | 1.73 MiB | 6.33x |
| `rust_croner` | 166.646 | 162.538 | 175.799 | 1666.46 | 5.66 MiB | 1.00x (baseline) |
| `go_robfig` | 50.875 | 50.436 | 51.373 | 508.75 | 11.02 MiB | 3.28x |

_SHA-256 verified identical across all implementations and rounds: `1be910972faf8b39adb7459b4b9cb4354c69f49b106a23b21b0bf58306a6d321`._

### W2: Next-After Stepping (100 Expressions × 20 Rounds × 50 Steps = 100,000 `next_after` ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 16.599 | 14.150 | 18.068 | 165.99 | 1.75 MiB | 4.88x |
| `rust_croner` | 81.025 | 78.088 | 83.629 | 810.25 | 5.69 MiB | 1.00x (baseline) |
| `go_robfig` | 141.754 | 131.178 | 142.884 | 1417.54 | 4.64 MiB | 0.57x |

_SHA-256 verified identical across all implementations and rounds: `58ad2a568af15f5aabd5ea178ade64496cd0f4f14c0cf778e71aa15a09db851f`._

### W3: Sparse / Rare Dates Stepping (`0 0 29 2 *`, `0 0 31 12 *`, `0 0 30 4 *`, `0 0 1 1 *`, `0 0 31 1,3,5,7,8,10,12 *`, 10,000 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 9.522 | 7.713 | 9.884 | 952.17 | 1.73 MiB | 3.13x |
| `rust_croner` | 29.784 | 28.364 | 34.493 | 2978.38 | 5.48 MiB | 1.00x (baseline) |
| `go_robfig` | 34.537 | 34.269 | 38.291 | 3453.70 | 4.52 MiB | 0.86x |

_SHA-256 verified identical across all implementations and rounds: `54226233917f64c1af181715a2cdb1e62a4d03c24a0000cfaa2ff82f14367747`._

### W4: Friday the 13th (`0 0 13 * 5` with `dom_and_dow = true`, 10,000 ops, Pion vs Rust `croner`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 10.804 | 9.462 | 13.164 | 1080.41 | 1.73 MiB | 6.70x |
| `rust_croner` | 72.371 | 65.344 | 73.873 | 7237.08 | 5.45 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `329bd33da0317b71d7d614d94a091b1498227820e127a83d6750ab7a343fb3ee`._

### Honest Benchmark Notes & Scope Boundaries

- **Why Pion is faster on W1–W4**: `packages/cron` parses directly from byte slices into an unboxed `val struct Cron` with zero heap allocation on 5/6-field schedules, and steps UTC civil `DateTime` values directly via 64-bit bitmasks and loop-free 7-bit rotated month DOW masks. By contrast, Rust `croner` allocates pattern/state structures and converts through `chrono::DateTime<Utc>`, while Go `robfig/cron/v3` allocates `SpecSchedule` on the heap and advances via `time.Time` (which carries location/DST handling).
- **Process-startup floor**: W3 and W4 complete in ~9.5–10.8 ms wall-clock in Pion, where a noticeable fraction is process startup and CLI setup; larger op counts would reduce per-op ns further.
- **Compatibility notes**:
  - `packages/cron` operates on UTC civil `DateTime` / Unix seconds and does not perform IANA timezone or DST gap/fold adjustment (pair with `packages/time` at the application layer if local-zone DST handling is needed).
  - Go `robfig/cron/v3` rejects `7` for Sunday (accepts `0–6` only), lacks a `dom_and_dow` AND option (hence excluded from W4), and caps single-call lookahead at `t.Year() + 5` (which fails on the 8-year leap-day gap `2096-02-29 → 2104-02-29`, so W3 bounds leap-day stepping to `2024..2088` across 125 rounds for 3-way parity).
