# `lepton` (v0.1.0)

Pure-Pion lossless JPEG recompression codec for 8-bit sequential (`SOF0` / `SOF1`) and progressive (`SOF2`) JPEG streams. Zero `extern "C"`, zero `World` dependency, Wasm32-compatible, with only `flate` as an in-repo dependency.

## Overview

`lepton` decodes JPEG entropy-coded scans into quantized 8×8 DCT coefficient blocks, recompresses those coefficients with context-modeled 32-bit binary arithmetic range coding, compacts standard Annex K Huffman tables (`DHT`), and compresses preserved non-ECS header/metadata chunks with raw DEFLATE (`flate`). Decoding reconstructs the exact original JPEG byte stream bit-for-bit, including non-ECS markers, restart intervals (`DRI` / `RST0..7`), extra `0xFF` fill bytes, pad-bit conventions, trailing ZRLs, progressive `EOBRUN` splits, and trailing bytes after `EOI`.

## Public API

```pion
import "lepton"

pub fn encode(jpeg : Bytes) -> Result[Bytes, String]
pub fn decode(data : Bytes) -> Result[Bytes, String]
```

- `encode(jpeg)`: parses an 8-bit sequential (`SOF0` / `SOF1`) or progressive (`SOF2`) JPEG stream, verifies canonical byte-exact reversibility, and returns a compact `LP` v1 payload. Returns `Err(String)` on unsupported JPEG features, malformed input, or limit violations.
- `decode(data)`: validates the `LP` v1 header, inflates and expands preserved metadata, range-decodes all DCT coefficient blocks, and restores the exact original JPEG bytes.

## Format & Security Limits

- **Scope**: 8-bit sample precision baseline sequential (`SOF0`), extended sequential (`SOF1`), and progressive (`SOF2`) JPEGs with Huffman coding (1–4 components, 4:4:4 / 4:2:2 / 4:2:0 / grayscale / CMYK, optional `DRI` restart intervals). Arithmetic-coded, lossless (`SOF3`), and 12-bit JPEGs are rejected cleanly with `Err`.
- **Wire format**: 2-byte `LP` magic (`0x4C 0x50`) followed by 1 version/flags byte (low 6 bits = version `1`, bit 7 = DEFLATE-compressed metadata, bit 6 = Annex K standard `DHT` compaction), varint metadata length, metadata blob, and context-modeled 32-bit range-coded DCT payload. Note: this `LP` v1 format is this package's own self-contained wire format and is not wire-compatible with Dropbox Lepton (`0xCF 0x84`).
- **License**: MIT (matching `AFK-surf/pion-packages`).
- **Hard security limits** (enforced symmetrically in `encode` and `decode`):
  - `max_total_blocks = 1,048,576` (8×8 DCT blocks)
  - `max_jpeg_scans = 1,024`
  - `max_output_bytes = 67,108,864` (64 MiB)
  - `max_meta_bytes = 16,777,216` (16 MiB)
  - `max_scan_meta_items = 1,048,576` per scan metadata array

## Verification

```sh
sh scripts/verify.sh packages/lepton
sh packages/lepton/bench/run_bench.sh
```

- **Unit tests**: 14 / 14 `lepton` tests pass (35 / 35 including `flate` dependency tests), covering minimal and photographic sequential/progressive JPEGs, CMYK/4:2:0/4:2:2/4:4:4/grayscale sampling, `DRI` restart intervals, `Al=5` progressive scans, `jpegtran -progressive -optimize`, trailing ZRLs, zero pad bits, extra `0xFF` fill bytes, trailing bytes after `EOI`, adversarial varint/bomb rejection, and deterministic mutation fuzzing.
- **4-mode `wasm_smoke`** (Native debug, Native `--release`, Wasm32 debug, Wasm32 `--release`): all 4 modes exit `0` with identical stdout and SHA-256:
  - Output: `lepton_wasm_smoke: OK checks=4 base=151 prog=1201 fnv64=979157046982172007`
  - Stdout SHA-256: `311e4623416b52a481bfadd5dcf1d1e37a4dd03df06ac336fc2fde7e0bbe60c0`

## Benchmarks

Head-to-head against Rust [`lepton_jpeg`](https://crates.io/crates/lepton_jpeg) `0.5.8` (`--release`, `DEFAULT_THREAD_POOL`), measured on Linux `x86_64` (`pionc 0.1.0`, `rustc 1.96.0`) via `sh packages/lepton/bench/run_bench.sh` (`scripts/bench_compare.py`, `--warmup 1 --rounds 5`, strictly interleaved). Every run writes the restored JPEG bytes to stdout and is verified byte-for-byte identical to the original JPEG via SHA-256.

| Workload | Pion Median (ms) | Pion Min / P95 (ms) | Rust Median (ms) | Pion MB/s | Rust MB/s | Pion Peak RSS | Rust Peak RSS | Speedup (vs Rust) | Pion Size | Rust Size |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline 512×512 RGB (`SOF0`, 50,288 B) Roundtrip ×10 | 446.070 | 294.785 / 664.138 | **212.924** | 1.13 | **2.36** | **4.89 MiB** | 8.71 MiB | 0.48x | 37,509 B (−25.41%) | **36,349 B (−27.72%)** |
| Progressive 512×512 Luma (`SOF2`, 44,142 B) Roundtrip ×10 | 385.331 | 331.269 / 859.268 | **262.010** | 1.15 | **1.68** | **4.58 MiB** | 8.26 MiB | 0.68x | 33,267 B (−24.64%) | **32,551 B (−26.26%)** |
| Baseline 512×512 RGB (`SOF0`, 50,288 B) Decode ×10 | 216.703 | 176.899 / 329.129 | **155.921** | 2.32 | **3.23** | **4.30 MiB** | 8.13 MiB | 0.72x | — | — |

Stdout SHA-256 verified identical across all rounds:
- Baseline 512×512 RGB (`50,288 B`): `7e9035d180b1c0be324c85c16b4048a7500c10b2c65d71e11ac903945216689d`
- Progressive 512×512 Luma (`44,142 B`): `ae6a32d2b290b90721081c6723ac8e17660aaaf467d279735d59fe5e2b11839d`

Honest notes:
- Single-threaded pure-Pion `lepton` trails multi-threaded Rust `lepton_jpeg` (`DEFAULT_THREAD_POOL`) on throughput (`0.48x`–`0.72x`), and achieves within 1.6–2.3 percentage points of Rust's compression ratio (`−25.41%` vs `−27.72%` on baseline RGB; `−24.64%` vs `−26.26%` on progressive luma).
- Because `rust_lepton_jpeg` uses `DEFAULT_THREAD_POOL`, both its Peak RSS and multi-core speedup vary with thread count and host load (Pion Peak RSS is ~1.3–1.9× lower depending on Rust thread pool startup, measured here at `4.30–4.89 MiB` vs `8.13–8.71 MiB`; timings were captured on a shared Linux VM).
