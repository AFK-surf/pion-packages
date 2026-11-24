# `bzip2` (`v0.1.0`)

Pure Pion implementation of the **bzip2 (`BZh1`–`BZh9`)** compressor and decompressor with zero external dependencies, zero `extern "C"`, and no `World` requirement.

## Features

- Complete bzip2 stream encoding and decoding (`BZh1`..`BZh9`, 100 KiB–900 KiB block sizes): RLE1, Burrows-Wheeler Transform (main sort with fallback sort cutoff), Move-To-Front + ZEROA/ZEROB RLE2, multi-table canonical Huffman coding (2–6 tables, 50-symbol groups), and per-block / combined stream CRC-32.
- Byte-exact encoder parity with Rust `bzip2` `0.6.1` (`libbz2-rs-sys` `0.2.3` golden suite; verified byte-identical against `bzip2` `0.6.1` / `libbz2-rs-sys` `0.2.7` at work factor 30).
- Strict stream validation & decompression-bomb protection: `decompress_limited(input, max_out)` enforces an explicit output byte budget before buffer growth, rejects negative limits, and fails cleanly on bad headers, truncated streams, invalid Huffman tables, CRC mismatches, and malformed trailing runs.
- Licensed under `MIT AND bzip2-1.0.6` — see root [`LICENSE`](../../LICENSE) and [`packages/bzip2/NOTICE`](NOTICE).

### `decompress_limited` Semantics

- `max_out < 0`: rejected immediately with `Err(...)`.
- `max_out == 0`: allows only zero-byte output (empty streams return `Ok(empty)`; any non-empty output returns `Err(...)`).
- `decompress(input)` calls `decompress_limited(input, 2_147_483_647)` (`Int` max); buffer growth saturates safely above 1 GiB without signed overflow.
- Trailing bytes after the bzip2 end-of-stream marker are ignored (matching single-stream `libbz2` semantics).

## Public API

```pion
///| Decompress the first bzip2 stream in `input`.
///| Fails on malformed, truncated or CRC-mismatched data; bytes after the stream end are ignored.
pub fn decompress(input : Bytes) -> Result[Bytes, String]

///| Decompress like `decompress`, failing once the output would exceed `max_out` bytes.
///| Fails when `max_out` is negative.
pub fn decompress_limited(input : Bytes, max_out : Int) -> Result[Bytes, String]

///| Compress `input` into a bzip2 stream at block level `1..=9`.
pub fn compress(input : Bytes, level : Int) -> Result[Bytes, String]
```

## Verification

```sh
sh scripts/verify.sh packages/bzip2
```

All 12 unit, golden, and limit tests pass (`12 / 12`).

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`3e8ba80c873e78ff09aa9f9cdc8c6dde0b9aeb3ecc48890e141b6594a6594de4`):

```sh
pionc run packages/bzip2/wasm_smoke
pionc run --release packages/bzip2/wasm_smoke
pionc run --target wasm32 packages/bzip2/wasm_smoke
pionc run --target wasm32 --release packages/bzip2/wasm_smoke
```

## Head-to-Head Benchmarks (`Linux x86_64`, `warmup=1`, `rounds=5`)

Run via `sh packages/bzip2/bench/run_bench.sh` on Intel Xeon Platinum 8581C (`Linux x86_64`, `pionc 0.1.0 --release` vs Rust `bzip2 0.6.1` / `libbz2-rs-sys 0.2.7 --release`). Compressed (`786,432 B -> 34,946 B`, `sha256:d4cb2a2a092f2c02...`) and decompressed (`34,946 B -> 786,432 B`, `sha256:ea091dc1e46ec9ab...`) outputs are verified **byte-for-byte identical** across both implementations:

| Workload | `pion_bzip2` Median (Min / P95, Throughput, Peak RSS) | `rust_bzip2` Median (Min / P95, Throughput, Peak RSS) | `pion_bzip2` vs `rust_bzip2` |
| --- | ---: | ---: | ---: |
| Compress L6: Structured JSON Logs (768 KiB × 3 = 2.25 MiB) | 656.495 ms (518.935 / 1252.113 ms, 3.59 MB/s, 15.34 MiB) | 269.012 ms (259.422 / 386.063 ms, 8.77 MB/s, 7.77 MiB) | **0.41x** |
| Decompress L6: Structured JSON Logs (768 KiB × 10 = 7.50 MiB) | 267.268 ms (220.058 / 348.702 ms, 29.42 MB/s, 8.79 MiB) | 182.432 ms (150.926 / 224.205 ms, 43.11 MB/s, 6.46 MiB) | **0.68x** |
