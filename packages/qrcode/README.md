# `qrcode`

Pure Pion, zero-dependency, `World`-free, Native + Wasm32 dual-target **ISO/IEC 18004 QR Code** encoder, Reed-Solomon matrix decoder, and multi-format renderer.

## Features

- **Complete ISO/IEC 18004 Encoder (`src/tables.pion`, `src/rs.pion`, `src/segment.pion`, `src/encode.pion`)**
  - All **40 versions** (`v1` `21×21` through `v40` `177×177`) × **4 error correction levels** (`L` 7%, `M` 15%, `Q` 25%, `H` 30%) — all 160 Table 9 codeword/block entries.
  - All core data modes: **Numeric**, **Alphanumeric** (45-char set), **Byte** (UTF-8 / arbitrary binary), **Kanji** (Shift-JIS double-byte), and **ECI** (including UTF-8 ECI `26`).
  - **Exact O(n) dynamic programming optimal mixed-mode segmenter** (`optimize_segments`) minimizing exact bit length across Numeric/Alphanumeric/Byte transitions (0 bits excess vs exact O(n²) optimum across 12,000 test strings).
  - Precomputed GF(256) (`x^8 + x^4 + x^3 + x^2 + 1 = 0x11D`) `exp`/`log` tables and Reed-Solomon generator polynomials (`degree 1..=30`) with zero-allocation remainder computation and full multi-block interleaving.
  - Full function-pattern layout: Finder + Separator, Alignment patterns (`v2..v40`), Timing patterns, Dark Module, Format BCH(15,5) (2 copies), Version BCH(18,6) (`v7..v40`, 2 copies).
  - All **8 mask patterns (`0..7`)** and **exact ISO/IEC 18004 §7.8.3.1 / Nayuki `qrcodegen` penalty rules (N1 + N2 + N3 + N4)** including implicit light quiet-zone N3 edge matching (160/160 exact auto-mask match vs `qrcodegen 1.8.0`).
- **Pure Pion Matrix Decoder & Error Correction (`src/decode.pion`)**
  - Decodes raw `size × size` module matrices for any version `v1..v40` with **automatic 0°/90°/180°/270° rotation and mirror-image (transposed) detection**.
  - Format BCH(15,5) and Version BCH(18,6) decoding with minimum Hamming-distance error correction (up to 3 bit errors).
  - Full **Berlekamp-Massey + Chien Search + Forney** Reed-Solomon decoder correcting up to `floor(ec_codewords / 2)` corrupted codewords per block.
  - Reconstructs Numeric, Alphanumeric, Byte, Kanji (with strict Shift-JIS pair validation), ECI (strict `<= 999999`), FNC1 (`0101`/`1001`), and Structured Append (`0011`) headers.
- **Multi-Format Renderers (`src/render.pion`)**
  - **Compact SVG** (`to_svg_default` / `to_svg` / `to_svg_checked`): merges horizontal dark module runs into a single `<path>` (or optional `<rect>` mode), with strict color allowlisting against SVG XSS/attribute injection and 64-bit coordinate arithmetic to prevent `viewBox` overflow.
  - **UTF-8 Terminal Half-Blocks** (`to_terminal` / `to_terminal_checked`): `▀`/`▄`/`█`/` ` (half height, directly scannable in terminal) and plain ASCII (`to_ascii` / `to_ascii_checked`) with safe dimension bounds.
  - **Raster Export**: 8-bit binary P5 PGM (`to_pgm` / `to_pgm_checked`) and 32-bit RGBA (`to_rgba` / `to_rgba_checked`) with 64-bit overflow checks and a 256 MiB safety cap (no integer-overflow aborts on Native or Wasm32).

## Quick Start

```pion
import "qrcode"

pub fn example() -> Result[String, qrcode::QrError] {
  let qr = match qrcode::encode("https://example.com", qrcode::EcLevel::M) {
    Result::Ok(q) => q
    Result::Err(e) => return Result::Err(e)
  }
  let svg = qr.to_svg_default()
  let decoded = match qrcode::decode(qr) {
    Result::Ok(d) => d
    Result::Err(e) => return Result::Err(e)
  }
  let _ = decoded.text // "https://example.com"
  Result::Ok(svg)
}
```

## Verification

### Native Unit, Compliance & Red-Team Suites

- `sh scripts/verify.sh packages/qrcode`: **`17/17`** tests passing (`qrcode_test.pion`, `decode_test.pion`, `render_test.pion`), covering ISO/IEC 18004 Annex I `HELLO WORLD` vectors, all 160 `(version, ec)` capacity & block-division invariants, Numeric/Alphanumeric/Byte/Kanji/ECI modes, exact DP mixed-mode optimization, all 8 masks + 4 exact penalty rules, Format/Version BCH distance bounds, Reed-Solomon up-to-`floor(ec/2)` error recovery & `t+1` rejection, multi-version `v1..v40` + 90°/180°/270° rotated + mirror-imaged + bit-flip corrupted matrix decoding, and SVG/Terminal/ASCII/PGM/RGBA renderers with XSS and overflow guards.
- `pionc test --json --only-pkg packages/qrcode/audit`: **`21/21`** red-team audit tests passing (`13/13` remediated findings + `8/8` controls, `0` failures).
- Differential oracle (`packages/qrcode/audit/run_audit.sh`): `1280/1280` pixel-identical fixed-mask symbols vs `qrcodegen 1.8.0`, `160/160` exact auto-mask match (`0` worse), `0/12000` suboptimal DP segmentations, `2689/2689` + `771/771` mirror cross-decoding with `rqrr 0.11.0`, `0` silent RS miscorrections across 4,688 injections, and byte-identical 4-mode Native/Wasm32 outputs with `0` traps.

### 4-Mode `wasm_smoke` Verification

All 4 modes run with independent clean `PION_CACHE_DIR` exit `0` and emit byte-identical stdout:

```sh
pionc run packages/qrcode/wasm_smoke
pionc run --release packages/qrcode/wasm_smoke
pionc run --target wasm32 packages/qrcode/wasm_smoke
pionc run --target wasm32 --release packages/qrcode/wasm_smoke
```

- Verified stdout SHA-256 across all 4 modes: `942df35238cee14406e00bdf7b407e750dd2466bb2de007336bb65a5523aaf47`

## Formal Verification (Lean 4)

Existing production `#verify` kernels (2 types, 15 functions, 0 externals) across `src/types.pion`, `src/tables.pion`, `src/segment.pion`, and `src/encode.pion` are extracted via `pionc extract-lean` and formally verified in `packages/qrcode/proofs/` (**22 theorems**, 0 `sorry`, 0 `admit`, 0 custom axioms, 0 `bv_decide`, 0 `native_decide`):

- **`QrcodeProofs/GeometryAndModes.lean` (11 theorems)**: `EcLevel::to_int`/`format_bits` bijections & `ec_level_eq` reflection, `Mode::to_int`/`indicator` injectivity & `mode_eq` reflection, `version_size` exact `4*v+17` in `[21, 177]` (`≡ 1 mod 4`) & strict monotonicity, `raw_data_modules` exact `[208, 29648]` bounds & strict monotonicity across all 40 versions, `total_codewords` `[26, 3706]`, `char_count_bits` version monotonicity across all 5 modes, `ceil_sixths` rounding & idempotence, and `is_numeric_byte` exact ASCII digit spec.
- **`QrcodeProofs/MaskAndKanji.lean` (11 theorems)**: Exact ISO/IEC 18004 specifications for all **8 QR mask patterns (`0..7`)** on `0 ≤ x, y ≤ 176`, `kanji_value` 13-bit range `[0, 8191]`, `kanji_from_value` Shift-JIS validity (excluding `0x7F`), and end-to-end `kanji_encode_decode_roundtrip`.
- **Reproduce**: `packages/qrcode/proofs/run_proofs.sh` (verifies extraction, static scan, `lake build`, `CheckAxioms.lean` standard-axioms-only check, and 40-case Native Pion vs Lean `EvalDiff` `diff -u` cross-check).

## Head-to-Head Multi-Baseline Benchmarks (`pion` vs `qrcode 0.14.1` / `qrcodegen 1.8.0` / `fast_qr 0.14.0`)

Measured with `packages/qrcode/audit/run_audit.sh bench` (`scripts/bench_compare.py --warmup 1 --rounds 5`, strictly interleaved, mandatory byte-identical stdout SHA-256 across all implementations and rounds). All Rust baselines are built with `cargo build --release --locked`; Pion is built with `pionc build --release`.

> **Honest summary (leads & lags)**:
> - **Leads**: Pion is **3.87×–7.39× faster** than `qrcode 0.14.1` across all workloads, **beats Nayuki `qrcodegen 1.8.0` on W1** (`1115.2 ms` vs `1172.0 ms`), uses the **lowest peak RSS** of all 4 implementations (`1.89–2.16 MiB`), and produces **smaller QR versions** than `qrcodegen`/`fast_qr` on real mixed-case payloads thanks to exact O(n) mixed-mode DP segmentation.
> - **Lags**: `fast_qr 0.14.0` is **2.18× faster** than Pion on W1 and **3.57× faster** on W2; `qrcodegen 1.8.0` is **~8% faster** than Pion on large `v10..v40` binary encodes (W2).

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved)

### W1: Batch URL / 2FA OTP URI Encode (10,000 ops, v2–v6 M/Q, auto best mask)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Peak RSS | Speedup (vs `qrcode 0.14.1`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` | **1115.197** | 1057.980 | 1181.276 | **1.89 MiB** | **4.83x** (1.05x faster than `qrcodegen`; 2.18x slower than `fast_qr`) |
| `rust_qrcode014` (`qrcode 0.14.1`) | 5382.242 | 5045.563 | 19670.618 | 2.48 MiB | 1.00x (baseline) |
| `rust_qrcodegen` (`qrcodegen 1.8.0`) | 1171.980 | 1160.355 | 2165.364 | 2.42 MiB | 4.59x |
| `rust_fast_qr` (`fast_qr 0.14.0`) | **511.794** | 500.976 | 895.892 | 2.17 MiB | **10.52x** |

- Stdout SHA-256 (4-impl `audit/oracle` W1): `a58f60af0df01ae748d6ce495ed1c66abf1f26096bb871c245a434b9ab151869` (2-impl `bench/pion_bench` vs `bench/rust`: W1 `ef441039060c80753eba6ab8bab357edeb0846715b50a43334064df2c9872357`, W3 `ff4e46713732b6ef461cf923589d62b48b3b466787ea5378624b05efe8d1c48d`)

### W2: Large Multi-Version Binary Encode (300 ops, v10–v40 + RS Interleaving)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Peak RSS | Speedup (vs `qrcode 0.14.1`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` | 772.248 | 643.787 | 1170.226 | **2.16 MiB** | **3.87x** (1.08x slower than `qrcodegen`; 3.57x slower than `fast_qr`) |
| `rust_qrcode014` (`qrcode 0.14.1`) | 2987.593 | 2343.264 | 5385.102 | 3.14 MiB | 1.00x (baseline) |
| `rust_qrcodegen` (`qrcodegen 1.8.0`) | 712.249 | 596.495 | 1210.970 | 2.94 MiB | 4.19x |
| `rust_fast_qr` (`fast_qr 0.14.0`) | **216.022** | 198.212 | 350.301 | 2.30 MiB | **13.83x** |

- Stdout SHA-256: `0de3a5ce50d6c47499463e1e3ae0d8982cca9ec4734991d1a85d6ec2371ab8ba`

### Real-World Mixed-Case Payloads (10,000 ops, OTP / Wi-Fi / vCard / URL / Numeric, DP optimizer on)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Peak RSS | Speedup (vs `qrcode 0.14.1`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` | **1098.078** | 1004.872 | 1188.221 | **1.92 MiB** | **7.39x** |
| `rust_qrcode014` (`qrcode 0.14.1`) | 8118.516 | 4535.996 | 10226.765 | 2.64 MiB | 1.00x (baseline) |

- Note: `qrcodegen 1.8.0` (`make_segments`) and `fast_qr 0.14.0` lack a mixed-mode optimizer and pick larger versions on these payloads, so only optimizer-equipped encoders match the SHA-256 gate (`bebae88dbe9b0261454f429b21024f59f369f7311da8bba24540b9eba6e1fb44`).
