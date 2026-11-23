# `brotli` (`v0.1.0`)

Pure Pion implementation of the **Brotli (RFC 7932)** decompressor with zero external dependencies, zero `extern "C"`, and no `World` requirement.

## Features

- Complete RFC 7932 decoding: empty streams, uncompressed meta-blocks, metadata meta-blocks, multi-meta-block streams, canonical simple & complex prefix codes, context modeling with RLE + MTF, distance ring buffer, and the full 122,784-byte static dictionary with all 121 transforms.
- High-performance pure Pion hot path: 64-bit bit buffer, 2-level canonical prefix-code LUT (8-bit primary + dynamic subtables), module-level cached static dictionary & context LUT, in-place dictionary transforms, and 8-byte unrolled RLE/LZ77 copies.
- Strict security & compliance checks: `DecodeLimits` (`max_output_bytes`, `max_window_bits`) enforced before allocation and writes to defeat decompression bombs; strict rejection of non-zero padding bits, trailing garbage bytes, duplicate simple prefix symbols, and non-canonical `MLEN`/`MSKIPLEN`.

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
| Web HTML/CSS/JS/JSON (2 MiB q6 × 10 = 20 MiB) | 37.003 ms (566.75 MB/s) | 19.867 ms (1055.59 MB/s) | 17.887 ms (1172.47 MB/s) | **0.54x** |
| WOFF2 Binary Font Payload (1 MiB q11 × 10 = 10 MiB) | 44.062 ms (237.98 MB/s) | 20.187 ms (519.42 MB/s) | 18.271 ms (573.91 MB/s) | **0.46x** |
| Small Packet Batch (512 pkts q5 × 10 = 5,120 pkts) | 63.249 ms (43.04 MB/s) | 75.967 ms (35.84 MB/s) | 38.175 ms (71.32 MB/s) | **1.20x** |
