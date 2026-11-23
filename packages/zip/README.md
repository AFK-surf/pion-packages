# `zip` — Pure Pion ZIP Archive Reader & Writer (APPNOTE 6.3.10 + ZIP64)

A pure Pion, zero-C-dependency, Native + Wasm32 compatible ZIP archive library modeled on **Go `archive/zip`** and **Rust `zip`**, built directly on `packages/flate` for RFC 1951 raw DEFLATE (Method 8), Store (Method 0), and IEEE CRC-32 verification.

Designed with a **Sans-IO** architecture: no `World` dependency, `Send`-safe public metadata types, zero-copy `Bytes` slicing on Store entries, O(1) `Map`-indexed random-access lookup, and hardened Day-1 security defenses against Zip-Slip, Zip Bombs, overlapping entries, and malformed headers.

## Features

- **Full Reader (`ZipReader`)**:
  - **EOCD Search**: Scans backwards up to the maximum 65,535-byte archive comment with exact length validation (`eocd_pos + 22 + comment_len == len`), resilient to fake `PK\x05\x06` signatures embedded in comments.
  - **Central Directory & Local File Header Validation**: Cross-checks LFH signature, compression method, non-descriptor CRC-32/sizes, and bounds against Central Directory start.
  - **Compression Methods**: Method `0` (Store, zero-copy `Bytes::slice`) and Method `8` (Raw DEFLATE via `flate::deflate_decompress_with_limit`).
  - **Data Descriptors (Bit 3)**: Supports both 16/24-byte descriptors with `0x08074b50` signature (as emitted by Go `archive/zip`) and 12/20-byte signature-less descriptors, verifying CRC-32 and sizes.
  - **ZIP64**: Full support for ZIP64 EOCD Record (`0x06064b50`), ZIP64 EOCD Locator (`0x07064b50`), and `0x0001` Extended Information Extra Fields (`>4 GiB` offsets/sizes and `>65,535` entries).
  - **Metadata & Timestamps**: UTF-8 Language Encoding Flag (bit 11), MS-DOS date/time encoding/decoding (`DosDateTime::from_dos`, `to_dos`, `from_unix`, `to_unix`), Unix permissions / directory / symlink `external_attr` (`unix_mode`, `is_dir`, `is_symlink`).
  - **Random-Access API**: `open`, `open_with_limits`, `find_index`, `open_by_name`, `read_entry`, `read_entry_with_limits`, `read_all`, `read_all_with_limits`.
- **Full Writer (`ZipWriter`)**:
  - Chunked 64 KiB `ZipBuf` builder finalized via balanced pairwise `Bytes::concat` (native `memcpy`).
  - Store (Method 0) and Deflate (Method 8, configurable compression levels `0..9`).
  - Automatic UTF-8 flag (bit 11) for non-ASCII filenames/comments, MS-DOS timestamps, file & archive comments, directories (`add_dir`), and POSIX symlinks (`add_symlink`).
  - Automatic **ZIP64** upgrade (0x0001 Extra Field + ZIP64 EOCD + Locator) when any size/offset reaches `>= 0xFFFFFFFF` or entry count reaches `>= 0xFFFF` (or via `WriteOptions.force_zip64`).
- **Day-1 Security Defenses**:
  - **Zip-Slip & Path Sanitizer (`clean_extract_path`)**: Rejects `..` traversal (`/` and `\`), absolute paths, NUL bytes, Windows drive letters & NTFS Alternate Data Streams (`:`), and Windows reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`..`COM9`, `LPT1`..`LPT9`, case-insensitive with optional extension/trailing spaces).
  - **Zip Bomb Protection (`Limits`)**: Configurable `max_entries`, `max_entry_size`, `max_total_size`, and `max_compression_ratio`. Enforces strict byte caps inside `flate::deflate_decompress_with_limit`—including against lying headers claiming `uncompressed_size == 0`—so malicious streams terminate without OOM.
  - **Structural Integrity**: Detects overlapping Local File Header / payload ranges (O(N) fast path for sorted archives, O(N log N) mergesort fallback), duplicate filenames (`reject_duplicates`), forged/negative/out-of-bounds offsets, malformed EOCD, and truncated streams with 0 panics and 0 Wasm32 traps.

## Quick Start

```pion
import "zip"

// Write a ZIP archive
let w = zip::ZipWriter::new()
let _ = w.set_comment("created with pion zip")
let _ = w.add_file_stored("hello.txt", "Hello, ZIP!\n".to_bytes())
let _ = w.add_file("dir/中文.txt", "Deflated UTF-8 content".to_bytes())
let _ = w.add_dir("empty_dir")
let archive = match w.finish() {
  Ok(b) => b
  Err(e) => {
    let _ = zip::zip_error_message(e)
    Bytes::new(0)
  }
}

// Read and verify entries safely
match zip::ZipReader::open(archive) {
  Ok(r) => {
    match r.open_by_name("dir/中文.txt") {
      Ok(data) => {
        let _ = data.to_string()
      }
      Err(_) => ()
    }
    match zip::clean_extract_path("../etc/passwd") {
      Err(zip::ZipError::InsecurePath(_)) => () // blocked
      _ => ()
    }
  }
  Err(_) => ()
}
```

## Verification

- **Compliance & Day-1 Security Suite**: `pionc test --json packages/zip` — **34 / 34 passing** (14/14 `zip` tests + 20/20 dependency `flate` tests), covering APPNOTE 6.3.10, Python `zipfile` & Go `archive/zip` embedded interop vectors, Data Descriptors with and without signature, ZIP64, CRC-32 mismatch, Zip-Slip, Zip Bombs (honest & lying headers), overlaps, duplicates, and every prefix truncation.
- **Live Interoperability**: Archives written by Pion `ZipWriter` (Store, Deflate L6, UTF-8 filename, directory, archive comment, ZIP64) verified 100% byte-identical by both `python3 -m zipfile` and Go 1.27 `archive/zip`.
- **Dual-Target Wasm32 Smoke (`packages/zip/wasm_smoke`)**: Native debug/release and Wasm32 debug/release (executed on `node v24.22.2` with `pion_wasm_rt.mjs`) all 4 modes exit `0`.
- **Formatting & Typecheck**: `pionc fmt --check packages/zip` and `pionc check --json packages/zip` pass with 0 diagnostics.

## Head-to-Head Benchmarks

Measured on `Darwin arm64` (`tokyo-mac-studio-0`) via `sh packages/zip/bench/run_bench.sh` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) comparing:
- **`pion`**: `packages/zip` (`pionc 0.1.0 --release`)
- **`go_zip`**: Go `go1.27.3` stdlib `archive/zip`
- **`rust_zip`**: Rust `1.100.0` `zip =2.2.3` (`--release`, `default-features = false, features = ["deflate"]`)

### 1. Full Decompress + CRC-32 (200 mixed JSON/log/source files, 23,566,337 B uncompressed)

_SHA-256 verified identical across all implementations and rounds: `df6e3ff7b79285ecb05e3bce3f23738539322811666aea50ae9a6236498d1ec2`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `go_zip`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 43.897 | 42.903 | 51.351 | 536.86 | 6.23 MiB | 0.84x |
| `go_zip` | 36.895 | 36.384 | 43.782 | 638.74 | 17.02 MiB | 1.00x (baseline) |
| `rust_zip` | 23.992 | 22.742 | 25.070 | 982.25 | 4.75 MiB | 1.54x |

### 2. Deflate L6 Pack & Write (200 mixed JSON/log/source files, 23,566,337 B uncompressed)

_SHA-256 verified identical across all implementations and rounds: `a8a92fa0e98f2bdc245c3ddb2811d932a85b4fc902568c8b78907c95298a903b`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `go_zip`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 147.712 | 136.654 | 159.852 | 159.54 | 63.98 MiB | 0.52x |
| `go_zip` | 76.125 | 72.703 | 80.376 | 309.57 | 64.39 MiB | 1.00x (baseline) |
| `rust_zip` | 106.362 | 100.476 | 111.706 | 221.57 | 28.52 MiB | 0.72x |

### 3. 20,000-Entry Central Directory Scan + 60,000 Random Name Lookups (3 × 20,000 ops)

_SHA-256 verified identical across all implementations and rounds: `5a54f9e6c779591b9b80273100d47f9256ba6cd8f1ef3c1dd34503607e1b2a8b`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_zip`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 36.031 | 34.053 | 41.863 | 600.52 | 15.80 MiB | **2.54x** |
| `go_zip` | 91.693 | 81.859 | 96.983 | 1528.21 | 29.09 MiB | 1.00x (baseline) |
| `rust_zip` | 148.669 | 146.731 | 154.716 | 2477.82 | 18.20 MiB | 0.62x |

### Honest Performance Analysis

- **Strengths**:
  - **Large-archive CD indexing & random lookup (`2.54×` Go, `4.13×` Rust `zip`)**: Direct `Bytes` Central Directory parsing, O(1) `Map[String, Int]` indexing, zero-copy `Bytes::slice` Store reads, and an O(N) sorted-order overlap check give `600.5 ns/op` at `15.80 MiB` RSS (nearly half Go's `29.09 MiB` RSS), even with duplicate and overlap checks enabled by default.
  - **Low-memory full extraction (`536.9 MB/s`, `6.23 MiB` RSS)**: Reaches `0.84×` Go throughput while using **2.7× less peak RSS** than Go (`17.02 MiB`).
- **Remaining Gaps**:
  - **Full Decompress (`0.84×` Go, `0.55×` Rust)** and **Deflate L6 Write (`0.52×` Go, `0.72×` Rust)**: Both Go (`crc32_arm64.s`) and Rust (`crc32fast`) use ARMv8 hardware `CRC32X` instructions and native SIMD/unaligned 64-bit loads inside their DEFLATE engines, whereas `packages/zip` delegates to pure-Pion `packages/flate` (scalar Slice-by-16 CRC-32 and byte-indexed LZ77). Any future SIMD/hardware-CRC improvements in `packages/flate` will automatically lift `packages/zip` throughput without API changes.
