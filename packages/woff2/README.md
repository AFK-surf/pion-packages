# `woff2` (`v0.1.0`)

Pure Pion implementation of the **W3C WOFF 2.0 (`wOF2`)** and **WOFF 1.0 (`wOFF`)** font container decoders to TrueType/OpenType (SFNT), with zero `extern "C"` and no `World` requirement. Directly reuses `packages/brotli` and `packages/flate`.

## Features

- **Automatic Format Detection**: `decode(data)` auto-detects `wOF2` (WOFF 2.0 via `brotli::decode_with_limits`) and `wOFF` (WOFF 1.0 via `flate::zlib_decompress_with_limit`).
- **Complete WOFF 2.0 Support**: all 63 known table tags + custom 4-byte tags (`0x3F`), strict `UIntBase128` validation (rejecting leading zeros, >5 bytes, and `uint32` overflow), `255UInt16`, `glyf` + `loca` transformation reconstruction (empty/simple/composite glyphs, 128-entry triplet lookup tables, `Int32` coordinate overflow checks, OpenType `REPEAT_FLAG` RLE byte-identical to `google/woff2`/`wuff`, overlap bit, explicit/computed bounding boxes, short & long `loca`, `head.indexToLocFormat`), and `hmtx` transformation reconstruction.
- **Complete WOFF 1.0 Support**: per-table RFC 1950 zlib decompression (with FCHECK + Adler-32 validation), uncompressed table passthrough, and O(n log n) duplicate-tag and non-overlapping table-span validation.
- **Strict Container & Consistency Validation**:
  - Exact container `length == data.length()` check for both WOFF 2.0 and WOFF 1.0;
  - WOFF 2.0 ignores header `reserved` per `conform-mustNotUseReservedValue` (WOFF 1.0 rejects `reserved != 0`);
  - WOFF 2.0 rejects extra decompressed Brotli bytes beyond the table directory sum (`conform-mustRejectExtraData`);
  - WOFF 2.0 requires `glyf` and `loca` to appear together with matching transform flags, exact transformed `loca` `origLength`, transformed `hmtx` to pair with transformed `glyf`, and `maxp.numGlyphs == glyf.numGlyphs` (rejecting mismatches in both directions).
- **Exact SFNT Assembly**: O(n log n) table sort by big-endian unsigned tag, 4-byte alignment, fused single-pass copy + big-endian `u32` per-table checksums, and exact `head.checkSumAdjustment` (`0xB1B0AFBA`).
- **Font-Bomb Defense (`DecodeLimits`)**: enforces `max_output_bytes` (default 64 MiB), `max_tables` (default 256), and `max_glyphs` (default 65,536) before allocations and during decompression/reconstruction.
  - **`<= 0` Semantics**: for all three limit fields (`max_output_bytes`, `max_tables`, `max_glyphs`), values `<= 0` mean unlimited (internally clamped to the runtime container maximum `2,147,483,631` bytes) consistently across both WOFF 2.0 and WOFF 1.0.
  - **Advisory `totalSfntSize`**: WOFF 2.0 `totalSfntSize` is treated as advisory; `max_output_bytes` is enforced on actual decompressed stream and reconstructed/assembled SFNT sizes, and `glyf` output buffers are sized from input evidence rather than untrusted `origLength` hints.
- **Pluggable Decompressor**: `decode_using(data, dec, limits)` accepts any custom `dyn Decompressor`.
- **Known Limitation**: WOFF 2.0 font collections (`ttcf` flavor) are not currently supported and return `Err(WoffError::UnsupportedCollection)`.

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

Run via `sh packages/woff2/bench/run_bench.sh` against pure-Rust **`wuff 0.2.10` (`--release`)** on real TrueType fonts (`Arial.ttf` 755 KB / 3,381 glyphs, `Monaco.ttf` 517 KB / 1,678 glyphs). Every decoded SFNT table payload — including full reconstructed **`glyf`** and **`loca`** tables — is verified **100% byte-for-byte identical** via full-SFNT SHA-256, and Pion's decoded SFNT whole-font checksum is verified exact (`0xB1B0AFBA`):

| Workload | `pion` Median (Throughput) | `rust_wuff` Median (Throughput) | `pion` Peak RSS | `rust_wuff` Peak RSS | `pion` vs `rust_wuff` |
| --- | ---: | ---: | ---: | ---: | ---: |
| WOFF2 Decode: `Arial.woff2` (755 KB SFNT × 10) | 66.423 ms (116.91 MB/s) | 36.295 ms (213.95 MB/s) | 7.84 MiB | 9.80 MiB | **0.55x** |
| WOFF2 Decode: `Monaco.woff2` (517 KB SFNT × 10) | 33.235 ms (159.21 MB/s) | 19.566 ms (270.45 MB/s) | 5.20 MiB | 4.75 MiB | **0.59x** |
| WOFF1 Decode: `Arial.woff` (755 KB SFNT × 10) | 43.867 ms (176.27 MB/s) | 29.495 ms (262.15 MB/s) | 6.59 MiB | 5.66 MiB | **0.67x** |
