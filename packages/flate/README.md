# `flate` — Pure Pion RFC 1951 (DEFLATE) / RFC 1950 (zlib) / RFC 1952 (gzip) + CRC-32 & Adler-32

A zero-dependency, pure Pion compression and checksum library implementing **RFC 1951 (DEFLATE)**, **RFC 1950 (zlib)**, **RFC 1952 (gzip)**, **IEEE CRC-32**, and **Adler-32**, modeled on **Rust `flate2`/`miniz_oxide`** and **Go `compress/{flate,zlib,gzip}` + `hash/{crc32,adler32}`**.

Designed with a **Sans-IO** architecture: no `World` dependency, no C/FFI bindings, explicit `Result[T, FlateError]` error handling, Day-1 Zip Bomb protection, and dual-target verified on **Native (`arm64_apple`)** and **WebAssembly (`wasm32`)**.

## Features

- **RFC 1951 Raw DEFLATE (`src/inflate.pion`, `src/deflate.pion`, `src/huffman.pion`)**:
  - **Decompressor (`deflate_decompress`, `deflate_decompress_with_limit`)**:
    - Supports all three block types: Stored (`BTYPE=00`), Fixed Huffman (`BTYPE=01`), and Dynamic Huffman (`BTYPE=10`).
    - 64-bit bit buffer (`UInt64`) with 32-bit bulk refills, 9-bit primary + secondary Huffman LUTs (`FixedArray[Int]`), fast RLE `dist == 1` memset fill, and 8-byte unrolled `dist >= 8` back-reference copies.
    - Handles overlapping RLE copies (`dist < len`), full 32 KiB sliding window (`dist == 32768`), and preset dictionary history (for zlib `FDICT`).
  - **Compressor (`deflate_compress`, `deflate_compress_default`)**:
    - Supports all compression levels `0..9`: level `0` (Stored blocks), levels `1..3` (fast greedy LZ77), levels `4..9` (lazy-matching LZ77 with 32 KiB sliding window and 15-bit multiplicative hash chains).
    - Exact **Package-Merge** length-limited (`<= 15` bit litlen/dist, `<= 7` bit code-length) Canonical Huffman encoder.
    - Per-block minimum-cost selection among Stored, Fixed Huffman, and Dynamic Huffman.
- **RFC 1950 zlib (`src/zlib.pion`)**:
  - `zlib_compress`, `zlib_compress_default`, `zlib_decompress`, `zlib_decompress_with_limit`, and `zlib_decompress_with_dict`.
  - Validates `CMF`/`FLG` `FCHECK` (`(CMF*256 + FLG) % 31 == 0`), `CM == 8`, `CINFO <= 7`, `FDICT` preset dictionary `DICTID` Adler-32, and 4-byte big-endian Adler-32 trailer.
- **RFC 1952 gzip (`src/gzip.pion`)**:
  - `gzip_compress`, `gzip_compress_default`, `gzip_compress_with_header`, `gzip_decompress`, `gzip_decompress_with_limit`, and `gzip_decompress_full`.
  - Full optional header support: `FEXTRA`, `FNAME`, `FCOMMENT`, `FHCRC` (16-bit header CRC-32 verification), `MTIME`, `XFL`, `OS`.
  - Multi-member concatenated gzip decoding (`member_count`) with per-member `CRC-32` + `ISIZE` trailer validation and cumulative `max_output_bytes` enforcement.
- **High-Throughput Checksums (`src/checksum.pion`)**:
  - **IEEE CRC-32**: **Slice-by-8** (`8 × 256` `FixedArray[UInt]` lookup tables) — `crc32`, `crc32_update`, `crc32_update_slice`, and streaming `Crc32`.
  - **Adler-32**: `NMAX = 5552` deferred modulo with 8-byte unrolled inner loop — `adler32`, `adler32_update`, `adler32_update_slice`, and streaming `Adler32`.
- **Day-1 Red-Team Security Defenses**:
  - **Zip Bomb interception**: Every decompression entry enforces `max_output_bytes` (default 256 MiB via `default_max_output_bytes`, configurable via `*_with_limit`) before writing or growing buffers, returning `Err(FlateError::OutputLimitExceeded(_))` without OOM.
  - **Strict RFC validation**: Rejects reserved `BTYPE=11` (`InvalidBlockType`), corrupted stored `NLEN != ~LEN` (`InvalidStoredLength`), oversubscribed or incomplete Huffman trees and missing EOB symbol 256 (`InvalidHuffmanTree`), invalid symbols 286/287/30/31 (`InvalidSymbol`), out-of-window distances (`InvalidDistance`), reserved gzip `FLG` bits (`InvalidHeader`), truncated streams (`UnexpectedEof`), and checksum mismatches (`ChecksumMismatch`).

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
let decoded = flate::deflate_decompress_with_limit(raw, 1048576)

// 3. zlib (RFC 1950)
let zb = flate::zlib_compress_default(payload)
let zout = flate::zlib_decompress(zb)

// 4. gzip (RFC 1952) with header metadata
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

- **Compliance & Red-Team Suite**: **19 / 19 passing** (`pionc test --json packages/flate`), covering IEEE CRC-32 & Adler-32 reference vectors and NMAX boundaries, RFC 1951 Stored / Fixed / Dynamic reference vectors, RLE overlapping copies (`dist=1,2,3`), all levels `0..9`, multi-block & 32 KiB window boundaries, RFC 1950 zlib `FCHECK` / `FDICT` preset dictionary / Adler-32, RFC 1952 gzip `FEXTRA` / `FNAME` / `FCOMMENT` / `FHCRC` / multi-member concatenation, and Day-1 Zip Bomb + malformed-stream red-team tests.
- **Formatting & Typecheck**: `pionc fmt --check packages/flate` and `pionc check --json packages/flate` pass with 0 diagnostics.
- **Dual-Target Smoke (`packages/flate/wasm_smoke`)**:
  - Native debug & `--release`: build and run exit `0`.
  - Wasm32 debug & `--release`: `pionc build --target wasm32` produces non-empty `.wasm` artifacts and `pionc run --target wasm32` exits `0`.

## Benchmarks

Head-to-head steady-state benchmarks via `sh packages/flate/bench/run_bench.sh` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification) on `Darwin arm64` against **Rust `flate2 1.1.11` (`rust_backend` / `miniz_oxide 0.9.1`, `crc32fast 1.5.5`, `adler2 2.0.1`, `--release`)** and **Go `compress/gzip` + `hash/{crc32,adler32}` (`go1.27.3`)**.

### Compression Ratio & Cross-Implementation Interoperability (2 MiB Mixed Prose / Code / JSON Corpus)

Every compressed `.gz` stream produced by Pion, Rust, and Go was independently decompressed by both Python `gzip` and Pion `flate::gzip_decompress` and verified SHA-256 identical to the original 2,097,152-byte corpus (`e18a374002e0d538...`):

| Implementation | Level 6 Size (Ratio) | Level 1 Size (Ratio) | Cross-Decompress SHA-256 |
| --- | ---: | ---: | :---: |
| `pion` (`packages/flate`) | **70,684 B (3.37%)** | **95,323 B (4.55%)** | Identical |
| `rust_miniz_oxide` (`flate2 1.1.11`) | 70,650 B (3.37%) | 120,956 B (5.77%) | Identical |
| `go_gzip` (`go1.27.3`) | 73,365 B (3.50%) | 100,105 B (4.77%) | Identical |

### 1. GZIP/DEFLATE Decompress (2 MiB mixed corpus × 10 = 20.97 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_miniz_oxide`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 37.992 | 37.098 | 46.621 | **551.99** | 10.17 MiB | 0.44x |
| `rust_miniz_oxide` | 16.812 | 16.552 | 17.935 | 1247.38 | 7.33 MiB | 1.00x (baseline) |
| `go_gzip` | 21.923 | 20.910 | 25.840 | 956.62 | 16.88 MiB | 0.77x |

_SHA-256 verified identical across all implementations and rounds: `6c4fcdae9eaa30bc30a6d912b5b6ed529c017f5a2de1ac6b37dd29472f4bc051`._

### 2. GZIP/DEFLATE Compress Level 6 (2 MiB mixed corpus × 4 = 8.39 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_miniz_oxide`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 52.075 | 50.710 | 54.351 | **161.09** | 6.31 MiB | 0.40x |
| `rust_miniz_oxide` | 20.998 | 20.316 | 23.294 | 399.50 | 4.73 MiB | 1.00x (baseline) |
| `go_gzip` | 21.393 | 20.838 | 23.536 | 392.12 | 13.73 MiB | 0.98x |

### 3. GZIP/DEFLATE Compress Level 1 (2 MiB mixed corpus × 6 = 12.58 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_miniz_oxide`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 31.890 | 30.864 | 37.899 | **394.57** | 6.58 MiB | 0.43x |
| `rust_miniz_oxide` | 13.862 | 12.753 | 15.376 | 907.71 | 4.53 MiB | 1.00x (baseline) |
| `go_gzip` | 17.198 | 16.125 | 17.891 | 731.66 | 14.88 MiB | 0.81x |

### 4. CRC-32 (IEEE) + Adler-32 Checksum (2 MiB × 32 = 67.11 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_crc_adler`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (pure scalar Slice-by-8) | 65.324 | 64.016 | 71.222 | **1027.32** | 5.81 MiB | 0.25x |
| `rust_crc_adler` (`crc32fast` + `simd-adler32` HW) | 16.649 | 16.091 | 22.160 | 4030.67 | 3.89 MiB | 1.00x (baseline) |
| `go_crc_adler` (ARMv8 CRC32 HW + scalar Adler) | 33.380 | 31.781 | 35.386 | 2010.47 | 6.56 MiB | 0.50x |

_SHA-256 verified identical across all implementations and rounds: `4b367f57c0b62d30f124814513fca84cb289746fb906e7147a87ba553a1b4dec`._

### Honest Performance Analysis

- **Strengths**:
  - Pure Pion achieves **552 MB/s** GZIP decompression, **395 MB/s** level-1 compression, **161 MB/s** level-6 compression, and **1.03 GB/s** combined CRC-32 + Adler-32 checksum throughput with zero C/FFI dependencies and full Wasm32 portability.
  - Compression ratios match `miniz_oxide` at level 6 (`3.37%` vs `3.37%`, smaller than Go's `3.50%`) and beat both `miniz_oxide` and Go at level 1 (`4.55%` vs `5.77%` / `4.77%`) thanks to exact Package-Merge length-limited Huffman coding and per-block min-cost selection.
  - Peak RSS is consistently ~2× lower than Go (`6–10 MiB` vs `14–17 MiB`).
- **Remaining Gaps**:
  - `rust_miniz_oxide` and `go_gzip` are ~2.2–2.5× faster in decompression/compression due to LLVM/Go auto-vectorization, unaligned 64-bit memory loads (`u64::from_le_bytes`), and ARMv8 hardware `CRC32X` instructions (`crc32fast` and Go's `crc32_arm64.s`) vs Pion's pure scalar byte-indexed Slice-by-8 CRC-32 and byte-at-a-time LZ77 match comparison.
