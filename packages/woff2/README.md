# `woff2` (`v0.1.0`)

Pure Pion implementation of the **W3C WOFF 2.0 (`wOF2`)** and **WOFF 1.0 (`wOFF`)** font container decoders to TrueType/OpenType (SFNT), with zero `extern "C"` and no `World` requirement. Directly reuses `packages/brotli` and `packages/flate`.

## Features

- **Automatic Format Detection**: `decode(data)` auto-detects `wOF2` (WOFF 2.0 via `brotli::decode_with_limits`) and `wOFF` (WOFF 1.0 via `flate::zlib_decompress_with_limit`).
- **Complete WOFF 2.0 Support**: all 63 known table tags + custom 4-byte tags (`0x3F`), strict `UIntBase128` validation (rejecting leading zeros, >5 bytes, and `uint32` overflow), `255UInt16`, `glyf` + `loca` transformation reconstruction (empty/simple/composite glyphs, all 6 triplet flag ranges, overlap bit, explicit/computed bounding boxes, short & long `loca`, `head.indexToLocFormat`), and `hmtx` transformation reconstruction (both transformed and untransformed `glyf`).
- **Complete WOFF 1.0 Support**: per-table RFC 1950 zlib decompression (with FCHECK + Adler-32 validation) and uncompressed table passthrough.
- **Exact SFNT Assembly**: tables sorted by big-endian unsigned tag, 4-byte aligned, exact per-table SFNT checksums, and exact `head.checkSumAdjustment` (`0xB1B0AFBA`).
- **Font-Bomb Defense (`DecodeLimits`)**: enforces `max_output_bytes` (default 64 MiB), `max_tables` (default 256), and `max_glyphs` (default 65,536) before allocations and during decompression/reconstruction.
- **Pluggable Decompressor**: `decode_using(data, dec, limits)` accepts any custom `dyn Decompressor`.

## Public API

```pion
pub val struct DecodeLimits {
  pub max_output_bytes : Int
  pub max_tables : Int
  pub max_glyphs : Int
}

pub enum WoffError {
  InvalidSignature(String)
  TruncatedHeader(String)
  UnsupportedCollection
  InvalidTableDirectory(String)
  InvalidVarInt(String)
  BoundsExceeded(String)
  BrotliError(String)
  ZlibError(String)
  GlyfReconstructionError(String)
  HmtxReconstructionError(String)
  LimitExceeded(String)
}

pub trait Decompressor {
  brotli_decode(self : Self, data : Bytes, max_output_bytes : Int) -> Result[Bytes, WoffError]
  zlib_decompress(self : Self, data : Bytes, max_output_bytes : Int) -> Result[Bytes, WoffError]
}

pub fn decode(data : Bytes) -> Result[Bytes, WoffError]
pub fn decode_with_limits(data : Bytes, limits : DecodeLimits) -> Result[Bytes, WoffError]
pub fn decode_using(data : Bytes, dec : dyn Decompressor, limits : DecodeLimits) -> Result[Bytes, WoffError]
```

## Verification

```sh
sh scripts/verify.sh packages/woff2
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`e0122b977fa6675a8948d027e30d3b62854ef0157960bcd9c52388541fec9354`):

```sh
pionc run packages/woff2/wasm_smoke
pionc run --release packages/woff2/wasm_smoke
pionc run --target wasm32 packages/woff2/wasm_smoke
pionc run --target wasm32 --release packages/woff2/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/woff2/bench/run_bench.sh` against pure-Rust **`wuff 0.2.10` (`--release`)** on real TrueType fonts (`Arial.ttf` 755 KB / 3,381 glyphs, `Monaco.ttf` 517 KB / 1,678 glyphs). All SFNT semantic summaries (all table hashes + all glyph headers) are verified byte-for-byte identical via SHA-256, and Pion's decoded SFNT whole-font checksum is verified exact (`0xB1B0AFBA`):

| Workload | `pion` Median (Throughput) | `rust_wuff` Median (Throughput) | `pion` Peak RSS | `rust_wuff` Peak RSS | `pion` vs `rust_wuff` |
| --- | ---: | ---: | ---: | ---: | ---: |
| WOFF2 Decode: `Arial.woff2` (755 KB SFNT × 10) | 125.529 ms (61.87 MB/s) | 36.565 ms (212.38 MB/s) | 7.86 MiB | 9.86 MiB | **0.29x** |
| WOFF2 Decode: `Monaco.woff2` (517 KB SFNT × 10) | 57.350 ms (92.31 MB/s) | 20.170 ms (262.47 MB/s) | 6.38 MiB | 4.77 MiB | **0.35x** |
| WOFF1 Decode: `Arial.woff` (755 KB SFNT × 10) | 43.770 ms (176.66 MB/s) | 29.522 ms (261.92 MB/s) | 6.55 MiB | 5.59 MiB | **0.67x** |
