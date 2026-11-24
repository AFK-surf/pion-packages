# `icc` (v0.1.0)

Pure Pion ICC.1:2022 (v2 / v4) color profile parser, JPEG/WebP ICC container extractor, and high-speed ICC → sRGB color transform engine — with zero external dependencies, zero `extern "C"`, zero `World` dependency, and zero mutable module globals.

## Features

- **ICC.1:2022 (v2 / v4) Profile Parser (`parse`)**:
  - Full 128-byte header decoding and strict validation: profile size consistency & truncation guard, CMM type, `major.minor.bugfix` version, device class (`mntr`/`scnr`/`prtr`/`spac`/`abst`/`nmcl`/`link`), data color space (`RGB `/`GRAY`/`CMYK`/`XYZ `/`Lab `), PCS (`XYZ `/`Lab `), UTC creation timestamp, mandatory `acsp` magic check, platform, flags, rendering intent (`0..3`), PCS D50 illuminant (`s15Fixed16`), creator, and 16-byte Profile ID.
  - Overflow-safe defensive tag table parser: rejects `tag_count > 4096`, verifies `132 + tag_count * 12 <= profile_size`, validates every tag with 64-bit overflow-safe bounds (`offset >= 128`, `size > 0`, `offset <= profile_size`, `size <= profile_size - offset`), and supports shared tag offsets (e.g., `rTRC`/`gTRC`/`bTRC` aliasing the same curve).
  - Profile descriptions: ICC v2 `desc` (`textDescriptionType` ASCII) and ICC v4 `mluc` (`multiLocalizedUnicodeType` UTF-16BE with full BMP + surrogate pair UTF-8 decoding and `enUS` locale preference).
  - Core color tags: `XYZ ` (`rXYZ`/`gXYZ`/`bXYZ`/`wtpt`/`bkpt`, exact signed two's-complement `s15Fixed16Number`), `sf32` (`chad` 3×3 chromatic adaptation matrix), `curv` (`count == 0` identity, `count == 1` `u8Fixed8` gamma, `count >= 2` 16-bit table with piecewise linear interpolation), and `para` (all 5 ICC v4 Table 65 parametric curve function types `0..4`).
  - Read-only inspection helpers: `is_srgb_like`, `description`, `color_space`, `pcs`, `device_class`, `version`, `rendering_intent`, `pcs_illuminant`, `white_point`, `black_point`, `chad`, `matrix`, `red_trc`/`green_trc`/`blue_trc`/`gray_trc`, `tags`, `has_tag`, `profile_id`.
- **Zero-Dependency Container ICC Extraction**:
  - `extract_jpeg_icc`: scans JPEG markers from `SOI (0xFFD8)` until `SOS (0xFFDA)` / `EOI (0xFFD9)`, handles `0xFF` fill bytes and standalone markers, extracts `APP2 (0xFFE2)` `ICC_PROFILE\0` segments with single-segment zero-copy `Bytes::slice` and out-of-order multi-segment reassembly, rejecting `seq_no == 0`, `seq_no > total`, mismatched totals, duplicate chunks, and missing chunks.
  - `extract_webp_icc`: validates `RIFF`/`WEBP` header and walks even-padded chunks (including `VP8X` extended WebP) to return the `ICCP` chunk via zero-copy `Bytes::slice`.
- **High-Speed ICC → sRGB Transform Engine (`Transform::to_srgb`)**:
  - Supports Matrix-TRC `RGB ` profiles (Display P3, AdobeRGB 1998, sRGB IEC61966-2.1, ProPhoto / ROMM RGB, Rec.2020, etc.) and `GRAY` (`kTRC`) profiles; cleanly returns `Err(IccError::UnsupportedProfile(_))` for CMYK/Lab/CLUT-only profiles.
  - Exact ICC.1:2022 PCS D50 → sRGB D65 colorimetry (without double-applying `chad`).
  - Zero-allocation pixel hot path: immutable Q14 256-entry input linearization LUTs, hoisted Q14 3×3 integer matrix multiply, and immutable 8193-entry linear → sRGB output LUT (`srgb_oetf_8193`), plus O(1) no-op identity fast path (`is_identity`) for sRGB profiles.
  - Pixel APIs: `transform_rgb_pixel`, `transform_gray_pixel`, `transform_rgb_in_place` (validates length % 3 == 0), and `transform_rgba_in_place` (validates length % 4 == 0, strictly preserves Alpha bytes).

## Usage

```pion
import "icc"

match icc::extract_jpeg_icc(jpeg_bytes) {
  Ok(Some(raw_icc)) => {
    match icc::parse(raw_icc) {
      Ok(profile) => {
        if !profile.is_srgb_like() {
          match icc::Transform::to_srgb(profile) {
            Ok(tf) => {
              let _ = tf.transform_rgba_in_place(rgba_pixels)
            }
            Err(_) => ()
          }
        }
      }
      Err(_) => ()
    }
  }
  _ => ()
}
```

## Verification

```sh
sh scripts/verify.sh packages/icc
sh packages/icc/bench/run_bench.sh
```

### 4-Mode Verification (`wasm_smoke`)

`packages/icc/wasm_smoke` builds cleanly and produces identical output across `native debug`, `native --release`, `wasm32 debug`, and `wasm32 --release`:

- Output: `icc_wasm_smoke: OK pixels=216 fnv64=8497055218630584498`

### Differential Accuracy vs Rust `qcms 0.3.0` & `moxcms 0.9.2`

Verified on a full **33×33×33 RGB grid (35,937 points = 107,811 channels)** across real macOS ColorSync system ICC profiles (tested out-of-tree; no proprietary `.icc` files committed):

| Profile | vs Rust `qcms 0.3.0` | vs Rust `moxcms 0.9.2` |
| --- | --- | --- |
| Display P3 (v4 `para` + `mluc`) | max 1 LSB, 97.87% exact, 100.00% ≤ 1 LSB | max 1 LSB, 96.85% exact, 100.00% ≤ 1 LSB |
| sRGB IEC61966-2.1 (v2 `curv[1024]`) | max 1 LSB, 99.74% exact, 100.00% ≤ 1 LSB | max 1 LSB, 99.17% exact, 100.00% ≤ 1 LSB |
| AdobeRGB 1998 (v2 `curv` gamma) | max 1 LSB, 98.14% exact, 100.00% ≤ 1 LSB | max 1 LSB, 95.38% exact, 100.00% ≤ 1 LSB |
| Generic Gray Gamma 2.2 (`kTRC`) | **max 0 LSB, 100.00% exact** | **max 0 LSB, 100.00% exact** |
| Rec. ITU-R BT.2020-1 (v4 `para`) | max 1 LSB, 98.08% exact, 100.00% ≤ 1 LSB | max 1 LSB, 97.07% exact, 100.00% ≤ 1 LSB |
| ROMM RGB / ProPhoto (v4 `para`) | max 1 LSB, 98.38% exact, 100.00% ≤ 1 LSB | max 2 LSB, 97.23% exact, 100.00% ≤ 1 LSB |

### Head-to-Head Benchmarks vs Rust `qcms 0.3.0` & `moxcms 0.9.2`

Measured on `Darwin arm64` (`sh packages/icc/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved, byte-identical stdout SHA-256 verified):

#### Scenario A: Parse Display-P3 v4 + `Transform::to_srgb` (100,000 iterations, 44.4 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_qcms`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_icc` (`--release`) | **115.554** | **110.368** | **196.736** | **384.24** | **1155.54** | **2.14 MiB** | **245.31x** |
| `rust_moxcms` (`0.9.2 --release`) | 5120.485 | 4939.163 | 5415.735 | 8.67 | 51204.85 | 2.91 MiB | 5.54x |
| `rust_qcms` (`0.3.0 --release`) | 28345.908 | 27939.903 | 28933.804 | 1.57 | 283459.08 | 2.23 MiB | 1.00x (baseline) |

#### Scenario B: 1920×1080 RGBA8 Display-P3 → sRGB (50 frames = 103.68M pixels, 414.72 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | MP/s | ns/px | Peak RSS | Speedup (vs `rust_qcms`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_moxcms` (`0.9.2 --release`, NEON) | 128.251 | 118.763 | 137.255 | 3233.65 | 808.4 | 1.24 | 18.31 MiB | 4.50x |
| `pion_icc` (`--release`, pure scalar) | **290.309** | **270.620** | **344.774** | **1428.55** | **357.1** | **2.80** | 20.58 MiB | **1.99x** |
| `rust_qcms` (`0.3.0 --release`) | 577.345 | 560.270 | 605.063 | 718.32 | 179.6 | 5.57 | 10.11 MiB | 1.00x (baseline) |

Note: On Scenario B, pure scalar `pion_icc` achieves **357.1 MP/s** (**5.81 ms / 1080p frame**, **1.99x faster than `rust_qcms`**), while `rust_moxcms` leads via hand-written ARM64 NEON SIMD intrinsics.
