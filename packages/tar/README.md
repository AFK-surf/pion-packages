# `tar` — Pure-Pion TAR Archive Library

Pure-Pion, zero-dependency, production-grade TAR archive reader and writer modeled after Go's standard library [`archive/tar`](https://pkg.go.dev/archive/tar), with Day-1 red-team security defenses built in by default.

## Features

- **Full format support**:
  - **USTAR** (POSIX.1-1988, including prefix/suffix path splitting up to 256 bytes)
  - **PAX** (POSIX.1-2001, both per-file `x` and global `g` extended headers: arbitrary-length `path`, `linkpath`, `size`, `uid`, `gid`, `uname`, `gname`, sub-second `mtime`/`atime`/`ctime`, `SCHILY.xattr.*`, and custom vendor records)
  - **GNU** (`L` LongName, `K` LongLink, base-256 binary integers including negative timestamps and >8 GiB sizes, plus GNU sparse formats `0.0`, `0.1`, `1.0`, and oldgnu `'S'`)
  - **V7** (original Unix V7 tar) and **STAR** (Schily tar reader support)
  - All standard typeflags: `Reg` (`'0'`), `RegA` (`'\0'`), `Link` (`'1'`), `Symlink` (`'2'`), `Char` (`'3'`), `Block` (`'4'`), `Dir` (`'5'`), `Fifo` (`'6'`), `Cont` (`'7'`), `XHeader` (`'x'`), `XGlobalHeader` (`'g'`), `GNULongName` (`'L'`), `GNULongLink` (`'K'`), `GNUSparse` (`'S'`).
- **Pure, `Send`-safe API**:
  - Zero `World` dependency; compiles cleanly to both **Native** and **Wasm32**.
  - Streaming `Reader` (`Reader::new`, `Reader::with_limits`, `next()`, `read_data()` with zero-copy `Bytes` slicing for regular files) and `Writer` (`Writer::new`, `write_header()`, `write_data()`, `finish()`).
  - High-level helpers: `read_all`, `read_all_with_limits`, `write_all`, and `Entry`.
  - Safe extraction path sanitizer: `clean_extract_path(name)` rejecting `..` traversal, absolute paths, NUL bytes, and Windows drive-letter injection.
- **Day-1 Red-Team Security Defenses**:
  - Full 64-bit (`Int64`) arithmetic for all sizes, offsets, and timestamps (immune to 32-bit overflow panics on `0x7fff_ffff_ffff_ffff` or negative base-256 sizes).
  - Explicit `Limits` (`max_entries`, `max_entry_size`, `max_pax_bytes`, `max_pax_records`, `max_sparse_holes`) defending against PAX bombs and multi-TiB sparse-hole OOM bombs.
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

- **33 compliance & red-team tests** (100% passing), embedding 34 official Go 1.27 `archive/tar/testdata/*.tar` archives (USTAR, PAX, GNU, V7, STAR, all 4 sparse formats, signed checksums, truncation, malformed headers) plus red-team vectors (64-bit overflow, PAX bombs, 1 TiB sparse bomb, `clean_extract_path` attacks).
- **Wasm32 smoke test**: `packages/tar/wasm_smoke/` builds and runs cleanly with `pionc build --release --target wasm32` and `pionc run --release --target wasm32`.

## Head-to-Head Benchmarks

Measured on **Darwin arm64** via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved) against Go 1.27.3 stdlib `archive/tar` and Rust `tar` 0.4.46 (`--release`, LTO), with mandatory byte-for-byte stdout SHA-256 verification.

Reproduce with:

```sh
sh packages/tar/bench/run_bench.sh
```

### Workload 1: Mixed USTAR/PAX/GNU TAR Read (20 × 2,000 = 40,000 entries, 122.9 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_tar`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 50.340 | 48.790 | 55.286 | 2441.63 | 1258.49 | 13.95 MiB | **1.49x** |
| `go_tar` | 74.827 | 71.281 | 80.039 | 1642.60 | 1870.67 | 19.55 MiB | 1.00x (baseline) |
| `rust_tar` | 42.500 | 42.086 | 43.642 | 2892.05 | 1062.49 | 7.75 MiB | 1.76x |

_SHA-256 verified identical across all implementations and rounds: `3c3d78ce0c9a18d405b4c9368ab245ab91670e0a5f2ec4f50ae20ae11a1bf76c`._

### Workload 2: Mixed USTAR/PAX/GNU TAR Write (20 × 2,000 = 40,000 entries, 122.9 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_tar`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 59.000 | 56.149 | 64.926 | 2083.23 | 1475.00 | 30.91 MiB | **1.09x** |
| `go_tar` | 64.407 | 61.052 | 66.805 | 1908.35 | 1610.17 | 40.64 MiB | 1.00x (baseline) |
| `rust_tar` | 47.072 | 44.753 | 47.888 | 2611.10 | 1176.81 | 18.83 MiB | 1.37x |

_SHA-256 verified identical across all implementations and rounds: `bc3a15c6b5370100c6a5c1e1b2cafd3c8a8808e3576da5d9c404939546a63888`._

### Notes on Performance
- **Read (`1.49x` Go)**: Single-pass branchless 8-byte unrolled checksum + ASCII detection, cached `String` view for zero-alloc header strings, and zero-copy `Bytes::slice` payload views.
- **Write (`1.09x` Go)**: Reusable 512B header block with dirty-prefix clearing, bounded checksum range, dedicated USTAR/GNU/PAX fast paths, and `StringBuilder` native `memcpy`. Rust `tar` remains faster on write (~1.25x faster than Pion) because Rust's `Builder<Vec<u8>>` returns its owned buffer directly with zero final copy, whereas Pion's `StringBuilder::to_string().to_bytes()` performs an additional copy into `Bytes`.
