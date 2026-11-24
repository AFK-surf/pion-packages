# `opentype` (v0.1.0)

Pure Pion OpenType / TrueType (SFNT + TTC) binary font parser — with zero external dependencies, zero `extern "C"`, zero `World` dependency, zero mutable module globals, and full Wasm32 compatibility.

## Features

- **SFNT & TrueType Collection (TTC) Container Parsing**:
  - Supports TrueType (`0x00010000`), CFF OpenType (`OTTO`), Apple TrueType (`true`), and TrueType Collections (`ttcf` v1.0 / v2.0 via `fonts_in_collection` and `Face::parse(data, face_index)`).
  - O(log N) binary-search table directory lookup (`table_data`, `table_data_by_name`) with 64-bit overflow-safe offset/length bounds checking and `max_num_tables` / `max_ttc_fonts` DoS guards.
- **Core Metadata & Metrics Tables**:
  - `head`: `units_per_em`, global bounding box (`x_min`/`y_min`/`x_max`/`y_max`), `mac_style`, `lowest_rec_ppem`, `index_to_loc_format`, and `magicNumber == 0x5F0F3CF5` validation.
  - `maxp`: v0.5 (CFF) and v1.0 (TrueType) `num_glyphs`.
  - `hhea` + `hmtx` & `vhea` + `vmtx`: `glyph_hor_advance`, `glyph_hor_side_bearing`, `glyph_ver_advance`, `glyph_ver_side_bearing` (correctly reusing the final advance metric for `gid >= number_of_h_metrics` / `number_of_v_metrics`).
  - `OS/2`: `weight_class`, `width_class`, `fs_selection`, `typo_ascender`/`typo_descender`/`typo_line_gap`, `x_height`/`cap_height` (v2+), subscript/superscript, strikeout, and 10-byte `panose`.
  - `post`: `italic_angle_fixed` / `italic_angle()`, `underline_position`, `underline_thickness`, `is_fixed_pitch`.
  - `name`: UTF-16BE (with full surrogate pair decoding) and Mac Roman decoding; `family_name`, `subfamily_name`, `full_name`, `postscript_name`, `typographic_family`, `typographic_subfamily`, `name_by_id`, and bounded `name_records()`.
- **Full `cmap` Character-to-Glyph Mapping (Formats 0, 4, 6, 10, 12, 13, 14)**:
  - Canonical subtable priority selection (Unicode full repertoire Format 12/13/10 > Unicode BMP Format 4 > Format 6/0 > Windows Symbol `(3, 0)` with `U+0000..U+00FF -> U+F000..U+F0FF` remapping), pre-resolved and deduplicated during `Face::parse` for O(log N) binary search and zero giant allocations. Legacy Mac Roman `(1, 0)` subtables are not indexed with Unicode scalar values; UTF-16 surrogates (`U+D800..U+DFFF`) and `.notdef` (glyph 0) return `None`.
  - Format 14 Unicode Variation Sequences (`glyph_variation_index(codepoint, variation_selector) -> Option[VariationGlyph]` returning `UseDefault` / `Found(gid)` / `None`).
- **Kerning (`kern`) & Variable Fonts (`fvar` / `avar`)**:
  - `kern` Format 0 (both OpenType v0, including >64 KiB last subtables whose `u16` length wraps, and Apple AAT v1.0) O(log N) binary search via `kerning(left_gid, right_gid)`.
  - `fvar` variation axes (`variation_axes`) and named instances (`named_instances`, mapping `postScriptNameID == 0xFFFF` to `None`), plus `avar` segment maps (`avar_segments`) and `normalize_variation_coords` (spec-compliant 16.16 fixed-point normalization and `avar` remapping with `+2 >> 2` conversion to F2Dot14 `[-16384, 16384]`).
- **TrueType Glyph Outlines & Bounding Boxes (`loca` + `glyf`)**:
  - Short (`index_to_loc_format == 0`) and long (`1`) `loca` tables.
  - Simple glyphs (multi-contour, on-curve/off-curve quadratic Bézier decoding, implicit midpoint expansion, `REPEAT_FLAG` overflow guard) and compound glyphs (`ARG_1_AND_2_ARE_WORDS`, `ARGS_ARE_XY_VALUES`, anchor-point matching when `!ARGS_ARE_XY_VALUES`, `SCALED_COMPONENT_OFFSET`, uniform scale, XY scale, full 2×2 affine transforms).
  - Strict DoS & cycle guardrails: ancestor cycle detection (`A -> B -> A` and self-loops immediately return `Err`), `max_compound_depth = 16`, `max_compound_components = 1024`, `max_glyph_points = 65536`, `max_glyph_contours = 8192`, with atomic rollback of `OutlineBuilder` commands on error.
  - `glyph_bounding_box(gid)` and `outline_glyph(gid, builder)` emitting `MoveTo` / `LineTo` / `QuadTo` / `Close`.

## Usage

```pion
import "opentype"

match opentype::Face::parse(font_bytes, 0) {
  Ok(face) => {
    let upem = face.units_per_em()
    match face.glyph_index(0x41) {
      Some(gid) => {
        let adv = face.glyph_hor_advance(gid)
        let ob = opentype::OutlineBuilder::new()
        let _ = face.outline_glyph(gid, ob)
      }
      None => ()
    }
  }
  Err(_) => ()
}
```

## Verification

```sh
sh scripts/verify.sh packages/opentype
sh packages/opentype/bench/run_bench.sh
```

### Unit & Red-Team Security Suite

All 33 unit, ported `ttf-parser` regression, and adversarial security test cases in `src/opentype_test.pion` pass using 100% in-memory synthesized SFNT/TTC fixtures (zero third-party `.ttf`/`.otf`/`.ttc` files committed to the repository).

### 4-Mode Verification (`wasm_smoke`)

`packages/opentype/wasm_smoke` builds and runs cleanly across `native debug`, `native --release`, `wasm32 debug`, and `wasm32 --release` with byte-identical stdout:

- Stdout: `opentype_wasm_smoke: OK glyphs=3 cmds=4 fnv64=3240767612368691165`
- Stdout SHA-256: `c6ff6601c00f35604a1d44c21c8301f64a0ac68b62ac33594ae0ec0b168e2cda`
- Wasm32 binary size: `71,499 B` (debug) / `71,725 B` (`--release`)

### Differential Oracle vs Rust `ttf-parser 0.25.1` (`--release`)

Verified via `sh packages/opentype/bench/run_bench.sh` across **8 font faces** (1 program-synthesized 512-glyph variable font + 7 read-only macOS system font faces; on environments without macOS system fonts, the script automatically falls back to the synthesized corpus):

- **Corpus tested (8/8 PASS, 0 deviations)**:
  - Synthesized fallback: `synthetic_512.ttf` (512 glyphs, 511 `cmap`, 128 `kern` pairs, 2 `fvar` axes, 2,555 outline commands) — **0 deviations**
  - System fonts (read in-place, never committed):
    - `Arial.ttf` (3,381 glyphs, 2,792 `cmap`, 104 `kern` pairs, 12,973 outline commands) — **0 deviations**
    - `Georgia.ttf` (1,134 glyphs, 1,111 `cmap`, 22,515 outline commands) — **0 deviations**
    - `Times New Roman.ttf` (3,380 glyphs, 2,790 `cmap`, 113 `kern` pairs, 17,515 outline commands) — **0 deviations**
    - `Courier New.ttf` (3,151 glyphs, 2,762 `cmap`, 19,630 outline commands) — **0 deviations**
    - `Helvetica.ttc` face 0 & face 1 (6-face TTC, 2,252 glyphs each, 2,067 `cmap`, 104/101 `kern` pairs, 13,216/12,902 outline commands) — **0 deviations**
    - `SFNS.ttf` (4-axis Variable Font, 2,954 glyphs, 1,686 `cmap`, 16,487 outline commands) — **0 deviations**
- Differential checks in `bench/run_bench.sh` cover: TTC face count, `head` (`units_per_em`, global bbox), `hhea`, `OS/2`, `post`, full Unicode `0..=0x10FFFF` `cmap` FNV-1a digest (excluding surrogates and `.notdef`), full `0..num_glyphs` `hmtx` digest, `kern` pair matrix digest for `gid < 256`, full `glyf` bbox digest, `glyf` outline command stream digest for `gid < 512` (quantized to 1/16 font unit), and `fvar` axis table digest.

### Head-to-Head Steady-State Benchmarks vs Rust `ttf-parser 0.25.1`

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, byte-identical stdout SHA-256 verified; workload = 200 iterations of lazy `Face::parse` + 256 `cmap`/`hmtx` lookups + 64 `glyf` outlines). Because `Face::parse` is lazy and touches only the queried tables rather than scanning the entire file, per-iteration latency (µs/op) and speedup ratio are reported instead of whole-file-size MB/s throughput:

#### System Font (`Arial.ttf`, 755 KiB, 200 iterations)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Peak RSS | µs/op | Speedup (vs `rust_ttf_parser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_opentype` (`--release`) | 14.544 | 14.148 | 15.034 | 3.45 MiB | 72.72 | 0.62x |
| `rust_ttf_parser` (`0.25.1 --release`, LTO) | 9.004 | 8.699 | 10.018 | 2.72 MiB | 45.02 | 1.00x (baseline) |

- Verified stdout SHA-256: `844d1e676bcb6b0bf0569fb430e6ab7f76fc845c5350445de896495bc37f5b7c`

#### Synthesized Variable Font (`synthetic_512.ttf`, 22.8 KiB, 200 iterations, `Linux x86_64`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Peak RSS | µs/op | Speedup (vs `rust_ttf_parser`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_opentype` (`--release`) | 4.466 | 4.098 | 4.741 | 10.90 MiB | 22.33 | 0.67x |
| `rust_ttf_parser` (`0.25.1 --release`, LTO) | 2.988 | 2.772 | 3.342 | 11.29 MiB | 14.94 | 1.00x (baseline) |

- Verified stdout SHA-256: `743e55b9beb82d9cda6edd244071c1bfac6f1f34b38520bbd4ad4aae3928f3f7`
