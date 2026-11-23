# `svg` (`packages/svg` v0.1.0)

Pure-Pion SVG 1.1/2 Path Data, 2D Affine Transform, Exact Analytical Geometry, Color/Style, Iterative DOM, Shape-to-Path, and SVGO-class Optimization library.

- **Zero C dependencies**, **zero external package dependencies**, **no `World`**
- **Native + Wasm32** dual-target with deterministic pure-Pion IEEE-754 trigonometry (byte-for-byte identical across Native debug/release and Wasm32 debug/release)
- **Built-in DoS protection** via `SvgLimits` (`max_depth`, `max_elements`, `max_path_segments`, `max_flatten_points`, `max_input_bytes`) and explicit-stack iterative parsing/flattening/traversal

## Features

1. **W3C SVG 1.1/2 Path Data (`src/path.pion`)**
   - `parse_path` / `parse_path_with_limits`: all 20 commands (`M/m/L/l/H/h/V/v/C/c/S/s/Q/q/T/t/A/a/Z/z`), implicit `L/l` after `M/m`, concatenated numbers (`1.2.3-4e-2`), and compact no-space arc flags (`a25 25 0 0150 25`).
   - `to_absolute`: converts relative subpaths & `z` resets to absolute coordinates.
   - `to_cubic_beziers` / `to_cubic_beziers_with_limits`: W3C SVG 1.1 Appendix F.6.5/F.6.6 elliptical arc to cubic Bézier conversion, quadratic degree elevation, and smooth `S`/`T` reflection.
   - `format_path(path, precision)`: SVGO-level compact serialization (drops leading zeros `0.5` -> `.5`, omits redundant spaces before `-`, `.`, and between arc flags).
2. **2D Affine Transforms & ViewBox (`src/transform.pion`)**
   - `Transform2D` (`val struct`, 6×`Double`): `identity`, `translate`, `scale`, `rotate`, `rotate_around`, `skew_x`, `skew_y`, `multiply`, `determinant`, `invert`, `apply_point`.
   - `parse_transform`, `transform_path`, `transform_cubics`.
   - `parse_viewbox`, `parse_preserve_aspect_ratio`, `viewbox_transform` (`none`, `meet`, `slice`, all 9 alignment modes).
3. **Exact Analytical Geometry (`src/geometry.pion`)**
   - `path_bbox` / `cubics_bbox`: exact tight bounding box by solving cubic first-derivative roots (`B'(t) = 0`), never loose control-point hulls.
   - `flatten_path` / `flatten_path_with_limits`: iterative adaptive De Casteljau subdivision within geometric tolerance `tolerance`.
   - `path_length`: adaptive 5-point Gauss-Legendre numerical integration.
4. **Colors, Paint & Lengths (`src/color.pion`)**
   - `parse_color`: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()` (comma & CSS4 space/slash syntax, `%` channels), `hsl()`/`hsla()`, `transparent`, and all **148 SVG/CSS named colors** (`lookup_svg_color`).
   - `parse_paint`: `none`, `currentColor`, `url(#...)`, or solid color.
   - `parse_length`: unitless, `px`, `pt`, `pc`, `mm`, `cm`, `in`, `%`.
5. **Iterative SVG DOM, Shapes & Render Path Extraction (`src/dom.pion`)**
   - `parse_svg` / `parse_svg_with_limits`: flat-array iterative XML/SVG DOM parser (no DTD expansion, zero recursion).
   - `shape_to_path`: converts `rect` (with `rx`/`ry`), `circle`, `ellipse`, `line`, `polyline`, `polygon`, and `path`.
   - `extract_render_paths`: walks DOM skipping `<defs>`/`<metadata>`/`display:none`, composes ancestor `transform` matrices, resolves inherited styles with inline `style="..."` override.
6. **SVGO-class Optimizer (`src/optimize.pion`)**
   - `optimize_svg(src, opts)`: removes XML declarations, comments, `<metadata>`, empty `<g>`, collapses attribute-less `<g>`, optionally converts basic shapes to paths, minifies color values, and compacts path `d` attributes.

## Verification

```sh
sh scripts/verify.sh packages/svg
```

- **28 / 28** unit, compliance, edge-case, and DoS tests passing.
- **4-mode `wasm_smoke`** (Native debug, Native release, Wasm32 debug, Wasm32 release): all exit `0` with identical stdout SHA-256:
  `130eef15a487da10738427e9b9f4c91c0b3a8bdd020992b32d3679d1a3cf8c02`

## Benchmarks

Run on `Darwin arm64` (`--warmup 1 --rounds 5`, strictly interleaved via `scripts/bench_compare.py`, all artifacts in `/private/tmp/w14-svg-bench`):

```sh
sh packages/svg/bench/run_bench.sh
```

### W1: 50,000 Complex SVG Paths (Parse + Cubic Normalize + Exact Analytical BBox)
Input: `3,836,510 B` (`50,000` paths) | Verified stdout SHA-256: `2afc7ef343f98bf7f5a1ba6f7a6d243a3ef0418878cb9999551dff7ad508a4c8`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_svgtypes`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 63.962 | 63.223 | 64.298 | 59.98 | 1279.24 | 11.83 MiB | 0.43x |
| `rust_svgtypes` (`svgtypes 0.15.3`) | 27.358 | 26.954 | 27.556 | 140.23 | 547.17 | 5.59 MiB | 1.00x (baseline) |

### W2: 2,000 Nested SVG Icons (DOM + Transforms + Shapes→Path + Exact BBox)
Input: `1,742,279 B` (`2,000` icons) | Verified stdout SHA-256: `f54a394e192f804f3e38a938cb4342ed67e7221556aa301e442639e321cb141d`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 26.246 | 25.987 | 27.194 | 66.38 | 13122.83 | 5.80 MiB | 0.61x |
| `rust_roxmltree_svgtypes` (`roxmltree 0.20.0` + `svgtypes 0.15.3`) | 16.003 | 15.617 | 16.148 | 108.87 | 8001.40 | 3.95 MiB | 1.00x (baseline) |

### W3: 2,000 SVG Icons Optimization
Input: `1,742,279 B` (`2,000` icons, `1,720,290 B` icon payload)

- **W3a (Exact byte-for-byte SHA-256 parity: `dd7a5dad3b2798fe557f9ff9f2ff9441ab6bfa9ecf3353aa63813059876f1595`)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Output Size | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 21.660 | 21.592 | 22.843 | 80.44 | 10830.08 | 5.89 MiB | 1,146,400 B (-33.4%) | 0.80x |
| `rust_roxmltree_svgtypes` | 17.232 | 16.523 | 17.492 | 101.11 | 8616.04 | 3.91 MiB | 1,146,400 B (-33.4%) | 1.00x (baseline) |

- **W3b (Node `svgo@3.3.2` reference on same 2,000 icons; SHA-256: `0775ffca382b0d6de636e768d708c52b9556bddf285cb8c4cf2c40ed078157b6`)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Output Size |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `node_svgo` (`svgo@3.3.2`, Node v24.22.2) | 523.072 | 517.500 | 528.559 | 3.33 | 261535.75 | 176.84 MiB | 885,794 B (-48.5%) |

### Honest Performance Summary
- Against Rust `--release` (`svgtypes` + `roxmltree`), pure-Pion achieves **0.43x** on pure path parsing/cubic/BBox (W1), **0.61x** on full DOM + transform + shape conversion (W2), and **0.80x** on SVG optimization/serialization (W3a), with low peak RSS (`5.8–11.8 MiB`). Main gap in W1 comes from allocating `SvgPath` segments before cubic normalization (whereas `svgtypes::PathParser` streams via an iterator) and software pure-Pion trig (`sin`/`cos`/`tan`/`acos`) for Wasm32 determinism.
- Against Node `svgo@3.3.2` on the same 2,000-icon corpus, Pion `optimize_svg` is **24.1x faster** (`21.7 ms` vs `523.1 ms`) with **30x lower peak RSS** (`5.89 MiB` vs `176.84 MiB`), while `svgo`'s default multi-plugin preset achieves deeper size reduction (`-48.5%` vs `-33.4%`) via extra passes such as `removeUselessDefs`, `convertStyleToAttrs`, and relative/absolute path command selection.
