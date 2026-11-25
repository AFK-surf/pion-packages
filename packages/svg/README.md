# `svg` (`packages/svg` v0.1.0)

Pure-Pion SVG 1.1/2 Path Data, 2D Affine Transform, Exact Analytical Geometry, Color/Style, Iterative DOM, Shape-to-Path, and SVGO-class Optimization library.

- **Zero C dependencies**, **zero external package dependencies**, **no `World`**
- **Native + Wasm32** dual-target with deterministic pure-Pion IEEE-754 trigonometry (Payne-Hanek + 3-term Cody-Waite) and 0-ULP correctly-rounded IEEE-754 number parsing (Clinger fast path + exact BigInt fallback), byte-for-byte identical across Native debug/release and Wasm32 debug/release
- **Built-in DoS protection** via `SvgLimits` (`max_depth`, `max_elements`, `max_path_segments`, `max_flatten_points`, `max_input_bytes`) and explicit-stack iterative parsing/flattening/traversal

## Features

1. **W3C SVG 1.1/2 Path Data (`src/path.pion`)**
   - `parse_path` / `parse_path_with_limits`: all 20 commands (`M/m/L/l/H/h/V/v/C/c/S/s/Q/q/T/t/A/a/Z/z`), implicit `L/l` after `M/m`, concatenated numbers (`1.2.3-4e-2`), and compact no-space arc flags (`a25 25 0 0150 25`).
   - `parse_path_to_cubics` / `parse_path_to_cubics_with_limits`: streaming path-to-cubic normalizer avoiding intermediate `PathSegment` allocation.
   - `to_absolute`: converts relative subpaths & `z` resets to absolute coordinates.
   - `to_cubic_beziers` / `to_cubic_beziers_with_limits`: W3C SVG 1.1 Appendix F.6.5/F.6.6 elliptical arc to cubic Bézier conversion, quadratic degree elevation, and smooth `S`/`T` reflection.
   - `format_path(path, precision)`: SVGO-level compact serialization with relative-command rounding-error compensation (no cumulative drift) and safe large-coordinate formatting (never emits `inf`/`nan`).
2. **2D Affine Transforms & ViewBox (`src/transform.pion`)**
   - `Transform2D` (`val struct`, 6×`Double`): `identity`, `translate`, `scale`, `rotate`, `rotate_around`, `skew_x`, `skew_y`, `multiply`, `determinant`, scale-invariant `invert`, `apply_point`.
   - `parse_transform`, `transform_path`, `transform_cubics`.
   - `parse_viewbox` (rejecting zero/negative dimensions per SVG 2), `parse_preserve_aspect_ratio`, `viewbox_transform` (`none`, `meet`, `slice`, all 9 alignment modes).
3. **Exact Analytical Geometry (`src/geometry.pion`)**
   - `path_bbox` / `cubics_bbox`: scale-invariant exact tight bounding box by solving cubic first-derivative roots (`B'(t) = 0`) with cancellation-free quadratic formula.
   - `flatten_path` / `flatten_path_with_limits`: iterative adaptive De Casteljau subdivision strictly within geometric tolerance `tolerance` (`16 * tol^2` Wang/Hain bound).
   - `path_length`: scale-invariant adaptive 5-point Gauss-Legendre numerical integration with derivative-root pre-splitting.
4. **Colors, Paint & Lengths (`src/color.pion`)**
   - `parse_color`: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()` (comma & CSS4 space/slash syntax, `%` channels), `hsl()`/`hsla()`, `transparent`, and all **148 SVG/CSS named colors** (`lookup_svg_color`).
   - `parse_paint`: `none`, `currentColor`, `url(#...)`, or solid color.
   - `parse_length`: unitless, `px`, `pt`, `pc`, `mm`, `cm`, `in`, `%`.
5. **Iterative SVG DOM, Shapes & Render Path Extraction (`src/dom.pion`)**
   - `parse_svg` / `parse_svg_with_limits`: flat-array iterative XML 1.0 well-formedness DOM parser (full UTF-8 numeric character references up to `U+10FFFF`, namespace prefix validation, no DTD expansion, zero recursion).
   - `shape_to_path`: converts `rect` (with SVG 2 `rx`/`ry` `auto` & negative handling), `circle`, `ellipse`, `line`, `polyline`, `polygon`, and `path`.
   - `extract_render_paths`: walks DOM skipping non-render containers (`<defs>`, `<marker>`, `<metadata>`, `display:none`, etc.), resolves namespace prefixes, nested `<svg>` viewports, CSS comments/`!important`/percentage opacity, and isolates per-element attribute/path errors.
6. **SVGO-class Optimizer (`src/optimize.pion`)**
   - `optimize_svg(src, opts)`: linear `O(N)` bottom-up optimizer that removes XML declarations (keeping `<?xml-stylesheet?>`), comments, `<metadata>`, empty `<g>` (keeping `<g filter="...">`), collapses safe attribute-less `<g>` (preserving `<switch>` children and animated groups), preserves `<text>`/`<tspan>`/`xml:space="preserve"` whitespace, re-escapes attribute TAB/LF/CR, keeps alpha colors SVG 1.1-compatible, and compacts path `d` attributes.

## Verification

```sh
sh scripts/verify.sh packages/svg
sh packages/svg/audit/run_audit.sh
```

- **30 / 30** unit, compliance, edge-case, and DoS tests passing (`sh scripts/verify.sh packages/svg`).
- **Red-team audit (`run_audit.sh`)**: **P1 38/38 PASS, P2 69/69 PASS, controls 25/25 PASS, 9/9 4-mode byte parity, 56/56 DoS probes PASS**.
- **4-mode `wasm_smoke`** (Native debug, Native release, Wasm32 debug `277,144 B`, Wasm32 release `276,755 B`): all exit `0` with identical stdout SHA-256:
  `bc1fc7dd7b0a24143a3574d34c9ba1b21824065d92441bd5b72a093c173ad711`

## Benchmarks

Run on `Linux x86_64` (`--warmup 1 --rounds 7`, strictly interleaved via `scripts/bench_compare.py`):

```sh
sh packages/svg/bench/run_bench.sh
```

### W1: 50,000 Complex SVG Paths (Parse + Cubic Normalize + Exact Analytical BBox)
Input: `3,836,510 B` (`50,000` paths)

- **W1a (Exact SHA-256 parity: `2afc7ef343f98bf7f5a1ba6f7a6d243a3ef0418878cb9999551dff7ad508a4c8`, same W3C F.6.5 arc & exact BBox algorithm)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_svgtypes_same_algo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` (streaming `parse_path_to_cubics`) | 69.850 | 56.021 | 122.411 | 54.92 | 1397.00 | 9.21 MiB | 0.90x |
| `rust_svgtypes_same_algo` (`svgtypes 0.15.3` + same F.6.5/bbox) | 62.776 | 44.145 | 75.392 | 61.11 | 1255.52 | 6.51 MiB | 1.00x (baseline) |

- **W1b (Idiomatic upstream Rust reference: `svgtypes 0.15.3 SimplifyingPathParser` + `kurbo 0.11.3 BezPath::bounding_box`; SHA-256: `5b88be8cef2210a526ea79f4f52312e81542cd1fddd3aefeaa692cbb07ee576b`)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Relative (`pion` vs `kurbo`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `rust_svgtypes_kurbo` (`svgtypes` + `kurbo`) | 98.563 | 90.911 | 131.398 | 38.92 | 1971.27 | 6.45 MiB | `pion` is 1.41x |

_(Note: `kurbo`'s `SimplifyingPathParser` uses an internal arc approximation tolerance of `0.1`, so its rounded bbox checksum differs slightly from W3C F.6.5 90°-split; W1a provides exact byte-for-byte SHA-256 parity and W1b provides the idiomatic upstream Rust library comparison.)_

### W2: 2,000 Nested SVG Icons (DOM + Transforms + Shapes→Path + Exact BBox)
Input: `1,742,279 B` (`2,000` icons) | Verified stdout SHA-256: `f54a394e192f804f3e38a938cb4342ed67e7221556aa301e442639e321cb141d`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 37.020 | 32.707 | 42.074 | 47.06 | 18510.25 | 5.86 MiB | 0.54x |
| `rust_roxmltree_svgtypes` (`roxmltree 0.20.0` + `svgtypes 0.15.3`) | 19.937 | 18.961 | 21.804 | 87.39 | 9968.59 | 4.49 MiB | 1.00x (baseline) |

### W3: 2,000 SVG Icons Optimization
Input: `1,742,279 B` (`2,000` icons, `1,720,290 B` icon payload)

- **W3a (Exact byte-for-byte SHA-256 parity: `dd7a5dad3b2798fe557f9ff9f2ff9441ab6bfa9ecf3353aa63813059876f1595`)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Output Size | Speedup (vs Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 24.371 | 22.954 | 26.651 | 71.49 | 12185.45 | 6.11 MiB | 1,146,400 B (-33.4%) | 0.96x |
| `rust_roxmltree_svgtypes` (`roxmltree` + `svgtypes` + same passes) | 23.290 | 20.137 | 52.635 | 74.81 | 11644.85 | 4.11 MiB | 1,146,400 B (-33.4%) | 1.00x (baseline) |

- **W3b (Non-equivalent reference: Node `svgo@3.3.2` default ~30-plugin preset on same 2,000 icons; SHA-256: `0775ffca382b0d6de636e768d708c52b9556bddf285cb8c4cf2c40ed078157b6`)**

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Output Size |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `node_svgo` (`svgo@3.3.2`, Node v24.22.1; includes ~213 ms Node + `import('svgo')` startup) | 2618.113 | 2235.121 | 2756.117 | 0.67 | 1309056.50 | 183.98 MiB | 885,794 B (-48.5%) |

### Honest Performance Summary
- Against Rust `--release` running the exact same algorithm (SHA-256 verified), pure-Pion achieves **0.90x** on W1a (`69.9 ms` vs `62.8 ms`), **0.54x** on W2 (`37.0 ms` vs `19.9 ms`, where Pion also performs full CSS style cascade resolution), and **0.96x** on W3a (`24.4 ms` vs `23.3 ms`), with low peak RSS (`5.9–9.2 MiB`), while providing 0-ULP IEEE-754 number parsing, Payne-Hanek deterministic trigonometry (4-mode Native/Wasm32 bit-exact), and full XML 1.0 well-formedness.
- Against idiomatic upstream Rust (`svgtypes::SimplifyingPathParser` + `kurbo::BezPath::bounding_box`, W1b), pure-Pion (`69.9 ms`) is **1.41x faster** (`98.6 ms`).
- W3b (`node_svgo@3.3.2`) is reported as a **non-equivalent reference** (no speedup headline claimed): `svgo`'s default ~30-plugin preset achieves deeper size reduction (`-48.5%` vs `-33.4%`) via additional passes (`removeUselessDefs`, `convertStyleToAttrs`, relative/absolute path conversion), and its wall-clock time (`2618 ms`) includes ~213 ms of Node + ESM import startup cost (`184.0 MiB` RSS).

## Formal Verification (Lean 4)

The SVG resource limits, RGBA/hex color encoding & clamping kernels, and W3C SVG/XML lexical & path command kernels (`SvgLimits`, `SvgColor`, `hex_nibble_code`, `clamp_u8_int`, `is_valid_hex_color_len`, `hex3_channel_expand`, `hex_pair_to_byte`, `is_svg_ws`, `is_xml_ws`, `is_ascii_digit`, `hex_val`, `is_number_start`, `is_path_moveto`, `is_path_closepath`, `is_ident_char`) are annotated with `#verify` and formally verified in Lean 4 under `proofs/` (24 `0-sorry` theorems, standard axioms only, 44-case native-vs-Lean differential cross-check):

```bash
bash packages/svg/proofs/run_proofs.sh
```
