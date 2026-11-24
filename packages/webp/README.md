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

Head-to-head against Go `golang.org/x/image/webp` `v0.48.0` (go1.27.3), measured at the Wave 20 release on Darwin arm64 with `sh packages/webp/bench/run_bench.sh` (`scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved). Each workload decodes a deterministic 512×512 WebP 30 times to RGBA8888 (30 MiB of RGBA; MB/s is RGBA output throughput). Both sides print the same 1,048,576 B of RGBA and the stdout SHA-256 matched in every round.

| Workload | Pion Median (ms) | Pion Min / Max (ms) | Go Median (ms) | Pion MB/s | Go MB/s | Pion Peak RSS | Go Peak RSS | Pion vs Go | RGBA8888 SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| VP8L Lossless | **130.652** | 128.435 / 132.096 | 154.463 | 240.77 | 203.66 | **4.47 MiB** | 11.95 MiB | **1.18x** | `d17d1dff27faae74…` |
| VP8 Lossy | 147.946 | 138.070 / 168.802 | **143.284** | 212.63 | 219.54 | **4.39 MiB** | 12.89 MiB | 0.97x | `290259f8f8ad61a0…` |
| VP8X + ALPH (VP8L alpha + VP8 lossy) | **179.968** | 175.499 / 185.194 | 192.009 | 174.79 | 163.83 | **4.80 MiB** | 11.97 MiB | **1.07x** | `19475dec78b0d4ff…` |

Honest notes: VP8L lossless and VP8X+ALPH lead Go; VP8 lossy is roughly at parity and trailed Go slightly in this run (0.97x; the audit's own bench section measured 1.00x on the same machine minutes earlier, with load around 6). Peak RSS is 2.5–2.9× lower than Go on all three.

### VP8L Lossless Encode (v0.2.0, Linux x86_64)

Measured with `sh packages/webp/bench/run_bench.sh` (`scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved) against an in-process C `-O2 -lwebp` (`libwebp 1.5.0`, `WebPEncode` with `WebPConfigLosslessPreset(&config, 4)` + `config.exact = 1`) harness (`packages/webp/bench/c/libwebp_encode_bench.c`). Both implementations load the same deterministic 512×512 RGBA8888 buffer (`alpha_512.rgba`, 1,048,576 B) once into RAM, encode it 10 times in-process (10 MiB RGBA total), decode the final encoded WebP back to RGBA8888, and write it to stdout (`SHA-256: e7da69a9c55682bc157c95b4c7da770478848a95115b4d5387bcaaf18be605ff`, matching the raw input RGBA8888 byte-for-byte across every round):

| Workload | Pion Median (ms) | Pion Min / P95 (ms) | `libwebp -z 4` Median (ms) | `libwebp` Min / P95 (ms) | Pion MB/s | `libwebp` MB/s | Pion Peak RSS | `libwebp` Peak RSS | Speedup | Pion Size | `libwebp -z 4` Size |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| VP8L Lossless Encode 512×512 RGBA (`exact`, in-process, ×10) | **583.544** | 537.638 / 606.467 | 1267.907 | 1224.872 / 1446.911 | **17.97** | 8.27 | **8.79 MiB** | 27.07 MiB | **2.17x** | 190,690 B (5.50x) | **169,386 B** (6.19x) |

Honest notes: Pion encodes 2.17× faster than in-process `libwebp` `-z 4` with 3.08× lower peak RSS (8.79 MiB vs 27.07 MiB); `libwebp -z 4` achieves ~11% smaller output on the 512×512 photographic image due to CrossColor and Meta-Huffman entropy groups. On palette and solid images (e.g. 127×64 solid: 44 B / 738.9×, 127×64 pattern: 126 B / 258.0×, 33×32 2-color: 56 B), Pion matches or approaches `libwebp -z 4`.

Verification (v0.2.0): **23 / 23** package unit tests pass (11 decode + 12 encode/regression tests including `exact` alpha=0 RGB preservation, ColorIndexing bitstream header verification, 300×300 multi-tile, Fibonacci 15-bit Huffman length cap, `1x257`/`257x1`/`16384x2` edge dimensions, and `LimitExceeded` OOM guard). All 19 cross-decode cases (18 synthetic/edge + 512×512 photo) decode byte-for-byte identically via Go `golang.org/x/image/webp` and `dwebp 1.5.0`. `wasm_smoke` passes all 5 checks with identical output across all 4 modes (native / wasm32 × debug / release): `webp_wasm_smoke: OK checks=5 fnv64=12293912141564746576`. Prior v0.1.0 decoder red-team audit (`sh packages/webp/audit/run_audit.sh`): **exit 0, `AUDIT PASS`** (20/20 red-team/control cases, 622-file differential corpus, 10,000 byte-level mutants, 12/12 DoS bombs, 0 `extern "C"` / 0 `World` / 0 module-level mutable state).
