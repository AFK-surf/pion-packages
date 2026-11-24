# `zstd` (`v0.1.0`)

Pure Pion implementation of **Zstandard (RFC 8878)** compression, decompression, and **xxHash64** with zero external dependencies, zero `extern "C"`, zero `World` requirement, zero floating-point arithmetic, and zero module-level mutable state.

## Features

- **Complete RFC 8878 Decompressor**:
  - Standard frames (`0xFD2FB528`) and Skippable frames (`0x184D2A50..0x184D2A5F`), including multi-frame concatenation with interleaved skippable frames.
  - Full `Frame_Header_Descriptor` parsing (`Frame_Content_Size` 0/1/2/4/8-byte with `+256` 2-byte offset, `Single_Segment_flag`, `Content_Checksum_flag`, `Dictionary_ID_flag`, strict rejection of non-zero `Reserved_bit`, and `UnsupportedDictionary` on non-zero dictionary IDs).
  - Exact `Window_Descriptor` decoding (`Exponent`/`Mantissa`) and `Block_Maximum_Size = min(Window_Size, 128 KiB)` enforcement.
  - All block types: `Raw_Block`, `RLE_Block`, `Compressed_Block`, with strict rejection of `Reserved` block type `3`.
  - Complete `Literals_Section`: `Raw`, `RLE`, `Compressed` (both FSE-compressed and Direct 4-bit Huffman weights, 1-stream and 4-stream backward bitstreams), and `Treeless` (per-frame Huffman table reuse with rejection when absent).
  - Complete `Sequences_Section`: 0/1/2/3-byte sequence counts, `Predefined`/`RLE`/`FSE_Compressed`/`Repeat` modes (with strict rejection of non-zero reserved mode bits and missing prior tables), Repeat Offsets 1/2/3 (initial `[1, 4, 8]`, including the `LL == 0` special case), overlapping match copies, exact `Frame_Content_Size` verification, and optional 4-byte `xxHash64` content checksum verification.
- **Pure Pion RFC 8878 Compressor**:
  - Levels `0..=9` (`0` = store/RLE, `1..=9` = hash-chain LZ77 with Repeat Offsets 1/2/3, RLE/Predefined FSE sequence encoding, Raw/RLE/Direct-Huffman literal encoding, and automatic fallback to `RLE_Block`/`Raw_Block` when expansion would occur).
  - Optional RFC 8878 4-byte `xxHash64` content checksum via `compress_with_checksum`.
  - Standalone `xxhash64(data : Bytes, seed : Int64) -> Int64` integer implementation.
- **Strict DoS Protection (`ZstdLimits`)**:
  - `max_input_bytes` (default `64 MiB`), `max_output_bytes` (default `64 MiB`), `max_window_bytes` (default `8 MiB`), `max_frames` (default `1024`).
  - Any negative limit returns `Err(ZstdError::LimitExceeded(...))`; `0` is strictly enforced.
  - Malicious `Frame_Content_Size` (e.g. 100 GiB) and RLE/match Zip Bombs are rejected **before** allocation; initial pre-allocation is bounded to `4 MiB` even when declared `Frame_Content_Size` is larger.

## Public API

```pion
pub val struct ZstdLimits {
  pub max_input_bytes : Int
  pub max_output_bytes : Int
  pub max_window_bytes : Int
  pub max_frames : Int
}

pub enum ZstdError {
  UnexpectedEof(String)
  InvalidMagic(UInt)
  InvalidFrameHeader(String)
  UnsupportedDictionary(UInt)
  InvalidBlockHeader(String)
  InvalidLiteralsHeader(String)
  InvalidHuffmanTable(String)
  InvalidFseTable(String)
  InvalidSequences(String)
  InvalidOffset(String)
  InvalidBitstream(String)
  ChecksumMismatch(String)
  ContentSizeMismatch(String)
  LimitExceeded(String)
  InvalidLevel(Int)
}

pub fn xxhash64(data : Bytes, seed : Int64) -> Int64
pub fn decompress(data : Bytes) -> Result[Bytes, ZstdError]
pub fn decompress_with_limits(data : Bytes, limits : ZstdLimits) -> Result[Bytes, ZstdError]
pub fn compress(data : Bytes) -> Result[Bytes, ZstdError]
pub fn compress_with_level(data : Bytes, level : Int) -> Result[Bytes, ZstdError]
pub fn compress_with_checksum(data : Bytes, level : Int) -> Result[Bytes, ZstdError]
pub fn zstd_error_to_string(err : ZstdError) -> String
```

## Concurrency & `Send` Guarantees

Verified directly with `pionc check --json` using `scope(world, fn(s : Scope) -> Unit { spawn(s, fn() -> Unit { let _ = v }) })` capture probes on every public type:

| Type | `Send` Status | Notes / Cross-`spawn` Pattern |
| --- | --- | --- |
| `ZstdLimits` | **`Send`** | `val struct` of `Int` — may be captured directly inside `spawn`. |
| `ZstdError` | **`Send`** | `enum` carrying `String`/`UInt`/`Int` — may be captured directly inside `spawn`. |
| `Int64` (`xxhash64`) | **`Send`** | Primitive scalar — may be captured directly inside `spawn`. |
| `Bytes` / `Result[Bytes, ZstdError]` | **`!Send`** | `Bytes` is a mutable byte buffer in Pion (`E_NOT_SEND` on capture). Pass UTF-8 payloads as `String` or transfer ownership explicitly instead of sharing `Bytes` across `spawn`. |

## Verification

```sh
sh scripts/verify.sh packages/zstd
```

### 4-Mode `wasm_smoke` Parity

All four modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`f0c876d54108186eaaf54a5145f74b569db0d110e91656ba5d44707b49903acd`):

```sh
pionc run packages/zstd/wasm_smoke
pionc run --release packages/zstd/wasm_smoke
pionc run --target wasm32 packages/zstd/wasm_smoke
pionc run --target wasm32 --release packages/zstd/wasm_smoke
```

### Bidirectional Byte-Exact Parity (`193` Cross-Checks, `0` Mismatches)

Verified via `sh packages/zstd/bench/run_bench.sh` across 8 deterministic corpora (empty, 1 byte, 64 KiB RLE, 200 KiB multi-block RLE, 32 KiB high-entropy, CJK UTF-8, 1 MiB Web HTML/CSS/JS/JSON, 1 MiB structured binary log):

- **Official `zstd v1.5.7` (`-1`, `-3`, `-9`, `-19`, with & without `--check`) → Pion `decompress`**: 64/64 byte-exact.
- **Multi-frame concatenation + Skippable Frame → Pion `decompress`**: 1/1 byte-exact.
- **Pion `compress_with_level` & `compress_with_checksum` (L0, L1, L3, L6) → Official `zstd -d` & Pure Safe Rust `ruzstd 0.7.3`**: 128/128 byte-exact.

## Head-to-Head Benchmarks (`Linux x86_64`, `warmup=1`, `rounds=5`)

Run via `sh packages/zstd/bench/run_bench.sh` using `scripts/bench_compare.py` (strictly interleaved, stdout SHA-256 verified identical across all implementations and rounds):

### Compression Ratios (1 MiB Corpora)

| Corpus | Raw Size | `zstd -3` | `pion_zstd` L3 | `pion_zstd` L6 |
| --- | ---: | ---: | ---: | ---: |
| Web HTML/CSS/JS/JSON | 1,048,576 B | 83,790 B (7.99%) | 107,496 B (10.25%) | 100,949 B (9.63%) |
| Structured Binary Log | 1,048,576 B | 262,088 B (24.99%) | 352,983 B (33.66%) | 323,238 B (30.83%) |

### Throughput & Latency

| Workload | `pion_zstd` Median (Throughput) | `rust_ruzstd` Median (Throughput) | `rust_zstd` (C libzstd) Median (Throughput) | `pion_zstd` vs Baseline |
| --- | ---: | ---: | ---: | ---: |
| Web HTML/CSS/JS/JSON Decompress (1 MiB × 10) | 44.857 ms (233.76 MB/s) | 27.052 ms (387.62 MB/s) | 9.932 ms (1055.71 MB/s) | **0.60x** vs `rust_ruzstd` |
| Web HTML/CSS/JS/JSON Compress L3 (1 MiB × 5) | 33.449 ms (156.74 MB/s) | — | 11.047 ms (474.60 MB/s) | **0.33x** vs `rust_zstd` |
| Structured Binary Log Decompress (1 MiB × 10) | 75.536 ms (138.82 MB/s) | 35.237 ms (297.57 MB/s) | 12.667 ms (827.81 MB/s) | **0.47x** vs `rust_ruzstd` |
| Structured Binary Log Compress L3 (1 MiB × 5) | 99.179 ms (52.86 MB/s) | — | 22.213 ms (236.02 MB/s) | **0.22x** vs `rust_zstd` |

_Peak RSS reported `N/A` by `/usr/bin/time` on the Linux benchmark host._
