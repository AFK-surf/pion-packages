# `unicode_segment` (v0.1.0)

Pure Pion, zero-external-dependency **Unicode 16.0.0 UAX #29** text segmentation engine: **Extended Grapheme Clusters** (including **GB9c Indic Conjunct Break**), **Word Boundaries** (including alphanumeric-only `unicode_words`), and **Sentence Boundaries**.

- Zero external dependencies (`[dependencies]` empty), zero `extern "C"`, zero `World` dependency, zero `Double`/`Float`, zero `FixedArray`, zero module-level `let mut` or mutable containers, strict O(n) linear time, and full Wasm32 compatibility.

## Features

1. **Extended Grapheme Cluster Segmentation (UAX #29 §3.1.1, GB1–GB999)**
   - Full Unicode 16.0.0 rule coverage: `CR × LF` (GB3), `Control`/`CR`/`LF` (GB4/GB5), Hangul Jamo `L`/`V`/`LV`/`LVT`/`T` (GB6–GB8), `Extend`/`ZWJ`/`SpacingMark`/`Prepend` (GB9/GB9a/GB9b), **GB9c Indic Conjunct Break** (`InCB=Consonant`/`Linker`/`Extend`), **GB11 Emoji ZWJ** (`Extended_Pictographic Extend* ZWJ × Extended_Pictographic`), and **GB12/GB13 Regional Indicator** flag pairs.
   - Zero-copy UTF-8 byte-span APIs (`grapheme_indices`, `grapheme_count`) plus string slices (`graphemes`) and editor cursor navigation (`is_grapheme_boundary`, `next_grapheme_boundary`, `prev_grapheme_boundary`) that never split multi-byte UTF-8 sequences, emoji sequences, flags, or Indic conjuncts. Cursor lookback is O(1) on ordinary text (including Latin, CJK, Hangul syllables, Devanagari, and standalone emoji) and only scans further across genuinely stateful runs (such as long Regional Indicator `RI` runs or `Extend`/`ZWJ`/GB9c chains, matching Rust `GraphemeCursor`).
2. **Word Boundary Segmentation (UAX #29 §4.1, WB1–WB999)**
   - Full Unicode 16.0.0 rule coverage including `CR × LF`, `Newline`/`CR`/`LF`, `ZWJ × Extended_Pictographic` (WB3c), `WSegSpace × WSegSpace` (WB3d), `Extend`/`Format`/`ZWJ` absorption (WB4), `ALetter`, `Hebrew_Letter` (`Single_Quote`/`Double_Quote` WB7a–WB7c), `MidLetter`/`MidNumLet`/`MidNum`, `Numeric`, `Katakana`, `ExtendNumLet`, and `Regional_Indicator` pairs.
   - Provides `word_bounds`, `words`, `unicode_word_bounds`, and `unicode_words` (filtering out pure whitespace and punctuation to retain segments containing Unicode `Alphabetic` or `General_Category=Nd/Nl/No` characters, matching Rust `unicode-segmentation::unicode_words`).
3. **Sentence Boundary Segmentation (UAX #29 §5.1, SB1–SB11 + SB998)**
   - Full Unicode 16.0.0 rule coverage with a strictly **O(n)** single-pass DFA and monotonic memoized SB8 lookahead (immune to O(n²) `ATerm`/`Close`/`Sp` backtracking bombs).
   - Provides `sentence_bounds` and `sentences`.
4. **DoS Guardrails (`SegmentLimits`) & Strict O(n) Guarantees**
   - Every full-string segmentation entrypoint (`grapheme_*`, `word_*`, `unicode_word*`, `sentence_*`) has a `*_with_limits(s, limits)` variant enforcing `max_input_bytes` and `max_segments`.
   - Negative limits immediately return `Err(SegmentError::LimitExceeded)` (even on empty strings); `0` is enforced strictly (any input with `length > max_input_bytes` fails, and `max_segments = 0` rejects whenever a segment would be emitted while permitting inputs that yield 0 segments, such as empty strings or punctuation-only input passed to `unicode_words_with_limits`); segment limits abort early without unbounded allocation.
   - All 3 full-string engines run in strictly O(n) linear time even on adversarial 100,000-character `Extend`, `ZWJ`, `Regional_Indicator`, and `ATerm`/`Close`/`Sp` chains.

## Usage

```pion
import "unicode_segment"

// Extended Grapheme Clusters (UTF-8 byte spans & slices)
let spans = unicode_segment::grapheme_indices("a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}\u{1F1E8}\u{1F1F3}")
// spans.length() == 3

// Cursor navigation (right arrow / backspace)
let next_pos = unicode_segment::next_grapheme_boundary("e\u{0301}x", 0) // Some(3)
let prev_pos = unicode_segment::prev_grapheme_boundary("e\u{0301}x", 3) // Some(0)

// Word & Sentence segmentation
let ws = unicode_segment::unicode_words("Don't stop, 3.14!") // ["Don't", "stop", "3.14"]
let ss = unicode_segment::sentences("Dr. Smith paid $3.14! Next?")

// Bounded execution with DoS limits
let lim = unicode_segment::SegmentLimits::new(65536, 4096)
match unicode_segment::grapheme_indices_with_limits("hello", lim) {
  Ok(g) => ()
  Err(unicode_segment::SegmentError::LimitExceeded) => ()
}
```

## Concurrency & `Send` Guarantees

Verified directly with `pionc check --json` across `scope`/`spawn` boundaries:

- **`Send` types** (safe to capture directly inside `spawn`): `SegmentSpan`, `SegmentLimits`, `SegmentError`, and `String` inputs/slices.
- **Non-`Send` types**: `Array[SegmentSpan]` and `Array[String]` returned by `grapheme_indices`, `graphemes`, `word_bounds`, `words`, `unicode_word_bounds`, `unicode_words`, `sentence_bounds`, and `sentences` (confirmed rejected with `E_NOT_SEND` when captured directly in `spawn`). Pass the input `String` and `SegmentLimits` into `spawn` and segment inside the worker task, or wrap returned arrays in `Mutex::new(...)` / transfer ownership explicitly.

```pion
import "unicode_segment"

pub fn count_in_worker(world : World, text : String, lim : unicode_segment::SegmentLimits) -> Unit {
  scope(world, fn(s : Scope) -> Unit {
    spawn(s, fn() -> Unit {
      let _ = unicode_segment::grapheme_count_with_limits(text, lim)
    })
  })
}
```

## Unicode 16.0.0 Data & License Attribution

Embedded lookup tables (`src/tables.pion`) are deterministically generated by `tools/gen_tables.py` using immutable `String` constants (two-level BMP paged tables + base-64 SMP range binary search; ~62 KB total, zero `FixedArray`, zero mutable globals) from the following official **Unicode 16.0.0** UCD data files:

- `GraphemeBreakProperty.txt`
- `WordBreakProperty.txt`
- `SentenceBreakProperty.txt`
- `emoji-data.txt` (`Extended_Pictographic`)
- `DerivedCoreProperties.txt` (`InCB=Linker/Consonant/Extend`, `Alphabetic`)
- `UnicodeData.txt` (`General_Category` `Nd`/`Nl`/`No` for `unicode_words`)

These Unicode data files and derived lookup tables are licensed under the **Unicode License v3 (`Unicode-3.0`)** by Unicode, Inc. The package source code is licensed under **MIT**.

```sh
python3 packages/unicode_segment/tools/gen_tables.py /path/to/unicode-16.0.0 packages/unicode_segment/src/tables.pion
python3 packages/unicode_segment/tools/gen_tables.py /path/to/unicode-16.0.0 packages/unicode_segment/src/tables.pion --check
```

## Verification

```sh
sh scripts/verify.sh packages/unicode_segment
sh packages/unicode_segment/bench/run_bench.sh
```

### Unit & Adversarial Stress Suite (Red → Green)

- **Red stage**: `0/12` passed on stub build (`pionc check --json` passed, `pionc test --json` failed all 12 tests).
- **Green stage**: **13/13** tests in `src/segment_test.pion` pass, covering GB1–GB999 (incl. GB9c Indic Conjunct Break, GB11 Emoji ZWJ, GB12/13 Regional Indicators), cursor navigation & mid-UTF-8-byte safety, linear-time Korean prose & pure Hangul cursor walks, WB1–WB999 + `unicode_words`, SB1–SB11 + SB998, invalid/truncated UTF-8 handling, negative/zero/exact `SegmentLimits`, and 100,000-character O(n) DoS stress tests.

### Official Unicode 16.0.0 UCD Test Suites (100% Pass)

All three normative Unicode 16.0.0 UAX #29 test files pass with **0 failures**:

| Official UCD Test File | Passed / Total | Pass Rate | Notes |
| --- | ---: | ---: | --- |
| `GraphemeBreakTest.txt` | 1,093 / 1,093 | 100.00% | Also verified `is_grapheme_boundary`, `next_grapheme_boundary`, `prev_grapheme_boundary` on every vector |
| `WordBreakTest.txt` | 1,826 / 1,826 | 100.00% | Full WB1–WB999 compliance |
| `SentenceBreakTest.txt` | 512 / 512 | 100.00% | Full SB1–SB11 + SB998 compliance |
| **Total** | **3,431 / 3,431** | **100.00%** | **0 deviations** |

### 4-Mode Verification (`wasm_smoke`)

`packages/unicode_segment/wasm_smoke` builds and executes cleanly across `native debug`, `native --release`, `wasm32 debug`, and `wasm32 --release` with byte-identical stdout:

- Stdout: `unicode_segment_wasm_smoke: OK samples=7 g=129 w=72 uw=34 s=16 lim=1 fnv64=5958427692630882875`
- Stdout SHA-256 (all 4 modes): `89e7ea936b3cbdde07b4a38e5ded9546787d5f30c3aab9d7d2055c3676d1ccbb`
- Wasm32 binary size: `84,973 B` (debug) / `84,948 B` (`--release`)

### Differential Oracle & Head-to-Head Benchmarks vs Rust `unicode-segmentation 1.12.0`

- **Differential oracle (`bench/run_bench.sh`)**: **20/20** multilingual/edge-case test lines matched **byte-for-byte (0 deviations)** across `grapheme_indices`, `word_bounds`, `unicode_word_bounds`, and `sentence_bounds` against pinned Rust `unicode-segmentation =1.12.0` (the Unicode 16.0.0 release).
- **Head-to-head steady-state benchmarks**: measured on `Linux x86_64` via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, byte-identical stdout SHA-256 verified across all rounds; each iteration runs Grapheme + Word + Unicode Words + Sentence segmentation over the full corpus):

#### Corpus 1: Multilingual Web/Social (ZH/JA/KO/EN/DE/EL/RU/AR/HE/Devanagari GB9c/Emoji ZWJ/Flags, 5.45 MB total)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Speedup (vs `rust_segment`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion_segment` (`--release`) | 81.680 | 75.547 | 129.691 | 66.76 | 0.51x |
| `rust_segment` (`1.12.0 --release`, LTO) | 41.823 | 39.710 | 58.587 | 130.38 | 1.00x (baseline) |

- Verified stdout SHA-256: `ec165b39282eeeee184088d9eb7422bb069d4f01fada5acd2dcd3d0008a9e9a8`

#### Corpus 2: Technical Docs & Dense Punctuation/Numbers/Abbreviations (4.93 MB total)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Speedup (vs `rust_segment`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion_segment` (`--release`) | 143.558 | 110.670 | 201.887 | 34.33 | 0.45x |
| `rust_segment` (`1.12.0 --release`, LTO) | 65.265 | 60.670 | 81.522 | 75.51 | 1.00x (baseline) |

- Verified stdout SHA-256: `b5b966a2fa1a51a41723176d7a5f833609c13df3ccf66be50e45151e20c01472`
