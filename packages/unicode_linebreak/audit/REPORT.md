# Red-team audit: `packages/unicode_linebreak` v0.1.0 (RT-unicode-linebreak)

> **NOT SIGNED OFF**: 1 P1 and 4 P2 findings are open (below). `STRICT=1 sh packages/unicode_linebreak/audit/run_audit.sh`
> exits 1 until they are fixed; the default mode exits 0 (no P0).

- **Audited commit:** `origin/feat/pkg-unicode-linebreak` @ `c79ed32e76553ba53b6e58b08904c01ff4207613`
- **Scope:** Unicode 16.0.0 UAX #14 (revision 53) rules LB1-LB31 incl. Mandatory / Allowed kinds, the
  generated `Line_Break` / East_Asian_Width / General_Category / Extended_Pictographic tables over all
  1,114,112 code points, `tools/gen_tables.py`, UTF-8 handling, `next_break_opportunity`,
  `line_breaks_with_limits` / `LineBreakLimits`, the inlined ASCII `AL x AL` fast path, DoS behaviour,
  `Send` claims, determinism across native / wasm32 x debug / release, `wasm_smoke`, benchmarks and every
  number in `README.md`.
- **Method:** an independent red-team package (`audit/`, public API only) plus a white-box dump of the shipped
  tables; an independent UCD loader (`diff/ucd.py`) cross-checked against Unicode's own `extracted/Derived*.txt`
  files on every code point; an independent UAX #14 16.0.0 model written rule by rule from tr14-53
  (`diff/model.py`, stdlib only, unit-list design unlike the package's streaming state machine, 16,672/16,672 on
  the official vectors); Rust `icu_segmenter =2.4.0` (`diff/rust`, `--locked`); 71,185 inputs (official vectors,
  hand-written adversarial cases, all ordered pairs of the 68 property combinations, an exhaustive ASCII
  fast-path corpus, 20,000 seeded fuzz strings with ill-formed UTF-8, ICU probes); 25 DoS bombs at n and 4n,
  self-timed in process; 20 injected bugs.
- **Re-run:** `sh packages/unicode_linebreak/audit/run_audit.sh` (~3.5 min on an 8-core Linux x86_64 box; heavy:
  run it on a build machine). Exit status 1 only for P0 conditions; with `STRICT=1` every open finding below
  also fails the run. Every README number is parsed from `README.md` at run time (`diff/readme.py`); the
  red-team cases use only the public API and accept any correct fix, so the gate runs unmodified on a fix branch.
  All Python runs as `python3 -I -B` (no `__pycache__`), all artifacts go to `$AUDIT_OUT` (default
  `/tmp/pion-unicode-linebreak-audit`), and the run ends by checking that `git status --porcelain --ignored`
  shows nothing under `packages/unicode_linebreak` except the new `audit/`.

## Summary

| Dimension | Result |
| --- | --- |
| 1. Tables, 1,114,112 code points | public `line_break_class` (4 modes byte-identical, 3,597 runs) and white-box raw class / LB1 class / 6 flag bits vs the independent loader: **94 mismatches, all P2-1** (U+1F80C..U+1F8FF gaps: ID instead of XX); EA, QU_Pi, QU_Pf, ExtPict&Cn, U+2010, U+25CC flags: 0 mismatches (182,842 / 12 / 10 / 1,477 code points); `-2^31`, `-1`, `0x110000`, `0x7FFFFFFF` ... -> XX, no panic. `gen_tables.py` reproduces the data token for token but `--check` fails (P2-4) |
| 1. Official `LineBreakTest-16.0.0.txt` | **16,672 / 16,672** break positions; kinds (17,707 Mandatory / 9,883 Allowed) 0 mismatches vs the model; independent hard-break kind check (BK / LF / NL / lone CR Mandatory, never CR ÷ LF, nothing else Mandatory): 0 errors; invariants (strictly increasing, decoder code-point boundaries, `(len, Mandatory)` last, `[]` for empty) 0 errors over all 71,185 inputs |
| 1. `next_break_opportunity` == `line_breaks` | 1,086,694 calls (every byte offset incl. continuation bytes, plus `INT_MIN`, `-1000000`, `-2`, `-1`, `len`, `len+1`, `len+2`, `INT_MAX`) on 53,861 inputs: 0 inconsistencies, native == wasm32. Correct, but O(n) per call from byte 0: **P1-1** |
| 2. Independent model (offsets + kinds) | lbtest 16,672/16,672, named 181/189, pairs 17,200/17,324, fastpath 16,992/17,000, fuzz 19,160/20,000; every divergence reproduced exactly by emulating one of P2-1 / P2-2 / P2-3; **0 unexplained** |
| 2. Rust `icu_segmenter 2.4.0` | ICU itself passes 16,578/16,672 official vectors. Pion == ICU: lbtest 16,578, named 161/189, pairs 16,993/17,324, fastpath 16,955/17,000, fuzz 17,256/20,000; every difference is an ICU-side deviation measured here (15.1 data, pre-15.1 LB19, pre-16.0 LB21a, a U+25CC-pair bug, LB15c / LB20a / LB25 / LB31 lag, SA) or a Pion finding; **0 unexplained** |
| 3. DoS | 24 bombs (SP, CM, ZWJ, QU, QU_Pf / Pi, OP SP*, CL CP SP*, NU IS / SY chains, PR OP NU, PR OP IS CM* NU, RI, AK VI, HY AL, lookahead-over-CM runs, ill-formed bytes, limits, `next_break_opportunity(len-1)`) up to 3 MB: 4n/n ratio 1.8-6.1 over all runs (linear; gate < 8, the geometric midpoint of 4x and 16x), native and wasm32, no crash, no recursion. Iterating `next_break_opportunity`: ratio 10.7-19.8, 16,000 B -> 3.6-4.4 s native: **P1-1**. `LineBreakLimits` negative / 0 / exact / exact-1 / exact+1 / `INT_MIN` / `INT_MAX` on both limits for every input: 0 errors |
| 4. ASCII fast path | 17,000-input corpus (`"ab"+c+"cd"`, `"ab"+c+d+"cd"` for all ASCII c, d; every representative r as `"ab"+r+"cd"`, `"ab"+r+CM+"cd"`, `r+"ab"`, `"a"+ZWJ+r+"b"`) + 34 named seams: 0 divergences from the model except the P2-1 code points; mutant 13 (fast path after any class) is caught by 13 control cases |
| 5. `Send`, 4 modes, README | `pionc check --json`: `LineBreakClass`, `BreakKind`, `BreakOpportunity`, `LineBreakError`, `LineBreakLimits`, `String` Send; `Array[BreakOpportunity]` `E_NOT_SEND`: as README says. `wasm_smoke` stdout and SHA-256 `5b5e94c5…8b70` identical in 4 modes and equal to README; wasm32 79,508 B (README 79,508). Unit tests 15/15. Bench: differential 123/123, both stdout SHA-256 equal README, speed 0.17-0.18x of Rust (README 0.16x / 0.14x). No internal machine names |
| 6. Mutation proof | **20 / 20** injected bugs caught (LB4, LB5 x2, LB8, LB9, LB15a, LB15b, LB19a, LB20a, LB21a, LB25, LB28a, LB30a, LB30b, QU_Pi table flag, ASCII fast path, UTF-8 overlong, negative limits, `max_input_bytes` off by one, `next_break_opportunity` at the offset); every mutant is built and dropped in `$AUDIT_OUT`, the repository is never touched |

## Findings

Each finding has a red-team case (`redteam_*` in `src/cases.pion`) or a DoS bomb that FAILs while it is open, and
a model emulation (`diff/model.py`, `emulate=`) that reproduces Pion's exact output, which is how every corpus
divergence is attributed.

### P1-1 — `next_break_opportunity` rescans from byte 0 on every call: iterating a text's opportunities is O(n²)

- **Repro:** `diff/dos.py` bomb d25: the natural incremental-layout loop
  `off = 0; while let Some(op) = next_break_opportunity(s, off) { off = op.byte_offset }` over `"a " x 2,000`
  (4,000 B) takes 0.27-0.32 s native `--release`; over `"a " x 8,000` (16,000 B) it takes 3.6-4.4 s (ratio
  11.4-16.2; wasm32 10.7-19.8 over four runs). A 1 MB document would need hours. A single `next_break_opportunity(s, len - 1)` is fine (O(n), d24).
- **Root cause:** `next_break_opportunity` calls `run_linebreak(s, -1, target)`, which always starts at byte 0
  and walks to the first opportunity after `target`, so k calls cost O(k·n). Nothing in the README warns about
  it; the README advertises "Strict O(n)" and the function reads like an iterator step (it is the ICU
  `following()` shape a layout engine calls once per line).
- **Fix options:** a resumable cursor / iterator (`LineBreakIterator` holding the state machine and lookahead
  cache) and `next_break_opportunity` implemented on it; or restart the scan from a safe point before `target`
  (the last mandatory break, or a bounded look-behind sufficient for the LB14-LB30a contexts); at minimum
  document the cost and point callers at `line_breaks`.

### P2-1 — 94 unassigned Supplemental Arrows-C code points are `Line_Break=ID`; Unicode 16.0.0 says `XX`

- **Repro:** `line_break_class(0x1F80C)` = `ID`, want `XX`; `line_breaks("a\u{1F80C}b")` = `1a,5a,6m` (Pion
  breaks around it as an ideograph), want `6m` (XX -> AL, LB28). Affected: U+1F80C..1F80F, 1F848..1F84F,
  1F85A..1F85F, 1F888..1F88F, 1F8AE..1F8AF, 1F8BC..1F8BF, 1F8C2..1F8FF (94 code points; all
  `Extended_Pictographic`, gc=Cn).
- **Root cause:** `tools/gen_tables.py` pre-fills `1F000..1FAFF` and `1FC00..1FFFD` with `ID` from the header
  comment of LineBreak.txt. The machine-readable 16.0.0 data does not: LineBreak.txt has only
  `@missing: 0000..10FFFF; XX` and lists every other default explicitly, and
  `extracted/DerivedLineBreak-16.0.0.txt` has `@missing: 1F000..1F7FF; ID` and `@missing: 1F900..1FAFF; ID`,
  leaving 1F800..1F8FF at XX. `diff/ucd.py defaults` shows these 94 are the only code points where the 14
  hard-coded blocks are not overridden by explicit entries (so the other 13 blocks are dead code).
- **Fix:** drive the defaults from the `@missing` lines (or `DerivedLineBreak.txt`) instead of hard-coded
  blocks; regenerate.

### P2-2 — LB21a ignores the `[BA - $EastAsian]` exclusion

- **Repro:** `line_breaks("\u{05D0}\u{3000}a")` = `6m`, want `5a,6m`: U+3000 IDEOGRAPHIC SPACE is BA with
  East_Asian_Width=F, so `HL (HY | [ BA - $EastAsian ]) × [^HL]` does not apply and LB31 breaks before `a`. Same
  with a CM after the HL (`\u{05D0}\u{0301}\u{3000}a`). 21 fuzz / named inputs reproduce it.
- **Root cause:** `after_hl_hy_ba = prev == cls_HL && (cur == cls_HY || cur == cls_BA)` (src/linebreak.pion).
  Revision 53 explicitly "Excluded [ BA & $EastAsian ] = [\N{IDEOGRAPHIC SPACE}] from participating in LB21a";
  LineBreakTest.txt has no such vector, which is why 16,672/16,672 does not show it.
- **Fix:** `(cur == cls_HY || (cur == cls_BA && !cur_ea))`.

### P2-3 — LB10 keeps a remaining mark's own East_Asian_Width

- **Repro:** `line_breaks(" \u{3099}\u{201C}\u{4E00}")` = `1a,4a,10m`, want `1a,10m`; the same at the start of
  text (`"\u{3099}\u{201C}\u{4E00}"` = `3a,9m`, want `9m`) and with U+302A / U+16FF0 / U+201D.
- **Root cause:** LB10 says a remaining CM / ZWJ takes "the properties of U+0041 A ... East_Asian_Width=Na". The
  state machine resolves the class to AL but keeps `cur_ea` / `prev_is_ea` (and the sot `prev_is_ea`) from the
  mark itself. U+3099, U+309A, U+302A..U+302D, U+16FF0, U+16FF1 are CM with ea=W, so LB19a's
  `[^$EastAsian] × QU` and `(sot | [^$EastAsian]) QU ×` see an East Asian character and break.
- **Fix:** clear the EA flag (and the other flags) when a CM / ZWJ is resolved by LB10, both in the loop and for
  the first code point.

### P2-4 — `tools/gen_tables.py --check` fails on the committed `src/tables.pion`

- **Repro:** `python3 packages/unicode_linebreak/tools/gen_tables.py --check <unicode-16.0.0> packages/unicode_linebreak/src/tables.pion`
  -> `FAIL: ... is out of date with Unicode 16.0.0 UCD`, exit 1. This is the determinism check README.md
  documents.
- **Root cause:** the generator writes string continuations indented by two spaces (42,835 B); the committed file
  was run through `pionc fmt` afterwards (42,097 B). The data is identical (token for token, verified by
  `run_audit.sh static`); the raw generator output is not `pionc fmt --check` clean, so regenerating per README
  also breaks `scripts/verify.sh`.
- **Fix:** emit `pionc fmt`'s layout (no indentation on continuation lines) or have `--check` compare tokens.

### P2-5 — README claims not reproduced

Placeholder id for README drift (counts, Send list, smoke hash / size, benchmark SHA / speed). **Not open:** every
claim checked reproduces (see Summary).

## Rust `icu_segmenter 2.4.0`: what it gets wrong (measured, not assumed)

`compare.py icu` accepts an ICU / Pion difference only when Pion equals the model (or a finding emulation) and
ICU's side is reproduced by one of the following, each measured on Unicode's own vectors or on the `icuprobe`
corpus (short contexts followed by every one of the 136 representatives):

1. **Unicode 15.1 Line_Break data** (FE20..FE2F CM instead of GL, 2E56..2E5C CL instead of CP, FE10 / FE13 / FE14,
   1B50.., new 16.0 characters ...): the model's `ICU` profile uses `LineBreak-15.1.0.txt` (vendored only for
   this purpose) wherever 16.0.0 changed a value.
2. **Pre-15.1 LB19** (`× QU`, `QU ×` without LB19a's East Asian exception) and **pre-16.0 LB21a**
   (`HL (HY | BA) ×`, no `[^HL]`, no `[BA - $EastAsian]`).
3. **A U+25CC pair bug:** right after exactly two dotted circles ICU breaks before anything but VF / CM / ZWJ —
   even before SP, LF, CR, BK (non-tailorable LB6 / LB7) and before IS / CL / EX / QU / GL / WJ. `"\u{25CC}\u{25CC} "`
   gives ICU `6,7`; UAX #14 forbids the break at 6.
4. **Rule lag** at boundary keys ICU fails on the official vectors or the probes: LB15c `SP ÷ IS NU`, LB20a,
   LB25 (`NU (SY | IS) × (PO | PR)`, `(PR | PO) × OP` only before NU, no `SY × NU`), LB31 after CL / CP before
   PO / PR.
5. **SA** boundaries (LB1: dictionary / morphological analysis, implementation-defined); the rule-only segmenter
   has its own SA handling. Pion's SA boundaries are still checked against the model (LB1 SA -> CM / AL).

The README's list of ICU 2.4.0 divergences (LB15c, LB19a, LB20a, LB21a, LB25) is right but incomplete (INFO-3).

## INFO (documented behaviour or outside this branch; never failing)

- **INFO-1:** root `THIRD_PARTY_NOTICES.md` does not list the Unicode 16.0.0 data embedded in
  `src/tables.pion` (LineBreak.txt, EastAsianWidth.txt, UnicodeData.txt, emoji-data.txt; Unicode-3.0). Root
  files are registered at release integration, not on this branch.
- **INFO-2:** the package arrives as one commit, so the Red stage (`1/15` on the stub build) is a README
  statement that history cannot reproduce (AGENTS.md recommends, not requires, separate commits).
- **INFO-3:** README's ICU divergence list misses the U+25CC-pair bug, the 15.1 data and SA; README's
  "Compact 3-level ... lookup table (`42.8 KB`)" is the raw generator output size; the committed file is 42,097 B.
- **INFO-4:** performance is honestly reported: 0.17-0.18x of ICU here (README 0.16x / 0.14x), i.e. about 6x
  slower; `next_break_opportunity` aside, every bomb is linear.
- **INFO-5:** ill-formed UTF-8 decodes to U+FFFD by maximal subpart (identical to Python's codec and ICU's
  `segment_utf8` in 20,000 random strings and every fuzz input); U+FFFD is AI -> AL, so a run of garbage
  bytes is one unbreakable "word". Offsets of opportunities may point at a stray continuation byte (it is its
  own code point boundary for the decoder), which is consistent with the README's "legal boundary" wording.

## Verification (what `run_audit.sh` runs)

| Section | What |
| --- | --- |
| `build` | audit CLI in 4 modes, white-box dumper (byte-identical copy of `src/*.pion` + `whitebox/dump.pion` in `$AUDIT_OUT`), Rust oracle (`cargo --locked`, offline first), corpora, vendored data SHA-256 + loader vs `Derived*.txt`, model self-test (decoder vs Python codec, 16,672 official vectors) |
| `static` | MIT, no deps, no `extern "C"` / `import` / `World` / module-level state / `FixedArray` / floats / panics, no internal names, Unicode-3.0 headers, table regeneration (bytes, tokens, two runs, `--check`, stale-file rejection), default-block analysis, Send probes vs README |
| `unit` | `pionc fmt --check` / `check` / `test` of the package, count vs README |
| `tables` | all 1,114,112 code points, 4 modes, vs `diff/ucd.py` |
| `cases` | 23 control + 3 red-team cases, one process each, 4 modes |
| `conformance` | 5 corpora x 4 modes byte-identical; official vectors (positions + kinds); invariants |
| `api` | `next_break_opportunity` at every offset and hostile offsets, 9 limit settings per input, native vs wasm32 |
| `oracles` | model (offsets + kinds, finding attribution) and ICU (deviation attribution) on 5 corpora |
| `dos` | 25 bombs x {native, wasm32} at n and 4n, median of 7 self-timed runs; 4n/n must stay < 8 (linear 4, quadratic 16), re-measured up to twice when over |
| `smoke` / `bench` | `wasm_smoke` 4 modes vs README; `bench/run_bench.sh` re-run, SHA-256 and speed vs README |
| `inject` | 20 mutants; gate = control cases + official vectors (positions + kinds) + API sweep |

## Files

`run_audit.sh`; `pion.toml` + `src/main.pion` (CLI: `classes`, `dump`, `api`, `bomb`, `list`, `case`) +
`src/cases.pion` (control / red-team cases); `whitebox/dump.pion`; `diff/ucd.py` (loader, table and default
checks), `diff/model.py` (UAX #14 16.0.0 model, finding / ICU emulations), `diff/gen.py` (corpora),
`diff/compare.py`, `diff/dos.py`, `diff/inject.py`, `diff/readme.py`; `diff/rust/` (icu_segmenter =2.4.0
oracle, Cargo.lock); `ucd/` (Unicode 16.0.0 LineBreak, EastAsianWidth, UnicodeData, emoji-data, LineBreakTest,
extracted Derived{LineBreak,EastAsianWidth,GeneralCategory}, and LineBreak-15.1.0 for the ICU profile only;
gzip, SHA-256 pinned; Unicode License v3 in `ucd/LICENSE`).
