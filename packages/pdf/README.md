# `pdf` — Pure Pion ISO 32000-1 PDF 1.4 Generator & Structural Validator

A pure Pion, zero-`World`, zero-`extern "C"` PDF 1.4 document builder and structural validator, upgraded from Farview's `pdf_export` engine and backed by `packages/flate` for RFC 1950 `/FlateDecode`.

## Features

- **Compression Filters (`src/filter.pion`)**:
  - `/FlateDecode` (RFC 1950 zlib via `flate::zlib_compress` / `flate::zlib_decompress_with_limit`).
  - `/RunLengthDecode` (ISO 32000-1 §7.4.5 PackBits `rle_encode` / `rle_decode`, single pre-allocated output buffer, preserving full Farview compatibility).
  - Uncompressed streams (`Compression::Uncompressed`).
- **General-Purpose PDF 1.4 Builder (`src/doc.pion`, `src/content.pion`)**:
  - Multi-page documents (`PdfDoc`, `Page`, `ContentStream`) with `PageSize::a4()` / `PageSize::letter()` / custom pt dimensions enforced within ISO 32000-1 / PDF 1.4 Annex C `[3.0, 14400.0]` pt; `add_page` freezes an immutable snapshot of each page.
  - Document metadata (`/Info`: Title, Author, Subject, Keywords, Creator, Producer) with ISO 32000-1 §7.9.2.2 text string encoding (ASCII literal strings with strict `escape_pdf_string`, non-ASCII encoded as UTF-16BE with `FE FF` BOM).
  - Exact 10-digit byte-offset `xref` table, `/Root`, `/Size`, `startxref`, and `%%EOF` emitted via an overflow-safe budgeted `ByteBuf` with zero-allocation ASCII integer/fixed-point formatters (no scientific notation, exact integer parts up to `1e14`, up to 12 fractional digits for small-scale transforms).
  - **Text**: All 14 PDF Standard Type 1 fonts (`Helvetica`, `Helvetica-Bold`, `Times-Roman`, `Courier`, `Symbol`, `ZapfDingbats`, etc.) emitted on demand; Latin text fonts transcode UTF-8 to `/WinAnsiEncoding` (cp1252).
  - **2D Vector Graphics**: `save`/`restore` (with `q`/`Q` balance & underflow checking), `concat_matrix` (singular-matrix guard), `set_fill_rgb`/`set_stroke_rgb`/`set_fill_gray`/`set_stroke_gray`, `set_line_width`/`set_line_cap`/`set_line_join`/`set_miter_limit`/`set_dash` (operand-range validated), `move_to`/`line_to`/`cubic_to`/`rect`/`close_path`, `fill`/`fill_even_odd`/`stroke`/`close_and_stroke`/`fill_and_stroke`/`clip`/`clip_even_odd`.
  - **Images**: `add_rgb_image`, `add_rgba_image` (`AlphaMode::BlendWhite` division-free white-paper compositing or `AlphaMode::SoftMask` `/SMask` `DeviceGray` transparency), `add_jpeg_image` (zero-recompression `/DCTDecode` passthrough with full SOF0–SOF15 dimension/component validation and Adobe APP14 CMYK `/Decode [1 0 1 0 1 0 1 0]` inversion), per-document `ImageId` ownership tags, O(1) resource deduplication, plus Farview-compatible `encode_pdf_pages` / `encode_pdf_pages_with_compression`.
- **Resource Limits (`Limits`)**:
  - Explicit `Result[T, PdfError]` error handling with early enforcement of `max_pages`, `max_objects`, `max_stream_bytes`, `max_document_bytes`, and `max_image_pixels` (strict `<= 0` means 0 allowed, never unlimited), plus per-`ContentStream` byte budget.
- **Structural Validator (`src/validate.pion`)**:
  - `validate_pdf(bytes)` is an O(N), `Int64`-overflow-safe structural validator for standard xref-table PDF 1.4 documents (such as this package's output): it checks `%PDF-1.x`, `startxref`, `xref` entry bounds before allocation, exact 10-digit `Int64` byte offsets to `N G obj`, exact stream `/Length` to `endstream`/`endobj`, `trailer` `/Size` & `/Root`, `/Catalog`, and `/Pages /Count`. It is intended as a strict structural self-validator rather than a general-purpose PDF 1.5+ xref-stream or incremental-update parser.

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

- **Unit & Spec Suite**: `sh scripts/verify.sh packages/pdf` — **28 / 28 passing** (`flate` 20/20 + `pdf` 8/8), 0 diagnostics, `pionc fmt --check` clean.
- **Red-Team Security & Compliance Suite**: `packages/pdf/audit/redteam_test.pion` — **30 / 30 passing** (`p0` 1/1, `p1` 8/8, `p2` 12/12, `control` 9/9); hostile inputs (`v_length_wrap`, `v_xref_50m`, `v_quadratic_40k` in 6 ms, `bigtext 1100 MiB`, `r_bomb_2g`) all handled cleanly without panic, hang, or OOM.
- **Four-Mode `wasm_smoke`** (`packages/pdf/wasm_smoke`): Native debug, Native `--release`, Wasm32 debug, and Wasm32 `--release` all exit `0` with byte-identical stdout SHA-256 (`568b565d39b9f0a2...`).
- **Third-Party Parser Interop**: All generated benchmark & audit PDFs (`report100`, `images_flate`, `images_rle`, `inject`, `floats`, `images`, `vector14`, `aliased_pages`) parse cleanly under Rust `lopdf 0.35.0`.

## Benchmarks (`packages/pdf/bench/run_bench.sh`)

Measured on `Darwin arm64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) against **Rust `pdf-writer 0.12.1` + `flate2 1.1` (`rust_backend`, `--release`)**:

| Workload | Pion Median | Rust `pdf-writer` Median | Pion Throughput / ns/op | Pion Peak RSS | Rust Peak RSS | Speedup vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100-Page Vector + Text Report (`/FlateDecode`) | 22.71 ms | 14.57 ms | 227.1 us/page | 4.11 MiB | 6.36 MiB | **0.64×** |
| 10-Page 800×600 RGBA Image Export (`/FlateDecode`, 14.4 MB RGB) | 75.77 ms | 74.52 ms | 190.06 MB/s | 24.62 MiB | 27.61 MiB | **0.98×** |
| 10-Page 800×600 RGBA Image Export (`/RunLengthDecode`, 14.4 MB RGB) | 64.56 ms | 37.54 ms | 223.05 MB/s | 55.41 MiB | 38.20 MiB | **0.58×** |

- **Output sizes**: `report100` Pion `93 KB` vs Rust `97 KB`; `images_flate` Pion `833 KB` vs Rust `814 KB`; `images_rle` Pion `11 MB` vs Rust `11 MB`.
- **Honest notes**: On `images_flate`, Pion is effectively tied with Rust `--release` (`0.98×`, lower Peak RSS `24.62` vs `27.61 MiB`). On `report100` (`0.64×`, lower Peak RSS `4.11` vs `6.36 MiB`), per-stream `flate` state initialization accounts for ~11 ms of the 22.7 ms total. On `images_rle` (`0.58×`), scalar PackBits scanning and byte-by-byte buffer copying account for the remaining gap vs LLVM auto-vectorized Rust.
