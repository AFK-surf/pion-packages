# Red-team audit: `packages/csv` (Pion) vs Rust `csv =1.4.0` / Go `encoding/csv`

Target: `AFK-surf/pion-packages` `origin/feat/pkg-csv` @ `dab6e75`, branch `audit/redteam-csv`.
Nothing outside `packages/csv/audit/` was changed.

| reference | version | used for |
| --- | --- | --- |
| Rust `csv` | **1.4.0** (resolves `csv-core` **0.1.13**, pinned in `tools/rust_ref/Cargo.lock`) | every behaviour claim (reader + writer), benchmarks |
| Go `encoding/csv` | go 1.27.3 stdlib | benchmarks |

Machine: `tokyo-mac-studio-0`, Apple M5 Max (18 cores, arm64 Darwin), pionc 0.1.0, cargo 1.100, go 1.27.3,
node 24.22. The machine is shared (load average 14-17 during the runs). Benchmarks are interleaved
`scripts/bench_compare.py` runs (warmup 1, 5 rounds, stdout SHA-256 identical across all implementations);
conclusions only rely on gaps far larger than the run-to-run spread (~5-10 %).

## Reproduce

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
sh packages/csv/audit/run_audit.sh                 # everything, ~5 min; logs in /tmp/pion-csv-audit/logs
sh packages/csv/audit/run_audit.sh --quick         # smaller fuzz, 3 bench rounds
SECTIONS="build tests" sh packages/csv/audit/run_audit.sh   # sections: build tests probes fuzz dos bench clean
pionc test --json -p csv_redteam_audit packages/csv/audit   # failing-test evidence alone (~2 s)
python3 packages/csv/audit/diff/probes.py         # hand-written probes, both outputs side by side (needs `build`)
```

`run_audit.sh` exits 1 while any `fN_*` test fails. `pionc test packages/csv` (the package's own suite,
24 tests) is unaffected by `audit/` and still passes.

Result of `pionc test -p csv_redteam_audit packages/csv/audit` today: **18 tests, 11 failed (every failure
is a finding below), 7 passed (controls / pinned divergences)**.

## Layout

| path | what |
| --- | --- |
| `redteam_test.pion` | `fN_*` tests assert the correct / Rust behaviour (FAIL now, PASS once fixed); `control_*`, `dN_*` pass and pin parity |
| `tools/rust_ref/` | Rust `csv =1.4.0` driver (`rust_ref`: differential; `rust_bench`: benchmarks) |
| `tools/pion_cli/` | Pion driver, same case/output format; 5 variants: `read-string` (fast path), `read-bytes`, `read-fresh` (`next_record`), `write`, `write-rec` |
| `diff/fuzz_diff.py` | differential fuzz over the full config matrix, batched greedy minimizer, automatic root-cause mapping, residual check, writer round trip, wasm32-vs-native |
| `diff/probes.py` | the brief's hand-written attack list, Pion vs Rust side by side |
| `dos/dos_probe.py` | O(n^2) scaling probe |
| `bench/` | adversarial corpora (`gen_adversarial.py`), Pion / Go benchmark drivers (Rust one is `tools/rust_ref/src/bench.rs`) |

## Summary

| id | sev | finding | evidence |
| --- | --- | --- | --- |
| F1 | **P1** | `has_headers=false`: if `headers()` fails on row 1 (bad UTF-8), `read_record` silently skips row 1 | `f1_*`, probe F1, fuzz (60 minimized groups) |
| F2 | **P1** | `RecordTooLarge` / `TooManyFields` do not consume the record: an error-skipping loop never terminates | `f2_*`, `f2b_*` |
| F3 | **P1** | default `Limits` reject ordinary files: 10,000,001 rows or 65,537 columns fail with `CsvConfig::default()` | `f3_*`, `f3b_*`, `run_audit.sh bench` (20 MB file) |
| F4 | **P1** | writer: a zero-field record is written as a blank line and vanishes on read-back (Rust writes `""`) | `f4_*`, probe F4 |
| P1-perf | **P1** | README's "Pion ~ Go, Rust 1.22x" holds only for its 15 MB, 2-pass, default-config corpus; on 7 of 9 other workloads Pion is 1.8-2.7x slower than like-for-like Rust, and slower than Go in 8 of 9 | bench tables below |
| F5 | P2 | `Position.line` differs between `from_string` and `from_bytes` (custom terminator + newline in quoted field; Rust is wrong here too) | `f5_*`, fuzz (43 groups, all position-only) |
| F6 | P2 | `Trim` is ASCII-only; Rust `StringRecord::trim` strips Unicode White_Space (`\x0B`, U+00A0, U+0085, U+2028, U+3000) | `f6_*`, probe F6 |
| F7 | P2 | `QuoteStyle::NonNumeric` quotes `NaN` / `inf` / `-inf` / `Infinity`; Rust writes them bare | `f7_*`, fuzz (505 cases) |
| F8 | P2 | `QuoteStyle::Never` + single empty field writes a blank line (row lost); Rust writes `""` | `f8_*`, fuzz (174 cases) |
| F9 | P2 | `has_headers=true`: a header with bad UTF-8 loses its field count; data rows are length-checked against row 2 instead | `f9_*`, fuzz residual (127 cases) |
| P2-perf | P2 | fast path is skipped until the last 16 MiB of any input > 16 MiB (1.14-1.22x); slow path 2x slower than Rust on `;`, escapes, wide rows, `from_bytes`; 1.65x Rust's memory in `read_all` | bench tables below |
| D1-D7 | - | divergences where Pion is at least as good as Rust (positions, comment termination, LF terminator, ...) | `d1_*`, `d3_*`, probes D1-D7 |

What held up (no finding): the quote/escape state machine (mid-field quotes, text after a closing quote,
`""`, `\"`, escape outside quotes, escaped newline, `quoting=false`, `double_quote=false`, trim vs quotes),
comment detection position, BOM stripping, strict UTF-8 validation (`F4 90 80 80`, overlong, surrogates,
lone continuation, truncation, 4-byte window edge, exact `field` / `valid_up_to`), `Record` reuse after
errors (no stale spans), the writer's quoting rules (comment char, custom escape, `Terminator::Any`),
round trip (6,400 written outputs re-read by both libraries: 0 lossy), wasm32 (133,816 differential runs
byte-identical to native), and DoS scaling (every adversarial pattern linear).

---

## Differential fuzz (what was run)

`diff/fuzz_diff.py 40000 10000 4180` (seeded, reproducible). Config matrix per case: `delimiter`
`, ; \t |`, `quote` `" '`, `double_quote`, `escape` None/`\`, `comment` None/`#`, `quoting`, `trim`
None/Headers/Fields/All, `terminator` CRLF / LF / Any(`\n`) / Any(`\r`) / Any(`0x1E`), `has_headers`,
`flexible`; 30 % of cases forced to the default config so the `read_record_fast` path is hit. Inputs mix
the config's special bytes, `\r`, `\n`, `\r\n`, ` \t\x0B\x0C`, doubled quotes, BOMs, multibyte and
Unicode-space text, and (15 % of cases) invalid UTF-8 (`FF`, `C0 AF`, `ED A0 80`, `F4 90 80 80`, truncations).
Every case runs through Rust and three Pion reader variants (`from_bytes`, `from_string` = fast path,
`next_record` = fresh records), and every divergence is classified:

```
reader: 40000 cases, 23594 divergent (positions account for most: D1)
  residual content divergences after neutralizing trim/comment/LF/has_headers: 252 of 12475
     127  F9-header-error-drops-length-check
     125  D7-error-precedence-UnequalLengths-vs-InvalidUtf8
  root causes of the minimized sample (fuzz hits):
     120  D1-position-semantics          60  F1-hdr0-first-row-error-dropped
      43  F5-line-numbers-from_string-vs-from_bytes   33  F6/D4-trim-semantics
      20  D3-comment-termination         7  D2-terminator-LF-is-CRLF
writer: 10000 cases: 505 F7-nonnumeric-nan-inf, 174 F8-never-single-empty-field, nothing else
round trip (Necessary/Always): 6400 outputs re-read: 0 lossy in all four writer x reader pairs
wasm32: read-bytes 40000 / read-string 36908 / read-fresh 36908 / write 10000 / write-rec 10000: identical to native
```

The residual check re-runs **every** content-divergent case with the known root-cause features switched
off; everything left is classified (F9, D7) and **0 are unexplained**. Zero-field writer records are
excluded from the writer fuzz because they always hit F4.

---

## P1

### F1 — `has_headers = false`: row 1 silently dropped after a `headers()` error

`src/reader.pion:1915-1918` caches the header error (`headers_err`) but never sets `pending_first`, and
`read_record` only re-reads the header for `has_headers = true` (`:1935`). So with `has_headers = false`
(row 1 is data) and invalid UTF-8 in row 1, the caller that does `headers()` then loops `read_record`
never sees row 1 nor its error.

```
probe F1  cfg: has_headers=false  input: b'\xff,b\na,b\n'
  rust        HE U8 0 0 @ 0 1 0 | E U8 0 0 @ 4 2 1 | R ['a','b']
  pion bytes  HE U8 0 0 @ 0 1 0 |                     R ['a','b']        <- row 1 vanished, no error
```

Fix direction: on header error with `has_headers = false`, keep the error pending for the first
`read_record` call (Rust: `read_byte_record` re-yields the cached first row).

### F2 — limit errors never advance: error-skipping loops spin forever

`TooManyFields` (`src/reader.pion:614-622`) and `RecordTooLarge` (`:784-794`, `:847-855`, `:901-911`, and
the bytes path `:1121`, `:1209`, `:1326`) `return Err(..)` before `self.offset = i` (`:960`), so the next
`read_record` re-scans the same record and returns the same error at the same byte. The package's own
suite documents "error + continue" as the recovery pattern (`rust_csv_unequal_lengths_and_continue`); with
these two errors that pattern is an infinite loop — a DoS for any service that skips bad rows and sets a
limit (which is what the limits are for). Rust and Go consume the offending record on every error.

`f2_*`: `max_record_bytes = 8`, input `0123456789abcdef\nok\n` → 5 calls, 5 x `RecordTooLarge @ byte 0`,
`ok` never reached. `f2b_*`: same with `max_fields_per_record = 3`.

Fix direction: skip to the end of the offending record (or at least past `scan_limit`) before returning.

### F3 — default `Limits` reject legitimate files

`Limits::default()` (`src/types.pion:36-42`) is applied by `CsvConfig::default()`: `max_records =
10,000,000`, `max_fields_per_record = 65,536`, `max_record_bytes = 16 MiB`. A 20 MB file of
10,000,001 one-column rows fails:

```
run_audit.sh bench:  pion_adv default many_rows.csv  -> parse error: csv: record count exceeded limit 10000000
                     rust_bench default byte many_rows.csv -> records=10000000 (+ header)
```

`f3b_*`: a 70,000-column row (genomics / sensor matrices) → `TooManyFields(65536)`. Neither Rust nor Go has
any such limit. `max_records` in particular protects nothing a streaming reader needs (memory per record
is already bounded by `max_record_bytes`), it only breaks large exports. Fix direction: limits opt-in
(`Limits::unlimited()` default, `Limits::strict()` preset), or at least `max_records = 0`.

### F4 — writer drops zero-field records

`Writer::write_record([])` (`src/writer.pion:361`, the `if n > 0` hot paths at `:391` / `:463`) writes only
the terminator. Every CSV reader, Pion's included, skips blank lines, so the record disappears and all
following row numbers shift. csv-core's `Writer::terminator` writes `""` when `record_bytes == 0`.

```
probe F4  records=[[a], [], [b]]
  rust  W b'a\r\n""\r\nb\r\n'
  pion  W b'a\r\n\r\nb\r\n'        -> read back: 2 records instead of 3
```

### P1-perf — the published benchmark is the best case

`packages/csv/README.md` reports Pion 1.01x Go and Rust 1.22x Pion on one 15.4 MB corpus read twice.
That reproduces (`bench/run_bench.sh`: Pion 87.4 ms, Rust 72.9, Go 88.6), but it is the single most
favourable setup:

1. the corpus is just under `max_record_bytes` (16 MiB), the only size where the fast path covers the
   whole input (P2-perf a);
2. Pion `from_string` does **no** UTF-8 validation while the Rust side uses `StringRecord` (validates
   every record): the like-for-like pairs are Pion `from_string` vs Rust `ByteRecord`, and Pion
   `from_bytes` vs Rust `StringRecord`;
3. only the default config (`,` `"` no trim/comment/escape) is measured: every other config takes the
   slow path.

Adversarial and like-for-like results (`run_audit.sh bench`, median ms, peak RSS; baseline `rust_byte`):

| corpus (size) / mode | Pion | Rust `StringRecord` | Rust `ByteRecord` | Go | Pion vs Rust (like-for-like) | Pion vs Go |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| mixed 15 MB, default (README corpus, 1 pass) | 51.7 / 31 MiB | 39.7 | 35.5 / 17 MiB | 48.4 | 1.45x slower | 1.07x slower |
| mixed 77 MB, default | 256.5 / 149 MiB | 164.8 | 141.2 / 76 MiB | 202.8 | 1.82x slower | 1.26x slower |
| mixed 77 MB, `from_bytes` (validated) | 377.1 | 164.0 | 141.5 | 201.0 | **2.30x** slower (vs `StringRecord`) | 1.88x slower |
| mixed 77 MB, every field as `String` (`Record::fields()`) | 344.0 | 359.2 | - | 203.9 | 0.96x (Pion faster) | 1.69x slower |
| heavy `""` quoting 52 MB | 210.5 / 101 MiB | 102.2 | 104.9 / 51 MiB | 177.0 | **2.01x** slower | 1.19x slower |
| 1,000 columns x 20k rows, 58 MB | 258.4 / 112 MiB | 121.5 | 119.7 / 57 MiB | 267.9 | **2.16x** slower | 0.96x (Pion faster) |
| `;` delimiter 55 MB | 206.4 / 107 MiB | 115.9 | 97.8 / 54 MiB | 155.5 | **2.11x** slower | 1.33x slower |
| `Trim::All` + `#` comment 64 MB | 145.0 / 124 MiB | 282.8 | 193.3 / 63 MiB | 111.2 | 0.75x (Pion faster) | 1.30x slower |
| escape `\` + `double_quote=false` 22 MB | 114.9 / 44 MiB | 45.4 | 42.7 / 23 MiB | n/a | **2.69x** slower | - |
| `read_all` 2M x 10 one-byte fields, 40 MB | 475.6 / **852 MiB** | 271.4 | 265.4 / 518 MiB | 397.6 / 520 MiB | 1.79x slower, **1.65x memory** | 1.20x slower |
| 1M one-byte records (dos probe, 4N) | 120.4 | - | 34.1 | - | **3.5x** slower | - |

All rows: stdout SHA-256 identical across implementations. Pion's peak RSS is ~2x the input in every
streaming row; the Go driver has the same ~2x (it converts the file to a `string`), Rust reads once. That
part is the runner's `fs_read` copy, not `packages/csv` — but `read_all` (1.65x Rust) is the package's own
per-record overhead (`Record` struct + `Array[Int]` spans of 16 bytes per field).

Where Pion wins: `Trim::All` + comment (1.33x faster than Rust `ByteRecord`, 1.95x faster than
`StringRecord`, whose Unicode `trim` reallocates every record) and field materialization vs Rust
`StringRecord` + `String::from`.

## P2

### F5 — line numbers depend on the input type

With `Terminator::Any(b)`, `build_read_lut` (`src/reader.pion:107-110`) sets no `cls_lf` / `cls_cr`, so the
4-byte window of the String path (`quote_stop_mask`, `:606`, loop at `:633-643`) skips newlines inside
quoted fields without counting them, while the Bytes path (`:1193-1201`) checks every byte. The same
document gets different `Position.line` values from `from_string` and `from_bytes`:

```
probe F5  cfg: term=Any(0x1E)  input: b'"abc\ndefghijk"\x1ec\x1e'   (position line of record 2)
  pion from_bytes 2      pion from_string 1      rust 1
```

Rust is no reference here: csv-core's `scan_and_copy` fast scan (`csv-core-0.1.13/src/reader.rs:679`)
skips the `\n` without counting it too (its byte-by-byte path at `:665` counts). Pion's own convention
(count every line break, used by `from_bytes` and by `d1_*`) gives 2; `f5_*` asserts both paths say 2.
Fuzz: 43 minimized groups, all position-only. Unquoted fields with `Terminator::Any` and an embedded `\n`
are counted by neither Pion path.

### F6 — `Trim` is ASCII-only

`ascii_ws_lut` (`src/reader.pion:62-72`) trims ` \t\n\x0C\r`. Pion returns `String` fields, and Rust's
`StringRecord::trim` (`csv-1.4.0/src/string_record.rs:428-441`) uses `str::trim`, i.e. Unicode
White_Space, which also includes `\x0B`, U+0085, U+00A0, U+2028, U+3000 (common in CJK / spreadsheet
exports). Probe F6: Rust `['a','b','c','d']`, Pion `['\x0ba\x0b', '\xa0b\xa0', '　c　', '\x85d ']`.
(Rust's `ByteRecord::trim` is ASCII-only, so either answer exists upstream; the `String` API should match
`StringRecord`, or the README should say ASCII.)

### F7 — `NonNumeric` disagrees with Rust on `NaN` / `inf`

`span_is_numeric` (`src/writer.pion:103`) is a decimal grammar; csv-core's `is_non_numeric` is
`s.parse::<f64>().is_err() && s.parse::<i128>().is_err()`, which accepts `NaN`, `inf`, `-inf`, `Infinity`
(case-insensitive). Pion quotes them; output differs from Rust byte-for-byte (505 of 10,000 writer fuzz
cases). Everything else matched: `1e5 -0.5 .5 5. +7` bare, `0x10 "" " 123" 1_000` quoted, and both write
`1.5` bare with delimiter `.` (shared, lossy in both).

### F8 — `QuoteStyle::Never` + single empty field loses the row

`src/writer.pion:378-383` (and `:567`) skip the `""` for `Never`. csv-core writes `""` whenever
`record_bytes == 0`, regardless of style (its doc comment says otherwise, the code does this). Pion's
output `x\n\n` reads back as one record. 174 of 10,000 writer fuzz cases.

### F9 — header UTF-8 error drops the header's field count

Same spot as F1 (`src/reader.pion:1915-1918`): on a header error `expected_len` is never set, so with
`has_headers = true, flexible = false` the first *data* row defines the expected length. Probe F9 input
`\xff,b\nx\n`: Rust `HE U8 | E UL 2 1`, Pion `HE U8 | R ['x']`. 127 residual fuzz cases.

### P2-perf

a. **16 MiB fast-path cliff.** `read_record_fast` hands every record to the slow
   `read_raw_record_string` while more than `max_record_bytes` of input remain (`src/reader.pion:1492`),
   so on a 77 MB file only the last 16 MiB are parsed by the fast path:
   `max_record_bytes = 0` makes the same file 1.14-1.22x faster (`fast-path cliff` table in
   `logs/bench.md`; 15 MB corpus: 1.02x, i.e. no cliff). The bound check could be done per record instead.
b. **Non-default configs are 2.0-2.7x slower than Rust** (`;`, escape, heavy `""`, 1,000 columns): they
   all run the generic LUT path with per-field `StringBuilder` promotion.
c. **`from_bytes` costs 1.47x `from_string`** (377 vs 257 ms): the Bytes path copies quoted fields byte by
   byte (`write_bytes_slice`, `:983-990`) and copies every record (`raw.slice(..).to_string()`, `:1426`)
   before validating.
d. **Per-record overhead**: 1M one-byte records take 3.5x Rust (dos probe), `read_all` uses 1.65x Rust's
   memory.

### Not attributed to `packages/csv`

- `Reader::from_string` trusts its `String` to be UTF-8, but `Bytes::to_string()` does not validate
  (`pion_cli` feeding `b'a,"b\xff"'` through `from_string` yields a field containing a raw `0xFF`). That is
  a String invariant of the language/runtime; `from_bytes` validates correctly.
- Peak RSS ~2x input in streaming benchmarks: the `fs_read` copy in the drivers (Go's driver does the same).

## Divergences where Pion is at least as good (no fix needed; pinned by `d1_*`, `d3_*`, probes)

| id | Pion | Rust csv 1.4.0 |
| --- | --- | --- |
| D1 | record `Position` = first byte of the record itself; `\r`, `\n`, `\r\n` each count one line; BOM counted in `byte` | position = where the previous record ended (before skipped blank / comment lines and the BOM); only `\n` counts (`a\n\n\nb`: Pion `b@4:4`, Rust `b@2:2`) |
| D2 | `Terminator::LF` in the reader behaves exactly like `CRLF` (`\r` alone ends a record) | has no LF; `Any(b'\n')` keeps `\r` as data |
| D3 | a comment line ends at the record terminator (`\r`, `\r\n`, `\n` or `Any(b)`) | ends only at `\n`: `#` at EOF yields a phantom `[""]` record; `comment` + `Any(0x1E)` returns `[""]` for `#x\x1ea\nb\x1ec\x1e` (Pion: `[a\nb]`, `[c]`) |
| D4 | `has_headers=false, Trim::Fields`: `headers()` is trimmed like the record it is | `headers()` untrimmed, the same row via `read_record` trimmed |
| D5 | unclosed quote is an error by default (`allow_unclosed_quotes` to opt out), like Go | always lenient |
| D6 | writer checks `UnequalLengths` before writing anything | writes the fields, then errors in `write_terminator` |
| D7 | a record with both wrong length and bad UTF-8 reports `InvalidUtf8` | reports `UnequalLengths` (checked on bytes first) |

(D6 is from reading `csv-1.4.0/src/writer.rs:918-927, 1128-1129`; the differential driver stops at the first writer error so it
does not compare partial output.)

## DoS / complexity (`dos/dos_probe.py`)

t(4N)/t(N), best of 3, includes process start-up; ~4 = linear, ~16 = quadratic.

| pattern | N | Pion t(N) / t(4N) ms | ratio | Rust t(N) / t(4N) ms | ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| one 8 MB quoted field of `""` | 1M | 11.8 / 41.2 | 3.48 | 6.7 / 18.2 | 2.73 |
| 10k-column rows | 100 | 12.9 / 41.7 | 3.24 | 6.5 / 18.2 | 2.79 |
| comment-line flood (`Trim::All` + `#`) | 1M | 8.9 / 23.1 | 2.61 | 14.5 / 47.9 | 3.30 |
| blank-line flood | 4M | 6.9 / 19.5 | 2.84 | 8.0 / 21.1 | 2.65 |
| escape flood in one field | 1M | 10.7 / 35.8 | 3.36 | 6.7 / 17.7 | 2.65 |
| text after closing quote, every field | 100 | 5.6 / 13.8 | 2.48 | 4.3 / 8.0 | 1.89 |
| 1M one-byte records | 1M | 32.6 / 120.4 | 3.69 | 11.1 / 34.1 | 3.08 |

No super-linear pattern found. The real DoS surface is F2 (infinite loop on a recoverable error), not
complexity. `read_all` has no total-size limit (neither has Rust's `records().collect()`); memory is
bounded by input size x the 1.65x overhead above, plus a fast-path `Record` keeps the whole input
`String` alive (its `backing_string()` is the input).

## Benchmark fairness notes (`packages/csv/bench/`)

- `pion_read` reads fields via `field_start` / `field_end` spans on the backing string; `rust_read` uses
  `StringRecord::get` (also zero-copy) and `go_read` gets allocated strings. The access pattern is fair;
  the UTF-8 validation is not (Pion none, Rust every record, Go none) — see P1-perf.
- Both rounds parse the same in-memory `String`; with one pass the fixed start-up share grows and Pion
  falls behind Go too (51.7 vs 48.4 ms on the same 15 MB corpus).
- The write benchmark only covers `QuoteStyle::Necessary` with the default delimiter, the one inlined hot
  path in `Writer::write_record`; other styles/delimiters go through `write_field_span`.
