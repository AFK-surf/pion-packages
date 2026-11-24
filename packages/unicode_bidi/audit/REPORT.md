# Red-team audit — `packages/unicode_bidi` v0.1.0

- Target: `origin/feat/pkg-unicode-bidi` @ `a14e5a742d` (`packages/unicode_bidi/src/**` untouched by this audit).
- Oracles: Rust `unicode-bidi =0.3.18` + `unicode-bidi-mirroring =0.4.0` (`audit/rust`, `--release`),
  Unicode 16.0.0 UCD (`DerivedBidiClass.txt`, `BidiBrackets.txt`, `BidiMirroring.txt`,
  `BidiCharacterTest.txt`, `BidiTest.txt`), UAX #9 revision 50 text, and ICU4C `ubidi`
  (macOS `libicucore`, `scripts/icu_oracle.py`) as a tie-breaker when Pion and Rust disagree.
- Machine: Mac Studio (arm64), `pionc 0.1.0`, `cargo 1.100.0`, node 24.22.2.
- Reproduce everything: `sh packages/unicode_bidi/audit/run_audit.sh` (≈4 min; `QUICK=1` for a smaller run).
  All artefacts go to `$AUDIT_TMP` (default `/private/tmp/redteam-bidi`); `git status --ignored` stays clean.

## Verdict

No P0. The UAX #9 core is a faithful port and is **conformance-clean** (91,707/91,707
BidiCharacterTest, 770,241/770,241 BidiTest cases), byte-identical in all four build modes, and
never panicked on any hostile range, invalid UTF-8 or depth/bracket bomb. In the differential, Pion
is **more correct than the Rust oracle** in every non-overflow mismatch (a Rust 0.3.18 N0 bug).
What must be fixed: one spec violation in BD16 overflow handling (P1), a quadratic and ~30–100×
slower per-line path (P1), 14× memory amplification at the advertised 16 MiB limit (P1), and a set
of table / API defects (P2).

| # | Sev | Finding | Evidence |
|---|-----|---------|----------|
| 1 | **P1** | BD16 stack overflow keeps earlier bracket pairs; spec says *return an empty list* | `p1_bd16_*` (2 tests) |
| 2 | **P1** | Per-line APIs copy the whole text's levels element-by-element → O(lines × text), 50–80× slower than Rust (225 KB / 25k lines: 87 s vs 1.06 s) | `dos.py` `paragraphs_*`, `crlf_ws_lines_*` |
| 3 | **P1** | ~65 bytes RSS per input byte: 16 MiB input → 1.04 GiB native / 1.75 GiB wasm32-under-node (Rust 73 MiB; with per-line reorder 1,044 vs 133 MiB) | `dos.py` `max_input_16mib_mixed` |
| 4 | P2 | 3,970 scalars have a Bidi_Class different from UCD 16.0.0 (noncharacters/default-ignorables L→BN; unassigned Arabic-default ranges R→AL) | `tables.py`, `p2_bidi_class_*`, `p2_noncharacter_prefix_*` |
| 5 | P2 | `default_level = Level::new(126)` yields `Level`s 127/128 (invariant 0..=126 broken; Rust panics) | `p2_default_level_126_*` |
| 6 | P2 | `BidiInfo::new` swallows `InputTooLong` → empty `levels` for non-empty text | `p2_new_silently_drops_levels_*` |
| 7 | P2 | `bidi_line_levels` helper applies paragraph 0's level in L1 to every paragraph | `p2_bidi_line_levels_*` |
| 8 | P2 | Line ranges inside a UTF-8 sequence are accepted and the RTL path emits U+FFFD per stray byte (output longer than the range) | `p2_reorder_line_mid_char_*` |
| 9 | P2 | `bidi_visual_order(Array[Int])` loops `max-min` times on unvalidated ints (`[0, 2e9]` → 2.2 s, `[-2e9, 1]` → 2.9 s) | manual probe below |
| 10 | P2 | Process: upstream conformance suites not ported; package missing from `index/`, README and BENCHMARKS.md | — |

Controls that passed (must stay green): N0 previous-strong scan across level runs (Rust gets it
wrong), overflow not resumed in later level runs (Rust resumes), BD16 canonical equivalents,
depth-125 overflow with unbalanced PDF/PDI, hostile `TextRange`s, invalid-UTF-8 byte soup, tiny
inputs, `Limits` edge values, lone 0xE0 before RLE.

## Commands and measured output

### 1. Red-team unit tests (`redteam_test.pion`)

```
cd packages/unicode_bidi/audit && pionc test --json -p unicode_bidi_audit .
total=18 passed=9 failed=9
  p1       fail=  2 pass=  0
  p2       fail=  7 pass=  0
  control  fail=  0 pass=  9
redteam_test.pion:80:  `)` must be level 0 once BD16 overflowed, got 1
redteam_test.pion:88:  `)` must be level 0, got 1
redteam_test.pion:103: cp 8293 expected BN (UCD 16), got L
redteam_test.pion:116: cp 2155 expected AL (UCD 16 @missing), got R
redteam_test.pion:125: P2 must skip BN U+FFFF; paragraph should be RTL
redteam_test.pion:139: level 127 > 126 at byte 1
redteam_test.pion:150: levels.length()=0 for 16777217 bytes
redteam_test.pion:159: trailing WS of the RTL paragraph must reset to 1 (L1), got 0
redteam_test.pion:170: reorder_line(1..5) returned 7 bytes for a 4-byte range
```

### 2. Tables over all 1,112,064 scalar values (`scripts/tables.py`)

```
Bidi_Class  pion==rust on all 1112064 scalars: True
Bidi_Class  pion vs UCD 16.0.0: 3970 code points differ in 35 ranges
    pion/rust=R   UCD16=AL : 12 ranges e.g. 086B..086F, 088F, 0892..0896, 10D28..10D2F, 10D3A..10D3F, 10EC0..10EC1, 10EC5..10EFB, 10F5A..10F6F
    pion/rust=L   UCD16=BN : 23 ranges e.g. 2065, FDD0..FDEF, FFF0..FFF8, FFFE..FFFF, 1FFFE..1FFFF, ... E0000, E0002..E001F, E0080..E00FF, E01F0..E0FFF
BidiBrackets (128 entries): pion==UCD16 True  pion==rust True      (BD16 canonical skeletons U+2329/232A -> U+3008/3009 included)
BidiMirroring: UCD16=428 pion=428 (==UCD16 True) rust-mirroring-0.4.0=407 (missing 21: U+223D, U+224C, ...)
```

### 3. Conformance (`scripts/conformance.py`)

```
BidiCharacterTest  pion  total=  91707 failed=0
BidiCharacterTest  rust  total=  91707 failed=0
BidiTest           pion  total= 770241 failed=0
BidiTest           rust  total= 770241 failed=0
```

### 4. Differential fuzz vs Rust (`scripts/diff_fuzz.py --fuzz 30000`)

Corpus: 6,770 targeted inputs × {auto, LTR, RTL} (BD16 canonical/cross-type brackets; 61–130 opens
with and without isolate-split sequences; depth 60–250 of every initiator with PDF/PDI tails;
unmatched PDI/PDF; FSI first-strong with nested isolates/embeddings and paragraph breaks;
ES/CS/ET/NSM with BN/explicit runs; every pair of L1-reset classes before TAB/CRLF/LF/U+2029/U+0085/S;
N0 across isolate-split level runs) + 30,000 random + 10,000 mutated = **60,310 records**, each
compared on paragraphs, per-byte classes and levels, `has_rtl`, `get_base_direction{,_full}`,
paragraph direction, and for the whole paragraph and a mid-point split: L1 levels, L2 visual runs,
per-char levels and `reorder_line` bytes.

```
records=60310 identical=60093 mismatches=217 rust_panics=0
ICU4C adjudication of mismatches: {'icu_agrees_pion': 205, 'bd16_overflow(spec-adjudicated)': 6,
                                   'ucd_table_confounded': 5, 'icu_agrees_neither': 1}
```

- **205 × Rust bug, Pion correct.** Rust 0.3.18 `IsolatingRunSequence::iter_backwards_from` chains
  the earlier level runs with `flat_map(Clone::clone)`, i.e. walks them *forwards*; N0's
  "first strong before the opening bracket" (and the W4–W6 BN back-fill) therefore picks the first
  strong of the earlier run instead of the last. Minimal: LTR `a א LRI x PDI ( ב )` — Pion & ICU: `(`,`)`,
  LRI, PDI at level 1; Rust: 0. Locked in by `control_n0_previous_strong_across_level_runs_beats_rust`.
- **6 × BD16 overflow.** Rust `break`s only the current level run and keeps matching closers in the
  next run of the same sequence; Pion stops for the whole sequence. Pion is closer to the spec here
  (`control_bd16_overflow_not_resumed_in_next_level_run`) but still wrong in general (finding 1).
- **5 × table-confounded**: inputs containing finding-4 code points (ICU uses UCD data, the two ports agree).
- **1 × "neither"**: `-ا a FSI NBSP PDI SHY [ PDI FSI y PDI a ] U+0670` — the only differing char is
  the NSM after `]`; UAX #9 N0 ("NSMs following a paired bracket that changed to L/R change to match")
  gives L → level 2 as Pion does; ICU leaves it at 1. Not a Pion defect.

### 5. Four-mode parity (`scripts/wasm4.py`, wasm executed under node)

```
info[10970 recs]  identical=True  native_debug=0.54s native_release=0.54s wasm32_debug=0.94s wasm32_release=0.95s
info[3000 recs]   identical=True  (raw invalid-UTF-8 byte soup)
info[6 recs]      identical=True  (20k bracket/isolate bombs, 2k paragraphs, 5k FSI nest)
cls / tab         identical=True
4-mode parity: ALL IDENTICAL   — no trap, stack overflow or OOM in any mode
```

### 6. DoS / complexity / memory (`scripts/dos.py`, seconds, `one <file> lines|l1`)

```
case                          pion x1  pion x2  grow     rss |  rust x1  rust x2  grow | 4-mode
open_brackets_50k               0.010    0.014     -     9.8 |    0.007    0.008     - | ok
alternating_pairs_50k           0.016    0.029     -    19.3 |    0.008    0.010     - | ok
pairs_with_strong_50k           0.022    0.043   2.0    31.1 |    0.010    0.044     - | ok
nested62_blocks                 0.020    0.020     -     9.9 |    0.015    0.013     - | ok
nested62_neutral_body           0.013    0.019     -     9.8 |    0.010    0.014     - | ok
lri_x50k_pdi_x50k               0.027    0.048   1.8    40.9 |    0.013    0.016     - | ok
fsi_x50k_pdi_x50k               0.028    0.048   1.7    40.9 |    0.010    0.015     - | ok
rle_x50k_pdf_x50k               0.028    0.048   1.7    40.9 |    0.009    0.015     - | ok
lri_a_pdi_x50k                  0.057    0.112   2.0    71.5 |    0.020    0.040     - | ok
ws_x50k_rtl                     0.011    0.014     -     9.8 |    0.008    0.007     - | ok
bn_x50k_rtl                     0.015    0.022     -    17.8 |    0.008    0.010     - | ok
nsm_x50k_after_pdi              0.014    0.023     -    17.8 |    0.009    0.013     - | ok
cs_bn_mix_50k                   0.012    0.022     -    16.6 |    0.008    0.012     - | ok
et_bn_run_50k                   0.020    0.032     -    27.5 |    0.010    0.014     - | ok
max_levels_alternating          0.059    0.107   1.8    16.6 |    0.014    0.024     - | ok
paragraphs_rtl_x5k              1.386    3.246   2.3     5.4 |    0.027    0.054   2.0 | ok
paragraphs_rtl_x5k_l1only       0.403    4.646  11.5     5.4 |    0.016    0.037     - | ok
paragraphs_ltr_x5k_l1only       0.535    2.371   4.4     4.5 |    0.010    0.027     - | ok
crlf_ws_lines_3k                1.326    5.554   4.2     7.3 |    0.032    0.137   4.3 | ok
line_levels_single_line_rtl         0.023    0.042   1.8     9.8 |      n/a      n/a     - | ok
vis_levels_0_125_50k            0.014    0.025     -     5.0 |      n/a      n/a     - | ok
max_input_16mib_mixed           1.651        -     -  1044.4 |    0.445        -     - | ok   (rust_rss=133.0 MB)

(--only re-run, idle host) crlf_ws_lines at 12.5k/25k lines (112/225 KB):
crlf_ws_lines_50k              22.933   87.104   3.8    22.4 |    0.293    1.061   3.6 | ok
```

All bracket / isolate / embedding / WS / BN / NSM bombs at 50k–100k are linear (N0 is bounded by the
63-deep stack: Σ enclosed ≤ 63·N, the insertion sort of pairs by ≤ 63·P shifts); X5c FSI resolution
is O(1) per strong char; no recursion anywhere, so no stack overflow in any mode.

## Findings in detail

### P1-1 BD16 overflow must discard all pairs (`implicit.pion` `identify_bracket_pairs`)

UAX #9 rev 50, BD16: *"If an opening paired bracket is found and there is no room in the stack,
stop processing BD16 for the remainder of the isolating run sequence **and return an empty list**."*
Pion sets `overflowed = true`, breaks both loops, then still sorts and returns the pairs collected so
far. Repro (LTR): `א(ב)` + 64 × `(` → `)` at byte 5 resolves via N0 to R (level 1); with the empty
list N1 gives e = L (level 0). Rust 0.3.18 has the same bug (and additionally resumes in the next
level run), so the differential is blind to it; BidiCharacterTest has no case with a pair before an
overflow. Fix: on overflow `bp_start.clear()` (and siblings) before returning.

### P1-2 Per-line APIs are O(text) per call and ~50–80× slower than Rust

`BidiInfo::reordered_levels` pushes **every** `Level` of the whole text into a fresh array per call
(Rust does `self.levels.clone()`, a memcpy of u8s), then `visual_runs` / `reorder_line` call it again
(`reorder_line` → `visual_runs` → `reordered_levels`), and `reordered_levels_per_char` walks the whole
text. A document laid out line by line is therefore O(lines × bytes): 10k one-character RTL
paragraphs (30 KB) take 3.2 s vs 0.054 s in Rust; `l1`-only 4.6 s (×11.5 growth with allocator
pressure); 25k `א ␉LRI CR LF` lines (225 KB) take **87 s** vs 1.06 s in Rust (both quadratic — the
Rust API has the same clone — but Pion's constant is ~80× larger). Fix: compute L1 into a
line-local buffer for `visual_runs`/`reorder_line` (O(line)), bulk-copy for the public full-length
`reordered_levels`, and only sample the line in `reordered_levels_per_char`.

### P1-3 Memory amplification ~14× Rust at the default 16 MiB limit

`orig_tags`, `level_ints`, `proc_tags` (all `Array[Int]`, 8 B/elem) plus the materialised
`original_classes: Array[BidiClass]` and `levels: Array[Level]`, all per **byte**: 16,777,208-byte
mixed input → native max RSS 1,095,204,864 B (1.02 GiB) for `BidiInfo::new`, Rust 76,152,832 B
(`lines`: Pion 1,044 MiB vs Rust 133 MiB);
`node pion_wasm_rt.mjs pion_probe_release.wasm one big16.txt lines` → 1,837,023,232 B RSS. A wasm32
host doing this twice concurrently is near the 4 GiB address-space ceiling. Fix: `FixedArray[Byte]`
(or `Bytes`) for classes/levels, drop the duplicate materialisation, reuse `orig_tags` buffers.

### P2-4 Bidi_Class table diverges from UCD 16.0.0 on 3,970 scalars

`tables.pion` claims "Complete Unicode 16.0.0 UCD tables" but copies Rust's table, which (a) maps
noncharacters and unassigned default-ignorables to **L** where `DerivedBidiClass-16.0.0.txt` lists
**BN** (U+2065, U+FDD0..FDEF, U+FFF0..FFF8, U+nFFFE..nFFFF, U+E0000, U+E0002..E001F, U+E0080..E00FF,
U+E01F0..E0FFF), and (b) maps unassigned code points in Arabic-letter default blocks to **R** where
the `@missing` lines say **AL** (U+086B..086F, 088F, 0892..0896, 10D28..10D2F, 10D3A..10D3F,
10EC0..10EC1, 10EC5..10EFB, 10F5A..10F6F, 1EC70, 1ECB5..1ECBF, 1ED00, 1ED3E..1ED4F). Visible effect:
`"￿א"` gets an LTR paragraph (P2 should skip the BN). Mirroring (428) and brackets (128) are
exact. Fix: regenerate from DerivedBidiClass.txt including `@missing` defaults (and say "matches UCD",
not "matches Rust").

### P2-5 Paragraph level 126 breaks the `Level` invariant

`Level::new(126)` is accepted as `default_level`; I1/I2 then add 1–2 → levels 127/128 returned as
`Level` (Rust panics `Level number error`). Fix: reject/clamp default levels > 125 (UAX #9 HL1 only
needs 0/1) or saturate in `resolve_implicit_levels`.

### P2-6 `BidiInfo::new` silently returns an empty analysis

For > 16 MiB it returns `levels = []`, `paragraphs = []` for a non-empty text; `bidi_line_levels`
returns `[]`. Callers indexing per byte/char go out of bounds. Fix: make `new` total (fall back to
LTR levels) or remove it in favour of the `Result` API.

### P2-7 `bidi_line_levels` uses paragraph 0's level for all paragraphs

`"a\nא "` → trailing space of the RTL paragraph gets level 0 instead of 1. Fix: run L1 per
paragraph (or document/enforce single-paragraph input).

### P2-8 Mid-character line ranges are accepted and corrupt the output

`reorder_line(TextRange(1, 5))` on `אבג` returns 7 bytes (stray continuation bytes re-encoded as
U+FFFD); the LTR fast path instead returns a byte slice that is not valid UTF-8. Rust panics. Fix:
snap or reject non-boundary ranges (`InvalidLineRange` already exists in `BidiError`).

### P2-9 `bidi_visual_order` trusts caller ints

`cur_max` walks from max to min level one step at a time over the whole array:
```
echo "0,2000000000" > vis.txt;  pion_probe one vis.txt vis 1   -> real 2.20 s (2 elements)
echo "-2000000000,1" > vis2.txt; pion_probe one vis2.txt vis 1 -> real 2.91 s
```
O((max−min)·n) for arbitrary `Array[Int]` from callers. Fix: clamp to 0..=126 or iterate only over
distinct levels.

### P2-10 Process gaps (AGENTS.md §1.1/§1.3/§1.4)

`bidi_test.pion` has 10 hand-written tests; the upstream conformance suites (BidiCharacterTest /
BidiTest, both 100 % green per §3 above) are not ported. `unicode_bidi` is not yet in `index/`,
README's package list or `BENCHMARKS.md`.

## Performance clues for the fix wave (Bench 2/4 at 0.52×–0.55× of Rust)

Static reading plus the phase probes above (`sample` was unavailable on the shared host):

1. **Five per-byte 8-byte arrays** built per `BidiInfo::new` (Rust: three `u8` vectors): Pass 1
   `orig_tags.push` per byte, Pass 2 `level_ints.push` per byte, a full `proc_tags` copy as soon as one
   paragraph is not pure LTR, then `bidi_class_from_int` + `Level` materialisation per byte. Memory
   traffic ~10× Rust; see P1-3.
2. **Per-line full-text copy** (P1-2) — Bench 4 calls `visual_runs` and `reorder_line`, i.e. three
   `reordered_levels` per line with element-wise `push`.
3. **Allocation churn per paragraph / isolating run sequence**: fast-path `IsoRunSeq` allocates two
   arrays per level run; `resolve_weak` / `resolve_neutral` / `identify_bracket_pairs` allocate ~10
   arrays per sequence (`et_run_indices`, `bn_run_indices`, `bp_*`×4, bracket stacks×3, `ni_run`) and
   the explicit stack per paragraph — reuse scratch buffers across paragraphs.
4. **Non-ASCII class lookup**: binary search over two parallel ~1,500-entry arrays (`bidi_range_lo`,
   `bidi_range_hi_tag`) per char; a two-level page table (or a BMP 64 K byte table) removes it; Hebrew/Arabic
   text hits it on every letter.
5. **`reorder_line_from_runs`** decodes each RTL run into a `cps` array and re-encodes; reversing by
   UTF-8 char boundaries with byte copies avoids decode/encode.
