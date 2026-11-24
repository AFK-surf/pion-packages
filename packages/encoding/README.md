# `encoding` (v0.1.0)

Pure Pion **WHATWG Encoding Standard** character set decoding & encoding library — 100% pure Pion, zero external dependencies, zero `extern "C"`, zero `World` dependency, and zero mutable module globals. Designed to power HTML charset sniffing and Web `TextDecoder` / `TextEncoder` APIs, as well as the broader Pion ecosystem (`email`, `html`, `csv`, legacy CJK text).

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
  - `ISO-2022-JP` (complete 7-state escape machine & WHATWG §12.2.2 encoder).
- **Streaming `Decoder` & Encoders**:
  - `Decoder::new(enc)` / `Decoder::with_options(enc, DecodeOptions::new(fatal, ignore_bom))` / `decode_chunk(bytes, last)` — 1-byte-at-a-time streaming is 100% identical to whole-buffer decoding, `had_errors()` persists across `last = true` until reset/next stream, and fatal `DecodeError` reports non-negative absolute stream byte offsets.
  - `encode_utf8`, `encode_utf16le`, `encode_utf16be`, strict `encode(enc, s) -> Result[Bytes, EncodeError]`, and WHATWG HTML `encode_html(enc, s) -> (Bytes, Bool)` (numeric character reference `&#...;` fallback; ill-formed UTF-8 `String` inputs are decoded with WHATWG maximal-subpart `U+FFFD` replacement).
- **Compact Immutable Tables & Fast CJK Encoders**:
  - All 40 encodings' decode tables, bucket-indexed CJK reverse lookup tables (`gb2312_hanzi`, `jis0208_kanji`, `big5_bmp`, `big5_astral`, `ksx1001_hanja`), and the direct-mapped O(1) Hangul encoder table (`euc_kr_hangul_enc_tbl`, covering all 11,172 KS X 1001 + CP949 syllables) are stored in immutable read-only printable ASCII (`String`, 4+6+6 bit-packed `u16`s) with zero startup allocation, zero mutable module globals, and a **550 KiB** release Wasm32 smoke binary.

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
sh packages/encoding/tests/diff_oracle.sh
STRICT=1 sh packages/encoding/audit/run_audit.sh
```

- **Differential Testing vs Rust `encoding_rs v0.8.44` (`packages/encoding/audit/run_audit.sh`)**: **0 divergences** across all **1,921,335** corpus cases in all 4 modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`):
  - **7,766** label resolution cases (all 228 WHATWG labels, whitespace & case-folding edge cases),
  - **1,348,129** decode cases (all 29 single-byte encodings, exhaustive 2-byte DBCS, 3-byte EUC-JP/gb18030, 4-byte gb18030 + GB18030-2022, ISO-2022-JP state machine, UTF-8/UTF-16LE/BE, BOM sniffing & streaming across 7 chunkings),
  - **565,440** encode cases across all 40 encodings (strict + WHATWG HTML NCR fallback, including ISO-2022-JP Roman/JIS0208 transitions).
- **Unit Test Suite**: **36** package unit tests (`packages/encoding/src/encoding_test.pion`) covering WHATWG, `encoding_rs`, WPT encoding vectors, and all red-team regressions.
- **4-Mode Verification (`wasm_smoke`)**:
  - `native debug` (**629 KiB**), `native --release` (**725 KiB**), `wasm32 debug` (**549 KiB**), `wasm32 --release` (**550 KiB**) all compile cleanly and produce identical output (including genuine 1-byte streaming decode):
  - `encoding_wasm_smoke: OK checks=13 fnv64=5273225285721917244`
  - SHA-256: `0d48911ddc9b1d317b8d4ff6d2d2a2ab0868f1a67d231dec65589e56001ce4df`

### Head-to-Head Benchmark vs Mozilla Rust `encoding_rs` (v0.8.44, `--release`)

Measured on `Linux x86_64` (`sh packages/encoding/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved, stdout SHA-256 verified identical across all implementations and rounds):

#### Decoding (100 iterations of ~1 MiB realistic HTML, ~104.8 MB total)

| Workload | `pion_encoding` Median (ms) | `pion_encoding` Throughput | `rust_encoding_rs` Median (ms) | `rust_encoding_rs` Throughput | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Decode UTF-8 HTML | 51.695 | 2,027.47 MB/s | 11.974 | 8,753.00 MB/s | 0.23x |
| Decode GB18030 HTML | 241.405 | 434.19 MB/s | 85.870 | 1,220.62 MB/s | 0.36x |
| Decode Shift_JIS HTML | 230.746 | 454.31 MB/s | 91.941 | 1,140.20 MB/s | 0.40x |

#### Encoding (20 iterations of ~1 MiB realistic UTF-8 HTML, ~21.0 MB total, HTML NCR fallback)

| Workload | `pion_encoding` Median (ms) | `pion_encoding` Throughput | `rust_encoding_rs` Median (ms) | `rust_encoding_rs` Throughput | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Encode Big5 HTML | 222.858 | 94.07 MB/s | 503.733 | 41.62 MB/s | **2.26x** |
| Encode GB18030 HTML | 166.894 | 125.65 MB/s | 512.246 | 40.94 MB/s | **3.07x** |
| Encode Shift_JIS HTML | 70.912 | 295.62 MB/s | 132.529 | 158.18 MB/s | **1.87x** |
| Encode EUC-KR HTML | 65.786 | 318.69 MB/s | 135.709 | 154.49 MB/s | **2.06x** |

Note: `rust_encoding_rs` uses hand-tuned x86_64 SSE2/AVX2 SIMD (`simdutf8` & 16-byte SIMD ASCII lanes) for decoding, whereas `pion_encoding` is 100% portable scalar Pion with zero `extern "C"` and zero SIMD intrinsics. All four CJK HTML encoders outperform `rust_encoding_rs --release` by **1.87x–3.07x** via hoisted immutable tables, bucket-indexed binary search / O(1) Hangul direct mapping, branchless UTF-8 fast paths, and division-free pointer arithmetic.
