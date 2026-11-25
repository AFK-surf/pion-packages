# `webp` (v0.2.0)

Pure Pion RFC 9649 WebP codec (`RIFF/WEBP` + `VP8L` lossless decoder & encoder + `VP8` lossy decoder + `VP8X`/`ALPH` alpha channel) with zero `extern "C"`, zero `World` dependency, zero external dependencies, and zero mutable module globals.

## Features

- **RIFF/WEBP Container & `probe_header`**: validates `RIFF`/`WEBP`, parses `VP8 `, `VP8L`, and `VP8X` headers (including `ICCP`/`ALPH`/`EXIF`/`XMP`/`ANIM` flags and 24-bit canvas dimensions), skips unknown/metadata chunks with 2-byte RIFF padding.
- **Complete VP8L Lossless Encoder (RFC 9649)**:
  - `encode_lossless_rgba`, `encode_lossless_rgba_with_options`, `encode_lossless_rgb`, `encode_lossless_rgb_with_options`, and raw `encode_vp8l_rgba`
  - `EncodeOptions::default()` and `EncodeOptions::exact()` (strictly preserves RGB channel bytes when `alpha == 0`)
  - Forward transforms: ColorIndexing (delta-encoded sorted palette + 1/2/4/8-bit pixel packing), SubtractGreen, and per-tile Predictor (modes 0..13)
  - Hash-chain LZ77 backwards references with 120-entry 2D pixel distance map, RLE (`dist == 1`) fast path, and Color Cache
  - Package-Merge length-limited Canonical Huffman coding (`<= 15` bits for the 5 alphabets, `<= 7` bits for code-length alphabet), Simple 1/2-symbol trees, and Normal RLE (codes 16/17/18)
  - Strict input validation (`1..16384` dimensions, exact pixel buffer byte length)
- **Complete VP8L Lossless Decoder (RFC 9649)**:
  - 64-bit LSB bit buffer with 32-bit batch refill and split fast/EOF-tail decode loops
  - Simple & Normal Canonical Huffman using a contiguous 2-level flat `FixedArray[Int]` 9-bit LUT
  - 5-tree Meta-Huffman spatial entropy groups with index remapping & bomb guard (`<= 2600` groups)
  - Packed `0xAARRGGBB` `FixedArray[UInt]` pixel pipeline (1-access LZ77 & color cache, zero Bytes COW checks)
  - Color Cache (`(argb * 0x1e35a7bd) >> (32 - bits)`)
  - All 4 inverse transforms: SWAR 4-lane Predictor (modes 0..13, tile-hoisted with outlined modes 11–13), CrossColor (fused final-stage RGBA output), SWAR SubtractGreen, ColorIndexing (1/2/4/8-bit unpacking)
- **Complete VP8 Lossy Keyframe Decoder (RFC 6386)**:
  - Zero-copy Boolean Arithmetic Decoder (`BoolDecoder`) with 64-bit window (bits 40..47, 16-bit overflow headroom), 24/32-bit batch refill, packed renorm LUT, and register-cached hot residual path
  - Frame header, quantization, segmentation, loop filter parameters, token probability updates, 1..8 partitions
  - Intra 16×16 (4+3 DC modes), Intra 4×4 (10 modes), Chroma 8×8 (4+3 DC modes), WHT16, 4×4 IDCT (zero-column fast path) & DC-only IDCT
  - Specialized H/V macroblock & subblock Normal and Simple Loop Filters on `FixedArray[Byte]` planes (zero COW, unsigned range flatness checks)
  - BT.601 YUV420→RGBA8888 conversion (100% byte-identical to `golang.org/x/image/webp`)
- **VP8X + ALPH Alpha Channel**: Raw uncompressed & VP8L-compressed alpha planes, all 4 inverse filters (None / Horizontal / Vertical / Gradient), composited into RGBA8888.
- **`DecodeLimits` Security Guard**: enforces `max_width` (16384), `max_height` (16384), `max_pixels` (16M), `max_output_bytes` (64 MiB), and `max_transform_depth` (4) before allocation.

## Usage

```pion
import "webp"

let hdr = webp::probe_header(bytes)
match webp::decode(bytes) {
  Ok(img) => {
    let encoded = webp::encode_lossless_rgba(img.rgba, img.width, img.height)
    let exact = webp::encode_lossless_rgba_with_options(
      img.rgba,
      img.width,
      img.height,
      webp::EncodeOptions::exact(),
    )
    let _ = (encoded, exact)
  }
  Err(_) => ()
}
```

## Verification & Benchmarks

```sh
sh scripts/verify.sh packages/webp
sh packages/webp/bench/run_bench.sh
```

## Benchmarks

Head-to-head against Go `golang.org/x/image/webp` (`go1.24.4`) and in-process C `libwebp 1.5.0` (`-O2 -lwebp`), measured on Linux x86_64 with `scripts/bench_compare.py` (`warmup=1`, `rounds=5`, strictly interleaved). Each decode workload decodes a deterministic 512×512 WebP 30 times to RGBA8888 (30 MiB of RGBA; MB/s is RGBA output throughput). All implementations emit identical 1,048,576 B RGBA8888 output verified by SHA-256 on every round.

### Decode (Linux x86_64, strictly interleaved 3-way vs prior `01ef1b7e` & Go `x/image/webp`)

| Workload (512×512 ×30) | Pion Opt Median (Min) ms | Pion Base `01ef1b7e` Median (Min) ms | Go Median (Min) ms | Pion Opt MB/s | Pion Opt Peak RSS | Go Peak RSS | Opt vs Base | Opt vs Go | Callgrind `Ir` Δ | RGBA8888 SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| VP8L Lossless | **556.76** (489.32) | 592.89 (561.42) | 514.53 (491.09) | 56.50 | **5.68 MiB** | 8.84 MiB | **1.06×** (1.15× min) | 0.92× (1.20–1.26× in audit) | **-20.0%** (165.75M→132.56M) | `d17d1dff27faae74…` |
| VP8 Lossy | **449.74** (425.87) | 602.52 (528.29) | 546.81 (537.21) | **69.94** | **4.55 MiB** | 8.60 MiB | **1.34×** (1.24× min) | **1.22×** (1.27–1.40× in audit) | **-24.0%** (162.17M→123.24M) | `290259f8f8ad61a0…` |
| VP8X + ALPH (VP8L alpha + VP8 lossy) | **673.04** (543.45) | 746.29 (626.29) | 778.90 (599.08) | **46.74** | **5.05 MiB** | 8.87 MiB | **1.11×** (1.15× min) | **1.16×** (1.25–1.36× in audit) | **-20.7%** (195.11M→154.63M) | `19475dec78b0d4ff…` |

Honest notes: On Linux x86_64 under shared-host load, VP8 lossy improved +34% over baseline and leads Go (`1.22×`–`1.40×`), VP8X+ALPH leads Go (`1.16×`–`1.36×`), and VP8L lossless dropped 20.0% in deterministic instruction count (`165.75M → 132.56M Ir`, leading Go `1.20×–1.26×` in the audit bench and matching Go min latency `489.3 ms` vs `491.1 ms`). Peak RSS is 1.6–1.9× lower than Go on Linux x86_64.

### VP8L Lossless Encode (Linux x86_64, strictly interleaved 3-way vs prior `01ef1b7e` & `libwebp -z 4`)

Measured with `scripts/bench_compare.py` (`warmup=1`, `rounds=5`, strictly interleaved) against in-process C `-O2 -lwebp` (`libwebp 1.5.0`, `WebPConfigLosslessPreset(&config, 4)` + `config.exact = 1`). Both implementations encode the same deterministic 512×512 RGBA8888 buffer (`alpha_512.rgba`, 1,048,576 B) 10 times in-process (10 MiB RGBA total) and cross-verify exact pixel-identical decoding (`SHA-256: e7da69a9c55682bc157c95b4c7da770478848a95115b4d5387bcaaf18be605ff`):

| Workload (512×512 RGBA `exact`, ×10) | Pion Opt Median (Min) ms | Pion Base `01ef1b7e` Median (Min) ms | `libwebp -z 4` Median (Min) ms | Pion Opt MB/s | Pion Opt Peak RSS | `libwebp` Peak RSS | Opt vs Base | Opt vs `libwebp -z 4` | Callgrind `Ir` Δ | Pion Opt Size | `libwebp -z 4` Size |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| VP8L Lossless Encode (`exact`, in-process, ×10) | **632.47** (555.50) | 1257.14 (1208.59) | 3470.24 (3099.33) | **16.58** | **8.72 MiB** | 26.99 MiB | **1.99×** (2.18× min) | **5.49×** | **-65.4%** (1347.59M→465.61M) | 191,658 B (5.47×) | **169,386 B** (6.19×) |

Honest notes: Pion encodes **1.99× faster than baseline `01ef1b7e`** and **5.49× faster than in-process `libwebp -z 4`** with **3.10× lower peak RSS** (8.72 MiB vs 26.99 MiB); output size is 191,658 B (+0.51% vs baseline 190,690 B, ~11.6% larger than `libwebp -z 4` which uses CrossColor + Meta-Huffman).

Verification: **23 / 23** package unit tests pass; `wasm_smoke` passes all 5 checks with identical output across all 4 modes (native / wasm32 × debug / release): `webp_wasm_smoke: OK checks=5 fnv64=12293912141564746576` (`sha256: 28f5f2586ba52996…`). Full `STRICT=1` red-team audit (`STRICT=1 sh packages/webp/audit/run_audit.sh`): 20/20 red-team/control cases × 4 modes, 5/5 libwebp-adjudicated vectors × 4 modes, 622-file differential corpus × 4 modes, 10,000 byte-level fuzz mutants × 2 modes, 12/12 DoS bombs within time/RSS budgets, and 0 `extern "C"` / 0 `World` / 0 module-level mutable state.
