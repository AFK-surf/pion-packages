# `pdf` — Pure Pion ISO 32000-1 PDF 1.4 Generator & Structural Validator

A pure Pion, zero-`World`, zero-`extern "C"` PDF 1.4 document builder and structural validator, backed by `packages/flate` for RFC 1950 `/FlateDecode`.

## Features

- **Compression Filters (`src/filter.pion`)**:
  - `/FlateDecode` (RFC 1950 zlib via `flate::zlib_compress` / `flate::zlib_decompress_with_limit`).
  - `/RunLengthDecode` (ISO 32000-1 §7.4.5 PackBits `rle_encode` / `rle_decode`, single pre-allocated output buffer).
  - Uncompressed streams (`Compression::Uncompressed`).
- **General-Purpose PDF 1.4 Builder (`src/doc.pion`, `src/content.pion`)**:
  - Multi-page documents (`PdfDoc`, `Page`, `ContentStream`) with `PageSize::a4()` / `PageSize::letter()` / custom pt dimensions enforced within ISO 32000-1 / PDF 1.4 Annex C `[3.0, 14400.0]` pt; `add_page` freezes an immutable snapshot of each page.
  - Document metadata (`/Info`: Title, Author, Subject, Keywords, Creator, Producer) with ISO 32000-1 §7.9.2.2 text string encoding (ASCII literal strings with strict `escape_pdf_string`, non-ASCII encoded as UTF-16BE with `FE FF` BOM).
  - Exact 10-digit byte-offset `xref` table, `/Root`, `/Size`, `startxref`, and `%%EOF` emitted via an overflow-safe budgeted `ByteBuf` with zero-allocation ASCII integer/fixed-point formatters (no scientific notation, exact integer parts up to `1e14`, up to 12 fractional digits for small-scale transforms).
  - **Text**: All 14 PDF Standard Type 1 fonts (`Helvetica`, `Helvetica-Bold`, `Times-Roman`, `Courier`, `Symbol`, `ZapfDingbats`, etc.) emitted on demand; Latin text fonts transcode UTF-8 to `/WinAnsiEncoding` (cp1252).
  - **2D Vector Graphics**: `save`/`restore` (with `q`/`Q` balance & underflow checking), `concat_matrix` (singular-matrix guard), `set_fill_rgb`/`set_stroke_rgb`/`set_fill_gray`/`set_stroke_gray`, `set_line_width`/`set_line_cap`/`set_line_join`/`set_miter_limit`/`set_dash` (operand-range validated), `move_to`/`line_to`/`cubic_to`/`rect`/`close_path`, `fill`/`fill_even_odd`/`stroke`/`close_and_stroke`/`fill_and_stroke`/`clip`/`clip_even_odd`.
  - **Images**: `add_rgb_image`, `add_rgba_image` (`AlphaMode::BlendWhite` division-free white-paper compositing or `AlphaMode::SoftMask` `/SMask` `DeviceGray` transparency), `add_jpeg_image` (zero-recompression `/DCTDecode` passthrough with full SOF0–SOF15 dimension/component validation and Adobe APP14 CMYK `/Decode [1 0 1 0 1 0 1 0]` inversion), per-document `ImageId` ownership tags, O(1) resource deduplication, plus convenience `encode_pdf_pages` / `encode_pdf_pages_with_compression`.
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

Measured on `Linux x86_64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) against **Rust `pdf-writer 0.12.1` + `flate2 1.1` (`rust_backend`, `--release`)** (Peak RSS measured via `wait4` `ru_maxrss`):

| Workload | Pion Median (Opt) | Pion Median (Base `9f6e1634`) | Rust `pdf-writer` Median | Pion Opt Throughput / ns/op | Pion Peak RSS | Rust Peak RSS | Speedup vs Rust (vs Base) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100-Page Vector + Text Report (`/FlateDecode`) | 14.45 ms | 16.5–26.8 ms | 6.31 ms | 144.5 us/page | 5.85 MiB | 5.85 MiB | **0.44×** (**1.14×** vs base) |
| 10-Page 800×600 RGBA Image Export (`/FlateDecode`, 14.4 MB RGB) | 125.09 ms | 132–197 ms | 101.48 ms | 115.12 MB/s | 23.54 MiB | 23.30 MiB | **0.81×** (**~1.03×** vs base) |
| 10-Page 800×600 RGBA Image Export (`/RunLengthDecode`, 14.4 MB RGB) | 72.89 ms | 110–142 ms | 54.75 ms | 197.57 MB/s | 44.10 MiB | 33.30 MiB | **0.75×** (**1.51×** vs base) |

- **Output sizes**: `report100` Pion `93 KB` vs Rust `98 KB`; `images_flate` Pion `834 KB` vs Rust `814 KB`; `images_rle` Pion `11 MB` vs Rust `11 MB`.
- **Phase breakdown (`audit/probe perf`, best of 5)**:
  - `report100`: `build_content_ms=1`, `encode_uncompressed_ms=0`, `encode_flate6_ms=8` — `packages/pdf` content building + PDF assembly is ~1 ms total; the remaining ~8 ms is per-page `flate::zlib_compress` (100× 3.5 KB streams in `packages/flate`).
  - `images10`: `rgba_to_white_rgb_ms=19`, `rle_encode_ms=10` (~1.44 GB/s), `flate_encode6_ms=77`, `full_flate_ms=96`, `full_uncompressed_ms=26`.
- **Honest notes**: Zero-COW `FixedArray[Byte]` `ByteBuf` + zero-copy large-payload chunking + zero-allocation `write_int`/`write_num`/`write_pad10` + 4-byte unrolled ASCII escaping + single-pass fused scan+copy `rle_encode` improved `images_rle` by **1.51×** (and cut Peak RSS by **10.5 MiB**, from `54.61` to `44.10 MiB`) and `report100` by **1.14×** (with `packages/pdf` itself at ~1 ms). Remaining gap vs Rust `--release` on `report100` (`0.44×`) and `images_flate` (`0.81×`) is dominated by `packages/flate`'s `zlib_compress` (not modified by `packages/pdf`), and on `images_rle` (`0.75×`) by synthetic RGBA input generation and scalar QBE bounds-checked byte loops vs LLVM auto-vectorization.
