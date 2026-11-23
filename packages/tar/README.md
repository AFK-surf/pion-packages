# `tar` — Pure-Pion TAR Archive Library

Pure-Pion, zero-dependency, production-grade TAR archive reader and writer modeled after Go's standard library [`archive/tar`](https://pkg.go.dev/archive/tar), with Day-1 red-team security defenses built in by default.

## Features

- **Full format support**:
  - **USTAR** (POSIX.1-1988, including prefix/suffix path splitting up to 256 bytes)
  - **PAX** (POSIX.1-2001, both per-file `x` and global `g` extended headers: arbitrary-length `path`, `linkpath`, `size`, `uid`, `gid`, `uname`, `gname`, sub-second `mtime`/`atime`/`ctime`, `SCHILY.xattr.*`, and custom vendor records; O(n) reader deduplication and O(n log n) writer key sorting)
  - **GNU** (`L` LongName, `K` LongLink, base-256 binary integers including negative timestamps and >8 GiB sizes, plus GNU sparse formats `0.0`, `0.1`, `1.0`, and oldgnu `'S'`)
  - **V7** (original Unix V7 tar) and **STAR** (Schily tar reader support)
  - All standard typeflags: `Reg` (`'0'`), `RegA` (`'\0'`), `Link` (`'1'`), `Symlink` (`'2'`), `Char` (`'3'`), `Block` (`'4'`), `Dir` (`'5'`), `Fifo` (`'6'`), `Cont` (`'7'`), `XHeader` (`'x'`), `XGlobalHeader` (`'g'`), `GNULongName` (`'L'`), `GNULongLink` (`'K'`), `GNUSparse` (`'S'`).
- **Pure, `Send`-safe API**:
  - Zero `World` dependency; compiles cleanly to both **Native** and **Wasm32**.
  - Streaming `Reader` (`Reader::new`, `Reader::with_limits`, `next()`, `read_data()`, `read_chunk(max_bytes)`, `is_sparse()`, `sparse_entries()`) parsing headers directly in place from `Bytes` without whole-archive string copies.
  - `Writer` (`Writer::new`, `Writer::with_capacity`, `write_header()`, `write_data()`, `finish()`) with explicit `Int64` 2 GiB (`2,147,482,624` bytes) archive-size guard preventing 32-bit `Bytes` length wrap or heap overflow, plus zero-copy staging for large payloads (`>= 64 KiB`).
  - High-level helpers: `read_all`, `read_all_with_limits`, `write_all`, and `Entry`.
  - Safe extraction path sanitizer: `clean_extract_path(name)` rejecting `..` traversal, absolute paths, NUL bytes, Windows drive letters / NTFS Alternate Data Streams (`:`), and Windows reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`).
- **Day-1 Red-Team Security Defenses**:
  - Full 64-bit (`Int64`) overflow-safe arithmetic for all sizes, offsets, and timestamps.
  - Explicit `Limits` defaults (`Limits::default()`):
    - `max_entries`: `1,000,000`
    - `max_entry_size`: `256 MiB` (`268,435,456` bytes) — caps both single-entry logical size and `read_all`'s cumulative materialized payload budget (defending against multi-entry sparse OOM bombs; use `Reader::read_chunk` or `Reader::with_limits` to stream larger entries or archives).
    - `max_pax_bytes`: `1 MiB` (`1,048,576` bytes, matching Go `maxSpecialFileSize`)
    - `max_pax_records`: `65,536`
    - `max_sparse_holes`: `1,048,576` (`1 << 20`, matching Go)
  - Strict dual checksum verification (POSIX unsigned + Sun tar signed), truncation detection, and double 512-byte zero-block EOF semantics.

## Quick Start

```pion
import "tar"

pub fn example() -> Result[Array[tar::Entry], tar::TarError] {
  let w = tar::Writer::new()
  let hdr = tar::Header::{
    ..tar::Header::new("hello.txt", 12L),
    mode: 420L, // 0644
    mod_time: tar::Timestamp::unix(1700000000L, 0L),
  }
  match w.write_header(hdr) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match w.write_data("hello world\n".to_bytes()) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let archive = match w.finish() {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  tar::read_all(archive)
}
```

## Testing & Verification

- **35 compliance & red-team unit tests** (100% passing), embedding 34 official Go 1.27 `archive/tar/testdata/*.tar` archives (USTAR, PAX, GNU, V7, STAR, all 4 sparse formats, signed checksums, truncation, malformed headers) plus red-team vectors (64-bit overflow, PAX bombs, sparse-hole bombs & streaming `read_chunk`, `clean_extract_path` Unix/Windows attacks, writer parity).
- **Differential verification**: 154/154 archives (44 Go testdata + 110 adversarial corpus) read identically to Go 1.27.3 `archive/tar` (Format field ignored), and 303/303 writer specs match Go byte-for-byte.
- **Wasm32 smoke test**: `packages/tar/wasm_smoke/` builds and runs cleanly with `pionc build --release --target wasm32` and `pionc run --release --target wasm32`.

## Formal Verification (Lean 4)

The core security and numeric kernels of `packages/tar` (`packages/tar/src/{path,format,types}.pion`) are annotated with `#verify` and formally verified end-to-end in Lean 4 (`v4.36.0-rc2` + Aeneas + `PionLean`) directly over the extracted `Tar.Funs` definitions (**0 `sorry`**, **0 `admit`**, **0 `native_decide`**, **0 `bv_decide`**, strictly standard axioms `propext`, `Classical.choice`, `Quot.sound` only).

Reproduce all proofs, axiom audits, and Lean-vs-Native differential checks (38 cases, `diff -u` exit 0) with zero worktree pollution:

```sh
sh packages/tar/proofs/run_proofs.sh
```

### Verified Theorem Suite (`packages/tar/proofs/TarProofs.lean`, 34 audited theorems)

1. **Zip-Slip & Extraction Path Safety (`packages/tar/src/path.pion`)**:
   - `validate_extract_path_bytes_sound`: Master safety theorem over the production `validate_extract_path_bytes` kernel (directly invoked by `clean_extract_path`) proving that any accepted path is simultaneously:
     - non-empty (`b.val.length > 0`);
     - non-absolute (no leading `'/'` or `'\\'`);
     - free of NUL bytes (`0x00`) and `':'` (`0x3A`, blocking Windows drive letters `[A-Za-z]:` and NTFS Alternate Data Streams);
     - free of any parent-directory traversal segment `".."` across both `'/'` and `'\\'` separators (`validate_extract_path_rejects_dotdot`);
     - free of any Windows reserved device name segment (`CON`, `PRN`, `AUX`, `NUL`, `COM1..9`, `LPT1..9`);
     - guaranteed to contain at least one real (non-empty, non-`"."`) segment.
   - `is_windows_reserved_name_total`, `is_windows_reserved_name_sound3`: Totality and case-insensitive soundness (including trailing spaces and `.ext` suffixes).
   - `ascii_upper_spec`, `ascii_upper_idempotent`, `is_path_sep_iff`, `is_dotdot_segment_spec`, `has_invalid_path_byte_spec`.
2. **TAR 512-Byte Block Alignment & Padding Arithmetic (`packages/tar/src/format.pion`)**:
   - `block_padding_total`, `block_padding_zero`: `block_padding` never panics and always yields `p ∈ [0, 512)` with `block_padding 0 = 0`.
   - `padded_size_spec`, `padded_size_zero`, `padded_size_mono`, `padded_size_idempotent`: For all `0 ≤ size ≤ 2^63 - 512`, `padded_size` never overflows, always yields a 512-byte multiple (`r % 512 = 0`) satisfying `size ≤ r < size + 512`, is monotone, and is idempotent.
3. **TAR Numeric Encoding/Decoding — Octal & GNU Base-256 (`packages/tar/src/format.pion`)**:
   - `fits_in_octal_spec`, `fits_in_octal_neg_false`, `fits_in_base256_spec`, `fits_in_octal_imp_fits_in_base256`: Exact capacity bounds for all widths and `Int64` values; negative integers never fit in octal; every octal-fitting integer fits in base-256.
   - `parse_octal_slice_fast_nonneg`: On all standard TAR header fields (`width ≤ 20`, covering 8-byte and 12-byte fields), `parse_octal_slice` never panics and every `Ok v` satisfies `0 ≤ v < 2^60` (never silently wraps negative to bypass `max_entry_size`).
   - `parse_numeric_slice_base256_sign`: For GNU base-256 fields (`b[start] & 0x80 ≠ 0`), `parse_numeric_slice` never panics, positive headers (`& 0x40 = 0`) always decode to `v ≥ 0`, and negative headers (`& 0x40 ≠ 0`) always decode to `v < 0`.
   - `format_numeric_invalid_width`, `format_numeric_spec`: Totality, rejection of `width ≤ 0`, and exact `Ok` length/capacity characterization (`out.length = width ↔ fits_in_base256 width x`).
4. **Typeflags & `TarFormat` Soundness (`packages/tar/src/types.pion`)**:
   - `is_header_only_type_total`, `is_header_only_type_iff`, `typeflag_classification`: Exact characterization of all 14 TAR typeflag constants.
   - `format_equals_iff`, `format_equals_refl`, `format_equals_symm`, `format_equals_trans`: Equivalence relation and exact equality decision on `TarFormat`.

### Proof Artifacts

- `packages/tar/proofs/TarProofs.lean`: Full Lean 4 proof suite over `Tar.Funs`.
- `packages/tar/proofs/CheckAxioms.lean`: `#print axioms` audit across all 34 main theorems (verified: only `propext`, `Classical.choice`, `Quot.sound`).
- `packages/tar/proofs/EvalDiff.lean`: `#guard` + `#eval` test suite over extracted `Tar.Funs`, cross-checked byte-for-byte (`diff -u`) against Pion native execution by `run_proofs.sh`.
- `packages/tar/proofs/run_proofs.sh`: Self-contained verification script using `/private/tmp/pion-lean-tar` (zero git worktree pollution).

## Head-to-Head Benchmarks

Measured on **Darwin arm64** (`AFK-surf/pion@69a0189d`) via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved) against Go 1.27.3 stdlib `archive/tar` and Rust `tar` 0.4.46 (`--release`, LTO), with mandatory byte-for-byte stdout SHA-256 verification. All three read benchmarks compute FNV-1a over **every payload byte**.

Reproduce with:

```sh
sh packages/tar/bench/run_bench.sh
```

### Workload 1: Mixed USTAR/PAX/GNU TAR Full Read (20 × 2,000 = 40,000 entries, 122.9 MB, full-payload FNV-1a)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_tar`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 123.035 | 119.883 | 129.687 | 998.99 | 3075.87 | 13.47 MiB | **1.25x** |
| `go_tar` | 153.760 | 151.349 | 162.253 | 799.37 | 3844.00 | 24.47 MiB | 1.00x (baseline) |
| `rust_tar` | 117.378 | 116.372 | 117.699 | 1047.14 | 2934.44 | 7.75 MiB | 1.31x |

_SHA-256 verified identical across all implementations and rounds: `5939564e36969c01c2515f273647be551478b5e83f0c0a5cb833e96990af56d6`._

### Workload 2: Mixed USTAR/PAX/GNU TAR Write (20 × 2,000 = 40,000 entries, 122.9 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_tar`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 81.573 | 74.858 | 87.505 | 1506.76 | 2039.32 | 30.94 MiB | 0.90x |
| `go_tar` | 73.339 | 70.686 | 80.267 | 1675.92 | 1833.48 | 41.94 MiB | 1.00x (baseline) |
| `rust_tar` | 53.750 | 52.196 | 54.971 | 2286.71 | 1343.75 | 18.84 MiB | 1.36x |

_SHA-256 verified identical across all implementations and rounds: `bc3a15c6b5370100c6a5c1e1b2cafd3c8a8808e3576da5d9c404939546a63888`._

### Additional Stress Workloads (`packages/tar/audit/run_audit.sh --quick`)

| Workload | `pion` | `go_tar` | `rust_tar` | `pion` vs `go_tar` |
| --- | ---: | ---: | ---: | ---: |
| Header scan, 64 MiB single file ×100 | 21.1 ms / 129.8 MiB | 17.6 ms / 69.8 MiB | 113.6 ms / 65.9 MiB | 0.83x (5.4x Rust) |
| Header scan, 4,000 PAX records/hdr ×1 | 99.9 ms / 46.7 MiB | 107.8 ms / 54.7 MiB | 129.2 ms / 24.5 MiB | **1.08x** |
| Write, 64 MiB single file ×10 | 163.9 ms / 194.0 MiB | 71.5 ms / 327.1 MiB | 97.3 ms / 131.0 MiB | 0.44x |
| Write, 4,000 PAX records/hdr ×1 | 375.4 ms / 232.3 MiB | 300.3 ms / 242.9 MiB | — | 0.80x |

### Notes on Performance
- **Full Read (`1.25x` Go)**: Direct in-place header parsing from `Bytes` (zero whole-archive `String` copy), single-pass 8-byte unrolled checksum + ASCII detection, O(n) `Map`-indexed PAX parsing, and full-payload FNV-1a parity across all three implementations.
- **Write (`0.90x` Go mixed, `1.16x` Go on 100k tiny files, `1.41x` Go on long names)**: Hybrid `StringBuilder` + zero-copy large-payload `Bytes` staging (`>= 64 KiB`) with balanced `Bytes::concat` in `finish()`, O(n log n) merge sort for PAX keys, and explicit `Int64` 2 GiB archive-size guard. Large 64 MiB writes still perform two `Bytes::concat` passes (`hdr + payload` and `+ trailer`) compared to Go/Rust's single-buffer append.
