# Red-team audit: `packages/unicode_segment` v0.1.0 (RT-unicode-segment)

> **NOT SIGNED OFF.** 1 P1 and 1 P2 finding are OPEN (below). No P0: every correctness, determinism,
> table, conformance and mutation check passes.

- **Audited commit:** `origin/feat/pkg-unicode-segment` @ `aa2d0a146c437fb2bcdceb03c249c102de000849`
- **Scope:** UAX #29 16.0.0 grapheme / word / sentence segmentation, `unicode_words`, cursor APIs
  (`is_` / `next_` / `prev_grapheme_boundary`), `SegmentLimits`, the generated tables (`tools/gen_tables.py`,
  `src/tables.pion`), ill-formed UTF-8, `Send` claims, determinism across native / wasm32 × debug / release,
  README claims and benchmarks.
- **Method:** independent audit package (`audit/`, public API only) with an in-process invariant checker,
  an independent UCD reader (`diff/ucd.py`, stdlib only, written from UAX #44, not from `gen_tables.py`) over the
  vendored official Unicode 16.0.0 files, an in-Pion dump of the package's own table lookup for every code
  point, the full official `GraphemeBreakTest` / `WordBreakTest` / `SentenceBreakTest` 16.0.0, two Rust oracles
  (`unicode-segmentation =1.13.3` as requested and `=1.12.0`, the last Unicode 16.0.0 release; both `--locked`),
  6,200 seeded fuzz inputs + 96 hand-written adversarial inputs, 21 bomb shapes × 5 APIs at 100,000+ units,
  a cursor-walk complexity probe, real `pionc check` `Send` probes, and 14 injected defects.
- **Re-run:** `sh packages/unicode_segment/audit/run_audit.sh` (~2.5 min on a 16-core Linux box; needs `pionc`,
  `node`, `cargo`, `python3`). Exit 1 only for P0 conditions; with `STRICT=1` the OPEN findings below also fail
  the run. Every README number is parsed from `README.md` at run time (`diff/readme.py`); the checks accept any
  reasonable fix, so the gate can be run unmodified on a fix branch.

## Result on `aa2d0a1` (pvg-office-2, x86_64 Linux, load ~9)

`STRICT=1 sh packages/unicode_segment/audit/run_audit.sh` → **EXIT=1**, OPEN = **P1-1, P2-1**, 0 P0.
Without `STRICT` the same run exits 0.

| Section | Result |
| --- | --- |
| static | MIT, 0 deps, 0 `extern "C"`, 0 `World`, 0 `FixedArray`, 0 `panic`, 0 module-level `let mut` / containers, 0 `Double`/`Float`, 0 internal host names; `gen_tables.py --check` on the official 16.0.0 files: byte-identical |
| Send | `SegmentSpan`, `SegmentLimits`, `SegmentError`, `String`: `Send` (= README). `Array[SegmentSpan]`, `Array[String]`: `!Send` (`E_NOT_SEND`, = README); `move` into `spawn` **and `Mutex::new(arr)` captured in `spawn` + `with_lock` compile** (SPEC: `Mutex[Array[E]]` with `E: Send` is shareable) — the README's `Mutex::new(...)` advice is **true**; README `count_in_worker` example compiles and runs |
| unit | 12/12 package tests (= README); 5/5 audit control tests; `scripts/verify.sh packages/unicode_segment` PASS |
| tables | in-Pion lookup of all **1,114,112** code points × 7 properties (GCB, ExtPict, InCB, WB, ExtPict, alnum, SB) vs the UCD: **0 mismatches**; out-of-range code points (−1, 0x110000, Int max / min) read as the default class |
| conformance | GraphemeBreakTest **1,093/1,093**, WordBreakTest **1,826/1,826**, SentenceBreakTest **512/512**, each also checked for tiling, `concat(graphemes / words / sentences) == s`, string = byte slice, `is_` / `next_` / `prev_grapheme_boundary` at **every byte offset −3..=n+3** (incl. inner UTF-8 bytes) and Int extremes, the full `SegmentLimits` contract — in all 4 modes |
| oracles | Rust 1.12.0 (Unicode 16.0.0): **9,727 inputs × 4 APIs, 0 differences**. Rust 1.13.3 (Unicode 17.0.0): 0 unexplained; 39 inputs differ only on code points whose properties changed 16 → 17 (INFO-3). README differential corpus: 20/20 (= README) |
| determinism | 9,727 inputs (365 with ill-formed UTF-8) + 130-line limit sweep: native / wasm32 × debug / release byte-identical |
| dos | 21 bomb shapes × 5 APIs at N and 4N (100,000–1,000,000 units, up to 7.2 MB): all linear (max ratio 6.4 with N timed at ≥ 5 ms, typical 4.0), worst 0.47 s, peak RSS 69 MiB; wasm32 --release agrees. **Cursor walk quadratic on Korean / Hangul (P1-1)**, on RI runs (INFO-4) |
| smoke | `wasm_smoke` 4 modes SHA-256 `89e7ea93…ccbb` (= README), stdout = README; wasm sizes 84,476 / 84,451 B (README 84,973 / 84,948; path-dependent) |
| bench | `bench/run_bench.sh`: 20/20; stdout SHA-256 `ec165b39…` / `b5b966a2…` (= README); speedups 0.60x / 0.42x vs README 0.53x / 0.40x |
| inject | **14/14** injected defects caught |

## OPEN findings

### P1-1 — cursor APIs are O(n²) on ordinary Korean text (and any run without two adjacent "neutral" code points)

`is_grapheme_boundary`, `next_grapheme_boundary` and `prev_grapheme_boundary` (`src/grapheme.pion:388/431/467`)
all start from `find_safe_grapheme_anchor` (`src/grapheme.pion:340`), which walks backwards until it finds **two
consecutive** code points accepted by `g_is_neutral_base` (`:9`: `GCB=Other`, not `Extended_Pictographic`,
`InCB=None`) and re-scans forward from there. Hangul syllables (`GCB=LV/LVT`), Indic consonants
(`InCB=Consonant`), marks (`Extend`/`SpacingMark`), emoji and regional indicators are never neutral, and a single
space between words is only one neutral code point — so in Korean prose without punctuation (chat messages,
titles, search queries, Hangul-only fields) every call rescans back to the start of the run: one call costs
O(distance), walking the text with `next_grapheme_boundary` / `prev_grapheme_boundary` (the README's "editor
cursor navigation", exactly what `wasm_smoke` does) costs O(n²). There is no `*_with_limits` variant for these
three APIs (README: "Every segmentation entrypoint has a `*_with_limits` variant") and the README promises
"strict O(n) linear time".

Reproduce (`run_audit.sh dos`, audit CLI `cursor <kind> <units>`; forward walk to the end then backward walk to 0):

| text | 4N bytes | t(N) | t(4N) | ratio | Rust 1.13.3 `GraphemeCursor`, same walk |
| --- | ---: | ---: | ---: | ---: | ---: |
| `ko_prose` ("안녕하세요 세계 반갑습니다 " × 800) | 31,200 | 0.41 s | **5.17 s** | 12.6 | 0.33 ms |
| `gb_hangul` ("가각" × 8000) | 48,000 | 0.56 s | **9.69 s** | 17.2 | 0.48 ms |
| `en_prose` | 54,000 | 1.3 ms | 5.4 ms | 4.1 | 0.90 ms |
| `hi_prose` (has vowel letters after spaces) | 81,600 | 4.0 ms | 19 ms | 4.7 | — |

(On an M5 Max: 46,800 B of `ko_prose` = 8.3 s vs Rust 0.35 ms, ≈ 24,000×.) A 1 MB Korean document would take
on the order of an hour; a single `is_grapheme_boundary` call costs a full scan of the run before the offset.

Root cause / fix direction: the only state that crosses a boundary is GB9c (InCB consonant chain), GB11
(`ExtPict Extend* ZWJ`) and GB12/13 (RI parity). A position X is a safe anchor whenever the break before X does
not depend on that state and X's own successor state is independent of its predecessor — e.g. accept X when
`grapheme_should_break(Y, X)` is `true` for every `(ri_odd, ep_state, incb_state)` combination and X is not
`Extend` / `ZWJ` / `SpacingMark` / RI / InCB=Linker|Extend (then the DFA state after X is exactly the fresh
state). Every Hangul syllable after another (`LVT ÷ LV`, `LV ÷ LV`), every letter after a space, etc. qualifies,
so the lookback becomes O(1) except inside genuinely stateful runs (RI, long Extend chains), which matches Rust.
Add a cursor bomb (Korean prose) to the package's own DoS test. The gate closes this when the `ko_prose` and
`gb_hangul` cursor walks are linear (ratio ≤ 8).

### P2-1 — README: the Rust oracle "`unicode-segmentation 1.13.3` (Unicode 16.0.0 aligned)" is false

`unicode-segmentation 1.13.3` embeds **Unicode 17.0.0** tables (`src/tables.rs:17`,
`UNICODE_VERSION = (17, 0, 0)`; the audit oracle prints it). It is not 16.0.0-aligned: on the official 16.0.0
vectors it fails `GraphemeBreakTest` line 1105 (`✁ ZWJ ✁`, U+2701 lost `Extended_Pictographic` in 17.0) and the
matching WordBreakTest lines 1733 / 1734 (U+2701 after ZWJ), and on the fuzz corpus it differs from Pion on 35
inputs, all on code points whose properties changed in 17.0. Pion is right in every one of these cases (1.12.0,
the last Unicode 16.0.0 release, agrees with Pion on all 9,727 inputs). The README's "20/20, 0 deviations"
holds only because the 20 lines contain no such code point. `bench/rust_bench/Cargo.toml` asks for
`unicode-segmentation = "1.12.0"` (a caret requirement) while `Cargo.lock` pins 1.13.3, so the oracle silently
moved to Unicode 17. Fix: pin `"=1.12.0"` in `bench/rust_bench/Cargo.toml` and regenerate `Cargo.lock` (and the
README rows), or keep 1.13.3 and state that it is Unicode 17.0.0 and differs from 16.0.0 on drifted code points.
The gate closes this when the README's stated Unicode version of the locked oracle matches the crate's.

## INFO (not defects, not blocking)

- **INFO-1** Root `THIRD_PARTY_NOTICES.md` does not list the package's Unicode 16.0.0 data (6 UCD files,
  Unicode-3.0): root file, release integration.
- **INFO-2** README "`0` is enforced strictly (accepting only empty input)": `unicode_word_bounds_with_limits` /
  `unicode_words_with_limits` with `max_segments = 0` return `Ok([])` for non-empty input that contains no word
  (`"  !!  "`). That is the right semantics (0 segments ≤ 0); only the wording is too broad.
- **INFO-3** Rust 1.13.3 is Unicode 17.0.0: the comparator explains a difference only when the input contains a
  code point whose GCB / WB / SB / ExtPict / InCB / alphanumeric value differs between the vendored 16.0.0 and
  17.0.0 files (6,076 code points); nothing is explained against 1.12.0.
- **INFO-4** Walking a long run of regional indicators with the cursor APIs is quadratic (16× per 4×): RI parity
  genuinely needs the whole run, and Rust's `GraphemeCursor` rescans as well. Same remedy as P1-1 bounds it to
  RI runs only.
- **INFO-5** Benchmarks: measured 0.60x / 0.42x vs README 0.53x / 0.40x; stdout SHA-256s identical.
- **INFO-6** wasm32 sizes are ~0.6 % below README (the binary embeds absolute source paths).
- **INFO-7** Mutation candidate "remove the mid-UTF-8 lead-byte alignment loop in `find_safe_grapheme_anchor`" is
  an **equivalent mutant**: the backward walk re-synchronises through its `start + clen != cur` branch, and every
  cursor result at every byte offset of the 9,727 inputs stays identical. The loop is redundant, not wrong; it was
  replaced in the proof by a real decoder defect.
- **INFO-8** Ill-formed UTF-8 (reachable through `\xHH` literals, `StringBuilder::write_byte`,
  `Bytes::to_string`): each byte that does not start a well-formed sequence is one U+FFFD of length 1 (not the
  WHATWG "maximal subpart" substitution). Consistent across all APIs, cursors and 4 modes, never splits a
  well-formed sequence, and equal to Rust run on the same scalar sequence (the oracle maps offsets back).

## What was attacked (and held)

1. **Tables** — independent UCD reader (ranges, `<…, First>`/`<…, Last>` blocks, InCB values, Alphabetic +
   GC N*) vs the package's own lookup compiled from a copy of `src/` with one exported accessor, all 1,114,112
   code points, BMP pages and every SMP range edge: 0 mismatches. `gen_tables.py --check` byte-identical.
2. **UAX #29 16.0.0** — all 3,431 official vectors, plus 2,000 mutations of them (insert / replace / delete
   1–3 code points drawn per property class), 4,000 random strings drawn per GCB / WB / SB / InCB / ExtPict class,
   200 long mixtures (6,200 fuzz inputs, 365 with ill-formed bytes), 96 hand-written cases (GB9c chains in Devanagari / Bengali / Malayalam / Gujarati / Telugu
   incl. nukta / ZWJ / Extend / double linker, ZWJ families with skin tones and FE0F, keycaps, tag flags, odd /
   even / 101-long RI runs, RI with Extend / ZWJ between, Hangul jamo and syllables, Prepend chains, Hebrew
   `'` / `"` with Extend, abbreviations `Dr. U.S.A. e.g. 3.14`, full-width CJK punctuation, SB8 / SB8a / SB9-11
   close / space chains, ParaSep variants, 14 ill-formed UTF-8 shapes, CR/LF runs, controls, SMP edges).
   Pion = Rust 1.12.0 on every input and API.
3. **DoS** — SB8 / SB8a / SB11 (`ATerm Close* Sp*` ×100k, with Extend, STerm variant, `ATerm Sp Numeric`
   ×100k, one 1,000,000-unit SB8 lookahead), WB6 / WB7 / WB7b / WB11 / WB12 (`ALetter Extend MidLetter Extend`
   ×100k, `Numeric Extend MidNum Extend` ×100k, MidLetter + 8 Extend ×100k, Hebrew `"`), GB9c / GB11 / GB12
   (`Consonant Extend Linker Extend` ×100k, `ExtPict Extend ZWJ` ×100k, RI ×100k), Extend, Hangul, CR/LF,
   ill-formed bytes, prose: all linear in all 5 APIs.
4. **`SegmentLimits`** — for every input of every corpus and all 9 `*_with_limits` APIs: exact `(n, k)` accepted
   with `k` segments, `(n, k−1)` and `(n−1, ·)` rejected, negative and Int-min limits rejected (also on `""`),
   Int-max and default limits equal the unlimited API; `grapheme_count_with_limits` included.
5. **Byte offsets** — `SegmentSpan` is documented as UTF-8 byte offsets and Pion `String` is UTF-8 bytes
   (`SPEC.md`): every span equals `s.slice(start, end)` and `slice_span`; cursor APIs at every inner byte of 2-,
   3- and 4-byte sequences (👨‍👩‍👧‍👦, 🇨🇳, CJK), negative, past-the-end and Int-extreme offsets: correct, no panic, no
   loop.

## Files

`run_audit.sh` (gate), `src/main.pion` (audit CLI: `dump`, `bomb`, `cursor`, `api`), `redteam_test.pion`
(control tests), `tabprobe/*.in` (table accessor + dumper, compiled only against a copy of the package),
`diff/ucd.py` (UCD reader, table check, 16 → 17 drift set), `diff/gen.py` (corpora), `diff/compare.py`,
`diff/dos.py`, `diff/inject.py` (14 mutants), `diff/readme.py`, `diff/rust` (`=1.13.3`) and `diff/rust12`
(`=1.12.0`) oracles, `ucd/` (official Unicode 16.0.0 data + test files and the 17.0.0 property files, gzip,
Unicode License v3 in `ucd/LICENSE`).
