# `css_color` (v0.1.0)

Pure Pion, zero-dependency, production-grade W3C CSS Color Module Level 4 & 5 color engine — with zero external dependencies, zero `extern "C"`, zero `World` dependency, and zero mutable module globals (100% `Send` safe and bit-deterministic across Native and Wasm32).

## Features

- **W3C CSS Color 4 & 5 Parser (`parse(input : String) -> Result[Color, ColorError]`)**:
  - **148 CSS named colors + `transparent`** (ASCII case-insensitive, pure `match` lookup with zero mutable state).
  - **Hex**: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA` with strict CSS hash-token boundaries.
  - **Legacy & modern functions**: `rgb()`, `rgba()`, `hsl()`, `hsla()`, `hwb()` (strict legacy comma vs modern space/`/` separation, angle units `deg`/`rad`/`grad`/`turn` with exact binary `fmod` normalization for arbitrarily large angles, percentages, and `none` missing components).
  - **Perceptually uniform spaces**: `lab()`, `lch()`, `oklab()`, `oklch()` with CSS Color 4 percentage scaling (`lab` L `0..100` / a,b `±125`; `lch` C `0..150`; `oklab` L `0..1` / a,b `±0.4`; `oklch` C `0..0.4`).
  - **Wide-gamut `color()` function**: `srgb`, `srgb-linear`, `display-p3`, `display-p3-linear`, `a98-rgb`, `prophoto-rgb`, `rec2020`, `xyz`, `xyz-d50`, `xyz-d65`.
  - **CSS Color 5 ED `color-mix()`**: all 15 rectangular and polar interpolation spaces (omitted `in` defaults to `oklab`), 1..N colors, all 4 polar hue interpolation modes (`shorter`, `longer`, `increasing`, `decreasing hue`), CSS Color 5 ED percentage normalization (including `0% + 0%` transparent result and `calc()` percentages), premultiplied alpha interpolation, missing-hue fill before fix-up, and `none` carry-forward (including analogous components `x/y/z ↔ r/g/b` and analogous sets).
  - **CSS Color 5 Relative Color Syntax (`from`)**: `rgb(from ...)`, `rgba(from ...)`, `hsl(from ...)`, `hsla(from ...)`, `hwb(from ...)`, `lab(from ...)`, `lch(from ...)`, `oklab(from ...)`, `oklch(from ...)`, `color(from <origin> <space> ...)`, preserving `none` and powerless hues on bare channel keywords, with typed CSS Values 4 `calc()` (`+ - * /` with whitespace & type checking, parentheses, `pi`/`e`/`infinity`/`-infinity`/`nan`, IEEE-754 division by zero, percentages, and angles).
  - **DoS Guards**: `max_nesting_depth = 32` for `color-mix()` / relative `from` / `calc()`, `max_input_length = 16384` bytes, explicit `Result::Err(ColorError)` on malformed inputs (zero panics/traps).
  - **Out of scope by design**: `currentcolor`, system colors, CSS-wide keywords, `var()`/`env()`, `light-dark()`/`contrast-color()`/`alpha()`, CSS math functions other than `calc()`, CSS comments/escapes, and unclosed `(` auto-closing at EOF.
- **Color Space Conversions & W3C CSS Color 4 §13.2 Gamut Mapping**:
  - 2023+ W3C CSS Color 4 ED rational-derived matrices (including updated Bradford D65 ↔ D50 and ProPhoto RGB matrices), direct D50 ↔ D50 hub routing, Ottosson/CSS Color 4 Oklab matrices, ED powerless-hue epsilon guards, and extended-range sign-preserving transfer functions across all 15 color spaces (`Color::convert`). Note: `rec2020` uses the BT.2020 piecewise OETF (matching Chrome 159 and Rust `color 0.3.3`; 2 pinned WPT 2025 ED vectors expect BT.1886 gamma 2.4).
  - **W3C CSS Color 4 §13.2 Oklch binary-search gamut mapping** (`Color::to_gamut(target)` with `ΔE_OK < 0.02` JND threshold, step-11 clip shortcut, and `eps = 1e-4`).
  - **Output & Accessibility**: `to_rgba8()`, `to_rgba8_clamped()`, `to_hex()`, `to_css()` (with deterministic scientific notation for large/tiny magnitudes and `calc(NaN)`/`calc(infinity)` for non-finite coordinates), `relative_luminance()` (opaque sRGB WCAG 2.1 luminance), and `contrast_ratio()` (WCAG 2.1 contrast with Porter-Duff source-over alpha compositing of translucent foregrounds over the backdrop).

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

Unit tests include 32 core tests (`src/css_color_test.pion`) plus ported WPT `css/css-color/parsing` compliance & regression tests (`src/wpt_test.pion`).

### 4-Mode Verification (`wasm_smoke`)

`packages/css_color/wasm_smoke` builds cleanly and produces byte-identical output across `native debug`, `native --release`, `wasm32 debug`, and `wasm32 --release`:

- Output: `css_color_wasm_smoke: OK samples=22 fnv64=5651596144648448670`
- SHA-256 (all 4 modes): `74a7423765ce57c187e60dbb52669bd4d3fee96f6d1ebcba914c45546d1e5455`
- Wasm32 binary size: `180,751 B` (debug), `179,811 B` (`--release`)

### Differential Accuracy vs Rust Linebender `color 0.3.3`

Verified via `sh packages/css_color/bench/run_bench.sh` (`bench/diff_oracle.py`) across a curated corpus of **2,562** deterministic test cases (only inputs that `color 0.3.3` accepts: no rejection tests, no `none`, no relative colors, no `calc()`, 7 `*grey` aliases omitted; the gamut row checks the in-gamut property):

| Suite | Cases | Max Float Error | Max 8-bit Error | Pass Rate |
| --- | ---: | ---: | ---: | ---: |
| Parse + Space Convert (`Srgb`, `Oklab`, `DisplayP3`) | 2,042 | `0.0000930` (`9.3e-5`) | `0 LSB` | `100.00%` exact |
| `color-mix()` (14 spaces + 4 polar hue modes + alpha scaling) | 360 | `0.0000030` (`3.0e-6`) | `1 LSB` | `100.00%` ≤ 1 LSB |
| W3C Oklch Binary-Search Gamut Mapping | 160 | — | — | `160/160` (`100.0%`) in gamut |

### Fair Head-to-Head Benchmarks vs Rust Linebender `color 0.3.3`

Measured on `Linux x86_64` (`sh packages/css_color/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved, byte-identical stdout SHA-256 verified):

#### Scenario A: CSS Color 4 Parse + sRGB Convert (204,200 ops, 6.25 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_color`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_css_color` (`--release`, pure f64) | 42.549 | 40.855 | 46.664 | 146.91 | 208.37 | 2.51 MiB | 0.96x |
| `rust_color` (`0.3.3 --release`, f32 + libm) | 40.947 | 40.240 | 42.376 | 152.65 | 200.53 | 2.67 MiB | 1.00x (baseline) |

#### Scenario B: 4-Stage Color Space Pipeline `sRGB → Oklch → Display-P3 → Lab → sRGB` (408,400 ops)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `rust_color`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_css_color` (`--release`, pure f64 bit-exact) | 111.433 | 111.086 | 120.446 | 272.85 | 2.55 MiB | 0.84x |
| `rust_color` (`0.3.3 --release`, f32 + libm) | 93.553 | 92.509 | 93.616 | 229.07 | 2.86 MiB | 1.00x (baseline) |

Note: `pion_css_color` uses hardware `Double::sqrt()` + O(1) bit-level IEEE-754 `f64` math (`Double::to_bits`/`Double::from_bits`, Estrin-scheme Chebyshev transfer functions, 2-Halley `cbrt`) with zero `extern "C"` for 100% Native/Wasm32 bit-determinism, whereas Rust `color` uses `f32` with platform `libm`.
