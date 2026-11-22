# `csv` — Pure-Pion RFC 4180 + Flexible Streaming CSV Library

Zero-dependency, pure-Pion streaming CSV reader and writer modeled after Rust [`BurntSushi/rust-csv`](https://github.com/BurntSushi/rust-csv), with an O(N) deterministic scanner, Day-1 DoS/OOM `Limits`, strict RFC 3629 UTF-8 validation, and 4-byte unrolled fast paths.

## Compliance & Test Results

- **Ported `BurntSushi/rust-csv` Reader Suite (`reader_test.pion`)**: **12 / 12 (100%)** — `csv-core/src/reader.rs` & `src/reader.rs` matrix (single/multi-row, trailing comma, `\n` / `\r\n` / lone `\r` normalization, empty lines, custom delimiters/quotes/escapes/terminators, ASCII delimited `\x1F`/`\x1E`, comments, `strange.csv` fixture, `Trim::None`/`Headers`/`Fields`/`All`, lazy/cached headers with & without `has_headers`, unequal lengths error + continue + `flexible`, unclosed quote error with 1-based line & 0-based byte offset, reusable `Record` buffer)
- **Ported `BurntSushi/rust-csv` Writer Suite (`writer_test.pion`)**: **6 / 6 (100%)** — `csv-core/src/writer.rs` & `src/writer.rs` matrix (single/multi-field, single empty field `""\n` disambiguation, `QuoteStyle::Necessary`/`Always`/`NonNumeric`/`Never`, doubled quotes `""` & custom escape `\`, `Terminator::LF`/`CRLF`/`Any`, comment character auto-quoting, unequal length enforcement vs `flexible`, full RFC 4180 round-trip)
- **Day-1 Red-Team Security Suite (`redteam_test.pion`)**: **6 / 6 (100%)** — giant unclosed quote bounded in O(`max_record_bytes`), `max_fields_per_record`, `max_records`, O(N) linear scaling on 50k commas / 20k doubled quotes / 50k blank lines, strict RFC 3629 UTF-8 validation (bare 0xFF, overlong `0xC0 0xAF`, UTF-16 surrogates `0xED 0xA0 0x80` with exact field index, `valid_up_to`, 1-based line & byte offset), and UTF-8 BOM stripping
- **Wasm32**: `pionc build --release --target wasm32 -o /tmp/csv_wasm_smoke.wasm packages/csv/wasm_smoke` builds cleanly (`51 KiB` `.wasm`, validated with Node.js `WebAssembly.compile`)

## Features

- **`CsvConfig`**: `delimiter`, `quote`, `double_quote`, `escape`, `comment`, `has_headers`, `flexible`, `trim` (`None` / `Headers` / `Fields` / `All`), `terminator` (`CRLF` / `LF` / `Any(Byte)`), `quoting`, `quote_style` (`Necessary` / `Always` / `NonNumeric` / `Never`), `strip_bom`, `allow_unclosed_quotes`, `limits`, and `.ascii()` preset.
- **Streaming `Reader`**: `Reader::from_string`, `Reader::from_string_with_config`, `Reader::from_bytes`, `Reader::from_bytes_with_config`, `headers()`, `next_record()`, `read_record(rec)` (reusable zero-copy buffer), `read_all()`, and `position()`.
- **`Record`**: contiguous backing buffer with byte spans (`len`, `is_empty`, `get`, `field`, `field_span`, `field_start`, `field_end`, `backing_string`, `fields`, `position`, `line`, `byte_offset`).
- **High-Performance `Writer`**: `Writer::new`, `Writer::with_config`, `Writer::with_capacity`, `write_record`, `write_csv_record`, `write_all`, `finish`, `finish_bytes`.
- **Day-1 Resource `Limits`**: `max_record_bytes` (default 16 MiB), `max_fields_per_record` (default 65,536), `max_records` (default 10,000,000).

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

Measured on `Darwin arm64` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification). Run with `sh packages/csv/bench/run_bench.sh`.

### Bench 1 (Read): 200k-row Mixed CSV × 2 Steady-State Rounds (400,000 records)

Input: `30,910,952 B` (200,000 rows × 8 columns containing unquoted fields, quoted fields with commas, doubled quotes `""`, embedded `\n`, numbers, and UTF-8 text × 2 rounds)
Stdout SHA-256 (verified identical): `1ead353719fe54e5aea4d0c4818d61134d51f364cef4f4f8bd4beff1b5310c24`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_csv`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **89.263** | 86.097 | 97.943 | **346.29** | **223.16** | 31.27 MiB | **1.01x** |
| `rust_csv` (`=1.4.0 --release`) | **72.498** | 68.409 | 75.431 | **426.37** | **181.24** | 16.66 MiB | **1.24x** |
| `go_csv` (`encoding/csv`) | 90.079 | 85.647 | 101.192 | 343.15 | 225.20 | 37.66 MiB | 1.00x (baseline) |

### Bench 2 (Write): 200k Structured Records × 2 Steady-State Rounds (400,000 records)

Output: `29,001,498 B` (200,000 structured 8-column mixed records with RFC 4180 necessary quoting × 2 rounds)
Stdout SHA-256 (verified identical): `ddc27c6360c7b492919a2ebe9e6421cf6adf7aec87566c2a2794c81592e69db5`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_csv`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **74.941** | 73.872 | 79.947 | **386.99** | **187.35** | 30.00 MiB | **1.28x** |
| `rust_csv` (`=1.4.0 --release`) | 77.115 | 74.584 | 87.889 | 376.08 | 192.79 | 16.38 MiB | 1.25x |
| `go_csv` (`encoding/csv`) | 96.165 | 93.405 | 109.630 | 301.58 | 240.41 | 40.42 MiB | 1.00x (baseline) |

## Verification

```sh
pionc fmt --check packages/csv
pionc check --json packages/csv
pionc test --json packages/csv
pionc build --release --target wasm32 -o /tmp/csv_wasm_smoke.wasm packages/csv/wasm_smoke
sh packages/csv/bench/run_bench.sh
```
