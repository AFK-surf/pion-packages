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
