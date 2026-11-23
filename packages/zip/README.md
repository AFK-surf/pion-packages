# `zip` — Pure Pion ZIP Archive Reader & Writer (APPNOTE 6.3.10 + ZIP64)

A pure Pion, zero-C-dependency, Native + Wasm32 compatible ZIP archive library modeled on **Go `archive/zip`** and **Rust `zip`**, built directly on `packages/flate` for RFC 1951 raw DEFLATE (Method 8), Store (Method 0), and IEEE CRC-32 verification.

Designed with a **Sans-IO** architecture: no `World` dependency, `Send`-safe public metadata types, zero-copy `Bytes` slicing on Store entries, HashDoS-immune SipHash-1-3 open-addressing O(1) name lookup, and hardened Day-1 security defenses against Zip-Slip, Zip Bombs, HashDoS, overlapping entries, integer-overflow offsets, and malformed headers.

## Features

- **Full Reader (`ZipReader`)**:
  - **EOCD Search & Trailing Data**: Scans backwards up to the maximum 65,535-byte archive comment, allowing trailing bytes after EOCD (`eocd_pos + 22 + comment_len <= len`) while rejecting `comment_len` past EOF and skipping fake `PK\x05\x06` signatures embedded in comments via O(1) structural plausibility checks.
  - **SFX / Prepended Data (`baseOffset`)**: Supports self-extracting archives and concatenated `zip1 || zip2` layouts by computing `baseOffset = eocd_start - cd_size - cd_offset` when direct `cd_offset` misses `PK\x01\x02`.
  - **Central Directory & Local File Header Validation**: Parses all `PK\x01\x02` records across `[cd_offset, cd_offset + cd_size)` (supporting legacy 16-bit >65,535 entry archives via `count mod 65536` while rejecting hidden trailing CD records), and cross-checks LFH signature, filename (byte-for-byte), compression method, non-descriptor CRC-32/sizes, and overflow-checked bounds against Central Directory start.
  - **Compression Methods**: Method `0` (Store, zero-copy `Bytes::slice` with exact length assertion) and Method `8` (Raw DEFLATE via `flate::deflate_decompress_with_limit`).
  - **Data Descriptors (Bit 3)**: Supports both 16/24-byte descriptors with `0x08074b50` signature (as emitted by Go `archive/zip` and CPython streaming `force_zip64`) and 12/20-byte signature-less descriptors, selecting 32-bit vs 64-bit descriptor width from the LFH `0x0001` ZIP64 extra field per APPNOTE §4.3.9.2.
  - **ZIP64**: Supports ZIP64 EOCD Record (`0x06064b50`), ZIP64 EOCD Locator (`0x07064b50`), and `0x0001` Extended Information Extra Fields (`>= 65,535` entries and `force_zip64`), following APPNOTE §4.4.1.4 sentinel rules (only sentinel fields are overridden; non-sentinel disagreements are rejected).
  - **HashDoS-Immune Name Index**: Replaces generic string hashing with a per-archive keyed **SipHash-1-3** open-addressing index (`NameIndex`), keeping `open` and `open_by_name` strictly linear O(N) / O(1) even against adversarial colliding filenames.
  - **Metadata & Timestamps**: UTF-8 Language Encoding Flag (bit 11), MS-DOS date/time encoding/decoding (`DosDateTime::from_dos`, `to_dos`, `from_unix`, `to_unix`, clamping `< 1980` to `1980-01-01 00:00:00`, `> 2107` to `2107-12-31 23:59:58`, and clamping invalid calendar days such as Feb 31 to month end), Unix permissions / directory / symlink `external_attr` (`unix_mode`, `is_dir`, `is_symlink`).
  - **Random-Access API**: `open`, `open_with_limits`, `find_index`, `open_by_name`, `read_entry`, `read_entry_with_limits`, `read_all`, `read_all_with_limits`.
- **Full Writer (`ZipWriter`)**:
  - Chunked 64 KiB `ZipBuf` builder finalized via a **single-pass pre-allocated merge** (eliminating `⌈log2(N)⌉` intermediate full-archive copies and lowering peak RSS).
  - Store (Method 0) and Deflate (Method 8, configurable compression levels `0..9`).
  - Automatic UTF-8 flag (bit 11) for non-ASCII filenames/comments, MS-DOS timestamps, file & archive comments, directories (`add_dir`), and POSIX symlinks (`add_symlink`).
  - Automatic **ZIP64** headers (`0x0001` Extra Field + ZIP64 EOCD + Locator) when entry count reaches `>= 0xFFFF` or when `WriteOptions.force_zip64` is enabled.
- **In-Memory Size Limit (2 GiB Ceiling)**:
  - Because `ZipReader` and `ZipWriter` operate on in-memory `Bytes` buffers whose length and indices are signed 32-bit `Int`, single archives and single entries are capped at **`2 GiB - 1` (`2,147,483,647` bytes)**. Archives or entries `>= 2 GiB` cannot be represented in memory and return `ZipError::LimitExceeded`; streaming I/O for multi-gigabyte archives is outside the current Sans-IO `Bytes` buffer API.
- **Day-1 Security Defenses**:
  - **Zip-Slip & Path Sanitizer (`clean_extract_path`)**: Rejects `..` traversal (`/` and `\`), absolute paths, control characters (`0x00..0x1F`, `0x7F`), Windows drive letters & NTFS Alternate Data Streams (`:`), trailing `.` or space on any segment, and Windows reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`..`COM9`, `LPT1`..`LPT9`, superscript `COM¹`..`COM³` / `LPT¹`..`LPT³`, `CONIN$`, `CONOUT$`, case-insensitive with optional extension/trailing spaces).
  - **Zip Bomb Protection (`Limits`)**: Configurable `max_entries`, `max_entry_size`, `max_total_size`, and `max_compression_ratio`. Enforces strict byte caps inside `flate::deflate_decompress_with_limit`—including against lying headers claiming `uncompressed_size == 0`—so malicious streams terminate without OOM.
  - **Structural Integrity**: Overflow-safe `Int64` range checks on all offsets and sizes, overlapping Local File Header / payload detection (O(N) fast path for sorted archives, O(N log N) mergesort fallback), duplicate filename rejection (`reject_duplicates`), LFH/CD filename consistency verification, malformed EOCD rejection, and truncated stream handling with 0 panics and 0 Wasm32 traps.

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

- **Compliance & Security Suite**: `pionc test --json packages/zip` — **35 / 35 passing** (15/15 `zip` tests + 20/20 dependency `flate` tests), covering APPNOTE 6.3.10, Python `zipfile` & Go `archive/zip` embedded interop vectors, Data Descriptors with and without signature, ZIP64, CRC-32 mismatch, Zip-Slip, Zip Bombs (honest & lying headers), overlaps, duplicates, SFX `baseOffset`, trailing bytes, LFH/CD filename checks, MS-DOS timestamp clamping, and every prefix truncation.
- **Red-Team Audit Suite (`packages/zip/audit`)**:
  - `pionc test --json packages/zip/audit`: **18 / 18 passing** (12/12 `redteam_*` + 6/6 `control_*`).
  - `sh packages/zip/audit/run_audit.sh all`: **0 crashes** across 62 crafted differential vectors and 12,000 mutation-fuzz cases (6,000 clean + 6,000 including crash seeds), **100% byte-identical** stdout across all 4 build modes (Native/Wasm32 × debug/release), and **0.09 s** on 65,536 adversarial HashDoS colliding names (linear, matching 0.10 s control).
- **Dual-Target Wasm32 Smoke (`packages/zip/wasm_smoke`)**: Native debug/release and Wasm32 debug/release (executed on `node v24.22.2` with `pion_wasm_rt.mjs`) all 4 modes exit `0`.
- **Formatting & Typecheck**: `pionc fmt --check packages/zip` and `pionc check --json packages/zip` pass with 0 diagnostics.

## Formal Verification (Lean 4)

The core ZIP security invariants and MS-DOS timestamp bitfield codec in `packages/zip/src/` (`in_range64`, `ascii_upper`, `is_zip_path_sep`, `is_zip_forbidden_byte`, `is_zip_forbidden_seg_tail`, `is_win_reserved_3`, `is_win_reserved_4`, `clamp_int`, `days_in_month`, `DosDateTime::default`, `DosDateTime::new`, `DosDateTime::from_dos`, `DosDateTime::to_dos`) are annotated with `#verify`, extracted directly into Lean 4 via `pionc extract-lean`, and mechanically proved in `packages/zip/proofs/` (**22 theorems, 0 `sorry` / `admit` / `bv_decide` / `native_decide`, standard axioms only**):

- **`ZipProofs/Security.lean` (12 theorems)**: `Int64` overflow-safe range checking (`in_range64` rejects negatives and `INT64_MAX` wrap-around without arithmetic overflow), ASCII uppercasing idempotence & lowercase elimination, Zip-Slip path separator / control / colon / DEL / trailing `.` & space byte classification, and complete Windows reserved device name predicates (`CON`/`PRN`/`AUX`/`NUL`, `COM1`..`COM9`, `LPT1`..`LPT9`, strictly rejecting `0`).
- **`ZipProofs/DosTime.lean` (10 theorems)**: `clamp_int` bounds & identity, Gregorian `days_in_month` bounds & leap-year `2000`/`2100` exactness, `DosDateTime::new` clamping & even-second normalization & idempotence, `DosDateTime::from_dos` totality and valid calendar output for all `u32`, `DosDateTime::to_dos` 16-bit range guarantee (`≤ 65535`), default epoch round-trip, and exact lossless `from_dos(to_dos(dt)) = dt` bitfield round-trip for every valid even-second `DosDateTime`.
- **Differential Cross-Check**: `packages/zip/proofs/EvalDiff.lean` cross-checks 35 cases between Native Pion execution and Lean 4 `#eval` (`diff -u` exit `0`). Run `sh packages/zip/proofs/run_proofs.sh` to reproduce end-to-end.

## Head-to-Head Benchmarks

Measured on `Darwin arm64` (`tokyo-mac-studio-0`) via `sh packages/zip/bench/run_bench.sh` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) comparing:
- **`pion`**: `packages/zip` (`pionc 0.1.0 --release`)
- **`go_zip`**: Go `go1.27.3` stdlib `archive/zip`
- **`rust_zip`**: Rust `1.100.0` `zip =2.2.3` (`--release --locked`, `default-features = false, features = ["deflate"]`, locked via `packages/zip/bench/rust/Cargo.lock`: `flate2 1.1.11`, `miniz_oxide 0.9.1`, `crc32fast 1.5.5`)

### 1. Full Decompress + CRC-32 (200 mixed JSON/log/source files, 23,566,337 B uncompressed)

_SHA-256 verified identical across all implementations and rounds: `df6e3ff7b79285ecb05e3bce3f23738539322811666aea50ae9a6236498d1ec2`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `go_zip`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 51.997 | 46.998 | 59.155 | 453.22 | 6.23 MiB | 0.83x |
| `go_zip` | 43.306 | 42.174 | 43.810 | 544.18 | 15.42 MiB | 1.00x (baseline) |
| `rust_zip` | 29.660 | 29.248 | 30.896 | 794.55 | 4.75 MiB | 1.46x |

### 2. Deflate L6 Pack & Write (200 mixed JSON/log/source files, 23,566,337 B uncompressed)

_SHA-256 verified identical across all implementations and rounds: `a8a92fa0e98f2bdc245c3ddb2811d932a85b4fc902568c8b78907c95298a903b`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `go_zip`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 160.149 | 153.976 | 181.847 | 147.15 | 55.72 MiB | 0.49x |
| `go_zip` | 78.654 | 72.730 | 81.822 | 299.62 | 65.97 MiB | 1.00x (baseline) |
| `rust_zip` | 121.926 | 103.381 | 130.851 | 193.28 | 28.53 MiB | 0.65x |

### 3. 20,000-Entry Central Directory Scan + 60,000 Random Name Lookups (3 × 20,000 ops)

_SHA-256 verified identical across all implementations and rounds: `5a54f9e6c779591b9b80273100d47f9256ba6cd8f1ef3c1dd34503607e1b2a8b`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_zip`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 43.756 | 36.921 | 48.859 | 729.27 | 15.06 MiB | **2.33x** |
| `go_zip` | 101.993 | 86.057 | 113.823 | 1699.88 | 28.86 MiB | 1.00x (baseline) |
| `rust_zip` | 159.757 | 147.226 | 201.739 | 2662.62 | 18.20 MiB | 0.64x |

### Honest Performance & Methodology Notes

- **Strengths**:
  - **Large-archive CD indexing & random lookup (`2.33×` Go, `3.65×` Rust `zip`)**: Direct `Bytes` Central Directory parsing, HashDoS-immune SipHash-1-3 open-addressing indexing, zero-copy `Bytes::slice` Store reads, and an O(N) sorted-order overlap check achieve `729.3 ns/op` at `15.06 MiB` RSS (nearly half Go's `28.86 MiB` RSS), with duplicate, overlap, and LFH/CD filename checks all enabled by default.
  - **Low-memory extraction & single-pass writing**: W1 reaches `0.83×` Go throughput at **2.5× lower peak RSS** (`6.23 MiB` vs `15.42 MiB`). Replacing pairwise `Bytes::concat` with single-pass pre-allocated chunk merging reduced W2 peak RSS from `63.98 MiB` to **`55.72 MiB`** (`10.25 MiB` below Go's `65.97 MiB`).
- **Benchmark Caveats & Remaining Gaps**:
  - **W3 API shape caveat**: On Store entries, Pion's `open_by_name` returns a zero-copy `Bytes::slice`, whereas Go (`io.ReadAll` through `fs.File`, which also lazily builds a sorted `fs.FS` directory tree on first `Open`) and Rust (`read_to_end` through `ZipFile`) copy payload bytes into fresh buffers. The W3 lead is real for in-memory Store workloads, but partly reflects zero-copy slicing vs streaming-reader copy semantics.
  - **W2 compressed size caveat**: W2's stdout SHA-256 gate verifies metadata (`files`, `total_uncomp`, `xor_crc`), not compressed archive size. On the 200-file corpus at Deflate level 6, `packages/flate` emits `2,317,817 B` vs Go `compress/flate` `2,237,829 B` (**+3.6%**) and C zlib `2,241,847 B`.
  - **W1 (`0.83×` Go, `0.57×` Rust) & W2 (`0.49×` Go, `0.76×` Rust) root cause**: Profiling (`run_audit.sh prof`) confirms `packages/zip` header/framing overhead is negligible (`<= 10%`); the throughput gap belongs to **`packages/flate`** (scalar Slice-by-16 CRC-32 ~4.5× slower than Go/Rust ARMv8 hardware `CRC32X`, plus scalar LZ77 L6 matching). Any future SIMD/hardware-CRC improvements in `packages/flate` will automatically lift `packages/zip` W1/W2 throughput without API changes.
