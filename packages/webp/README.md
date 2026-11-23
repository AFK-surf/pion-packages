# `webp` (v0.1.0)

Pure Pion RFC 9649 WebP decoder (`RIFF/WEBP` + `VP8L` lossless + `VP8` lossy + `VP8X`/`ALPH` alpha channel) with zero `extern "C"`, zero `World` dependency, zero external dependencies, and zero mutable module globals.

## Features

- **RIFF/WEBP Container & `probe_header`**: validates `RIFF`/`WEBP`, parses `VP8 `, `VP8L`, and `VP8X` headers (including `ICCP`/`ALPH`/`EXIF`/`XMP`/`ANIM` flags and 24-bit canvas dimensions), skips unknown/metadata chunks with 2-byte RIFF padding.
- **Complete VP8L Lossless Decoder (RFC 9649)**:
  - 64-bit LSB bit buffer with 32-bit batch refill
  - Simple & Normal Canonical Huffman using a contiguous 2-level flat `FixedArray[Int]` 9-bit LUT
  - 5-tree Meta-Huffman spatial entropy groups with index remapping & bomb guard (`<= 2600` groups)
  - LZ77 backwards references with 120-entry 2D pixel distance map and RLE (`dist == 1`) fast path
  - Color Cache (`(argb * 0x1e35a7bd) >> (32 - bits)`)
  - All 4 inverse transforms: Predictor (modes 0..13, tile-hoisted), CrossColor (tile-hoisted), SubtractGreen, ColorIndexing (1/2/4/8-bit unpacking)
- **Complete VP8 Lossy Keyframe Decoder (RFC 6386)**:
  - Zero-copy Boolean Arithmetic Decoder (`BoolDecoder`) with 16-bit batch refill and register-cached hot residual path
  - Frame header, quantization, segmentation, loop filter parameters, token probability updates, 1..8 partitions
  - Intra 16×16 (4+3 DC modes), Intra 4×4 (10 modes), Chroma 8×8 (4+3 DC modes), WHT16, 4×4 IDCT & DC-only IDCT
  - Normal and Simple Loop Filters
  - BT.601 YUV420→RGBA8888 conversion (100% byte-identical to `golang.org/x/image/webp`)
- **VP8X + ALPH Alpha Channel**: Raw uncompressed & VP8L-compressed alpha planes, all 4 inverse filters (None / Horizontal / Vertical / Gradient), composited into RGBA8888.
- **`DecodeLimits` Security Guard**: enforces `max_width` (16384), `max_height` (16384), `max_pixels` (16M), `max_output_bytes` (64 MiB), and `max_transform_depth` (4) before allocation.

## Usage

```pion
import "webp"

let hdr = webp::probe_header(bytes)
let img = webp::decode(bytes)
let img_limited = webp::decode_with_limits(bytes, webp::DecodeLimits::default())
```

## Verification & Benchmarks

```sh
sh scripts/verify.sh packages/webp
sh packages/webp/bench/run_bench.sh
```

## Benchmarks

Head-to-head against Go `golang.org/x/image/webp` `v0.48.0` (go1.27.3), measured at the Wave 20 release on Darwin arm64 with `sh packages/webp/bench/run_bench.sh` (`scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved). Each workload decodes a deterministic 512×512 WebP 30 times to RGBA8888 (30 MiB of RGBA; MB/s is RGBA output throughput). Both sides print the same 1,048,576 B of RGBA and the stdout SHA-256 matched in every round.

| Workload | Pion Median (ms) | Pion Min / Max (ms) | Go Median (ms) | Pion MB/s | Go MB/s | Pion Peak RSS | Go Peak RSS | Pion vs Go | RGBA8888 SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| VP8L Lossless | **130.652** | 128.435 / 132.096 | 154.463 | 240.77 | 203.66 | **4.47 MiB** | 11.95 MiB | **1.18x** | `d17d1dff27faae74…` |
| VP8 Lossy | 147.946 | 138.070 / 168.802 | **143.284** | 212.63 | 219.54 | **4.39 MiB** | 12.89 MiB | 0.97x | `290259f8f8ad61a0…` |
| VP8X + ALPH (VP8L alpha + VP8 lossy) | **179.968** | 175.499 / 185.194 | 192.009 | 174.79 | 163.83 | **4.80 MiB** | 11.97 MiB | **1.07x** | `19475dec78b0d4ff…` |

Honest notes: VP8L lossless and VP8X+ALPH lead Go; VP8 lossy is roughly at parity and trailed Go slightly in this run (0.97x; the audit's own bench section measured 1.00x on the same machine minutes earlier, with load around 6). Peak RSS is 2.5–2.9× lower than Go on all three.

Red-team audit (`sh packages/webp/audit/run_audit.sh`, `audit/` untouched): **exit 0, `AUDIT PASS`**. 1 P0 + 5 P2 findings fixed. 20 / 20 red-team and control cases pass in all 4 modes (native / wasm32 × debug / release), 11 / 11 package unit tests, 5 / 5 libwebp-adjudicated vectors, 622-file differential corpus identical to x/image/webp in all 4 modes (601 identical, 21 rejected by both), 10,000 byte-level mutants with 0 crashes and native == wasm32 on all of them, 12 / 12 DoS bombs within time and RSS budgets, and 0 `extern "C"` / 0 `World` / 0 module-level mutable state. `wasm_smoke` prints the same 55 B in all 4 modes (SHA-256 `8a00bb493b1061cbc6ec503a8fe400de88fbf6fb5fc39956ca9f54e41bd65eec`).
