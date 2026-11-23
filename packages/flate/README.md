# `flate` — Pure Pion RFC 1951 (DEFLATE) / RFC 1950 (zlib) / RFC 1952 (gzip) + CRC-32 & Adler-32

A zero-dependency, pure Pion compression and checksum library implementing **RFC 1951 (DEFLATE)**, **RFC 1950 (zlib)**, **RFC 1952 (gzip)**, **IEEE CRC-32**, and **Adler-32**, modeled on **Rust `flate2`/`miniz_oxide`** and **Go `compress/{flate,zlib,gzip}` + `hash/{crc32,adler32}`**.

Designed with a **Sans-IO** architecture: no `World` dependency, no C/FFI bindings, explicit `Result[T, FlateError]` error handling, configurable Zip Bomb protection, and dual-target verified on **Native (`arm64_apple`)** and **WebAssembly (`wasm32`)**.

## Features

- **RFC 1951 Raw DEFLATE (`src/inflate.pion`, `src/deflate.pion`, `src/huffman.pion`)**:
  - **Decompressor (`deflate_decompress`, `deflate_decompress_with_limit`)**:
    - Supports all three block types: Stored (`BTYPE=00`), Fixed Huffman (`BTYPE=01`), and Dynamic Huffman (`BTYPE=10`).
    - 64-bit bit buffer (`UInt64`) with 32-bit bulk refills, **10-bit primary + secondary packed Huffman LUTs** (length/distance bases & extra bit counts packed directly into LUT entries), opportunistic multi-literal decoding per refill, zero-loop Stored block slicing (`Bytes::slice` + balanced pairwise `Bytes::concat`), fast RLE `dist == 1` memset fill, and 8-byte unrolled `dist >= 8` back-reference copies.
    - Handles overlapping RLE copies (`dist < len`), full 32 KiB sliding window (`dist == 32768`), and preset dictionary history (for zlib `FDICT`).
  - **Compressor (`deflate_compress`, `deflate_compress_default`)**:
    - Supports all compression levels `0..9`: level `0` (Stored blocks), levels `1..3` (fast greedy LZ77 with adaptive miss-skipping), levels `4..9` (lazy-matching LZ77 with carry-over, 32 KiB sliding window, 15-bit multiplicative hash chains, and standard zlib-style `good_length`/`max_lazy`/`nice_length` early exit).
    - **Incompressible / high-entropy fast path**: cheap entropy + 3-byte-match probe skips LZ77 & Package-Merge on random/already-compressed chunks and emits Stored blocks directly via native `Bytes::slice` `memcpy`.
    - Exact **Package-Merge** length-limited (`<= 15` bit litlen/dist, `<= 7` bit code-length) Canonical Huffman encoder and per-block minimum-cost selection among Stored, Fixed Huffman, and Dynamic Huffman.
- **RFC 1950 zlib (`src/zlib.pion`)**:
  - `zlib_compress`, `zlib_compress_default`, `zlib_decompress`, `zlib_decompress_with_limit`, and `zlib_decompress_with_dict`.
  - Validates `CMF`/`FLG` `FCHECK` (`(CMF*256 + FLG) % 31 == 0`), `CM == 8`, `CINFO <= 7`, `FDICT` preset dictionary `DICTID` Adler-32 (including empty preset dictionary `DICTID == adler32("") == 1` via `zlib_decompress_with_dict`), and 4-byte big-endian Adler-32 trailer.
- **RFC 1952 gzip (`src/gzip.pion`)**:
  - `gzip_compress`, `gzip_compress_default`, `gzip_compress_with_header`, `gzip_decompress`, `gzip_decompress_with_limit`, and `gzip_decompress_full`.
  - Full optional header support: `FEXTRA`, `FNAME`, `FCOMMENT`, `FHCRC` (16-bit header CRC-32 verification), `MTIME`, `XFL`, `OS`.
  - Strict RFC 1952 §2.3.1 **ISO-8859-1 (Latin-1)** wire encoding/decoding for `FNAME` and `FCOMMENT`: rejects NUL (`\u{0}`) and characters outside U+0001..U+00FF with `Err(FlateError::InvalidHeader(_))`.
  - Multi-member concatenated gzip decoding (`member_count`) with reusable inflate scratch tables, lazy output allocation (zero buffer allocation for empty members), per-member `CRC-32` + `ISIZE` trailer validation, and cumulative `max_output_bytes` enforcement.
- **High-Throughput Checksums (`src/checksum.pion`)**:
  - **IEEE CRC-32**: **Slice-by-16** (`16 × 256` `FixedArray[UInt]` lookup tables) — `crc32`, `crc32_update`, `crc32_update_slice`, and streaming `Crc32`.
  - **Adler-32**: `NMAX = 5552` deferred modulo with 16-byte unrolled tree-reduced inner loop — `adler32`, `adler32_update`, `adler32_update_slice`, and streaming `Adler32`.

## Output Limits & Memory Model

All compression and decompression entry points are **one-shot (`Bytes -> Bytes`)**:

- **Default limit**: `deflate_decompress`, `zlib_decompress`, and `gzip_decompress` enforce `default_max_output_bytes = 268435456` (**256 MiB**). Exceeding the limit returns `Err(FlateError::OutputLimitExceeded(_))` before writing or growing past the cap.
- **Custom or unlimited**: Pass any positive byte limit to `*_with_limit` / `gzip_decompress_full` / `zlib_decompress_with_dict` (recommended for untrusted inputs, e.g. 1–16 MiB). Pass **`0`** to **disable the output limit** (for trusted large `.gz`/`.zlib`/DEFLATE payloads up to Pion's `Int` container limit).
- **One-shot memory boundary**: Because there is currently no incremental/streaming `Inflater`/`Deflater` state machine, peak RSS scales as `O(input + output)` (up to ~1.5× `max_output_bytes` during the final geometric buffer growth on a zip bomb, e.g., ~394 MiB RSS at the default 256 MiB cap vs ~6 MiB RSS with a 1 MiB cap). Set an explicit small `max_output_bytes` whenever decoding untrusted data.

## Quick Start

```pion
import "flate"

// 1. Checksums
let c = flate::crc32("123456789".to_bytes())    // 0xCBF43926U
let a = flate::adler32("Wikipedia".to_bytes())  // 0x11E60398U

// 2. Raw DEFLATE (RFC 1951)
let payload = "The quick brown fox jumps over the lazy dog.".to_bytes()
let raw = match flate::deflate_compress(payload, 6) {
  Ok(b) => b
  Err(e) => {
    let _ = flate::flate_error_message(e)
    Bytes::new(0)
  }
}
// Bounded (1 MiB cap) or unlimited (limit = 0):
let decoded = flate::deflate_decompress_with_limit(raw, 1048576)
let decoded_unlimited = flate::deflate_decompress_with_limit(raw, 0)

// 3. zlib (RFC 1950)
let zb = flate::zlib_compress_default(payload)
let zout = flate::zlib_decompress(zb)

// 4. gzip (RFC 1952) with ISO-8859-1 header metadata
let gz = flate::gzip_compress_with_header(
  payload,
  6,
  flate::GzipHeader::with_name("hello.txt"),
)
let gout = match gz {
  Ok(b) => flate::gzip_decompress_full(b, 1048576)
  Err(e) => Err(e)
}
```

## Verification

Every check below is reproducible with `sh packages/flate/audit/run_audit.sh all`:

- **Unit & Red-Team Compliance Suite**: **20 / 20 passing** (`pionc test --json packages/flate`) + **11 / 11 passing** (`pionc test --json packages/flate/audit`, including all 4 `redteam_*` compliance guards and 7 `control_*` regression guards).
- **Differential RFC Edge Vectors (`difftest.py vectors`)**: **81 / 81** vectors pass across 5 decoders (Pion Native, Pion Wasm32, Go `compress/*`, Rust `flate2/miniz_oxide`, CPython `zlib`), with **0** Native vs Wasm32 mismatches.
- **Compressor Interoperability (`difftest.py compress`)**: **100 / 100** streams (10 pathological & real corpora × levels `0..9`, including Fibonacci-frequency literals forcing 15-bit Package-Merge clamping) decode byte-identically across Pion, Go, Rust `miniz_oxide`, and CPython `zlib`.
- **Differential Mutation Fuzz (`difftest.py fuzz`)**: **24,000** mutated raw/zlib/gzip cases with **0** crashes/hangs, **0** Native vs Wasm32 diffs, and **0** disagreements vs unanimous `(Go, Rust, Python)`.
- **Dual-Target Smoke (`packages/flate/wasm_smoke`)**: Native debug/release + Wasm32 debug/release all 4 modes exit `0`.
- **Formatting & Typecheck**: `pionc fmt --check packages/flate` and `pionc check --json packages/flate` pass with 0 diagnostics.

## Multi-Shape Benchmarks

Measured via `sh packages/flate/audit/run_audit.sh bench` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification where compress modes re-decompress and print output length + CRC-32 so a broken encoder cannot win) on `Darwin arm64` (`tokyo-mac-studio-0`) against **Rust `flate2 1.1.11` (`rust_backend` / `miniz_oxide`, `--release`)** and **Go `go1.27.3` `compress/gzip` + `hash/{crc32,adler32}`**.

### 1. Throughput Across 6 Real & Pathological Corpora (MB/s)

| Corpus | Operation | Pion Before | **Pion After** | `miniz_oxide` | Go | Pion vs `miniz` | Pion vs Go |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `entropy` (4 MiB rand) | gzip decompress | 530.6 | **639.6** | 1959.9 | 1765.1 | 0.33× | 0.36× |
| `entropy` | compress L1 | 37.0 | **538.5** | 277.2 | 1592.4 | **1.94×** | 0.34× |
| `entropy` | compress L6 | 33.7 | **542.3** | 68.1 | 1470.6 | **7.96×** | 0.37× |
| `entropy` | compress L9 | 34.1 | **410.4** | 64.8 | 183.1 | **6.33×** | **2.24×** |
| `html` (4 MiB Go spec) | gzip decompress | 260.5 | **305.5** | 392.7 | 291.4 | 0.78× | **1.05×** |
| `html` | compress L1 / L6 / L9 | 83.4 / 30.2 / 17.7 | **100.8 / 44.4 / 21.3** | 216.1 / 51.4 / 37.8 | 216.0 / 139.1 / 29.0 | 0.47 / 0.86 / 0.56× | 0.47 / 0.32 / 0.74× |
| `json` (4 MiB records) | gzip decompress | 268.3 | **291.9** | 401.2 | 269.3 | 0.73× | **1.08×** |
| `json` | compress L1 / L6 / L9 | 88.9 / 35.2 / 10.3 | **98.1 / 52.8 / 17.1** | 255.2 / 45.8 / 23.6 | 240.9 / 138.8 / 24.7 | 0.38 / **1.15** / 0.72× | 0.41 / 0.38 / 0.69× |
| `source` (4 MiB Go src) | gzip decompress | 268.4 | **321.2** | 409.6 | 293.9 | 0.78× | **1.09×** |
| `source` | compress L1 / L6 / L9 | 84.5 / 26.7 / 19.0 | **103.7 / 49.8 / 25.9** | 236.0 / 55.8 / 43.4 | 222.0 / 143.6 / 40.9 | 0.44 / 0.89 / 0.60× | 0.47 / 0.35 / 0.63× |
| `text` (2.4 MiB words) | gzip decompress | 191.5 | **247.5** | 337.9 | 229.3 | 0.73× | **1.08×** |
| `text` | compress L1 / L6 / L9 | 70.5 / 20.9 / 6.4 | **93.3 / 26.7 / 9.9** | 207.6 / 29.2 / 15.5 | 180.3 / 101.6 / 17.0 | 0.45 / 0.91 / 0.64× | 0.52 / 0.26 / 0.58× |
| `big16` (16 MiB mix) | gzip decompress | 232.5 | **290.7** | 412.3 | 283.5 | 0.71× | **1.03×** |
| `big16` | compress L1 / L6 / L9 | 64.0 / 23.1 / 11.4 | **87.2 / 37.5 / 15.4** | 182.2 / 36.0 / 24.8 | 167.9 / 110.3 / 23.5 | 0.48 / **1.04** / 0.62× | 0.52 / 0.34 / 0.65× |
| All 6 corpora | CRC-32 + Adler-32 | 702–826 | **843–1007** | 1721–2450 | 1175–1510 | 0.40–0.49× | 0.63–0.72× |

### 2. Compressed Sizes Across All 6 Corpora (Bytes)

| Corpus | Level 1 (Pion / `miniz` / Go) | Level 6 (Pion / `miniz` / Go) | Level 9 (Pion / `miniz` / Go) |
| --- | ---: | ---: | ---: |
| `entropy` (4,194,304 B) | 4,194,629 / 4,198,186 / 4,194,631 | 4,194,629 / 4,194,969 / 4,194,631 | 4,194,629 / 4,194,969 / 4,194,946 |
| `html` (4,194,304 B) | 1,377,159 / 1,624,878 / 1,386,629 | 1,137,769 / 1,118,477 / 1,164,462 | 1,115,022 / 1,115,149 / 1,110,233 |
| `json` (4,194,304 B) | 1,493,524 / 1,479,550 / 1,344,991 | 1,286,711 / 1,230,323 / 1,210,476 | 1,238,121 / 1,217,228 / 1,144,530 |
| `source` (4,194,304 B) | 1,289,950 / 1,515,528 / 1,301,005 | 1,076,127 / 1,061,930 / 1,096,465 | 1,059,646 / 1,059,129 / 1,055,047 |
| `text` (2,493,885 B) | 822,484 / 958,958 / 896,916 | 759,198 / 756,053 / 795,315 | 759,909 / 755,944 / 742,391 |
| `big16` (16,777,216 B) | 6,272,725 / 6,873,194 / 6,187,274 | 5,512,700 / 5,383,712 / 5,489,706 | 5,418,442 / 5,368,321 / 5,270,229 |

### 3. DoS & Adversarial Pathological Inputs (`run_audit.sh dos`)

| Workload | Pion Before | **Pion After** | `miniz_oxide` | Go |
| --- | ---: | ---: | ---: | ---: |
| `empty_members_100k.gz` (100k empty members) | 0.49 s | **0.00 s (5.8 MiB RSS)** | 0.16 s (4.0 MiB) | 0.02 s (6.4 MiB) |
| `bomb_1GiB.gz` (limit = 1 MiB) | 0.00 s (5 MiB) | **0.00 s (6.0 MiB RSS)** | 0.00 s (5.1 MiB) | 0.00 s (8.4 MiB) |
| `bomb_1GiB.gz` (limit = 256 MiB) | 0.13 s (391 MiB) | **0.16 s (394.1 MiB RSS)** | 0.04 s (293.1 MiB) | 0.12 s (580.2 MiB) |
| `adv_ab_4M` compress L6 / L9 | — / 4.40 s | **0.22 s / 2.06 s** | 0.27 s / 1.08 s | 0.02 s / 37.35 s |
| `adv_prefix3_4M` compress L6 / L9 | — / 1.61 s | **0.20 s / 0.46 s** | 0.23 s / 0.74 s | 0.02 s / 0.18 s |

### Honest Performance Analysis

- **Strengths**:
  - **Decompression beats Go across all 5 compressible/mixed corpora** (`1.03–1.09×` Go; `0.71–0.78×` `miniz_oxide`) with zero C/FFI and full Wasm32 portability.
  - **Level-6 compression matches or beats `miniz_oxide`** on `big16` (`1.04×`), `json` (`1.15×`), and `entropy` (`7.96×`), and reaches `0.86–0.91×` on `html`/`source`/`text`, while staying within ~0–4.6% of `miniz_oxide` compressed size (and 8–15% *smaller* than `miniz_oxide` at L1 on `html`/`source`/`text`/`big16`).
  - **Incompressible/random compression** jumped **12–16×** (`34–37 MB/s -> 410–542 MB/s`), beating `miniz_oxide` at L1/L6/L9 (`1.94–7.96×`) and Go at L9 (`2.24×`).
  - **100,000 empty gzip members** dropped from `0.49 s` to **`0.00 s`** (`5.8 MiB` RSS), faster than both Go (`0.02 s`) and `miniz_oxide` (`0.16 s`).
- **Remaining Gaps**:
  - **CRC-32 (`0.40–0.49×` `miniz_oxide`, `0.63–0.72×` Go)** and **entropy gzip decompress (`0.33×` `miniz_oxide`)**: both Rust (`crc32fast`) and Go (`crc32_arm64.s`) use ARMv8 hardware `CRC32X` instructions and single-pass `memcpy`, whereas pure Pion pays scalar byte-indexed Slice-by-16 CRC-32 plus pairwise `Bytes::concat` passes.
  - **Level-1 compression (`0.38–0.48×` `miniz_oxide` on compressible data)** and **Go L6 (`0.26–0.38×` Go)**: Pion lacks unaligned 64-bit loads (`u64::from_le_bytes`) for 8-byte LZ77 match comparisons and `Bytes::blit` in-place bulk copy.
  - **Streaming API**: All entry points remain one-shot `Bytes -> Bytes`; streaming `Inflater`/`Deflater` with a constant 32 KiB ring buffer is future work.
