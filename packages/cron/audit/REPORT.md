# Red-team audit: `packages/cron` @ `2eac9b1` (`feat/pkg-cron`)

Scope: the pure-Pion cron engine (`src/parse.pion`, `src/schedule.pion`, `src/types.pion`,
`src/describe.pion`), `wasm_smoke`, and `bench/`. References: Rust **croner 2.1.0**
(+ chrono 0.4.39), Go **robfig/cron/v3 v3.0.1**, Java **Quartz 2.3.2** `org.quartz.CronExpression`
(the only reference that defines the 7th "year" field, `L-n` and `LW`), plus Vixie cron source
semantics where they decide a question.

## Reproduce

```sh
sh packages/cron/audit/run_audit.sh            # full run, ~85 s on an M-series Mac
QUICK=1 sh packages/cron/audit/run_audit.sh    # 3k-case corpus, no benchmarks, ~25 s
pionc test --json packages/cron/audit          # red-team unit tests only (fix-phase gate)
```

Needs `pionc` (`$HOME/.pion/bin`, tested with `AFK-surf/pion@bee7628`), node, go, cargo, java/javac,
python3. The first run downloads `quartz-2.3.2.jar` from Maven Central (sha256-checked). Everything
is built and written under `$AUDIT_OUT` (default `/private/tmp/pion-cron-audit`); the worktree stays
clean.

| File | Purpose |
| --- | --- |
| `redteam_test.pion` | 9 failing `redteam_*` tests (findings F1–F3, F5, F6) + 9 passing `control_*` tests |
| `probe/` | Pion driver: `diff` (next/prev chains), `inv` (invariants), `unix`, `time`, `bench-*` |
| `rust/`, `go/`, `java/QuartzProbe.java` | croner / robfig / Quartz drivers, same input/output format |
| `gen_corpus.py` | deterministic corpora (seed 20261123): 20k std, 5k 6-field, 20k Quartz-legal, 143 hand-written, 180k invariant cases |
| `compare.py`, `triage.py` | bucket every mismatch and prove its root cause by rewriting the expression |
| `gen_bench.py` | adversarial benchmark inputs A1–A6 |

## Summary

| ID | Sev | Finding | Gate |
| --- | --- | --- | --- |
| F1 | **P1** | DOW `7/<step>` expands from Sunday across the whole week (`7/2` = Sun,Tue,Thu,Sat; `7/1` = every day). croner: Sunday only; Vixie/robfig: reject | `redteam_F1_*` (2) |
| F2 | **P1** | Year `*/n` is anchored at year 1, Quartz anchors at 1970: `*/2` fires odd years (Quartz: even), `*/5` fires 2026, 2031 (Quartz: 2025, 2030) | `redteam_F2_*` (2) |
| F3 | **P1** | `DateTime::from_unix_secs` truncates the era to 32-bit `Int`: `3388401920987913600` (year ≈ 1.07e11) and `-3388401919084176000` decode to `Ok(2000-03-01T00:00:00Z)`; `next_after_unix` then returns a time ~1e11 years *earlier* than its input. Native and wasm32 alike | `redteam_F3_*` (3) |
| F4 | **P1** | DoS: a multi-item year list is kept as a string and re-parsed on every search step → O(years × list length). One `next_after` on an impossible date with a 9,999-item list (49 KB): **10.0 s**; 2,000 items: 0.38 s; 157 items: 1.67 ms/call, **3.8× slower than Quartz incl. JVM start** (A4). The only workload where Pion loses | `run_audit.sh` §5, §7 A4 |
| F5 | P2 | `DateTime` is a `pub val struct` with public fields: a struct literal skips validation, and `matches()` shifts 64-bit masks by ≥ 64, which wraps — `second: 64` matches a second-0 schedule | `redteam_F5_*` |
| F6 | P2 | Quartz accepts `L-0` (== `L`); Pion rejects it | `redteam_F6_*` |
| F7 | P2 | Semantic divergences where the upstreams disagree with each other (no gate; needs a decision), see below | — |

**No P0.** No crash, trap, hang, stack overflow or OOM in any input or mode; 0 invariant violations;
native debug/release and wasm32 debug/release outputs are byte-identical.

## P1 details

### F1 — DOW `7/<step>`

`parse_bitmask_item` (kind 2, single value with step) does `a0 = a % 7` and then fills `a0..6`.
For `a = 7` that becomes `0..6`, i.e. the whole week stepped.

```
0 0 * * 7/2  from 2024-01-01:  pion   2024-01-02(Tue) 01-04(Thu) 01-06(Sat) 01-07(Sun)
                               croner 2024-01-07(Sun) 01-14(Sun) 01-21(Sun) 01-28(Sun)
                               robfig / Vixie: reject ("7" out of range / N/step without range)
0 0 * * 7/1:                   pion fires every day; croner Sundays only
```

Fix direction: expand `a/s` for DOW over `a..7` (the existing `b == 7` branch of
`fill_range_mask`), or reject `7/s`.

### F2 — year `*/n` anchoring

`parse_year_item` maps `*` to `MIN_YEAR = 1`, so `*/n` = `1 + n·k`. Quartz's year field `*` starts at
1970 (its year minimum), so `*/n` = `1970 + n·k`:

```
0 0 0 1 1 ? */2  from 2024-01-01:  pion   2025, 2027, 2029   (matches(2024-01-01) = false)
                                  Quartz 2026, 2028, 2030   (isSatisfiedBy(2024-01-01) = true)
0 0 0 1 1 ? */5:                  pion   2026, 2031, 2036;  Quartz 2025, 2030, 2035
```

The 7-field syntax is Quartz's, so an "every N years" schedule silently fires in different years.
Fix direction: anchor `*` (with a step) at 1970 while keeping 1..=9999 as the valid range.

### F3 — `from_unix_secs` aliasing

`civil_from_days` computes `era` as `Int64` but uses `era.to_int()` and 32-bit `y = yoe + era*400`.
With `era = 2^28`, `era*400 ≡ 0 (mod 2^32)`, so the year wraps into 1..=9999 and passes the range
check. Repro: `probe unix 3388401920987913600` → `OK 2000-03-01T00:00:00Z back=951868800`
(native and wasm32). croner/chrono returns `None` for out-of-range timestamps and Go's `time` keeps
the true year; neither aliases. `next_after_unix(3388401920987913600)` returns `951955200`.
Fix direction: reject `|days| > 3_000_000` (or do the civil math in `Int64`) before converting.

### F4 — year-list DoS

`year_matches` / `next_matching_year` / `prev_matching_year` re-run `parse_year_item` over
`year_spec` (the raw text) on every loop iteration of `find_next_from` / `find_prev_from`.

| `0 0 0 31 2,4,6,9,11 ? <years>` (impossible), one `next_after` | Pion |
| --- | ---: |
| `1970-2126` (range) | 0.006 s |
| `1-9999` (range) | 0.007 s |
| 157-item list 1970..2126 | 0.009 s (1.67 ms/call in A4) |
| 2,000-item list 1..2000 | 0.381 s |
| 9,999-item list 1..9999 (49 KB) | **10.042 s** |

Quartz keeps years in a `TreeSet` and caps them at 2126; on the same 157-item list it is 3.8× faster
(A4, JVM start-up included). Fix direction: compile the year list at parse time into a 9,999-bit
set (157 `UInt64` words) or a sorted range array and step with `next_set_bit`.

## P2 details

- **F5** `DateTime::{ year: 2024, month: 1, day: 1, hour: 0, minute: 0, second: 64 }` compiles from
  another package; `Cron::parse("0 * * * * *").matches(it)` is `true` (shift amount wraps mod 64).
  Same for `minute: 64`. chrono and Go `time` cannot represent such a value. Fix: bounds-check in
  `matches`/`next_after`/`prev_before`, or make the fields read-only outside the package.
- **F6** `0 0 0 L-0 * ?` → Pion `OutOfRange("L-offset must be in 1..=30")`; Quartz: 2024-01-31,
  2024-02-29 (same as `L`).
- **F7 divergences (upstreams disagree; listed for a decision, not gated):**
  - *Star semantics.* Pion (like croner) treats only the exact field `*`/`?` as "unrestricted".
    robfig sets its star bit for `*`, `?` or `*/1` anywhere in the field; Vixie sets DOM_STAR /
    DOW_STAR whenever the field *starts* with `*` (so also `*/2`). `0 0 */1 * MON`: Pion/croner fire
    daily, robfig/Vixie on Mondays; `0 0 *,13 * 5`: Pion daily, robfig/Vixie Fridays, croner rejects.
    All 94 + 15 robfig next-chain mismatches in 25k random cases are this (proven by `triage.py`).
    The README's "Standard Vixie cron DOM/DOW OR semantics" claim is inaccurate for these inputs.
  - *DOW `a/s` upper bound.* Pion (like robfig) expands to 6, croner to 7: `MON/2` is Mon/Wed/Fri
    in Pion, Mon/Wed/Fri/Sun in croner; Vixie rejects `N/step`. Together with croner's textual
    `-sun` → `-7` rewrite (`SUN-SUN`, `0-SUN` = every day in croner, Sunday in Pion) this explains
    all 165 + 42 croner mismatches.
  - `?` is only accepted in DOM/DOW (Quartz: same; croner/robfig accept it in any field).
  - Steps larger than the field span are rejected (`*/60`, `0 */24`, `*/32`, `*/13`, `*/8`);
    croner and robfig accept them (= first value only).
  - Empty list items and signs (`1,,2`, `,1`, `1,`, `+1`) are rejected; croner and robfig accept.
  - Only space/tab/CR/LF separate fields; `\v` and Unicode spaces do not (croner
    `split_whitespace` and Go `strings.Fields` accept them).
  - `31W`/`30W` in a shorter month: Pion skips the month (like croner); Quartz fires on the month's
    last day only when the lenient `Calendar` overflow lands on a Saturday (e.g. `31W` in June 2051
    → 06-30). These are the only 7 mismatches in 20,000 Quartz cases.
  - DOW `L` alone (Quartz: Saturday) is rejected.

## What `packages/cron` withstood (and where it beats upstream)

- **Quartz semantics:** 20,000 random Quartz-legal 6/7-field cases (L, LW, L-n, nW, d#n, dL, year
  ranges/steps/lists): identical `next_after` chains (5 steps) and `matches()` except the 7
  `31W` cases above. Hand-written edge cases all agree with Quartz: `LW` in Feb 2020 (29th Sat →
  28th) and 2024 (29th Thu), `1W` on a Saturday → the 3rd, `31W`/`28W` on a weekend → the Friday
  before, `FRI#5` skipping months, `SUNL`, `L-30`, `2000,2100,2400` leap handling.
- **croner bugs Pion does not have:** croner fires `1W` on 2021-12-31 and 2024-05-31 (previous
  month), `31W` on 2024-01-01 (next month), and `7L` / DOW `L` never fire at all.
- **Quartz bugs Pion does not have:** `0 0 0 0W * ?` makes `getTimeAfter` spin forever (Pion
  rejects); Quartz accepts trailing garbage (`... ? 2024 extra`), year `0`, step `2024/0`, and
  silently mis-schedules `1-5W` / `1,15W`; it cannot parse `L,15`, `1#1,5#2`, `JAN-11`, or years > 2126.
- **robfig limits Pion does not have:** robfig gives up after start + 5 years (misses the
  2096-02-29 → 2104-02-29 leap gap) and rejects `7` for Sunday.
- **Invariants:** 180,572 cases (every corpus expression × random starts across years 1..9999 + edges):
  `matches(next)`, `matches(prev)`, `prev_before(next_after(t)) == prev_before_inclusive(t)`,
  `next_after(prev_before(t)) == next_after_inclusive(t)`, inclusive/strict consistency and Unix
  helpers — **0 violations** in all four build modes.
- **Calendar extremes:** year 1 / 9999 boundaries, negative timestamps (1969, 1900, 1601, 0001),
  century leap years and impossible dates (`0 0 0 29 2 * 2100-2103`, `0 0 0 29 2 1 2000-2100` with
  `dom_and_dow`, `L-30` in February) all terminate in ≤ 7 ms.
- **Malformed input:** 100 KB comma lists, 100 KB whitespace, `0-59/99999999999999999999`,
  control characters, multi-byte UTF-8, NUL: all rejected or parsed in ≤ 5 ms, no crash.
- **Native vs Wasm32:** the 45,143-case differential output is byte-identical across native
  debug/release and wasm32 debug/release run under node (`sha256 fa1f722c…a074d`); `wasm_smoke`
  passes in all four modes; F3 reproduces identically on wasm32.

## Benchmarks

### Fairness review of `packages/cron/bench`

- **W1 dead-code elimination:** a Pion variant that folds every parsed mask into the output takes the
  same time as the W1 shape (17–20 ms vs 18–20 ms, 3 runs) → the parse is not eliminated. Rust uses
  `black_box` on the input; croner's cost is genuinely its string rewriting.
- **W2–W4** are equal work. Caveat (already disclosed in the README): Pion steps UTC civil time while
  croner converts through `chrono::DateTime<Utc>` and robfig through `time.Time`.
- **W1/W3/W4** finish in 9–26 ms wall-clock, so process start-up is a visible share of ns/op.
- **Gaps:** no Quartz-feature, 7-field year, malformed-input, long-list or `prev_before` workload,
  and no Quartz baseline. A1–A6 below add them (`prev_before` has no upstream counterpart: croner
  2.1.0 and robfig have no backward search, Quartz 2.3.2's `getTimeBefore` returns `null`).

### Adversarial workloads (`run_audit.sh` §7, Darwin arm64, `--warmup 1 --rounds 5`, SHA-256 identical)

| Workload | Pion | croner 2.1.0 | robfig v3.0.1 | Quartz 2.3.2 | Pion vs best |
| --- | ---: | ---: | ---: | ---: | ---: |
| A1 L/W/#/nL stepping, 320k ops | 136 ns/op | 1,150 ns/op | — | 2,267 ns/op | **8.45× faster** |
| A2 LW / L-n stepping, 200k ops | 164 ns/op | — | — | 2,943 ns/op | **18.0× faster** |
| A3 7-field year ranges/steps/lists, 66.8k ops | 295 ns/op | — | — | 4,076 ns/op | **13.8× faster** |
| A4 **F4**: impossible date + 157-item year list, 2k searches | **1,668,307 ns/op** | — | — | 442,330 ns/op | **3.77× slower** |
| A5 reject 21 malformed expressions, 420k ops | 95 ns/op | 975 ns/op | 309 ns/op | — | **3.2× faster** |
| A6 long explicit lists (up to 2 KB), 60k parses | 5,633 ns/op | 22,113 ns/op | 16,613 ns/op | — | **2.9× faster** |

Peak RSS: Pion 1.75–1.80 MiB, croner 5.5–5.8 MiB, robfig 12–13.5 MiB, Quartz 211–557 MiB.
Quartz timings include JVM start-up (≈ 0.1 s per run), which flatters Pion on A1–A3 and makes A4's
loss *larger* in steady state.
