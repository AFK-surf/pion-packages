# `csv` — Pure-Pion RFC 4180 + Flexible Streaming CSV Library

Zero-dependency, pure-Pion streaming CSV reader and writer modeled after Rust [`BurntSushi/rust-csv`](https://github.com/BurntSushi/rust-csv), with an O(N) deterministic scanner, Day-1 DoS/OOM `Limits`, strict RFC 3629 UTF-8 validation, and 4-byte unrolled fast paths.

## Compliance & Test Results

- **Ported `BurntSushi/rust-csv` Reader Suite (`reader_test.pion`)**: **12 / 12 (100%)** — `csv-core/src/reader.rs` & `src/reader.rs` matrix (single/multi-row, trailing comma, `\n` / `\r\n` / lone `\r` normalization, empty lines, custom delimiters/quotes/escapes/terminators, ASCII delimited `\x1F`/`\x1E`, comments, `strange.csv` fixture, `Trim::None`/`Headers`/`Fields`/`All`, lazy/cached headers with & without `has_headers`, unequal lengths error + continue + `flexible`, unclosed quote error with 1-based line & 0-based byte offset, reusable `Record` buffer)
- **Ported `BurntSushi/rust-csv` Writer Suite (`writer_test.pion`)**: **6 / 6 (100%)** — `csv-core/src/writer.rs` & `src/writer.rs` matrix (single/multi-field, single empty field `""\n` disambiguation, `QuoteStyle::Necessary`/`Always`/`NonNumeric`/`Never`, doubled quotes `""` & custom escape `\`, `Terminator::LF`/`CRLF`/`Any`, comment character auto-quoting, unequal length enforcement vs `flexible`, full RFC 4180 round-trip)
- **Day-1 Red-Team Security & Regression Suite (`redteam_test.pion`)**: **9 / 9 (100%)** — giant unclosed quote bounded in O(`max_record_bytes`), `max_fields_per_record`, `max_records`, error-skipping recovery on limit errors (F2), O(N) linear scaling on 50k commas / 20k doubled quotes / 50k blank lines, strict RFC 3629 UTF-8 validation (bare 0xFF, overlong `0xC0 0xAF`, UTF-16 surrogates `0xED 0xA0 0x80` with exact field index, `valid_up_to`, 1-based line & byte offset), header UTF-8 error retention & field-count locking (F1/F9), `Limits::default()` unlimited vs `Limits::strict()` (F3), writer zero-field & `QuoteStyle::Never` empty-field preservation (F4/F8), `Terminator::Any` line-number parity (F5), Unicode `White_Space` trimming (F6), `QuoteStyle::NonNumeric` special floats `NaN`/`inf`/`Infinity` (F7), and UTF-8 BOM stripping
- **Red-Team Differential Audit (`packages/csv/audit`)**: **18 / 18 (100%)** vs Rust `csv =1.4.0` (`csv-core 0.1.13`), plus 40,000 reader + 10,000 writer differential fuzz cases, 6,400 lossless round-trips (0 lossy), and 133,816 wasm32-vs-native byte-identical runs
- **Wasm32**: `pionc build --release --target wasm32 -o /tmp/csv_wasm_smoke.wasm packages/csv/wasm_smoke` builds cleanly and matches native byte-for-byte

## Features

- **`CsvConfig`**: `delimiter`, `quote`, `double_quote`, `escape`, `comment`, `has_headers`, `flexible`, `trim` (`None` / `Headers` / `Fields` / `All` — Unicode `White_Space` aligned with Rust `char::is_whitespace()`), `terminator` (`CRLF` / `LF` / `Any(Byte)`), `quoting`, `quote_style` (`Necessary` / `Always` / `NonNumeric` / `Never`), `strip_bom`, `allow_unclosed_quotes`, `limits`, and `.ascii()` preset.
- **Streaming `Reader`**: `Reader::from_string`, `Reader::from_string_with_config`, `Reader::from_bytes`, `Reader::from_bytes_with_config`, `headers()`, `next_record()`, `read_record(rec)` (reusable zero-copy buffer), `read_all()`, and `position()`.
- **`Record`**: contiguous backing buffer with byte spans (`len`, `is_empty`, `get`, `field`, `field_span`, `field_start`, `field_end`, `backing_string`, `fields`, `position`, `line`, `byte_offset`).
- **High-Performance `Writer`**: `Writer::new`, `Writer::with_config`, `Writer::with_capacity`, `write_record`, `write_csv_record`, `write_all`, `finish`, `finish_bytes`.
- **Opt-In Resource `Limits`**: `Limits::default()` / `Limits::unlimited()` imposes no limits (`0` for all fields, matching Rust `csv` and Go `encoding/csv`); use `Limits::strict()` (`max_record_bytes = 16 MiB`, `max_fields_per_record = 65,536`, `max_records = 10,000,000`) or custom `Limits` for untrusted inputs.

## Quick Start

```pion
import "csv"

pub fn example() -> Result[String, csv::CsvError] {
  let rdr = csv::Reader::from_string("name,score\n\"Alice, Ace\",99.5\nBob,87\n")
  let hdr = match rdr.headers() {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  let wtr = csv::Writer::with_config(csv::CsvConfig::default().with_terminator(csv::Terminator::CRLF))
  match wtr.write_csv_record(hdr) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let rec = csv::Record::new()
  while true {
    match rdr.read_record(rec) {
      Ok(true) => {
        match wtr.write_csv_record(rec) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      Ok(false) => break
      Err(e) => return Err(e)
    }
  }
  Ok(wtr.finish())
}
```

## Head-to-Head Benchmarks (Pion Native vs Rust `csv =1.4.0 --release` vs Go `encoding/csv`)

Measured on `Linux x86_64` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification).

### Like-for-Like Comparison Methodology

- `Reader::from_string` trusts its `String` input to be UTF-8 (no per-record UTF-8 validation): its like-for-like Rust counterpart is **`Rust ByteRecord`** (`rust_byte`).
- `Reader::from_bytes` validates UTF-8 strictly per RFC 3629: its like-for-like Rust counterpart is **`Rust StringRecord`** (`rust_str`).

### Adversarial & Large-File Matrix (`SECTIONS="bench" sh packages/csv/audit/run_audit.sh`)

All rows verified byte-for-byte stdout SHA-256 identical across every implementation and round.

| Corpus (Size) / Mode | Pion (ms / RSS) | Rust `StringRecord` | Rust `ByteRecord` | Go `encoding/csv` | Pion vs Like-for-Like Rust & Go | Stdout SHA-256 (prefix) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `mixed_200k.csv` (15 MB, default `from_string`) | **63.5** / 31.3 MiB | 40.9 | 35.4 / 16.7 MiB | 65.0 | 1.79x vs `ByteRecord` (**1.02x faster vs Go**) | `238820ffb412645a` |
| `mixed_1m.csv` (77 MB, default `from_string`) | **296.6** / 149.4 MiB | 184.2 | 149.1 / 75.8 MiB | 299.9 | 1.99x vs `ByteRecord` (**1.01x faster vs Go**) | `97221bca6d1004af` |
| `mixed_1m.csv` (77 MB, `from_bytes` validated) | **294.0** / 149.3 MiB | 162.2 | 141.3 / 75.8 MiB | 252.9 | 1.81x vs `StringRecord` | `97221bca6d1004af` |
| `mixed_1m.csv` (77 MB, `Record::fields()` alloc) | **327.4** / 149.3 MiB | 319.1 | 147.1 / 75.6 MiB | 322.5 | 1.03x vs `StringRecord` (~parity with Rust & Go) | `97221bca6d1004af` |
| `heavy_quote.csv` (52 MB, dense `""` escapes) | **208.0** / 101.0 MiB | 108.5 | 108.2 / 51.4 MiB | 194.7 | 1.92x vs `ByteRecord` (1.07x vs Go) | `3c55bcf725b2b4d0` |
| `wide_1000.csv` (58 MB, 1,000 cols × 20k rows) | **310.4** / 112.6 MiB | 149.9 | 151.2 / 57.2 MiB | 391.2 | 2.05x vs `ByteRecord` (**1.26x faster vs Go**) | `073eb90b9624881a` |
| `semicolon.csv` (55 MB, `;` delimiter) | **247.4** / 107.0 MiB | 147.4 | 128.1 / 54.5 MiB | 245.0 | 1.93x vs `ByteRecord` (~parity with Go) | `40345eda2400b10b` |
| `trim_comment.csv` (64 MB, `Trim::All` + `#`) | **210.7** / 124.1 MiB | 276.8 | 202.5 / 63.1 MiB | 188.5 | **1.31x faster vs `StringRecord`**, 1.04x vs `ByteRecord` | `66276dcc4331b3f9` |
| `escape.csv` (22 MB, `\` escape, `double_quote=false`) | **118.1** / 44.2 MiB | 55.2 | 53.6 / 23.1 MiB | n/a | 2.20x vs `ByteRecord` | `9ae0aabfea6d2ca3` |
| `narrow.csv` (40 MB, `read_all` 2M × 10 fields) | **523.1** / **471.2 MiB** | 601.4 | 579.8 / 574.6 MiB | 788.9 / 510.5 MiB | **1.11x faster & -103 MiB RSS vs `ByteRecord`**, **1.51x faster vs Go** | `0f6b0ef0092b8c05` |

- **No 16 MiB fast-path cliff**: on `mixed_1m.csv` (77 MB), `CsvConfig::default()` (`348.6 ms`) and `max_record_bytes = 0` (`371.6 ms`) are within run-to-run variance (`0.94x`).

### Steady-State 2-Round Benchmarks (`sh packages/csv/bench/run_bench.sh`)

#### Bench 1 (Read): 200k-row Mixed CSV × 2 Steady-State Rounds (400,000 records, `30,910,952 B`)

Stdout SHA-256 (verified identical): `1ead353719fe54e5aea4d0c4818d61134d51f364cef4f4f8bd4beff1b5310c24`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_csv`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (`from_string`) | **95.742** | 86.369 | 97.058 | **322.86** | **239.35** | 31.31 MiB | **1.10x** |
| `rust_csv` (`StringRecord`, `=1.4.0 --release`) | **71.969** | 64.928 | 96.865 | **429.50** | **179.92** | 16.70 MiB | **1.47x** |
| `go_csv` (`encoding/csv`) | 105.718 | 94.370 | 113.833 | 292.39 | 264.29 | 34.26 MiB | 1.00x (baseline) |

#### Bench 2 (Write): 200k Structured Records × 2 Steady-State Rounds (400,000 records, `29,001,498 B`)

Stdout SHA-256 (verified identical): `ddc27c6360c7b492919a2ebe9e6421cf6adf7aec87566c2a2794c81592e69db5`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_csv`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **83.718** | 78.958 | 96.432 | **346.42** | **209.30** | 31.76 MiB | **1.51x** |
| `rust_csv` (`=1.4.0 --release`) | **70.046** | 67.606 | 80.255 | **414.04** | **175.11** | 18.39 MiB | **1.80x** |
| `go_csv` (`encoding/csv`) | 126.341 | 102.084 | 147.008 | 229.55 | 315.85 | 39.81 MiB | 1.00x (baseline) |

## Verification

```sh
pionc fmt --check packages/csv
pionc check --json packages/csv
pionc test --json packages/csv
pionc test --json -p csv_redteam_audit packages/csv/audit
pionc build --release --target wasm32 -o /tmp/csv_wasm_smoke.wasm packages/csv/wasm_smoke
sh packages/csv/audit/run_audit.sh
sh packages/csv/bench/run_bench.sh
```
