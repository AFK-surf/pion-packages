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
  - Case-insensitive month (`JAN`–`DEC`) and weekday (`SUN`–`SAT`) aliases; both `0` and `7` represent Sunday (`7/<step>` matches Sunday only, matching `croner`)
  - **DOM/DOW OR/AND semantics** (aligned with `croner`): when both DOM and DOW are restricted, matches the union (OR); when either field is exact `*` or `?`, matches the intersection (AND). Note: unlike Vixie cron / `robfig`, stepped wildcards like `*/1` or lists containing `*` (e.g. `*,13`) are treated as restricted rather than setting the unrestricted star flag. Opt-in strict `dom_and_dow: true` (`ParseOptions`) is available for expressions like Friday the 13th (`0 0 13 * 5`)
- **Quartz extensions**:
  - DOM: `L` (last day of month), `L-n` (`0..=30` days before month end; `L-0` is equivalent to `L`), `LW` (last weekday Mon–Fri of month), `<d>W` (nearest weekday within the same month)
  - DOW: `<d>L` (last weekday `<d>` of month), `<d>#<n>` (`n`-th weekday `<d>` of month, `1..=5`), `?`
  - Year (7th field): `1..=9999`, ranges, steps (`*/n` anchored at Quartz epoch `1970`), and comma-separated lists (precompiled at parse time into a compact `Send`-safe 4-bit-per-char ASCII bitmap for O(1) matching and stepping without re-parsing)
- **O(1) bitmask calendar stepping & safety**:
  - Zero-allocation `pub val struct Cron` on 5/6-field and single-range 7-field schedules with 64-bit field bitmasks (`seconds_mask`, `minutes_mask`, `hours_mask`, `dom_mask`, `months_mask`, `dow_mask`), De Bruijn `ctz64` / binary-search `msb64`, and loop-free 7-bit rotated month DOW expansion
  - `next_after` (strict `>`), `next_after_inclusive` (`>=`), `prev_before` (strict `<`), `prev_before_inclusive` (`<=`), Unix-second helpers (`matches_unix`, `next_after_unix`, `prev_before_unix`), `iter_after`, `iter_before`, `take_after`, and `describe`
  - Strict bounds validation on `DateTime` (`matches` / `next_*` / `prev_*` reject invalid struct literals) and 64-bit Unix timestamp range enforcement (`[-62135596800, 253402300799]`) preventing 32-bit era truncation/aliasing
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
| `pion` | 23.914 | 22.227 | 27.972 | 239.14 | 1.75 MiB | 6.36x |
| `rust_croner` | 152.088 | 146.412 | 171.631 | 1520.88 | 5.66 MiB | 1.00x (baseline) |
| `go_robfig` | 50.801 | 45.282 | 52.404 | 508.01 | 12.28 MiB | 2.99x |

_SHA-256 verified identical across all implementations and rounds: `1be910972faf8b39adb7459b4b9cb4354c69f49b106a23b21b0bf58306a6d321`._

### W2: Next-After Stepping (100 Expressions × 20 Rounds × 50 Steps = 100,000 `next_after` ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 15.311 | 14.351 | 16.666 | 153.11 | 1.77 MiB | 5.13x |
| `rust_croner` | 78.508 | 73.963 | 83.178 | 785.08 | 5.67 MiB | 1.00x (baseline) |
| `go_robfig` | 141.102 | 132.285 | 142.351 | 1411.02 | 4.55 MiB | 0.56x |

_SHA-256 verified identical across all implementations and rounds: `58ad2a568af15f5aabd5ea178ade64496cd0f4f14c0cf778e71aa15a09db851f`._

### W3: Sparse / Rare Dates Stepping (`0 0 29 2 *`, `0 0 31 12 *`, `0 0 30 4 *`, `0 0 1 1 *`, `0 0 31 1,3,5,7,8,10,12 *`, 10,000 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 8.095 | 7.655 | 13.684 | 809.45 | 1.75 MiB | 3.47x |
| `rust_croner` | 28.057 | 27.752 | 41.915 | 2805.67 | 5.48 MiB | 1.00x (baseline) |
| `go_robfig` | 34.111 | 33.779 | 41.001 | 3411.12 | 4.41 MiB | 0.82x |

_SHA-256 verified identical across all implementations and rounds: `54226233917f64c1af181715a2cdb1e62a4d03c24a0000cfaa2ff82f14367747`._

### W4: Friday the 13th (`0 0 13 * 5` with `dom_and_dow = true`, 10,000 ops, Pion vs Rust `croner`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_croner`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 8.962 | 7.829 | 9.591 | 896.16 | 1.75 MiB | 6.98x |
| `rust_croner` | 62.558 | 60.504 | 64.561 | 6255.83 | 5.45 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `329bd33da0317b71d7d614d94a091b1498227820e127a83d6750ab7a343fb3ee`._

### Adversarial Workloads A1–A6 (`sh packages/cron/audit/run_audit.sh` §7, `Darwin arm64`, `--warmup 1 --rounds 5`, SHA-256 verified identical)

| Workload | Pion | Rust `croner` 2.1.0 | Go `robfig` v3.0.1 | Java `Quartz` 2.3.2 | Pion vs best upstream |
| --- | ---: | ---: | ---: | ---: | ---: |
| A1 Quartz `L`/`W`/`#`/`nL` stepping (320k ops) | 123.43 ns/op | 1,040.21 ns/op | — | 2,085.80 ns/op | **8.43x faster** |
| A2 Quartz `LW` / `L-n` stepping (200k ops) | 137.21 ns/op | — | — | 2,704.71 ns/op | **19.71x faster** |
| A3 7-field year ranges/steps/lists (66.8k ops) | 237.63 ns/op | — | — | 3,558.31 ns/op | **14.97x faster** |
| A4 Impossible date + 157-item year list (2k searches) | 9,624.88 ns/op | — | — | 346,684.19 ns/op | **36.02x faster** |
| A5 Reject 21 malformed expressions (420k ops) | 95.53 ns/op | 919.47 ns/op | 310.42 ns/op | — | **3.25x faster** |
| A6 Long explicit lists up to 2 KB (60k parses) | 5,350.61 ns/op | 21,389.53 ns/op | 15,941.90 ns/op | — | **2.98x faster** |

_9,999-item year list DoS probe (`0 0 0 31 2,4,6,9,11 ? 1,2,...,9999`, single `next_after`): **0.008 s** wall-clock (including process start), down from 10.042 s prior to year-bitmap precompilation._

### Honest Benchmark Notes & Scope Boundaries

- **Why Pion is faster on W1–W4**: `packages/cron` parses directly from byte slices into an unboxed `val struct Cron` with zero heap allocation on 5/6-field schedules, and steps UTC civil `DateTime` values directly via 64-bit bitmasks and loop-free 7-bit rotated month DOW masks. By contrast, Rust `croner` allocates pattern/state structures and converts through `chrono::DateTime<Utc>`, while Go `robfig/cron/v3` allocates `SpecSchedule` on the heap and advances via `time.Time` (which carries location/DST handling).
- **Process-startup floor**: W3 and W4 complete in ~9.5–10.8 ms wall-clock in Pion, where a noticeable fraction is process startup and CLI setup; larger op counts would reduce per-op ns further.
- **Compatibility notes**:
  - `packages/cron` operates on UTC civil `DateTime` / Unix seconds and does not perform IANA timezone or DST gap/fold adjustment (pair with `packages/time` at the application layer if local-zone DST handling is needed).
  - Go `robfig/cron/v3` rejects `7` for Sunday (accepts `0–6` only), lacks a `dom_and_dow` AND option (hence excluded from W4), and caps single-call lookahead at `t.Year() + 5` (which fails on the 8-year leap-day gap `2096-02-29 → 2104-02-29`, so W3 bounds leap-day stepping to `2024..2088` across 125 rounds for 3-way parity).
