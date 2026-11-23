# Red-team audit: `packages/pdf` v0.1.0

Target: `packages/pdf` at `08cad25` (branch `feat/pkg-pdf`), `pionc 0.1.0`, Darwin arm64. Production code (`packages/pdf/src/`) is untouched; this directory only adds evidence.

Oracle: Rust `lopdf =0.35.0` + `flate2 =1.1.11` (`rust/`, pinned in `rust/Cargo.lock`). lopdf repairs broken files quietly, so the oracle also checks the raw bytes itself: xref offsets, 20-byte entries and every `/Length`. It also decodes RunLength streams itself, because lopdf has no RunLength decoder.

Reproduce everything with one command (about 3 minutes). Build output goes to `/private/tmp/redteam-pdf`, and `git status --porcelain --ignored` stays empty afterwards:

```sh
sh packages/pdf/audit/run_audit.sh            # QUICK=1: skip hang probes + bench; HEAVY=1: add the 3.4 GB xref probe
```

| Part | Contents |
|---|---|
| `redteam_test.pion` | 30 tests: 1 `p0_`, 8 `p1_`, 12 `p2_` (each failure is evidence) and 9 `control_` tests that must pass |
| `probe/` | Pion probe: `gen` (8 adversarial fixtures), `validate`, `rle`, `flate`, `rgba`, `split`, `bigtext`, `perf`; built for native and wasm32 |
| `rust/` | `oracle check` (lopdf plus raw-byte checks, 158 checks over 8 fixtures) and `oracle mkvalidate` (hostile inputs) |
| `scripts/make_jpegs.py` | Real PIL JPEGs at 16×8: gray, RGB, Adobe CMYK, progressive |
| `run_audit.sh` | Runs all of the above, plus a phase breakdown and the head-to-head benchmark |

Result: `pionc test --json -p pdf_audit packages/pdf/audit` gives `total=30 passed=9 failed=21`. All 21 p-tests fail (that failure is the evidence), and all 9 controls pass. The oracle reports `ORACLE_FAILS 14` and 144 PASS. Native and wasm32 write byte-identical fixtures, and the P0 panic reproduces under wasm32 too.

---

## P0: a tiny untrusted input crashes the process or exhausts memory

`validate_pdf(bytes)` is a public API that accepts arbitrary bytes. The README presents it as the package's structural validator.

### P0-1: `validate_pdf` aborts on `/Length 2147483600` (305-byte file)

`src/validate.pion:363`: `let s_data_end = s_data_start + slen` overflows 32-bit `Int` and goes negative. The bounds check `s_data_end > xref_off` then passes. At `:372`, `es_pos < xref_off && pdf[es_pos]` indexes with `es_pos = -2147483552`, and the process aborts.

```
validate v_length_wrap (305 B)     rc=134  | pion panic: index -2147483552 out of bounds (len 305)
  same, wasm32 under node          rc=1    | pion panic: index out of bounds: idx=-2147483552, len=305
```

Reproduce: `p0_validate_pdf_length_overflow_panics`, or `probe validate $T/hv/v_length_wrap.pdf`.

Fix: compute the end in `Int64` (or check `slen > xref_off - s_data_start` first). Reject `es_pos < 0`.

### P0-2: `validate_pdf` allocates `xref_count` entries before any bounds check (102 bytes → 813 MiB)

`:160-162` allocates three `FixedArray::make(xref_count, …)` from the header `xref\n0 <N>`. That happens before checking that `N × 20` bytes exist before `startxref`; only after that does the parser read the first entry and fail.

| Input | Size | Peak RSS | Result |
|---|---:|---:|---|
| `v_xref_50m.pdf` | 102 B | 813 MiB | `ERR non-digit in xref offset` (after allocating) |
| `v_xref_200m.pdf` (`HEAVY=1`) | 104 B | 3.4 GB | same |
| `0 2147483647` | 106 B | ≈36 GB extrapolated (not run on the shared Studio) | OOM abort |

Fix: `if xref_count > (sx_pos - pos) / 19 { Err(...) }` before allocating.

---

## P1: crashes and hangs needing large input, wrong output, and DoS

### P1-1: `ByteBuf::ensure` overflows at 1 GiB and spins forever, and `Limits` cannot stop it

`src/buf.pion:25-27`: `cap = len * 2` with a 32-bit `Int`. Once the buffer reaches 2^30 bytes, `cap` becomes `-2^31` and then `0`, so `while cap < n + extra { cap = cap * 2 }` never ends: 100% CPU, no error.

- **`ContentStream` has no limit at all.** `Limits.max_stream_bytes` is checked only in `encode()`, after the stream is built. One page with more than 1 GiB of drawing ops (for example, generated from untrusted HTML) hangs even with `Limits::default()`.
- **`rle_decode(src, 0)`**: `0` means "up to 2^31-1", so a 33 MiB input hangs once the buffer grows past 1056 MiB.

```
bigtext 1100 MiB content stream    rc=124  45.16s  1542 MiB | … content bytes=864000000 …  [KILLED by 45s timeout = hang]
rle r_bomb_2g (33 MiB) limit=0     rc=124  45.15s  1619 MiB |  [KILLED by 45s timeout = hang]
```

Fix: grow in `Int64` and fail cleanly at 2^31-1. Give `ContentStream` a byte budget, taken from the owning document's `Limits` or set explicitly.

### P1-2: `validate_pdf` is quadratic: 2.3 MB takes 14 s

`:281`: for each in-use object, `pdf_find_ascii(pdf, body_start, xref_off, ">>")` scans to the xref table. Objects without `>>` (arrays, numbers, `null`) rescan the rest of the file, and the brace-depth scan that follows is not bounded by `endobj` either.

| Objects | File | Time |
|---:|---:|---:|
| 20 k | 1.1 MB | 3.50 s |
| 40 k | 2.3 MB | 14.28 s (×4.1 for ×2 input) |

A 10 MB file of this shape would take about 4–5 minutes (extrapolated). Fix: limit every search to `endobj_pos`, and find `endobj` once per object.

### P1-3: the public pixel helpers overflow and abort

`rgba_to_white_rgb` and `rgba_split_rgb_alpha` (`src/filter.pion:142,179`) are `pub` and compute `count = width * height` and `count * 3` in 32-bit `Int` with no check. `PdfDoc` protects itself through `check_image_dims` before calling them, but anyone calling the public helpers directly does not get that protection.

```
rgba_to_white_rgb 40000 20000      rc=134 | pion panic … negative bytes length
rgba_split_rgb_alpha 46341 46341   rc=134 | pion panic … negative bytes length
rgba_to_white_rgb 65536 65536      rc=0   | -> 0 bytes   (wraps to 0: silent empty image)
```

Fix: apply the same `Int64` check, return `Result`, or make the helpers private.

### P1-4: `add_jpeg_image` trusts the caller's width and height

The SOF header says 16×8, but `add_jpeg_image(4000, 3000, jpeg)` writes `/Width 4000 /Height 3000`. The oracle reports `images.pdf page1_img_Im8_dct_dims_match_sof FAIL dict 4000x3000 vs SOF 16x8`. The dictionary and the JPEG stream then disagree about the image size; how a viewer handles that varies (an error or a distorted image). `detect_jpeg_color_space` already walks to the SOF; it should return W, H and the component count and reject a mismatch. Test: `p1_jpeg_dimensions_not_checked_against_sof`.

### P1-5: Adobe CMYK JPEGs render as negatives

Photoshop and PIL (APP14 `Adobe`) store CMYK inverted. Without `/Decode [1 0 1 0 1 0 1 0]`, every PDF viewer paints the photographic negative. The oracle uses a real PIL CMYK JPEG and reports `Im6_adobe_cmyk_decode_inverted FAIL`. Test: `p1_adobe_cmyk_jpeg_missing_decode_inversion`.

### P1-6: non-ASCII text is written as UTF-8 bytes into a `/WinAnsiEncoding` font (garbled text)

`ContentStream::text` writes the string's UTF-8 bytes as octal escapes. With WinAnsiEncoding, `é` (`\303\251`) renders as `Ã©`. lopdf `extract_text` of the fixture gives `"hÃ©llo â€” â€œquotesâ€• â‚¬"` and `"ä¸-æ–‡ ðŸ˜€"`. Characters outside cp1252 cannot be shown at all, and nothing reports that.

Fix: transcode to WinAnsi (cp1252), and fail or substitute for anything that cannot be mapped. For Symbol and ZapfDingbats, use their built-in encodings. Test: `p1_text_utf8_bytes_under_winansi_mojibake`.

### P1-7: `/Info` strings are not PDF text strings

ISO 32000-1 §7.9.2.2 says a text string without a BOM is PDFDocEncoding. The UTF-8 bytes written here read back through lopdf `decode_text_string` as `"hÃ©llo â•ﬂ â•œquotesâ•š …"`. Non-ASCII Title, Author and similar fields need UTF-16BE with a `FE FF` BOM. Test: `p1_info_non_ascii_not_encoded_as_text_string`.

### P1-8: `add_page` accepts `+Inf`, `1e20`, `1e-12` and `0.00004` and writes `/MediaBox [0 0 0 100]`

`src/doc.pion:300` rejects only NaN and `<= 0`. `write_num` then prints every one of these widths as `0`, so the result is a zero-area page that viewers reject or show blank. The oracle reports 4× `mediabox_sane FAIL [0.0, 0.0, 0.0, 100.0]`.

Fix: require finite values in `[3, 14400]` (PDF 1.4 Annex C) or a documented range. Test: `p1_add_page_accepts_infinite_and_unrepresentable_sizes`.

### P1-9: 4-decimal fixed point makes small-scale matrices singular

`concat_matrix(0.00001, 0, 0, 0.00001, 0, 0)` serializes as `0 0 0 0 0 0 cm`. The oracle reports `singular cm`. Everything drawn after it disappears, and strict viewers raise an error. `write_num` (`src/buf.pion:137`) rounds every operand to 1e-4 absolute, which is also a 5% relative error at a scale of 0.001.

Fix: print as many significant digits as needed (shortest round-trip, still without an exponent). Test: `p1_small_scale_matrix_becomes_singular_cm`.

---

## P2: API hardening and spec conformance

| # | Finding | Evidence |
|---|---|---|
| P2-1 | NaN, ±Inf and values with \|v\| > 1e14 are **silently written as `0`** (line width, colour, `Tf` size, coordinates) instead of being rejected. No `nan`, `inf` or exponent ever reaches the file (see controls), but values change without notice. | `p2_non_finite_and_huge_numbers_silently_zero`; oracle `Tf size 0` |
| P2-2 | `write_num` loses precision above 2^53/1e4: `99999999999999.0` prints as `99999999999999.0016`. | `p2_write_num_spurious_fraction_digits` |
| P2-3 | `set_line_cap(99)`, `set_line_join(-7)` and negative or all-zero dash arrays are emitted as is, giving invalid operands. | `p2_line_cap_join_dash_unvalidated`; oracle `J 99, j -7, dash [0,-3]` |
| P2-4 | Page sizes above 14400 units (the PDF 1.4 Annex C limit) are accepted. | `p2_page_size_above_14400_accepted`; oracle `[0,0,14400.5,14400.5]` |
| P2-5 | `encode()` of a document with no pages succeeds (`/Count 0 /Kids []`). | `p2_zero_page_document_encodes`; oracle `empty.pdf nonzero_pages` |
| P2-6 | `Page` is a shared mutable handle. Drawing after `add_page` changes the page already in the document, and adding one `Page` twice shares its stream. | `p2_page_mutable_after_add_page`; oracle `aliased_pages.pdf 2 Tj` |
| P2-7 | `ImageId` is a bare index (`pub index`). An id from document A silently draws document B's image with the same index (oracle: a 2×2 id resolved to a 1×1 image). Out-of-range ids are rejected (control). | `p2_foreign_image_id_draws_wrong_image` |
| P2-8 | `q`/`Q` balance is not tracked: `restore()` before `save()`, and unclosed `save()`, are both accepted. | `p2_unbalanced_graphics_state_not_detected` |
| P2-9 | JPEG SOF detection covers only C0–C3. A 4-component arithmetic SOF9 is tagged `/DeviceRGB`, a 2-component JPEG is accepted as RGB, and bytes `FF D8 00 00…` with no SOF are accepted as a JPEG. | `p2_jpeg_colorspace_detection_gaps` |
| P2-10 | `Limits` is checked late. Images are compressed and kept at `add_*` time with no document budget: ten 786 KiB images are held under a 64 KiB `max_document_bytes`. `max_objects` and `max_stream_bytes` for content are checked only in `encode()`. `max_document_bytes` is checked after each stream is written, so the buffer can overshoot by one stream plus a doubling. | `p2_limits_checked_after_data_is_retained`; P1-1 |
| P2-11 | A limit of `0`, or any negative value, means "unlimited" (`rle_decode`, `flate_decode`, every `Limits` field). `0` reads as "nothing allowed", which is the opposite. | `p2_zero_limit_means_unlimited` |
| P2-12 | `validate_pdf` truncates 10-digit xref offsets with `.to_int()` (`:206`), so `4294967305` is accepted as `9`. | `p2_validate_xref_offset_truncation_alias` |
| P2-13 | The README benchmark ratios do not reproduce. A re-run on the same Studio (load average about 20; it was over 100 earlier the same day) gives different results (see "Performance"): on the image/Flate workload, Pion is at 0.94×, not 0.46×, and on RunLength it is at 0.39×, not 0.52×. | `run_audit.sh` §5 |
| P2-14 | `validate_pdf` matches strings (`/Type /Page`, `/Length` anywhere in the dictionary, `/Type/Page` without a space is not counted). It only fits the generator's own output and is not a general PDF validator. The README should say so. | code review |

---

## Controls: attacks the package survived

- **String injection is closed.** In `/Info` and in `Tj`, every payload stays one literal string with the exact original bytes: `) /JS (…`, `\) /OpenAction`, unbalanced `(((`/`)))`, a trailing `\`, `CR`/`LF`/`>>\nendobj\n9 0 obj`, NUL, DEL, `ET BT … Tj`, and CJK and emoji. lopdf finds no extra `/Info` keys and no operator outside the whitelist, and each `Tj` operand is byte-identical to its payload (`control_string_escaping_closes_every_injection`, `control_injection_document_validates`, and the oracle's `info_*_bytes_roundtrip`, `tj_strings_exact_bytes` and `content_ops_whitelisted`).
- **Numbers.** No `nan`, `inf`, `e+`/`e-` or `-0` token is ever written (`control_numbers_never_nan_inf_or_exponent`).
- **Image dimensions in `PdfDoc`.** Products such as 65536², 46341² and `i32::MAX × 2` are rejected through `Int64` before any allocation (cap 536,870,911 px). A buffer length that does not match `w*h*{3,4}`, and 0 or negative dimensions, are rejected too (`control_image_dimension_overflow_rejected`).
- **Filters.** RunLength rejects truncated literal and repeat packets and honours its limit, and `0x80` EOD stops decoding. A Flate bomb that would inflate to 512 MiB stops at a 64 MiB limit with 105 MiB RSS (`control_filters_truncation_and_bombs`; `run_audit.sh` §4).
- **JPEG parsing.** 4000 random marker sequences after SOI (fill `0xFF`s, `FF 00`, SOF length < 2, segments past the end) never crash (`control_jpeg_marker_fuzz_no_crash`).
- **Structure.** All 8 fixtures (14 fonts, clipping, dashes, RunLength page, SMask, gray/RGB/CMYK/progressive JPEG, multi-page) load in lopdf. Every xref entry is exactly 20 bytes and points to `N 0 obj`, every `/Length` matches the bytes up to `\nendstream`, and every `/Font`, `/XObject` and `/SMask` reference resolves. Sample counts are exact (`w*h*3`, alpha `w*h`), and `/Count` equals the number of pages.
- **ImageId bounds.** Out-of-range ids, including `ImageId(-1)`, are rejected at `encode()` (`control_out_of_range_image_id_rejected`).
- **wasm32.** All fixtures are byte-identical between native and wasm32 (`probe.wasm` under node).

---

## Performance: where the time goes (`probe perf`, best of 5, in-process)

| Workload | Phase | ms |
|---|---|---:|
| report100 | build 100 pages of ops (`ContentStream`) | 2 |
| | `encode()` uncompressed | 0 |
| | `encode()` with Flate 6 | 10 |
| images (10 × 800×600) | `rgba_to_white_rgb` ×10 | 13 |
| | `flate_encode(6)` ×10 (14.4 MB) | 39 |
| | `rle_encode` ×10 | 29 |
| | full `encode_pdf_pages` Flate / uncompressed | 53 / 31 |

Head-to-head, `bench_compare.py` with 15 rounds and stdout SHA verified (same binaries as `bench/run_bench.sh`), load average about 20:

| Workload | Pion | Rust `pdf-writer` | Ratio | README |
|---|---:|---:|---:|---:|
| report100 (Flate) | 22.7 ms | 13.7 ms | 0.60× | 0.61× |
| images_flate | 71.8 ms | 67.3 ms | **0.94×** | 0.46× |
| images_rle | 73.8 ms | 28.6 ms | **0.39×** | 0.52× |

Where the gaps likely come from:

1. **report100: Flate setup on every stream.** Building and serializing take about 2 ms; the remaining 10 ms is 100 calls to `flate::zlib_compress` on roughly 1 KB streams, about 100 µs each. That points to window and hash-table allocation plus zeroing on every call. Reusing a compressor or table across streams would close most of the in-process gap. The rest of the 22.7 ms is process start and the benchmark harness itself.
2. **images_rle: scalar RunLength and byte-by-byte copies.** `rle_encode` costs 29 ms for 14.4 MB, about 500 MB/s, checking three bytes per literal step and calling `write_byte`/`ensure` per byte. Its output is about 11 MB because the gradients barely compress, and that output is then copied byte by byte again: `ByteBuf::write_bytes` and `write_slice` loop over single bytes instead of doing a block copy, and `ensure` copies byte by byte on growth. Peak RSS is 55 MiB against Rust's 38 MiB, which is consistent with one extra full copy.
3. **`rgba_to_white_rgb`: 13 ms.** It divides by 255 per channel and pre-fills the white buffer before overwriting it. `(x*a + 255*(255-a) + 127) * 257 >> 16`, without the pre-fill, should cut that noticeably (not measured).
4. **images_flate:** essentially even (0.94×), and dominated by `flate` LZ77 (39 of 53 ms).
5. `draw_image` deduplicates by linear search over `used_images`, which is O(images²) per page. It does not matter for the benchmarks but grows badly for image-heavy pages.

---

## What I would fix first

1. P0-1 and P0-2, plus P1-2 (validator): use `Int64` arithmetic, check the xref size against the file length before allocating, and bound every scan by `endobj`. These are about 20 lines.
2. P1-1: make `ByteBuf` growth overflow-safe and give `ContentStream` a byte budget. Today `Limits` gives no protection against a large page.
3. P1-4 and P1-5: take the JPEG size and components from the SOF, and add `/Decode` for Adobe CMYK.
4. P1-6 and P1-7: encode text strings properly (WinAnsi for `Tj`, UTF-16BE with a BOM for `/Info`).
5. P1-8, P1-9 and P2-1: reject non-finite and out-of-range numbers, and print with enough significant digits.
