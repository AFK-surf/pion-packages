# `exif` (v0.1.0)

Pure Pion TIFF 6.0 / EXIF 2.32 metadata and image orientation parser with zero-copy JPEG, WebP, and PNG container extraction, zero `extern "C"`, zero `World` dependency, zero external dependencies, and zero mutable module globals.

## Features

- **Multi-Container Extraction & Auto-Detection**:
  - `extract_from_jpeg`: scans JPEG markers starting at `0xFFD8`, skips arbitrary `0xFF` fill bytes and non-EXIF segments (`APP0`, `COM`, XMP `APP1`, standalone markers), locates `APP1 0xFFE1` with `"Exif\x00\x00"` header, stops at `SOS 0xFFDA` / `EOI 0xFFD9`, validates segment length `>= 2` and bounds.
  - `extract_from_webp`: validates `RIFF`/`WEBP` header, walks RIFF chunks with 2-byte even padding to locate `EXIF` chunk (compatible with both raw TIFF and `"Exif\x00\x00"`-prefixed payloads).
  - `extract_from_png`: validates 8-byte PNG signature, walks chunks to locate `eXIf` (stops at `IEND`, rejects chunk lengths `> 2^31 - 1`).
  - `parse` / `parse_with_limits`: auto-detects JPEG, WebP, PNG, or raw TIFF (`II\x2A\x00` / `MM\x00\x2A`) and parses directly on the input slice without copying the TIFF payload.
- **Complete TIFF 6.0 / EXIF 2.32 IFD Engine**:
  - Full Little-Endian (`II`) and Big-Endian (`MM`) support, including TIFF 6.0 left-aligned inline values (`count * type_size <= 4`) in Big-Endian (e.g. BE `Short(6)` stored as `00 06 00 00`).
  - Parses `IFD0` (`Primary`), `IFD1` (`Thumbnail`), `IFD2+` (`Other`), and sub-IFDs: `ExifIFD` (`0x8769`), `GPSInfoIFD` (`0x8825`), `InteropIFD` (`0xA005`).
  - All 12 standard TIFF/EXIF field types (`Byte`, `Ascii`, `Short`, `Long`, `Rational`, `SByte`, `Undefined`, `SShort`, `SLong`, `SRational`, `Float` via exact IEEE 754 binary32→binary64 widening, `Double`), including multi-value arrays and multi-string ASCII.
- **Browser & Photography Strongly-Typed API**:
  - `Orientation` enum (`Normal=1` .. `Rotate270CW=8`) with `from_int`, `to_int`, `cw_degrees`, `flip_horizontal`, and `swaps_dimensions` (`true` for 5/6/7/8). Transform order: rotate clockwise by `cw_degrees()`, then flip horizontally if `flip_horizontal()`.
  - Typed accessors: `orientation`, `color_space`, `make`, `model`, `software`, `date_time`, `date_time_original`, `date_time_digitized`, `pixel_x_dimension`, `pixel_y_dimension`, `x_resolution`, `y_resolution`, `exposure_time`, `f_number`, `iso_speed`, `focal_length`, `focal_length_35mm`, `lens_model`, `image_description`, `copyright`, `artist`.
  - GPS decoding: `gps_coords() -> Option[(Double, Double)]` (validates non-zero denominators, `N/S` & `E/W` signs, and `[-90, 90]` / `[-180, 180]` range) and `gps_altitude() -> Option[Double]`.
  - Generic inspection: `get(ifd, tag)`, `fields()`, `tag_name(ifd, tag)`, and deterministic `format_canonical()`.
- **Panic-Free Security Guard (`ExifLimits`)**:
  - Tracks visited IFD offsets to reject self-loops and mutual sub-IFD cycles (`InvalidIfd`).
  - Enforces `max_ifds` (32), `max_entries_per_ifd` (4096), `max_total_entries` (4096), and `max_payload_bytes` (4 MiB) with 64-bit overflow-safe length/offset arithmetic.

## Usage

```pion
import "exif"

match exif::parse(image_bytes) {
  Ok(meta) => {
    let ori = meta.orientation().unwrap_or(exif::Orientation::Normal)
    let swaps = ori.swaps_dimensions()
    let cs = meta.color_space()
    let coords = meta.gps_coords()
  }
  Err(e) => ()
}
```

## Verification & Benchmarks

```sh
sh scripts/verify.sh packages/exif
sh packages/exif/bench/run_bench.sh
```

### 4-Mode Verification (`wasm_smoke`)

`packages/exif/wasm_smoke` produces identical output across all 4 modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`):

- Output: `exif_wasm_smoke: OK checks=5 fnv64=13655980523038887051`
- SHA-256: `87f92b30cb019e7116d9996b19ef2de8a60e1700d9d723dba062cb0035d98ffa`

### Head-to-Head Benchmark vs Rust `kamadak-exif`

Measured on Darwin arm64 (`EXIF_BENCH_ITERS=25000 sh packages/exif/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved) against Rust `kamadak-exif v0.6.2` (`--release`, locked `Cargo.lock`). Workload parses a 4-container corpus (JPEG with APP0+XMP+EXIF, Big-Endian TIFF, WebP with odd-padded chunk + EXIF, PNG with `eXIf`; 2,619 B total, 25 tags/file across IFD0/ExifIFD/GPSIFD/InteropIFD/IFD1) 25,000 times (`100,000` parses, `65,475,000 B` input) and outputs canonical tag dumps for byte-for-byte SHA-256 verification.

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_kamadak_exif`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_exif` (`--release`) | **171.718** | **148.954** | **185.381** | **381.29** | **1717.18** | **1.94 MiB** | **1.01x** |
| `rust_kamadak_exif` (`0.6.2 --release`) | 173.922 | 162.159 | 193.601 | 376.46 | 1739.22 | 2.67 MiB | 1.00x (baseline) |

Canonical output SHA-256 (3,084 B, verified identical across both implementations and all rounds):
`aa3f9fec49a5f9b45ecbde9fb57902cad8eb282c98495a55d0575436d6218830`
