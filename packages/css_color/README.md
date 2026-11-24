# `css_color` (v0.1.0)

Pure Pion, zero-dependency, production-grade W3C CSS Color Module Level 4 & 5 color engine — with zero external dependencies, zero `extern "C"`, zero `World` dependency, and zero mutable module globals (100% `Send` safe and bit-deterministic across Native and Wasm32).

## Features

- **Complete W3C CSS Color 4 & 5 Parser (`parse(input : String) -> Result[Color, ColorError]`)**:
  - **148 CSS named colors + `transparent`** (ASCII case-insensitive, pure `match` lookup with zero mutable state).
  - **Hex**: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`.
  - **Legacy & modern functions**: `rgb()`, `rgba()`, `hsl()`, `hsla()`, `hwb()` (strict legacy comma vs modern space/`/` separation, angle units `deg`/`rad`/`grad`/`turn`, percentages, and `none` missing components).
  - **Perceptually uniform spaces**: `lab()`, `lch()`, `oklab()`, `oklch()` with exact CSS Color 4 percentage scaling (`lab` L `0..100` / a,b `±125`; `lch` C `0..150`; `oklab` L `0..1` / a,b `±0.4`; `oklch` C `0..0.4`).
  - **Wide-gamut `color()` function**: `srgb`, `srgb-linear`, `display-p3`, `a98-rgb`, `prophoto-rgb`, `rec2020`, `xyz`, `xyz-d50`, `xyz-d65`.
  - **CSS Color 5 `color-mix()`**: all 14 rectangular and polar interpolation spaces, all 4 polar hue interpolation modes (`shorter`, `longer`, `increasing`, `decreasing hue`), CSS Color 5 percentage normalization (`p1 + p2 < 100%` alpha multiplier, `p1 + p2 > 100%` proportional scaling), premultiplied alpha interpolation, and `none` carry-forward.
  - **CSS Color 5 Relative Color Syntax (`from`)**: `rgb(from ...)`, `rgba(from ...)`, `hsl(from ...)`, `hsla(from ...)`, `hwb(from ...)`, `lab(from ...)`, `lch(from ...)`, `oklab(from ...)`, `oklch(from ...)`, `color(from <origin> <space> ...)`, with channel keywords and recursive-descent `calc()` (`+ - * /`, parentheses, unary signs, percentages, angles).
  - **DoS Guards**: `max_nesting_depth = 32` for `color-mix()` / relative `from` / `calc()`, `max_input_length = 16384` bytes, explicit `Result::Err(ColorError)` on all malformed/non-finite/overflow inputs (zero panics/traps).
- **Exact Color Space Conversions & W3C CSS Color 4 §13.2 Gamut Mapping**:
  - Exact W3C CSS Color 4 §18 matrices, exact Bradford D65 ↔ D50 chromatic adaptation, exact Ottosson/CSS Color 4 Oklab matrices, and extended-range sign-preserving transfer functions across all 14 color spaces (`Color::convert`).
  - **W3C CSS Color 4 §13.2 Oklch binary-search gamut mapping** (`Color::to_gamut(target)` with `ΔE_OK < 0.02` JND threshold) for hue-preserving wide-gamut → sRGB / Display-P3 / Rec.2020 mapping.
  - **Output & Accessibility**: `to_rgba8()`, `to_rgba8_clamped()`, `to_hex()`, `to_css()`, `relative_luminance()`, and `contrast_ratio()` (WCAG 2.1).

## Usage

```pion
import "css_color"

match css_color::parse("oklch(from color-mix(in oklch, coral, dodgerblue) calc(l + 0.05) c h)") {
  Ok(c) => {
    let (r, g, b, a) = c.to_rgba8()
    let hex = c.to_hex()
    let p3 = c.to_gamut(css_color::ColorSpace::DisplayP3)
    let _ = (r, g, b, a, hex, p3.to_css())
  }
  Err(_) => ()
}
```

## Verification

```sh
sh scripts/verify.sh packages/css_color
sh packages/css_color/bench/run_bench.sh
```

### 4-Mode Verification (`wasm_smoke`)

`packages/css_color/wasm_smoke` builds cleanly and produces byte-identical output across `native debug`, `native --release`, `wasm32 debug`, and `wasm32 --release`:

- Output: `css_color_wasm_smoke: OK samples=22 fnv64=5651596144648448670`
- SHA-256 (all 4 modes): `74a7423765ce57c187e60dbb52669bd4d3fee96f6d1ebcba914c45546d1e5455`
- Wasm32 binary size: `151,723 B` (debug), `150,022 B` (`--release`)

### Differential Accuracy vs Rust Linebender `color 0.3.3`

Verified via `sh packages/css_color/bench/run_bench.sh` (`bench/diff_oracle.py`) across **2,562** deterministic test cases:

| Suite | Cases | Max Float Error | Max 8-bit Error | Pass Rate |
| --- | ---: | ---: | ---: | ---: |
| Parse + Space Convert (`Srgb`, `Oklab`, `DisplayP3`) | 2,042 | `0.0000030` (`3.0e-6`) | `0 LSB` | `100.00%` exact |
| `color-mix()` (14 spaces + 4 polar hue modes + alpha scaling) | 360 | `0.0000030` (`3.0e-6`) | `1 LSB` | `100.00%` ≤ 1 LSB |
| W3C Oklch Binary-Search Gamut Mapping | 160 | — | — | `160/160` (`100.0%`) in gamut |

### Fair Head-to-Head Benchmarks vs Rust Linebender `color 0.3.3`

Measured on `Darwin arm64` (`sh packages/css_color/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved, byte-identical stdout SHA-256 verified):

#### Scenario A: CSS Color 4 Parse + sRGB Convert (204,200 ops, 6.25 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_color`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_css_color` (`--release`, pure f64) | 64.639 | 64.178 | 65.317 | 96.70 | 316.55 | 2.34 MiB | 0.46x |
| `rust_color` (`0.3.3 --release`, f32 + libm) | 29.775 | 28.904 | 30.912 | 209.93 | 145.81 | 2.23 MiB | 1.00x (baseline) |

#### Scenario B: 4-Stage Color Space Pipeline `sRGB → Oklch → Display-P3 → Lab → sRGB` (408,400 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_color`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_css_color` (`--release`, pure f64 software math) | 277.789 | 268.698 | 282.324 | 680.19 | 2.56 MiB | 0.28x |
| `rust_color` (`0.3.3 --release`, f32 + libm) | 77.971 | 76.746 | 78.934 | 190.92 | 2.30 MiB | 1.00x (baseline) |

Note: `pion_css_color` evaluates all transcendental functions (`pow`, `cbrt`, `sin`, `cos`, `atan2`, `sqrt`) in pure-Pion IEEE-754 `f64` with zero `extern "C"` for 100% Native/Wasm32 bit-determinism, whereas Rust `color` uses `f32` with platform `libm`.
