# `icc` (v0.1.0)

Pure Pion ICC.1:2022 (v2 / v4) color profile parser, JPEG/WebP ICC container extractor, and high-speed ICC → sRGB color transform engine — with zero external dependencies, zero `extern "C"`, zero `World` dependency, and zero mutable module globals.

## Features

- **ICC.1:2022 (v2 / v4) Profile Parser (`parse`)**:
  - Full 128-byte header decoding and strict validation: profile size consistency & truncation guard, CMM type, strict major version check (`2` or `4`, rejecting v0 / v5 iccMAX / v255), device class (`mntr`/`scnr`/`prtr`/`spac`/`abst`/`nmcl`/`link`), data color space (`RGB `/`GRAY`/`CMYK`/`XYZ `/`Lab `), PCS (`XYZ `/`Lab `), UTC creation timestamp, mandatory `acsp` magic check, platform, flags, rendering intent (`0..3`), PCS D50 illuminant (`s15Fixed16`), creator, and 16-byte Profile ID.
  - Overflow-safe defensive tag table parser: rejects `tag_count > 4096`, rejects duplicate tag signatures in O(1) (`IccError::InvalidTagTable`, eliminating O(tag_count × tag_size) DoS and last-wins ambiguity), verifies `132 + tag_count * 12 <= profile_size`, validates every tag with 64-bit overflow-safe bounds (`offset >= 128`, `size > 0`, `offset <= profile_size`, `size <= profile_size - offset`), and reuses shared tag offsets (e.g., `rTRC`/`gTRC`/`bTRC` aliasing the same curve without redundant decoding).
  - Profile descriptions: ICC v2 `desc` (`textDescriptionType` ASCII) and ICC v4 `mluc` (`multiLocalizedUnicodeType` UTF-16BE with full BMP + surrogate pair UTF-8 decoding and `enUS` locale preference).
  - Core color tags: `XYZ ` (`rXYZ`/`gXYZ`/`bXYZ`/`wtpt`/`bkpt`, exact signed two's-complement `s15Fixed16Number`), `sf32` (`chad` 3×3 chromatic adaptation matrix), `curv` (`count == 0` identity, `count == 1` `u8Fixed8` gamma, `count >= 2` 16-bit table with piecewise linear interpolation), and `para` (all 5 ICC v4 Table 65 parametric curve function types `0..4`).
  - Read-only inspection helpers: `is_srgb_like` (strictly checks all 256 encoded levels within ≤ 1 LSB and rejects `A2B0`/`A2B1` LUT profiles), `description`, `color_space`, `pcs`, `device_class`, `version`, `rendering_intent`, `pcs_illuminant`, `white_point`, `black_point`, `chad`, `matrix`, `red_trc`/`green_trc`/`blue_trc`/`gray_trc`, `tags`, `has_tag`, `profile_id`.
- **Zero-Dependency Container ICC Extraction**:
  - `extract_jpeg_icc`: scans JPEG markers from `SOI (0xFFD8)` until `SOS (0xFFDA)` / `EOI (0xFFD9)`, handles `0xFF` fill bytes and standalone markers, extracts `APP2 (0xFFE2)` `ICC_PROFILE\0` segments with single-segment zero-copy `Bytes::slice` and out-of-order multi-segment reassembly, rejecting `seq_no == 0`, `seq_no > total`, mismatched totals, duplicate chunks, and missing chunks.
  - `extract_webp_icc`: validates `RIFF`/`WEBP` header, requires an extended-format `VP8X` first chunk with the `ICCP` feature flag (`0x20`) set (matching WebP spec and `libwebp`), and walks even-padded chunks to return the first `ICCP` chunk via zero-copy `Bytes::slice`.
- **High-Speed ICC → sRGB Transform Engine (`Transform::to_srgb`)**:
  - Supports Matrix-TRC `RGB ` profiles (Display P3, AdobeRGB 1998, sRGB IEC61966-2.1, ProPhoto / ROMM RGB, Rec.2020, etc.) and `GRAY` (`kTRC`) profiles; cleanly returns `Err(IccError::UnsupportedProfile(_))` for CMYK/Lab/CLUT (`A2B0`/`A2B1`) profiles.
  - Exact ICC.1:2022 PCS D50 → sRGB D65 colorimetry (without double-applying `chad`).
  - Zero mutable module globals: precomputed sRGB EOTF/OETF tables stored as immutable 7-bit ASCII `String` constants; IEEE-754 bit-level `f64_pow_unit_fast` + stride-4 cubic LUT interpolation for smooth `Gamma`/`Parametric(3)` curves; O(1) shared TRC alias detection; bulk pixel loops use 3-lane packed `Int64` SWAR pre-multiplied LUTs + padded zero-clamp 8193-entry sRGB OETF (zero multiplies, zero clamps, zero stack spills in the hot loop); tight O(1) identity fast path (`eps = 0.00015`, exact 256-level integer LUT verification).
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

- Output: `icc_wasm_smoke: OK pixels=216 fnv64=10137988538645260462`

### Differential Accuracy vs Exact ICC Reference, Rust `qcms 0.3.0` & `moxcms 0.9.2`

Verified via `packages/icc/audit/diff/compare.py grid` on 40,033 RGB pixels (4×256 ramps + 33³ grid + 4,096 random pixels) across 37 synthetic profiles and 11 macOS ColorSync system ICC profiles (read in place out-of-tree; zero proprietary `.icc` files committed). Every well-formed profile is **≤ 1 LSB** vs the exact ICC.1:2022 float reference:

| Profile | vs Exact ICC Ref | vs Rust `qcms 0.3.0` | vs Rust `moxcms 0.9.2` |
| --- | --- | --- | --- |
| Display P3 (v4 `para` + `mluc`) | max 1 LSB, 98.27% exact, 100.00% ≤ 1 LSB | max 1 LSB, 97.88% exact, 100.00% ≤ 1 LSB | max 1 LSB, 96.80% exact, 100.00% ≤ 1 LSB |
| sRGB IEC61966-2.1 (v2 `curv[1024]`) | max 1 LSB, 99.97% exact, 100.00% ≤ 1 LSB | max 1 LSB, 99.73% exact, 100.00% ≤ 1 LSB | max 1 LSB, 99.21% exact, 100.00% ≤ 1 LSB |
| AdobeRGB 1998 (v2 `curv` gamma) | max 1 LSB, 97.72% exact, 100.00% ≤ 1 LSB | max 1 LSB, 98.04% exact, 100.00% ≤ 1 LSB | max 1 LSB, 95.42% exact, 100.00% ≤ 1 LSB |
| Generic Gray Gamma 2.2 (`kTRC`) | **max 0 LSB, 100.00% exact** | **max 0 LSB, 100.00% exact** | **max 0 LSB, 100.00% exact** |
| Rec. ITU-R BT.2020-1 (v4 `para`) | max 1 LSB, 98.51% exact, 100.00% ≤ 1 LSB | max 1 LSB, 98.16% exact, 100.00% ≤ 1 LSB | max 2 LSB, 96.51% exact, 100.00% ≤ 1 LSB |
| ROMM RGB / ProPhoto (v4 `para`) | max 1 LSB, 98.68% exact, 100.00% ≤ 1 LSB | max 1 LSB, 98.38% exact, 100.00% ≤ 1 LSB | max 2 LSB, 97.28% exact, >99.99% ≤ 1 LSB |

### Fair Head-to-Head Benchmarks vs Precached Rust `qcms 0.3.0` & `moxcms 0.9.2`

Measured on `Linux x86_64` (`sh packages/icc/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved, byte-identical stdout SHA-256 verified using saturated non-neutral probes and whole-frame RGB digests). `rust_qcms_pre` enables `precache_output_transform()` (Firefox production configuration; uses SSE2 SIMD on `x86_64`):

#### Scenario A: Parse + `Transform::to_srgb` + Saturated Probe `(200, 70, 40)` (20,000 iterations each)

| Profile | `pion_icc` (ns/op) | `rust_qcms_pre` (ns/op) | `rust_moxcms` (ns/op) | Pion vs `rust_qcms_pre` | Pion vs `rust_moxcms` |
| --- | ---: | ---: | ---: | ---: | ---: |
| Display-P3 v4 (`para3`) | **1,634.34** | 5,487.50 | 340,806.11 | **3.36x** | **208.53x** |
| sRGB v2 (`curv[1024]`) | **3,140.68** | 7,518.82 | 350,292.43 | **2.39x** | **111.53x** |
| AdobeRGB v2 (`curv` gamma) | **2,810.38** | 7,861.68 | 341,268.15 | **2.80x** | **121.43x** |
| Rec.2020 v4 (`para3` 709 TRC) | **3,111.57** | 4,549.18 | 326,929.16 | **1.46x** | **105.07x** |

#### Scenario B: 1920×1080 RGBA8 Display-P3 → sRGB (20 frames = 41.47M pixels, 165.89 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | MP/s | ns/px | Peak RSS | Speedup (vs `rust_qcms_pre`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_moxcms` (`0.9.2 --release`, SIMD) | 63.310 | 62.814 | 84.110 | 2620.26 | 655.1 | 1.53 | 18.69 MiB | 1.06x |
| `rust_qcms_pre` (`0.3.0 --release`, SSE2) | 66.986 | 61.059 | 88.295 | 2476.47 | 619.1 | 1.62 | 10.66 MiB | 1.00x (baseline) |
| `pion_icc` (`--release`, pure scalar SWAR) | 140.715 | 118.857 | 160.945 | 1178.89 | 294.7 | 3.39 | 17.89 MiB | 0.48x |

Notes:
- On Scenario A, `pion_icc` leads precached `rust_qcms_pre` across all 4 profiles (**1.46–3.36×**) and leads `rust_moxcms` by **105–209×**.
- On Scenario B, pure-scalar SWAR `pion_icc` achieves **294.7 MP/s** median (**348.9 MP/s** peak, **2.66×** faster than baseline scalar `pion_icc`), while `rust_qcms_pre` (SSE2) and `rust_moxcms` (SIMD) use x86_64 vector intrinsics. 1-frame 1080p accuracy gate verifies `max_err <= 2 LSB` (**max 1 LSB, 100.0000% ≤ 1 LSB** vs `rust_qcms_pre`; **max 2 LSB, 99.9967% ≤ 1 LSB** vs `rust_moxcms`, alpha 100% preserved).
