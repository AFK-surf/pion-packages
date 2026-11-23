# `pdf` — Pure Pion ISO 32000-1 PDF 1.4 Generator & Structural Validator

A pure Pion, zero-`World`, zero-`extern "C"` PDF 1.4 document builder and structural validator, upgraded from Farview's `pdf_export` engine and backed by `packages/flate` for RFC 1950 `/FlateDecode`.

## Features

- **Compression Filters (`src/filter.pion`)**:
  - `/FlateDecode` (RFC 1950 zlib via `flate::zlib_compress` / `flate::zlib_decompress_with_limit`).
  - `/RunLengthDecode` (ISO 32000-1 §7.4.5 PackBits `rle_encode` / `rle_decode`, preserving full Farview compatibility).
  - Uncompressed streams (`Compression::Uncompressed`).
- **General-Purpose PDF 1.4 Builder (`src/doc.pion`, `src/content.pion`)**:
  - Multi-page documents (`PdfDoc`, `Page`, `ContentStream`) with `PageSize::a4()` / `PageSize::letter()` / custom pt dimensions.
  - Document metadata (`/Info`: Title, Author, Subject, Keywords, Creator, Producer) with strict ISO 32000-1 §7.3.4.2 string escaping (`escape_pdf_string`) against parenthesis/backslash/newline/control-char injection.
  - Exact 10-digit byte-offset `xref` table, `/Root`, `/Size`, `startxref`, and `%%EOF` emitted via a single `ByteBuf` hot path with zero-allocation ASCII integer/fixed-point formatters (no scientific notation).
  - **Text**: All 14 PDF Standard Type 1 fonts (`Helvetica`, `Helvetica-Bold`, `Times-Roman`, `Courier`, `Symbol`, `ZapfDingbats`, etc.); only used fonts are emitted.
  - **2D Vector Graphics**: `save`/`restore`, `concat_matrix`, `set_fill_rgb`/`set_stroke_rgb`/`set_fill_gray`/`set_stroke_gray`, `set_line_width`/`set_line_cap`/`set_line_join`/`set_miter_limit`/`set_dash`, `move_to`/`line_to`/`cubic_to`/`rect`/`close_path`, `fill`/`fill_even_odd`/`stroke`/`close_and_stroke`/`fill_and_stroke`/`clip`/`clip_even_odd`.
  - **Images**: `add_rgb_image`, `add_rgba_image` (`AlphaMode::BlendWhite` white-paper compositing or `AlphaMode::SoftMask` `/SMask` `DeviceGray` transparency), `add_jpeg_image` (zero-recompression `/DCTDecode` passthrough with SOF color-space detection), plus Farview-compatible `encode_pdf_pages` / `encode_pdf_pages_with_compression`.
- **Resource Limits (`Limits`)**:
  - Explicit `Result[T, PdfError]` error handling with configurable `max_pages`, `max_objects`, `max_stream_bytes`, `max_document_bytes`, and `max_image_pixels`.
- **Structural Validator (`src/validate.pion`)**:
  - `validate_pdf(bytes)` verifies `%PDF-1.x`, `startxref`, every 20-byte `xref` entry and exact `N G obj` byte alignment, every stream's exact `/Length` to `endstream`/`endobj`, `trailer` `/Size` & `/Root`, `/Catalog`, and `/Pages /Count`.

## Quick Start

```pion
import "pdf"

let doc = pdf::PdfDoc::new()
doc.set_title("Quarterly Report")
doc.set_author("Pion")

let page = pdf::Page::a4()
page.set_fill_rgb(0.15, 0.39, 0.92)
page.rect(40.0, 740.0, 515.28, 60.0)
page.fill()
page.set_fill_rgb(1.0, 1.0, 1.0)
page.text(52.0, 764.0, 18.0, pdf::StandardFont::HelveticaBold, "Hello, PDF 1.4!")

let _ = doc.add_page(page)
let bytes = doc.encode()
```

## Verification

- **Unit & Spec Suite**: `sh scripts/verify.sh --allow-dirty packages/pdf` — **28 / 28 passing** (`flate` 20/20 + `pdf` 8/8), 0 diagnostics, `pionc fmt --check` clean.
- **Four-Mode `wasm_smoke`** (`packages/pdf/wasm_smoke`): Native debug, Native `--release`, Wasm32 debug, and Wasm32 `--release` all exit `0` with byte-identical stdout SHA-256 (`568b565d39b9f0a2...`).
- **Third-Party Parser Interop**: All generated PDFs (`report100`, `images_flate`, `images_rle`) parse cleanly under Rust `lopdf 0.35` with matching object and page counts.

## Benchmarks (`packages/pdf/bench/run_bench.sh`)

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) against **Rust `pdf-writer 0.12.1` + `flate2 1.1` (`rust_backend`, `--release`)**:

| Workload | Pion Median | Rust `pdf-writer` Median | Pion Throughput / ns/op | Pion Peak RSS | Rust Peak RSS | Speedup vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100-Page Vector + Text Report (`/FlateDecode`) | 37.32 ms | 22.89 ms | 373.2 us/page | 4.12 MiB | 6.36 MiB | 0.61× |
| 10-Page 800×600 RGBA Image Export (`/FlateDecode`, 14.4 MB RGB) | 254.77 ms | 116.13 ms | 56.52 MB/s | 24.62 MiB | 27.61 MiB | 0.46× |
| 10-Page 800×600 RGBA Image Export (`/RunLengthDecode`, 14.4 MB RGB) | 120.20 ms | 62.62 ms | 119.80 MB/s | 55.41 MiB | 38.20 MiB | 0.52× |

- **Output sizes**: `report100` Pion `93 KB` vs Rust `97 KB`; `images_flate` Pion `834 KB` vs Rust `814 KB`; `images_rle` Pion `11 MB` vs Rust `11 MB`.
- **Honest notes**: Pion achieves `0.46–0.61×` of Rust `--release` across all three workloads with lower peak RSS on `report100` (`4.12` vs `6.36 MiB`) and `images_flate` (`24.62` vs `27.61 MiB`). The remaining gap in image export is dominated by scalar byte loops in `rgba_to_white_rgb`, `rle_encode`, and `flate` LZ77 vs LLVM auto-vectorized Rust.
