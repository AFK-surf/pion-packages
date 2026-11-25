# `brotli` (`v0.1.0`)

Pure Pion implementation of the **Brotli (RFC 7932)** decompressor with zero external dependencies, zero `extern "C"`, and no `World` requirement.

## Features

- Complete RFC 7932 decoding: empty streams, uncompressed meta-blocks, metadata meta-blocks, multi-meta-block streams, canonical simple & complex prefix codes, context modeling with RLE + MTF, distance ring buffer, and the full 122,784-byte static dictionary with all 121 transforms.
- High-performance pure Pion hot path: 64-bit bit buffer with spill-free sequential 4-byte refill, flattened 2-level canonical prefix-code LUTs with branchless single-symbol encoding (zero inner-loop RC), precomputed 704-entry command insert/copy LUTs, split single-tree/multi-tree `Int`-returning hot loops, fresh single-meta-block `Bytes` allocation (zero immutability checks / zero final copy), reusable `CodeScratch` for small packets, module-level cached static dictionary & `FixedArray[Int]` context LUT, in-place dictionary transforms, and 8-byte/16-byte unrolled RLE/LZ77 copies.
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

## Head-to-Head Benchmarks (`Linux x86_64`, `warmup=1`, `rounds=5`)

Run via `sh packages/brotli/bench/run_bench.sh` (all outputs verified byte-for-byte identical via SHA-256 across `pion --release`, Rust `brotli 7.0.0 --release`, and C `libbrotlidec 1.1.0 -O3`):

| Workload | `pion` Median (Throughput) | `rust_brotli` Median (Throughput) | `c_brotlidec` Median (Throughput) | `pion` vs `rust_brotli` |
| --- | ---: | ---: | ---: | ---: |
| Web HTML/CSS/JS/JSON (2 MiB q6 × 10 = 20 MiB) | 43.789 ms (478.92 MB/s) | 37.679 ms (556.58 MB/s) | 27.192 ms (771.25 MB/s) | **0.86x** |
| WOFF2 Binary Font Payload (1 MiB q11 × 10 = 10 MiB) | 45.033 ms (232.85 MB/s) | 27.724 ms (378.22 MB/s) | 20.157 ms (520.21 MB/s) | **0.62x** |
| Small Packet Batch (512 pkts q5 × 10 = 5,120 pkts) | 53.128 ms (51.24 MB/s) | 60.263 ms (45.18 MB/s) | 22.670 ms (120.09 MB/s) | **1.13x** |
