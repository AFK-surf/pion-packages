# `flate` — Pure Pion RFC 1951 (DEFLATE) / RFC 1950 (zlib) / RFC 1952 (gzip) + CRC-32 & Adler-32

A zero-dependency, pure Pion compression and checksum library implementing **RFC 1951 (DEFLATE)**, **RFC 1950 (zlib)**, **RFC 1952 (gzip)**, **IEEE CRC-32**, and **Adler-32**, modeled on **Rust `flate2`/`miniz_oxide`** and **Go `compress/{flate,zlib,gzip}` + `hash/{crc32,adler32}`**.

Designed with a **Sans-IO** architecture: no `World` dependency, no C/FFI bindings, explicit `Result[T, FlateError]` error handling, configurable Zip Bomb protection, and dual-target verified on **Native (`arm64_apple`)** and **WebAssembly (`wasm32`)**.

## Features

- **RFC 1951 Raw DEFLATE (`src/inflate.pion`, `src/deflate.pion`, `src/huffman.pion`)**:
  - **Decompressor (`deflate_decompress`, `deflate_decompress_with_limit`)**:
    - Supports all three block types: Stored (`BTYPE=00`), Fixed Huffman (`BTYPE=01`), and Dynamic Huffman (`BTYPE=10`).
    - 64-bit bit buffer (`UInt64`) with sequential 32-bit refills, **10-bit primary + secondary packed Huffman LUTs**, split fast/slow Huffman decode loops (immutable `out` in `inflate_huffman_fast`, single exit point, zero per-symbol EOF/bounds/`Result` overhead, literal-to-match LUT fall-through), safe `ISIZE` trailer pre-allocation hint for single-member gzip streams, zero-loop Stored block slicing (`Bytes::slice` + balanced pairwise `Bytes::concat`), fast RLE `dist == 1` fill, and 8-byte unrolled `dist >= 8` back-reference copies.
    - Handles overlapping RLE copies (`dist < len`), full 32 KiB sliding window (`dist == 32768`), and preset dictionary history (for zlib `FDICT`).
  - **Compressor (`deflate_compress`, `deflate_compress_default`)**:
    - Supports all compression levels `0..9`: level `0` (Stored blocks), level `1` (1-slot 14-bit direct-hash fast LZ77 with zero `prev` chain allocation), levels `2..3` (lean greedy LZ77 with adaptive miss-skipping), levels `4..9` (lazy-matching LZ77 with carry-over, 32 KiB sliding window, 15-bit multiplicative hash chains, 6-arg register-only `lz77_find_match`, and standard zlib-style `good_length`/`max_lazy`/`nice_length` early exit).
    - Zero-COW `FixedArray[Byte]` `BitWriter` with hoisted local `bitbuf`/`bitcnt` and packed `(code << 5) | nbits` / `len_pack` / `dist_pack` token emission.
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
  - **IEEE CRC-32**: Single flat `4096`-entry (`16 × 256`) `FixedArray[UInt]` Slice-by-16 lookup table (zero multi-table pointer spills) — `crc32`, `crc32_update`, `crc32_update_slice`, and streaming `Crc32`.
  - **Adler-32**: `NMAX = 5552` deferred modulo with low-register-pressure 8-byte (2×4-byte) unrolled inner loop — `adler32`, `adler32_update`, `adler32_update_slice`, and streaming `Adler32`.

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

- **Unit & Red-Team Compliance Suite**: **21 / 21 passing** (`pionc test --json packages/flate`) + **11 / 11 passing** (`pionc test --json packages/flate/audit`, including all 4 `redteam_*` compliance guards and 7 `control_*` regression guards).
- **Differential RFC Edge Vectors (`difftest.py vectors`)**: **81 / 81** vectors pass across 5 decoders (Pion Native, Pion Wasm32, Go `compress/*`, Rust `flate2/miniz_oxide`, CPython `zlib`), with **0** Native vs Wasm32 mismatches.
- **Compressor Interoperability (`difftest.py compress`)**: **100 / 100** streams (10 pathological & real corpora × levels `0..9`, including Fibonacci-frequency literals forcing 15-bit Package-Merge clamping) decode byte-identically across Pion, Go, Rust `miniz_oxide`, and CPython `zlib`.
- **Differential Mutation Fuzz (`difftest.py fuzz`)**: **24,000** mutated raw/zlib/gzip cases with **0** crashes/hangs, **0** Native vs Wasm32 diffs, and **0** disagreements vs unanimous `(Go, Rust, Python)`.
- **Dual-Target Smoke (`packages/flate/wasm_smoke`)**: Native debug/release + Wasm32 debug/release all 4 modes exit `0` with identical stdout SHA-256.
- **Formatting & Typecheck**: `pionc fmt --check packages/flate` and `pionc check --json packages/flate` pass with 0 diagnostics.

## Multi-Shape Benchmarks

Measured via `sh packages/flate/audit/run_audit.sh bench` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) on Linux `x86_64` (AMD Ryzen 7 PRO 8845HS) against **Rust `flate2 1.1.11` (`rust_backend` / `miniz_oxide` + `crc32fast`/`simd-adler32`, `--release`)** and **Go `go1.24.4` `compress/gzip` + `hash/{crc32,adler32}`**.

### 1. Throughput Across 6 Real & Pathological Corpora (MB/s, Linux `x86_64`)

| Corpus | Operation | **Pion** | `miniz_oxide` | Go | Pion vs `miniz` | Pion vs Go |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `entropy` (4 MiB rand) | gzip decompress | **249.0** | 1128.6 | 196.9 | 0.22× | **1.26×** |
| `entropy` | compress L1 / L6 / L9 | **207.8 / 114.0 / 91.1** | 159.3 / 26.2 / 18.1 | 201.3 / 15.4 / 13.8 | **1.30 / 4.36 / 5.03×** | **1.03 / 7.41 / 6.59×** |
| `html` (4 MiB) | gzip decompress | **104.1** | 208.1 | 69.5 | 0.50× | **1.50×** |
| `html` | compress L1 / L6 / L9 | **36.3 / 17.7 / 7.8** | 103.7 / 18.6 / 8.9 | 41.4 / 21.8 / 6.0 | 0.35 / 0.95 / 0.87× | 0.88 / 0.81 / **1.31×** |
| `json` (4 MiB) | gzip decompress | **97.0** | 165.0 | 57.1 | 0.59× | **1.70×** |
| `json` | compress L1 / L6 / L9 | **39.2 / 26.2 / 10.2** | 94.2 / 20.8 / 13.3 | 42.8 / 15.2 / 12.9 | 0.42 / **1.26** / 0.77× | 0.92 / **1.73** / 0.79× |
| `source` (4 MiB) | gzip decompress | **225.0** | 425.7 | 84.9 | 0.53× | **2.65×** |
| `source` | compress L1 / L6 / L9 | **71.5 / 13.7 / 6.7** | 169.8 / 16.4 / 10.8 | 83.2 / 16.5 / 9.2 | 0.42 / 0.83 / 0.62× | 0.86 / 0.83 / 0.73× |
| `text` (1.8 MiB) | gzip decompress | **134.2** | 198.8 | 58.3 | 0.67× | **2.30×** |
| `text` | compress L1 / L6 / L9 | **54.2 / 14.1 / 15.4** | 119.8 / 26.7 / 27.9 | 65.7 / 17.0 / 16.7 | 0.45 / 0.53 / 0.55× | 0.83 / 0.83 / 0.92× |
| `big16` (16 MiB mix) | gzip decompress | **158.0** | 338.9 | 92.7 | 0.47× | **1.70×** |
| `big16` | compress L1 / L6 / L9 | **69.7 / 23.3 / 14.4** | 137.2 / 22.2 / 17.9 | 70.4 / 19.8 / 14.8 | 0.51 / **1.05** / 0.81× | 0.99 / **1.18** / 0.97× |
| All 6 corpora | CRC-32 + Adler-32 | **251–610** | 1116–3353 | 389–1213 | 0.18–0.34× | 0.50–0.85× |

### 2. Compressed Sizes Across All 6 Corpora (Bytes)

| Corpus | Level 1 (Pion / `miniz` / Go) | Level 6 (Pion / `miniz` / Go) | Level 9 (Pion / `miniz` / Go) |
| --- | ---: | ---: | ---: |
| `entropy` (4,194,304 B) | 4,194,629 / 4,198,186 / 4,194,634 | 4,194,629 / 4,194,969 / 4,195,589 | 4,194,629 / 4,194,969 / 4,195,589 |
| `html` (4,194,304 B) | 923,350 / 809,282 / 837,888 | 838,072 / 814,778 / 771,640 | 816,275 / 812,165 / 755,919 |
| `json` (4,194,304 B) | 1,563,148 / 1,479,560 / 1,415,960 | 1,286,775 / 1,230,479 / 1,148,484 | 1,238,253 / 1,217,349 / 1,132,428 |
| `source` (4,194,304 B) | 1,449,152 / 1,539,452 / 1,348,233 | 1,088,605 / 1,074,313 / 1,079,970 | 1,071,690 / 1,071,384 / 1,078,039 |
| `text` (1,876,229 B) | 1,188,755 / 1,118,606 / 1,053,552 | 1,112,611 / 1,107,337 / 1,029,624 | 1,112,599 / 1,107,337 / 1,029,624 |
| `big16` (16,777,216 B) | 6,635,066 / 6,475,708 / 6,083,993 | 5,738,004 / 5,607,918 / 5,408,464 | 5,660,972 / 5,590,263 / 5,376,163 |

### 3. Honest Performance Analysis

- **Strengths**:
  - **Decompression beats Go across all 6 corpora by `1.26–2.65×`** (`1.26×` on `entropy`, `1.50×` on `html`, `1.70×` on `json`/`big16`, `2.30×` on `text`, `2.65×` on `source`) with zero C/FFI and full Wasm32 portability.
  - **Level-6 compression beats both `miniz_oxide` and Go** on `big16` (`1.05×` / `1.18×`), `json` (`1.26×` / `1.73×`), and `entropy` (`4.36×` / `7.41×`), and reaches `0.95×` `miniz_oxide` on `html`.
  - **Adversarial LZ77 inputs (`run_audit.sh dos`)**: `adv_ab_4M` L6 (`0.27 s` vs `0.36 s` Rust / `1.23 s` Go), `adv_acgt_4M` L6 (`0.51 s` vs `0.99 s` Rust / `1.91 s` Go), and `adv_prefix3_4M` L9 (`0.72 s` vs `1.50 s` Rust).
- **Remaining Gaps**:
  - **CRC-32 + Adler-32 (`0.18–0.34×` Rust, `0.50–0.85×` Go)** and **gzip decompress vs `miniz_oxide` (`0.47–0.67×` on compressible corpora, `0.22×` on `entropy`)**: `objdump -d` confirms Rust (`crc32fast::specialized::pclmulqdq::calculate_avx2` with 40 `pclmulqdq` instructions + `simd-adler32` AVX2) and Go (`crc32_amd64.s`) use hardware SIMD/CLMUL instructions, whereas pure Pion uses scalar single-table Slice-by-16 (`crc32_update_slice` = 600 insns, 38 stack accesses). In gzip decompress, scalar CRC-32 verification accounts for ~35–45% of total time.
  - **Level-1 compression vs `miniz_oxide` (`0.35–0.51×` on compressible corpora, `0.83–0.99×` Go)**: Pion lacks unaligned 64-bit loads (`u64::from_le_bytes`) for 8-byte LZ77 match comparisons and `Bytes::blit` in-place bulk copy.
  - **Streaming API**: All entry points remain one-shot `Bytes -> Bytes`; streaming `Inflater`/`Deflater` with a constant 32 KiB ring buffer is future work.
