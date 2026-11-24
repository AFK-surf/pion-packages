# `unicode_linebreak` (`v0.1.2`)

Pure Pion, zero-external-dependency implementation of the **Unicode 16.0.0 Line Breaking Algorithm (UAX #14, Revision 53)** covering all rules **LB1–LB31**.

- Zero external dependencies (`[dependencies]` empty), zero `extern "C"`, zero `World` dependency, zero `Double`/`Float`, zero `FixedArray`, zero module-level mutable globals/containers, and full Wasm32 compatibility.
- Strict **O(n)** single-pass streaming scanner with bounded O(1) lookahead cache — resistant to 100,000+ adversarial `SP`/`CM`/`ZWJ`/`QU`/`NU`/`OP`/`CL`/`RI`/`AK+VI` runs without backtracking or stack overflow.
- Compact 3-level pure-ASCII immutable `String` lookup table + `47×64` DFA pair-action table packed into a single `table_blob` (`45,326 B` in `src/tables.pion`) with O(1) lookup across all 1,114,112 Unicode code points (`U+0000..U+10FFFF`), including inline ASCII word/digit and CJK fast paths.

## Changelog

- **`v0.1.2`**: fixes a `v0.1.1` regression in `line_breaks`: the inline CJK `ID ÷ ID` tight loop left `prev_is_ea` stale when the run followed a non-East-Asian `ID` (e.g. `U+1F6E0`, `U+2600`, `U+2764`), so LB19a wrongly suppressed the break before a following quotation mark (`"🛠岩“東"` now yields `[4, 7, 13]`). `line_breaks_with_limits`, `LineBreakIter`, and `next_break_opportunity` were unaffected.
- **`v0.1.1`**: `47×64` DFA pair table and zero-allocation hot loops.
- **`v0.1.0`**: initial release.

## Features

1. **Complete Unicode 16.0.0 UAX #14 (LB1–LB31)**:
   - All 48 official `Line_Break` classes (`AI` through `ZWJ`), including Unicode 15.1 / 16.0.0 Brahmic classes (`AK`, `AP`, `AS`, `VF`, `VI`) and unassigned block defaults (`ID` for CJK/Plane 1–3 ranges, `PR` for Currency Symbols `U+20A0..U+20CF`, `XX` otherwise).
   - **Mandatory vs Allowed breaks**: distinguishes `BreakKind::Mandatory` (LB3 end of text, LB4 `BK`, LB5 `CR`/`LF`/`NL` with `CR × LF`) from `BreakKind::Allowed` (LB8, LB15c, LB18, LB20, LB31).
   - **Unicode 15.1 / 16.0.0 rule updates**:
     - **LB15a / LB15b**: `QU_Pi` (`General_Category=Pi`) and `QU_Pf` (`General_Category=Pf`) quotation rules;
     - **LB15c / LB15d**: decimal mark break `SP ÷ IS NU`;
     - **LB19 / LB19a**: `East_Asian_Width` (`F`/`W`/`H`) aware quotation rules;
     - **LB20a**: word-initial hyphen `(sot|BK|CR|LF|NL|SP|ZW|CB|GL) (HY|U+2010) × AL`;
     - **LB25**: revised Unicode 16.0.0 numeric/currency/parenthesis/fraction state machine (`NU (SY|IS)* (CL|CP)? × (PO|PR)`, `(PR|PO) × OP IS? NU`, etc.);
     - **LB28a**: Brahmic orthographic syllable rules (`AP`, `AK`, `AS`, `U+25CC`, `VF`, `VI`);
     - **LB30 / LB30a / LB30b**: non-East-Asian `OP`/`CP`, Regional Indicator flag parity, `EB × EM`, and `[\p{Extended_Pictographic}&\p{Cn}] × EM`.
2. **Public API**:
   - `line_breaks(s : String) -> Array[BreakOpportunity]` (empty string returns `[]`; non-empty string always ends with `(s.length(), BreakKind::Mandatory)`)
   - `line_breaks_with_limits(s : String, limits : LineBreakLimits) -> Result[Array[BreakOpportunity], LineBreakError]` (negative limits immediately return `Err(LineBreakError::LimitExceeded)`; `0` is enforced strictly)
   - `line_break_iter(s : String) -> LineBreakIter` + `LineBreakIter::next(self) -> Option[BreakOpportunity]` (resumable streaming iterator yielding the exact same sequence as `line_breaks(s)` in strict worst-case **O(n)** time and **O(1)** auxiliary memory for any input, including pure non-anchor punctuation streams)
   - `next_break_opportunity(s : String, byte_offset : Int) -> Option[BreakOpportunity]` (safe on negative, mid-UTF-8, and out-of-bounds offsets; never panics or loops. Single-call complexity is **O(distance to nearest backward state-reset anchor)** — covering all 31 context-independent resolved classes and ill-formed UTF-8 bytes, giving amortized O(1) per call / O(n) total over all natural-language text and ill-formed byte streams; for pure non-anchor punctuation streams such as repeated `"- "` or `"\" "`, or maximum streaming throughput, use `line_breaks(s)` or `LineBreakIter`)
   - `line_break_class(cp : Int) -> LineBreakClass` (raw UAX #14 `Line_Break` property lookup)
3. **Safe UTF-8 Handling**:
   - Invalid UTF-8 byte sequences are decoded to `U+FFFD` per the Unicode maximal subpart rule and always advance at least 1 byte.

## Usage

```pion
import "unicode_linebreak"

let breaks = unicode_linebreak::line_breaks("Hello world!\n中文测试。")
// Every BreakOpportunity has `byte_offset : Int` (UTF-8 boundary) and `kind : BreakKind`

let limited = unicode_linebreak::line_breaks_with_limits(
  "a b c",
  unicode_linebreak::LineBreakLimits::new(1024, 64),
)

let first = unicode_linebreak::next_break_opportunity("中文 a", 0)
// Some(BreakOpportunity::{ byte_offset: 3, kind: BreakKind::Allowed })

let iter = unicode_linebreak::line_break_iter("a-b c")
// iter.next() streams BreakOpportunity values in strict worst-case O(n)

let cls = unicode_linebreak::line_break_class(0x4E00)
// LineBreakClass::ID
```

## Concurrency & `Send` Guarantees

Verified directly with `pionc check --json` across `scope`/`spawn` boundaries:

- **`Send` types** (safe to capture directly in `spawn`): `LineBreakClass`, `BreakKind`, `BreakOpportunity`, `LineBreakError`, `LineBreakLimits`, and `String`.
- **Non-`Send` types**: `Array[BreakOpportunity]` (returned by `line_breaks` / `line_breaks_with_limits`) and `LineBreakIter` (mutable streaming cursor), both rejected by `pionc` with `E_NOT_SEND`. Do **not** attempt to wrap either in `Mutex::new(...)` (`Mutex[T]` requires `T: Send`). Instead, pass the immutable `String` input and `LineBreakLimits` across `spawn` and construct `line_breaks(s)` or `line_break_iter(s)` inside the task, or pass individual `BreakOpportunity` values across threads.

## Unicode Data & License Attribution

Embedded lookup tables (`src/tables.pion`) are deterministically generated by `tools/gen_tables.py` from official **Unicode 16.0.0** UCD data files licensed under the **Unicode License v3 (`Unicode-3.0`)** by Unicode, Inc.:

- `LineBreak.txt` (Unicode 16.0.0, including `@missing` and unassigned block defaults)
- `EastAsianWidth.txt` (Unicode 16.0.0, including `@missing` and unassigned block defaults)
- `UnicodeData.txt` (Unicode 16.0.0, `General_Category` for LB1 `SA`, LB15a/b `QU_Pi`/`QU_Pf`, and LB30b `Cn`)
- `emoji-data.txt` (Unicode 16.0.0, `Extended_Pictographic` for LB30b)

To regenerate or verify determinism:

```sh
python3 packages/unicode_linebreak/tools/gen_tables.py /path/to/unicode-16.0.0 packages/unicode_linebreak/src/tables.pion
python3 packages/unicode_linebreak/tools/gen_tables.py --check /path/to/unicode-16.0.0 packages/unicode_linebreak/src/tables.pion
```

## Verification

```sh
sh scripts/verify.sh packages/unicode_linebreak
sh packages/unicode_linebreak/bench/run_bench.sh
```

### Unit, Red → Green & Adversarial Suite

- Red → Green verified: `1/15` passed on stub build (`14/15` failed as expected), **`22/22` passed** after full implementation and red-team hardening.
- Covers mandatory vs allowed breaks (`CR+LF`/`CR`/`LF`/`NL`/`BK`), CJK kinsoku, `ZW`/`SP`/`GL`/`WJ`/`CM`, Emoji ZWJ & skin-tone modifiers (`EB × EM`, `ExtPict(Cn) × EM`), RI flag pairs, LB10 remaining `CM`/`ZWJ` East_Asian_Width clearing, LB15a/b/c/d, LB19/19a (including the `East_Asian_Width` state across non-East-Asian `ID` + CJK `ID` runs), LB20a/21a (including `[BA - $EastAsian]` exclusion), LB25, LB28a Brahmic syllables, unassigned Supplemental Arrows-C `U+1F80C..U+1F8FF` (`XX`), invalid UTF-8 safety, `next_break_opportunity` O(n) backward-anchor iteration across ASCII, Korean (`H2`/`H3`), Hebrew (`HL`), Kana (`CJ→NS`), ill-formed `0xFF`/`0x80` runs, and negative/mid-UTF-8/bounds handling, `LineBreakIter` strict worst-case O(n) streaming on pure non-anchor punctuation streams, `LineBreakLimits` negative/zero/exact bounds, and 100,000-character O(n) DoS stress runs.

### Official Unicode 16.0.0 `LineBreakTest.txt` Conformance

- Full official Unicode 16.0.0 `LineBreakTest.txt` (**16,672 test vectors**): **`16,672/16,672` PASS (100.00%, 0 deviations)**.

### 4-Mode Verification (`wasm_smoke`)

`packages/unicode_linebreak/wasm_smoke` builds and runs cleanly across `native debug`, `native --release`, `wasm32 debug`, and `wasm32 --release` with byte-identical stdout:

- Stdout: `unicode_linebreak_wasm_smoke: OK samples=12 opps=52 mandatory=16 fnv64=13553705255585179840`
- Stdout SHA-256: `5b5e94c5c1af8a9ab13fbab1c9c6c7997effa36c1ccd27381ff4963681518b70`
- Wasm32 binary size: `94,646 B` (debug & `--release`)

### Differential Oracle & Head-to-Head Benchmarks vs Rust `icu_segmenter 2.4.0`

Measured on `Linux x86_64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, byte-identical stdout SHA-256 verified across all rounds, locked `Cargo.lock` with `icu_segmenter 2.4.0 --release` LTO):

- **Differential oracle (`bench/run_bench.sh`)**: **`123/123` PASS (0 deviations)** byte-for-byte against `icu_segmenter 2.4.0`. Known `icu_segmenter 2.4.0` divergences from Unicode 16.0.0 UAX #14 — Unicode 15.1 `Line_Break` data (`FE20..FE2F`, `2E56..2E5C`, `FE10`/`FE13`/`FE14`, `1B50..`), pre-15.1 LB19/LB19a, pre-16.0 LB21a (`HL HY ÷ HL` and `[BA - $EastAsian]`), LB15c `SP ÷ IS NU`, LB20a word-initial hyphen, LB25 (`NU (SY|IS)* × (PO|PR)`, `(PR|PO) × OP IS? NU`, no `SY × NU`), a `U+25CC` pair bug (breaking after two dotted circles even before `SP`/`LF`/`CR`/`BK`), and implementation-defined `SA` dictionary/LSTM handling — are exhaustively verified against Unicode 16.0.0 by the 16,672/16,672 official `LineBreakTest.txt` suite.

#### Corpus 1: Multilingual Web/News Layout (41,916 B × 200 iters = 8.38 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_icu_segmenter`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_linebreak` (`--release`) | 53.230 | 51.745 | 61.350 | 157.49 | 266,149.08 | 2.30 MiB | 0.87x |
| `rust_icu_segmenter` (`2.4.0 --release`, LTO) | 46.286 | 44.003 | 61.164 | 181.12 | 231,431.80 | 2.12 MiB | 1.00x (baseline) |

- Verified stdout SHA-256: `4f3e0ed13a6f354869c8eef2e97ac96a6d28ae32f3edf72b4d8efbd8e3fec21d`

#### Corpus 2: Dense Tech Spec / Numbers / Punctuation (43,600 B × 200 iters = 8.72 MB)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_icu_segmenter`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_linebreak` (`--release`) | 65.854 | 60.288 | 81.442 | 132.41 | 329,267.85 | 2.30 MiB | 0.89x |
| `rust_icu_segmenter` (`2.4.0 --release`, LTO) | 58.761 | 53.997 | 78.228 | 148.40 | 293,805.64 | 2.14 MiB | 1.00x (baseline) |

- Verified stdout SHA-256: `15c9425ff0699122e752b8361caabefe61c54c5231ee7211ec7ce2ef9eaf665e`
