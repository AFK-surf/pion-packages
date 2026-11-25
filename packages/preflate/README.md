# `preflate` (`v0.1.0`)

Pure-Pion bit-exact **RFC 1951 DEFLATE** stream analyzer and reconstructor with zero `extern "C"`, zero `World` dependency, and full Native + Wasm32 support. Only depends on in-repo [`flate`](../flate).

`preflate` splits an arbitrary raw RFC 1951 DEFLATE bitstream into:
1. Its uncompressed **`plain`** bytes, and
2. A compact **`"PF"` correction stream** (`corrections`) that records only the minimal deviations from a deterministic zlib-accurate LZ77 + Huffman predictor.

Given `(corrections, plain)`, `reencode` deterministically reconstructs the **exact original raw DEFLATE bitstream bit-for-bit**, enabling downstream recompression pipelines (e.g. Zstd / LZMA / Brotli over uncompressed payloads) while preserving bit-exact DEFLATE restoration.

## Features

- **Bit-Exact RFC 1951 Coverage**:
  - Stored (`BTYPE=00`), fixed Huffman (`BTYPE=01`), and dynamic Huffman (`BTYPE=10`) blocks, including multi-block streams, empty blocks, sync-flush blocks, non-zero byte-alignment padding bits, alternate length-258 encoding, 32 KiB sliding-window boundaries, overlapping RLE matches, and trailing bytes after the final block (`compressed_size`).
  - Dynamic Huffman edge cases including `HDIST=32`, 15-bit tree depth boundaries, and RLE code-length repeats.
- **Compact `"PF"` Correction Stream**:
  - Deterministic zlib-accurate LZ77 predictor with automatic preset selection across **zlib levels 1–9**, **`windowBits` 9..15**, **`Z_FILTERED`**, RLE, and Huffman-only strategies.
  - Dynamic Huffman header prediction (zlib canonical tree builder) and optional `flate` compression of the correction payload when beneficial.
- **Security & Decompression-Bomb Limits**:
  - `analyze_limited(deflate, plain_limit)` enforces `plain_limit` incrementally before buffer growth and writes, rejecting zip bombs without OOM (`plain_limit < 0` is rejected immediately).
  - Hard raw correction-stream cap (`max_corrections_raw = 256 MiB`) enforced during both analysis and reconstruction.
  - Truncated compressed `"PF"` wrappers are decoded through `flate`'s bounded decompressor without preallocating untrusted declared sizes.
  - Corrupted match overrides, out-of-window back-references, malformed Huffman trees, and malformed `"PF"` headers return explicit `Err(String)` with zero panics and zero Wasm32 traps.

## Public API

```pion
/// Output of analyzing a raw RFC 1951 DEFLATE stream.
pub struct PreflateResult {
  pub compressed_size : Int
  pub corrections : Bytes
  pub plain : Bytes
}

/// Analyze a raw DEFLATE stream with no plain-text limit beyond `Int` bounds.
pub fn analyze(deflate : Bytes) -> Result[PreflateResult, String]

/// Analyze a raw DEFLATE stream, failing if decoded plain text exceeds `plain_limit`.
pub fn analyze_limited(deflate : Bytes, plain_limit : Int) -> Result[PreflateResult, String]

/// Recreate the exact raw DEFLATE bitstream from `corrections` and `plain`.
pub fn reencode(corrections : Bytes, plain : Bytes) -> Result[Bytes, String]
```

## Quick Start

```pion
import "flate"
import "preflate"

let plain = "The quick brown fox jumps over the lazy dog.\n".to_bytes()
let deflated = match flate::deflate_compress(plain, 6) {
  Ok(b) => b
  Err(_) => Bytes::new(0)
}

match preflate::analyze_limited(deflated, 1024 * 1024) {
  Ok(res) => {
    // `res.plain` equals `plain`, and `res.corrections` is a compact "PF" blob.
    match preflate::reencode(res.corrections, res.plain) {
      Ok(rebuilt) => {
        // `rebuilt` is bit-for-bit identical to `deflated`.
        let _ = rebuilt.length()
      }
      Err(_) => ()
    }
  }
  Err(_) => ()
}
```

## Verification

```sh
sh scripts/verify.sh packages/preflate
```

- **Unit & Security Suite**: `pionc test --json packages/preflate` — **10 / 10 `preflate` tests passing** (31 / 31 total including dependency `flate`), covering `flate` L0–L9 roundtrips, real-world Python `zlib` / PNG / QPDF streams, `windowBits` 9..12 and `Z_FILTERED`, trailing bytes, non-zero padding bits, dynamic Huffman edge cases, `plain_limit` bomb rejection, `max_corrections_raw` exact boundaries, truncated wrapper OOM guards, and mutation fuzzing.
- **Formatting & Typecheck**: `pionc fmt --check` and `pionc check --json` pass on `packages/preflate`, `packages/preflate/wasm_smoke`, and `packages/preflate/bench/pion_bench`.

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical `318 B` stdout SHA-256 (`38c79be0e351f93af21d461a33117f7e7bae0433081737298c4144b2c0528adf`, matching `flate v0.1.1` baseline):

```sh
pionc run packages/preflate/wasm_smoke
pionc run --release packages/preflate/wasm_smoke
pionc run --target wasm32 packages/preflate/wasm_smoke
pionc run --target wasm32 --release packages/preflate/wasm_smoke
```

Sample stdout:

```text
stored: def=3965 plain=3960 corr=7 fnv=1642679526
fixed: def=19 plain=17 corr=7 fnv=1443652498
dyn_l1: def=198 plain=15600 corr=88 fnv=2315173904
dyn_l6: def=161 plain=15600 corr=93 fnv=343177715
dyn_l9: def=152 plain=15600 corr=93 fnv=2198932572
preflate_wasm_smoke:ok bomb=rejected bad_def=rejected bad_corr=rejected
```

## Head-to-Head Benchmarks

Measured on `Linux x86_64` (`pionc 0.1.0 --release` vs Rust `preflate-rs =0.7.6 --release`) via `sh packages/preflate/bench/run_bench.sh` using `scripts/bench_compare.py` (strictly interleaved, mandatory stdout SHA-256 byte-exact equality with the original raw DEFLATE stream).

Workload: deterministic `964,166 B` (~942 KiB) synthetic structured JSON/log corpus compressed with Python `zlib` (`wbits=-15`) at levels 1, 6, and 9; each timed run performs `3` full `analyze` + `reencode` roundtrips (`2,892,498 B` plain text processed) and outputs the reconstructed raw DEFLATE stream to stdout.

### Speed (`analyze` + `reencode` Roundtrip, 3 × 964,166 B = 2,892,498 B plain)

| Workload | `pion` Median / Min / P95 (Throughput) | `rust_preflate_rs` Median / Min / P95 (Throughput) | Speedup (vs `rust_preflate_rs`) | Speedup (vs pre-opt `01ef1b7e`) | Stdout SHA-256 (original DEFLATE) |
| --- | ---: | ---: | ---: | ---: | --- |
| zlib L1 (`186,902 B` DEFLATE) | **49.839** / 47.926 / 52.207 ms (58.04 MB/s) | 60.545 / 49.683 / 63.584 ms (47.77 MB/s) | **1.21x** | **~1.7x–2.0x** | `751431aadfa83219...` |
| zlib L6 (`151,737 B` DEFLATE) | 112.930 / 106.653 / 114.523 ms (25.61 MB/s) | **103.819** / 90.250 / 108.649 ms (27.86 MB/s) | **0.92x–1.10x** | **~1.8x–1.9x** | `d2c58f601a6a2bdb...` |
| zlib L9 (`136,769 B` DEFLATE) | 295.000 / 281.605 / 303.301 ms (9.81 MB/s) | **116.257** / 114.688 / 116.774 ms (24.88 MB/s) | **0.39x–0.42x** | **~1.5x–1.7x** | `8ca8b1c8a544151b...` |

### Correction-Stream Compactness

| Workload | Original DEFLATE | `pion` Corrections | `rust_preflate_rs` Corrections | Notes |
| --- | ---: | ---: | ---: | --- |
| zlib L1 | 186,902 B | 57 B (0.03%) | **28 B** (0.01%) | Both near-zero overhead |
| zlib L6 | 151,737 B | **46 B** (0.03%) | 7,166 B (4.72%) | Measured on this synthetic repetitive JSON log workload (**155.8× smaller**) |
| zlib L9 | 136,769 B | **46 B** (0.03%) | 8,744 B (6.39%) | Measured on this synthetic repetitive JSON log workload (**190.1× smaller**) |

### Honest Performance Notes

- **Throughput**: With zero-COW `FixedArray[Byte]` `BitWriter`/`ByteWriter`, packed Huffman tables, split fast/slow 4-byte-refill inflate, reusable `FixedArray[Int]` token buffers, zero-tuple rolling-hash predictor with `end_b`/`end_p`/`end_m` pruning and 6-arg register-only slow-preset loops, and L1-first/early-bailout/zero-cost-prefix-reuse preset selection, `pion` now **matches or beats Rust `preflate-rs 0.7.6` at zlib L1 (`1.21x`) and L6 (`0.92x–1.10x`)**, and reaches **`0.39x–0.42x` at zlib L9** (~1.5x–1.7x faster than `01ef1b7e`) while walking the full 4096-deep zlib hash chain in pure Pion without SIMD or unsafe code.
- **Correction-stream size**: On this synthetic repetitive JSON log workload at zlib L6 and L9, `pion`'s zlib-accurate predictor emits `46 B` corrections vs `7,166 B` / `8,744 B` for `preflate-rs 0.7.6` (**155.8×** / **190.1×** smaller), while on L1 `preflate-rs` is slightly smaller (`28 B` vs `57 B`); real-world non-synthetic corpora will vary depending on compressor family and entropy.

## License

MIT (matching `AFK-surf/pion-packages`).
