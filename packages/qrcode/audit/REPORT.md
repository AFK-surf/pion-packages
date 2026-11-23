# RT-qrcode red-team audit of `packages/qrcode`

Baseline: `origin/feat/pkg-qrcode` @ `e05329a` (toolchain `AFK-surf/pion@79d1fbd`).
Only `packages/qrcode/audit/**` is added; the package itself is unchanged
(`sh scripts/verify.sh packages/qrcode` stays 15/15).

References (all `--release`, pinned in `diff/rust/Cargo.lock`):

| Reference | Role |
| --- | --- |
| Nayuki `qrcodegen` 1.8.0 | ISO/IEC 18004 reference encoder, reference N1..N4 penalty (`diff/qrdiff.py` has a port, checked against its mask choice on all 160 symbols) |
| `rqrr` 0.11.0 | independent quirc-derived matrix decoder (retries mirror images) |
| `qrcode` 0.14.1 (kennytm) | the W12 benchmark baseline |
| `fast_qr` 0.14.0 | modern optimised encoder, benchmark fairness |
| exact O(n²) optimum (`qrdiff.py exact_opt`) | ground truth for mixed-mode segmentation |

Reproduce everything: `sh packages/qrcode/audit/run_audit.sh` (stages `build tests diff wasm probe bench`;
artefacts go to `$AUDIT_OUT`, default `/tmp/rt-qrcode`).

## Verdict

No P0. The encoder core is **correct**: 1280/1280 fixed-mask symbols (all 160 `(v1..v40, L/M/Q/H)` × 8 masks,
Byte payloads filling every data module) are **pixel-identical** to qrcodegen, so Table 9 (codewords,
block counts), alignment coordinates, Format BCH(15,5), Version BCH(18,6) placement (Fig. 25/26), zigzag
placement, interleaving and all 8 mask formulas are right. Max/max+1 capacity agrees with qrcodegen for
every mode at every `(v, ec)`. Every Pion-encoded symbol in the corpus (2689 incl. Kanji, all 7 ECI widths,
empty/NUL/emoji/non-UTF-8) is decoded byte-exactly by rqrr, and Pion decodes every qrcodegen symbol in all 4
rotations. RS decoding is as strong as rqrr's (0 silent miscorrections in 4688 injections), the bitstream
parser is stricter than rqrr's, and 4000 fuzzed RS-valid symbols produce 0 crashes in all 4 build modes.

What is worse than the references: **two P1** (SVG attribute/script injection; raster renderers abort the
process on Int32 overflow) and **eight P2** (spec / interop gaps, below). The W12 speed claim is reproducible
against `qrcode 0.14.1` but that crate is the slowest mainstream Rust encoder: **qrcodegen and fast_qr are
both faster than Pion**.

## Findings

Each one is a currently-FAILING test in `redteam_test.pion`; 8 `control_*` tests pin what already holds.

### P1-1 SVG injection through `SvgOptions.dark_color` / `light_color` (`src/render.pion:20,53,85`)

`render_svg` writes both colour strings into `fill="…"` verbatim. `dark_color = "#000\" onload=\"alert(1)"`
yields `<path … fill="#000" onload="alert(1)"/>`; `light_color = "#fff\"/><script>alert(document.domain)</script><rect fill=\"#fff"`
closes the background `<rect>` and injects a `<script>` element. Any service that takes a colour from a
query string/theme and serves the SVG inline (or as `image/svg+xml`) has stored/reflected XSS.
Tests: `p1_svg_dark_color_attribute_injection`, `p1_svg_light_color_script_injection`.
Fix: validate colours (`#rgb`/`#rrggbb`/`#rrggbbaa`/named) and return `QrError::InvalidRenderOption`
(defined but never used today), or XML-escape `& < > " '`.

### P1-2 `to_rgba` / `to_pgm` abort the process on Int32 overflow (`src/render.pion:184,240`)

`dim * dim * 4` (RGBA) and `hlen + dim * dim` (PGM) are 32-bit `Int`. With quiet zone 4 on a v1 symbol:

| call | native | wasm32 |
| --- | --- | --- |
| `to_rgba(4, 1000, …)` (29000² × 4 = 3.36e9) | `Abort trap: 6` – `negative bytes length` | `pion panic: negative bytes length` |
| `to_rgba(4, 2000, …)` (wraps positive) | allocates 571 MB then `index 571184000 out of bounds` abort | same |
| `to_pgm(4, 2000)` | `negative bytes length` abort | same |

Panics are not recoverable, so one hostile `?scale=` kills the whole server process (Rust renderers use
`usize` and at worst fail an allocation). The same wrap gives a negative SVG `viewBox` (P2-1).
Tests: `p1_rgba_scale_1000_int32_overflow_aborts`, `p1_rgba_scale_2000_wraps_then_out_of_bounds`,
`p1_pgm_scale_2000_int32_overflow_aborts`. Fix: bound `quiet_zone`/`scale`/`module_size` (e.g. output
≤ 2^28 bytes) and return `Result[…, QrError::InvalidRenderOption]`.

### P2-1 SVG `module_size` overflow emits an invalid symbol

`module_size = 100000000` → `viewBox="0 0 -1394967296 -1394967296"` and negative path coordinates: a
silently broken SVG. Test `p2_svg_module_size_overflow_negative_viewbox`. (Huge `quiet_zone` is fine for
SVG – control – but `to_ascii`/`to_terminal` grow quadratically, 72 MB at `quiet_zone = 3000`, unbounded.)

### P2-2 N3 penalty is not the ISO/reference rule → 40 % of symbols get a worse mask

`compute_penalty` (`src/encode.pion:53,84`) only matches the literal 11-module windows
`00001011101`/`10111010000` fully inside the symbol. ISO/IEC 18004 §7.8.3.1 counts a 1:1:3:1:1 pattern
with 4 light modules on either side, and the quiet zone outside the symbol is light; qrcodegen and zxing
count edge patterns (qrcodegen also counts scaled k:k:3k:k:k runs). Minimal case: 21×21 light matrix with
row 10 = `101110101…` → reference 2047, Pion 2007 (one N3 missed)
(`p2_penalty_n3_counts_finder_pattern_against_quiet_zone`). Effect, measured on the 160 full-capacity
symbols: Pion's auto mask equals qrcodegen's on 96/160 and is **strictly worse under the reference
N1..N4 on 64/160** (e.g. v3-Q mask 7 = 1309 vs mask 0 = 1270); across the whole corpus the auto mask
differs on 443/1758 symbols. Symbols still decode (any mask is legal), but the README's "exact
§7.8.3.1 N1+N2+N3+N4" claim is false. Test `p2_auto_mask_follows_reference_penalty` (v2-L: Pion 6,
reference 3).

### P2-3 Mixed-mode optimiser is not exact → can pick a larger version

`optimize_segments` charges fixed `+4` (leaving Numeric) / `+3` (leaving Alphanumeric) sixths of a bit
instead of the exact round-up, and adds none for the final segment. Against the exact O(n²) optimum it is
1 bit too long on 2/12000 random strings — rare, but when the optimum lands exactly on a capacity the
encoder escalates: `encode("coofjvo8 062862655$*", L)` picks **v2** although
`Byte("coofjvo8 ") + Numeric("062862655") + Alnum("$*")` is exactly 152 bits = v1-L capacity
(`control_optimizer_exact_fit_segments_do_fit_v1` proves it encodes at v1). Test
`p2_optimizer_exact_fit_gets_v1`. Fix: carry `ceil()` as Nayuki's `makeSegmentsOptimally` does. The
optimiser is O(n) (1 MiB rejected in 20 ms; 100 KiB control) – no quadratic cliff.

### P2-4 Mirror-imaged symbols are rejected

ISO/IEC 18004:2015 readers handle mirror images; rqrr retries the transposed grid and decodes **771/771**
mirrored corpus symbols, Pion **0/771** (`FormatDecodeError`/`ReedSolomonError` – never a wrong payload).
Test `p2_mirror_image_symbol_is_decoded`. Fix: on failure retry `decode` on the transpose.

### P2-5 Structured Append (mode `0011`) is rejected

A symbol starting with the Structured Append header (§8.3; 4-bit index, 4-bit total, 8-bit parity) fails with
`UnsupportedMode(3)`; zxing skips/reports the header and decodes the payload (rqrr also fails).
Test `p2_structured_append_header_is_decoded`.

### P2-6 Decoder accepts ECI designators > 999999

A 3-byte ECI `0x1FFFFF` (2097151) is accepted although the encoder correctly rejects > 999999
(`control_encoder_rejects_invalid_kanji_and_eci`). rqrr is equally lax. Test
`p2_decoder_rejects_eci_designator_over_999999`.

### P2-7 Decoder emits non-Shift-JIS pairs for out-of-range Kanji values

13-bit values that no valid Shift-JIS pair encodes are mapped anyway: `0x00BF → 0x81FF`,
`0x1EBD → 0xDFFD` (`kanji_from_value`, `src/segment.pion:52`), so `bytes` contains invalid SJIS that the
encoder itself would reject. rqrr does the same. Test `p2_decoder_rejects_kanji_value_outside_shift_jis`.

### P2-8 Benchmark fairness: the baseline is the slowest Rust encoder

See the table below. Pion's lead over `qrcode 0.14.1` reproduces (W1 3.38×, W2 3.12×, and 3.66× on mixed-case
real payloads, so W1's all-lower-case inputs did not flatter Pion; the optimiser is O(n), no long-input
cliff), but **qrcodegen 1.8.0 and fast_qr 0.14.0
beat Pion on both workloads**. "Leads Rust" should read "leads `qrcode 0.14.1`; trails qrcodegen and
fast_qr". (BENCHMARKS rules require reporting lagging items.)

`run_audit.sh bench`, `bench_compare.py --warmup 1 --rounds 7`, strictly interleaved, stdout SHA-256 gated
(stdout = summed module count, so encoders with different legal masks still compare only when they pick the same
versions). Same host (Apple M5 Max, shared station, load 18–50 during the run; medians and mins agree).

| Workload | `pion` | `qrcode 0.14.1` | `qrcodegen 1.8.0` | `fast_qr 0.14.0` | Pion vs fastest |
| --- | ---: | ---: | ---: | ---: | --- |
| W1 10 000 URL/OTP encodes (median / min ms) | 1612.5 / 1442.6 | 5447.9 / 5208.7 | 1257.5 / 1162.6 | **526.1 / 509.7** | 3.07× slower than fast_qr, 1.28× slower than qrcodegen |
| W2 300 v10..v40 binary encodes | 689.6 / 671.1 | 2149.9 / 2107.5 | 530.3 / 501.6 | **171.8 / 167.7** | 4.01× slower than fast_qr, 1.30× slower than qrcodegen |
| real 10 000 mixed-case payloads (optimiser on) | **1132.2** / 1084.2 | 4139.7 / 4017.9 | n/a¹ | n/a¹ | 3.66× faster than qrcode 0.14.1 |
| peak RSS (W1 / W2) | 1.89 / 2.17 MiB | 2.47 / 3.14 MiB | 2.45 / 2.95 MiB | 2.17 / 2.30 MiB | Pion lowest |

¹ qrcodegen (`make_segments`) and fast_qr have no mixed-mode optimiser and pick larger versions on these
payloads, so their stdout differs and the SHA gate excludes them; Pion is genuinely better here on symbol size.

## What holds (controls and differential evidence)

| Attack | Result |
| --- | --- |
| 160 `(v,ec)` × 8 masks, fixed mask, Byte at capacity vs qrcodegen | 1280/1280 pixel-identical |
| max / max+1 for Byte, Numeric, Alnum, Kanji and 7 ECI widths at every `(v,ec)` | 0 status mismatches (645 overflows rejected by both) |
| v40-L 2953 B / 7089 N / 4296 A, v1-H 7 / 17 / 10, empty, NUL, emoji, non-UTF-8 | exact (`control_iso_capacity_boundaries`, `control_edge_payload_roundtrip`) |
| Pion symbols → rqrr | 2689/2689 byte-exact |
| qrcodegen symbols → Pion, 0/90/180/270° | 2689 + 3×771 byte-exact, 0 wrong |
| RS: k random byte errors in every block, k ≤ t | Pion 1656/1656, rqrr 1656/1656 |
| RS: k > t (t+1, t+2, t+4, e) | Pion 3032 errors / 0 silent wrong (rqrr identical) |
| misdecode-protection symbols (v1-L/M/Q, v2-L, v3-L) | Pion corrects up to ⌊e/2⌋ like rqrr/zxing; 0 miscorrections observed |
| hostile bitstreams (truncated counts, Byte len 255 / 65535, Numeric ≥ 1000, Alnum ≥ 45, bad ECI prefix, modes 0110/1010..1111) | all rejected; stricter than rqrr (rqrr accepts Numeric 1000/1023, Alnum 2047/63, ECI `111…`) |
| FNC1 `0101` / `1001` | decoded (rqrr fails) |
| 4000 random RS-valid symbols | 0 crashes |
| malformed matrices (size 0, −21, 1, 20, 22, 181, 10000, length mismatch, all-dark/all-light v1..v40) | errors, no panic |
| 100 KiB / 1 MiB auto-encode | `DataTooLong` in O(n) |
| 4 modes (native rel/dbg, wasm32 rel/dbg) over 4294 encodes + 14491 decodes | byte-identical, 0 traps |

## Files

- `redteam_test.pion` – 13 FAILING `p1_`/`p2_` tests + 8 passing `control_` tests (`pionc test packages/qrcode/audit`).
- `oracle/` – Pion driver (`enc`/`dec`/`seg`/`tables`/`render`/`bench`), built in 4 modes.
- `diff/rust/` – Rust references (`enc` via qrcodegen, `dec` via rqrr, `cw` = `encode_codewords`, `bench`).
- `diff/qrdiff.py` – corpus generator, comparators, Nayuki penalty port, exact optimiser, RS injector, hostile bitstreams.
- `run_audit.sh` – one-shot reproduction.
