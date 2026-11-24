# `encoding` (v0.1.0)

Pure Pion **WHATWG Encoding Standard** character set decoding & encoding library — 100% pure Pion, zero external dependencies, zero `extern "C"`, zero `World` dependency, and zero mutable module globals. Designed to power Farview's HTML charset sniffing and Web `TextDecoder` / `TextEncoder` APIs, as well as the broader Pion ecosystem (`email`, `html`, `csv`, legacy CJK text).

## Coverage (All 40 WHATWG Encodings)

- **Label Resolution & BOM Sniffing (WHATWG §4.2 & §6)**:
  - `Encoding::for_label(label)` & `Encoding::for_label_no_replacement(label)`: all **228** official WHATWG labels with ASCII whitespace trimming (`U+0009`, `U+000A`, `U+000C`, `U+000D`, `U+0020`) and ASCII case-insensitive matching.
  - `sniff_bom(data)`: strict WHATWG priority for UTF-8 (`EF BB BF`, 3), UTF-16BE (`FE FF`, 2), UTF-16LE (`FF FE`, 2).
- **Unicode Encodings**:
  - `UTF-8`: strict overlong, surrogate (`U+D800..U+DFFF`), and `> U+10FFFF` rejection with WHATWG maximal-subpart replacement, 8-byte unrolled ASCII validation, and zero-copy fast path for valid UTF-8.
  - `UTF-16LE` & `UTF-16BE`: full surrogate pair assembly, lone surrogate replacement, odd trailing byte handling, and arbitrary 1-byte streaming boundaries.
- **All 28 Single-Byte Encodings + `x-user-defined` + `replacement`**:
  - `IBM866`, `ISO-8859-2`..`16`, `ISO-8859-8-I`, `KOI8-R`, `KOI8-U`, `macintosh`, `windows-874`, `windows-1250`..`1258`, `x-mac-cyrillic`, `x-user-defined`, `replacement`.
- **All 7 CJK Multi-Byte Encodings**:
  - `GBK` & `gb18030` (2-byte GB2312/GBK + 4-byte BMP/astral linear ranges + `pointer 7457 -> U+E7C7` + GB18030-2022 PUA overrides + exact WHATWG unread/EOF recovery),
  - `Shift_JIS` (Hiragana/Katakana arithmetic fast path, JIS0208 Level 1/2, IBM Kanji, EUDC, half-width Katakana),
  - `EUC-JP` (JIS0208 2-byte, `0x8E` half-width Katakana, `0x8F` JIS0212 3-byte),
  - `Big5` (Big5/HKSCS BMP + Plane 2 astral + 4 double-codepoint pointers `1133`, `1135`, `1164`, `1166`),
  - `EUC-KR` (KS X 1001 + CP949/UHC extensions),
  - `ISO-2022-JP` (complete 7-state escape machine).
- **Streaming `Decoder` & Encoders**:
  - `Decoder::new(enc)` / `Decoder::with_options(enc, DecodeOptions::new(fatal, ignore_bom))` / `decode_chunk(bytes, last)` — 1-byte-at-a-time streaming is 100% identical to whole-buffer decoding.
  - `encode_utf8`, `encode_utf16le`, `encode_utf16be`, strict `encode(enc, s) -> Result[Bytes, EncodeError]`, and WHATWG HTML `encode_html(enc, s) -> (Bytes, Bool)` (numeric character reference `&#...;` fallback).
- **Compact Immutable Tables**:
  - All 40 encodings' index tables are stored in ~187 KB of read-only printable ASCII (4+6+6 bit-packed `u16`s), requiring zero startup initialization and keeping the release Wasm32 smoke binary at **297 KB**.

## Usage

```pion
import "encoding"

let enc = encoding::Encoding::for_label("gb18030").unwrap_or(encoding::Encoding::Utf8)
let text = encoding::decode(enc, raw_bytes)

// Streaming Web TextDecoder semantics
let dec = encoding::Decoder::with_options(
  encoding::Encoding::Utf8,
  encoding::DecodeOptions::new(false, false),
)
match dec.decode_chunk(chunk1, false) {
  Ok(part1) => ()
  Err(e) => ()
}
match dec.decode_chunk(chunk2, true) {
  Ok(part2) => ()
  Err(e) => ()
}
```

## Verification & Differential Parity vs Mozilla `encoding_rs`

```sh
sh scripts/verify.sh packages/encoding
sh packages/encoding/bench/run_bench.sh
```

- **Differential Testing vs Rust `encoding_rs v0.8.44`**: **0 divergences** across:
  - All 29 single-byte encodings × `0x00..0xFF` (7,424 cases),
  - All `0x81..0xFE × 0x00..0xFF` 2-byte combinations for `GBK`, `gb18030`, `Big5`, `EUC-KR` (32,256 each),
  - `gb18030` 4-byte BMP/astral ranges and malformed/EOF recovery,
  - All `Shift_JIS` 1-byte & 2-byte sequences (15,616 cases),
  - All `EUC-JP` JIS0208, `0x8E`, and JIS0212 3-byte sequences (33,417 cases),
  - `ISO-2022-JP`, `UTF-8`, `UTF-16LE`, `UTF-16BE` malformed/BOM/surrogate cases (whole-buffer & 1-byte streaming),
  - All 10 encoders (`UTF-8`, `windows-1252`, `KOI8-R`, `GBK`, `gb18030`, `Shift_JIS`, `EUC-JP`, `Big5`, `EUC-KR`, `ISO-2022-JP`) with HTML NCR fallback.
- **4-Mode Verification (`wasm_smoke`)**:
  - `native debug` (358 KB), `native --release` (423 KB), `wasm32 debug` (296 KB), `wasm32 --release` (297 KB) all compile cleanly and produce identical output:
  - `encoding_wasm_smoke: OK checks=5 fnv64=10389566807909293613`
  - SHA-256: `1bc026dd014a95b5b6eece2c90c52117bd4531cf741802b343c78d7da60fd225`

### Head-to-Head Benchmark vs Mozilla Rust `encoding_rs` (v0.8.44, `--release`)

Measured on `Darwin arm64` (`sh packages/encoding/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved, 100 iterations of ~1 MiB realistic HTML per scenario, stdout SHA-256 verified identical across all rounds):

| Workload (~104.8 MB total) | `pion_encoding` Median (ms) | `pion_encoding` Throughput | `rust_encoding_rs` Median (ms) | `rust_encoding_rs` Throughput | Speedup | Peak RSS (Pion / Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Mixed ASCII + UTF-8 HTML | 55.994 | 1,871.79 MB/s | 18.513 | 5,661.38 MB/s | 0.33x | **7.05 MiB** / 9.08 MiB |
| Mixed Chinese GB18030 HTML | 291.471 | 359.61 MB/s | 73.164 | 1,432.61 MB/s | 0.25x | 14.08 MiB / 9.14 MiB |
| Mixed Japanese Shift_JIS HTML | 268.739 | 390.08 MB/s | 99.784 | 1,050.57 MB/s | 0.37x | 15.48 MiB / 9.11 MiB |

Note: `rust_encoding_rs` uses hand-tuned ARM64 NEON SIMD (`simdutf8` & 16-byte SIMD ASCII lanes), whereas `pion_encoding` is 100% portable scalar Pion with zero `extern "C"` and zero SIMD intrinsics.
