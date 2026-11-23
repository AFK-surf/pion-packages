# `qrcode`

Pure Pion, zero-dependency, `World`-free, Native + Wasm32 dual-target **ISO/IEC 18004 QR Code** encoder, Reed-Solomon matrix decoder, and multi-format renderer.

## Features

- **Complete ISO/IEC 18004 Encoder (`src/tables.pion`, `src/rs.pion`, `src/segment.pion`, `src/encode.pion`)**
  - All **40 versions** (`v1` `21×21` through `v40` `177×177`) × **4 error correction levels** (`L` 7%, `M` 15%, `Q` 25%, `H` 30%) — all 160 Table 9 codeword/block entries.
  - All core data modes: **Numeric**, **Alphanumeric** (45-char set), **Byte** (UTF-8 / arbitrary binary), **Kanji** (Shift-JIS double-byte), and **ECI** (including UTF-8 ECI `26`).
  - **Dynamic programming optimal mixed-mode segmenter** (`optimize_segments`) minimizing total bit length across Numeric/Alphanumeric/Byte transitions.
  - Precomputed GF(256) (`x^8 + x^4 + x^3 + x^2 + 1 = 0x11D`) `exp`/`log` tables and Reed-Solomon generator polynomials (`degree 1..=30`) with zero-allocation remainder computation and full multi-block interleaving.
  - Full function-pattern layout: Finder + Separator, Alignment patterns (`v2..v40`), Timing patterns, Dark Module, Format BCH(15,5) (2 copies), Version BCH(18,6) (`v7..v40`, 2 copies).
  - All **8 mask patterns (`0..7`)** and **exact ISO/IEC 18004 §7.8.3.1 penalty rules (N1 + N2 + N3 + N4)** with automatic best-mask selection or explicit forced mask.
- **Pure Pion Matrix Decoder & Error Correction (`src/decode.pion`)**
  - Decodes raw `size × size` module matrices for any version `v1..v40` with **automatic 0°/90°/180°/270° rotation detection**.
  - Format BCH(15,5) and Version BCH(18,6) decoding with minimum Hamming-distance error correction (up to 3 bit errors).
  - Full **Berlekamp-Massey + Chien Search + Forney** Reed-Solomon decoder correcting up to `floor(ec_codewords / 2)` corrupted codewords per block.
  - Reconstructs Numeric, Alphanumeric, Byte, Kanji, and ECI segments.
- **Multi-Format Renderers (`src/render.pion`)**
  - **Compact SVG** (`to_svg_default` / `to_svg`): merges horizontal dark module runs into a single `<path>` (or optional `<rect>` mode) with configurable quiet zone, colors, and module size.
  - **UTF-8 Terminal Half-Blocks** (`to_terminal`): `▀`/`▄`/`█`/` ` (half height, directly scannable in terminal) and plain ASCII (`to_ascii`).
  - **Raster Export**: 8-bit binary P5 PGM (`to_pgm`) and 32-bit RGBA (`to_rgba`).

## Quick Start

```pion
import "qrcode"

pub fn example() -> Result[String, qrcode::QrError] {
  let qr = match qrcode::encode("https://still.fail", qrcode::EcLevel::M) {
    Result::Ok(q) => q
    Result::Err(e) => return Result::Err(e)
  }
  let svg = qr.to_svg_default()
  let decoded = match qrcode::decode(qr) {
    Result::Ok(d) => d
    Result::Err(e) => return Result::Err(e)
  }
  let _ = decoded.text // "https://still.fail"
  Result::Ok(svg)
}
```

## Verification

### Native Unit & Compliance Suite (`sh scripts/verify.sh packages/qrcode`)

- `15/15` tests passing (`qrcode_test.pion`, `decode_test.pion`, `render_test.pion`), covering ISO/IEC 18004 Annex I `HELLO WORLD` vectors, all 160 `(version, ec)` capacity & block-division invariants, Numeric/Alphanumeric/Byte/Kanji/ECI modes, DP mixed-mode optimization, all 8 masks + 4 exact penalty rules, Format/Version BCH distance bounds, Reed-Solomon up-to-`floor(ec/2)` error recovery & `t+1` rejection, multi-version `v1..v40` + 90°/180°/270° rotated + bit-flip corrupted matrix decoding, and SVG/Terminal/ASCII/PGM/RGBA renderers.

### 4-Mode `wasm_smoke` Verification

All 4 modes run with independent clean `PION_CACHE_DIR` exit `0` and emit byte-identical stdout:

```sh
pionc run packages/qrcode/wasm_smoke
pionc run --release packages/qrcode/wasm_smoke
pionc run --target wasm32 packages/qrcode/wasm_smoke
pionc run --target wasm32 --release packages/qrcode/wasm_smoke
```

- Verified stdout SHA-256 across all 4 modes: `e19b626d6e7669a7487f8f6ce5d2a7b4fc26a780bc7ae46e27608e15d6f6095c`

## Head-to-Head Benchmarks (`pion` vs Rust `qrcode 0.14.1`)

Run with `sh packages/qrcode/bench/run_bench.sh` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory byte-identical stdout SHA-256). Both implementations run their default auto-mask ISO/IEC 18004 encoders (`pionc build --release` vs `cargo build --release --locked`), verified to produce **100% pixel-for-pixel identical QR matrices** and byte-identical compact SVG output.

> **Methodology note**: Pion implements exact ISO/IEC 18004 §7.8.3.1 N3/N4 penalty scoring and DP mixed-mode segmentation, whereas Rust `qrcode 0.14.1` uses a heuristic segmenter, an unrounded balance penalty approximation, and per-row/column boxed closures in N3 (`canvas.rs`). Benchmark workloads use representative real-world URLs, OTP URIs, and `v10..v40` binary payloads where both encoders select the exact same version and mask, guaranteeing strict pixel-for-pixel SHA-256 equivalence.

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved)

### W1: Batch URL / 2FA OTP URI Encode (10,000 ops, v2–v6 M/Q, auto best mask)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_qrcode`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 1441.647 | 1390.821 | 1553.047 | 144164.68 | 1.86 MiB | **3.64x** |
| `rust_qrcode` | 5249.401 | 5094.418 | 12996.890 | 524940.14 | 2.34 MiB | 1.00x (baseline) |

- Stdout SHA-256: `79f18f02e786006b922fd6349ef3644a8f5f64bc15e6d98641ed9b5f55ba7f08`

### W2: Large Multi-Version Encode (300 ops, v10/v17/v27/v36/v40 + RS Interleaving)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_qrcode`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 700.823 | 694.389 | 730.627 | 2336075.97 | 2.14 MiB | **3.12x** |
| `rust_qrcode` | 2187.344 | 2133.254 | 2277.352 | 7291147.92 | 3.11 MiB | 1.00x (baseline) |

- Stdout SHA-256: `28822777da5fd0a9338c57c3764cf9750ce02c525fc0d37b6e84240ebe28d366`

### W3: End-to-End Encode + Compact SVG Generation (5,000 ops, Login/Device/OTP QR)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_qrcode`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 738.158 | 729.743 | 828.533 | 147631.64 | 2.05 MiB | **3.41x** |
| `rust_qrcode` | 2518.494 | 2483.286 | 3024.829 | 503698.73 | 2.41 MiB | 1.00x (baseline) |

- Stdout SHA-256: `da23c013b9221ec57785e89035ca476f623d38b6c5e8a4f2382a0c31bf8a415e`
