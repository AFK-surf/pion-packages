# `brotli` (`v0.1.0`)

Pure Pion implementation of the **Brotli (RFC 7932)** decompressor with zero external dependencies, zero `extern "C"`, and no `World` requirement.

## Features

- Complete RFC 7932 decoding: empty streams, uncompressed meta-blocks, metadata meta-blocks, multi-meta-block streams, canonical simple & complex prefix codes, context modeling with RLE + MTF, distance ring buffer, and the full 122,784-byte static dictionary with all 121 transforms.
- High-performance pure Pion hot path: 64-bit bit buffer, 2-level canonical prefix-code LUT (8-bit primary + dynamic subtables), module-level cached static dictionary & context LUT, in-place dictionary transforms, and 8-byte unrolled RLE/LZ77 copies.
- Strict security & compliance checks: `DecodeLimits` (`max_output_bytes`, `max_window_bits`) enforced before allocation and writes to defeat decompression bombs; strict rejection of non-zero padding bits, trailing garbage bytes, duplicate simple prefix symbols, `insert`/`copy`/dictionary overruns, and non-canonical `MLEN`/`MSKIPLEN`.

### `DecodeLimits` Semantics & Platform Notes

- `max_output_bytes < 0`: rejected immediately with `Err(BrotliError::OutputLimitExceeded(limit))`.
- `max_output_bytes == 0`: allows only zero-byte output (empty streams return `Ok(empty)`; any non-empty output returns `Err(BrotliError::OutputLimitExceeded(0))`).
- `max_output_bytes > 2_147_483_631` (`2^31 - 17`, Pion container max): safely clamped to `2_147_483_631` so `Int` max cannot trigger a container-length abort.
- **Wasm32**: because WebAssembly32 linear memory is bounded at 4 GiB and buffer growth temporarily holds old + new buffers, Wasm32 callers should keep `max_output_bytes <= 536870912` (512 MiB; default is 256 MiB).
- `max_window_bits`: must be in `10..=24` (`InvalidWindowBits` otherwise); streams declaring a larger `WBITS` return `WindowLimitExceeded`.

## Public API

```pion
pub val struct DecodeLimits {
  pub max_output_bytes : Int
  pub max_window_bits : Int
}

pub enum BrotliError {
  UnexpectedEof(String)
  InvalidWindowBits(Int)
  WindowLimitExceeded(Int)
  InvalidMetaBlock(String)
  InvalidPrefixCode(String)
  InvalidContextMap(String)
  InvalidDistance(String)
  InvalidDictionaryRef(String)
  InvalidTrailingBits(String)
  TrailingData(Int)
  OutputLimitExceeded(Int)
}

pub fn decode(data : Bytes) -> Result[Bytes, BrotliError]
pub fn decode_with_limits(data : Bytes, limits : DecodeLimits) -> Result[Bytes, BrotliError]
```

## Verification

```sh
sh scripts/verify.sh packages/brotli
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`027a31d9b0e0094c6dc068938bfd187f8561d338945e1b828ecd6cb3cd71e23e`):

```sh
pionc run packages/brotli/wasm_smoke
pionc run --release packages/brotli/wasm_smoke
pionc run --target wasm32 packages/brotli/wasm_smoke
pionc run --target wasm32 --release packages/brotli/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/brotli/bench/run_bench.sh` (all outputs verified byte-for-byte identical via SHA-256 across `pion --release`, Rust `brotli 7.0.0 --release`, and C `libbrotlidec 1.2.1 -O3`):

| Workload | `pion` Median (Throughput) | `rust_brotli` Median (Throughput) | `c_brotlidec` Median (Throughput) | `pion` vs `rust_brotli` |
| --- | ---: | ---: | ---: | ---: |
| Web HTML/CSS/JS/JSON (2 MiB q6 × 10 = 20 MiB) | 34.820 ms (602.28 MB/s) | 25.524 ms (821.63 MB/s) | 24.281 ms (863.71 MB/s) | **0.73x** |
| WOFF2 Binary Font Payload (1 MiB q11 × 10 = 10 MiB) | 33.678 ms (311.35 MB/s) | 24.419 ms (429.41 MB/s) | 25.004 ms (419.36 MB/s) | **0.73x** |
| Small Packet Batch (512 pkts q5 × 10 = 5,120 pkts) | 43.355 ms (62.80 MB/s) | 69.620 ms (39.11 MB/s) | 35.054 ms (77.67 MB/s) | **1.61x** |
