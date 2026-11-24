# Red-team audit: `packages/opentype` v0.1.0

Audited commit: `origin/feat/pkg-opentype @ 8f9e048` (pure Pion OpenType / TrueType SFNT + TTC parser).
Auditor: RT-opentype (independent, adversarial; nothing outside `packages/opentype/audit/` was changed).

**Result (8f9e048): 0 P0 · 2 P1 · 11 P2.** Re-review of the fix branch `feat/pkg-opentype-fix @ e88e6f09`:
see the "Re-review" section at the end (**not signed off**: P2-9 only partly
fixed, new P2-12). No crash, wasm trap, hang, out-of-bounds read or nondeterminism was found
on any input: every synthesized edge case, 553 system font faces, 20,000 mutated font files plus in-memory
mutation of real fonts, and 16 DoS bombs ran cleanly and byte-identically in all four build modes.
The two P1s are silent wrong answers on real-world font structures (lost kerning pairs, wrong glyphs from a
Mac Roman `cmap`).

```sh
sh packages/opentype/audit/run_audit.sh            # EXIT=0 while there is no P0; open P1/P2 are printed as OPEN
STRICT=1 sh packages/opentype/audit/run_audit.sh   # EXIT=1 until every P1/P2 below is fixed
sh packages/opentype/audit/run_audit.sh cases      # single sections: build cases unit diff system fuzz dos ...
```

Every red-team case asserts observable behaviour only (no source text), and every README number is parsed from
`README.md` at run time, so a fix branch turns `STRICT=1` green without touching `audit/`.

## Method

| Dimension | What was run | Result |
| --- | --- | --- |
| 1. Static red lines, licence, 4-mode determinism | `pion.toml`, `src/` scans, Send probe; every dump, case, fuzz digest and the `wasm_smoke` hash in native debug / native `--release` / wasm32 debug / wasm32 `--release` | MIT, 0 deps, 0 `extern "C"`, 0 `World`, 0 module `let mut` / mutable containers (11 immutable `Int` limits), 0 `Double::to_string`, 0 font binaries in git, no host names; all 4 modes byte-identical everywhere |
| 2. SFNT / TTC container | unsorted / duplicated / out-of-bounds / u32-wrapping table records, `numTables` 0 and 65535, truncated directories, bad versions, `ttcf` v1/v2, `numFonts` 0 and 0xFFFFFFFF, face index out of range, nested `ttcf`, 0..11-byte files | all bounded; **P2-1** |
| 3. `glyf` / `loca` | self / mutual / 6-cycle composites, 2^14 and 2^20 diamond DAGs, 16^8 wide DAG, depth 16 / 17 chains, all-off-curve, first-off-curve, 1-point, 0-point and repeated-endpoint contours, non-monotonic `endPtsOfContours`, `REPEAT_FLAG` overflow, 65,536-point glyphs, `numberOfContours` -2 / -32768, every composite flag (scale, x/y scale, 2x2, word/byte args, point matching, `ROUND_XY_TO_GRID`, `USE_MY_METRICS`, `SCALED`/`UNSCALED_COMPONENT_OFFSET`, conflicting transform bits), non-monotonic / truncated / odd / x2-overflowing `loca`, coordinates beyond int16 | guards hold (cycles and bombs return `Err` in < 30 ms); **P2-5, P2-6** |
| 4. `cmap` 0/4/6/10/12/13/14 | idDelta wrap, idRangeOffset (0, odd, OOB, 0xFFFF, glyph >= 0x8000), `segCountX2` 0 / odd, missing sentinel, overlapping / unsorted segments and groups, `start > end`, `end > 0x10FFFF`, surrogates, glyph overflow, `nGroups` 0xFFFFFFFF, UVS default / non-default / OOB offsets / u24 overflow, 15 subtable-priority layouts | **P1-2, P2-3, P2-4, P2-9, P2-11** |
| 5. metrics, `name`, `kern`, `fvar` / `avar` | `numberOfHMetrics` 0 / > numGlyphs / truncated, `vmtx` without `vhea`, OS/2 v0..v5 at every length, `name` lone / trailing surrogates, odd length, OOB offset, all 128 Mac Roman high bytes, format 1, encodings 0/3/10, `kern` v0 + AAT, coverage bits, override / minimum, unsorted pairs, nPairs overflow, the u16 length overflow, `fvar` default == min / max, min > max, Fixed precision, `avar` knees / non-monotonic / missing anchors / axis-count mismatch | **P1-1, P2-2, P2-8** |
| 6. Independent oracles | ttf-parser 0.25.1 (the claimed reference) **and** skrifa 0.44.0 / read-fonts 0.41.0 (Google fontations, FreeType-compatible) dump the same `key = value` protocol; 152 synthesized fonts + 553 macOS system faces (`.ttf`/`.ttc`/`.otf`, SF variable fonts, CJK, symbol fonts): 1.99 M mapped code points (full 0..0x10FFFF sweep per face), 667,765 outlined glyphs, 57,736 real kern pairs, 5,759 UVS sequences and 252 variation coordinates taken from the fonts themselves, all names / metrics / OS/2 / post / fvar | every divergence attributed to a finding or to a source-checked oracle quirk (an oracle quirk is accepted only when the *other* oracle agrees with pion) |
| 7. DoS + benchmark | 16 bombs < 8 KiB through the full API in native and wasm32 `--release`; shipped `bench/run_bench.sh` re-run, README ratios parsed and compared | 15/16 bombs < 50 ms, one linear amplification (**P2-9**); bench ratios reproduced; **P2-10** |

Injected-bug check: five realistic one-token bugs (format 12 off-by-one, `hmtx` last-advance reuse, x-delta
sign, swapped 2x2 matrix entries, Mac Roman 0xDB = U+00A4) are each caught by the diff gate and/or the control
cases (`harness` section).

## P0

None.

## P1

### P1-1 `kern`: pairs beyond 64 KiB in the last OpenType subtable are silently lost

* Case: `redteam_p1_1_kern_u16_length_overflow`; fixture `kern_v0_u16_length_overflow` (one format 0 subtable,
  12,371 pairs = 74,240 bytes, `length` field = 74,240 mod 65,536 = 8,704).
* `kern_lookup_pair` (`src/kern_var.pion`) trusts the u16 `length` and clamps `nPairs` to
  `(length - 14) / 6 = 1,448`; the binary search then runs over the first 1,448 pairs only: 10,923 of 12,371
  pairs return 0 (e.g. `kerning(17, 25) = 0`, want 44).
* The OpenType `kern` subtable length is a uint16, so a format 0 subtable with more than 10,920 pairs cannot
  state its length. Fonts in the wild do exactly this (HarfBuzz's source comment cites Microsoft fonts with one
  big subtable whose length overflowed), and HarfBuzz, ttf-parser 0.25.1 (`kern.rs`: "if there is only one subtable, this property can be ignored")
  and read-fonts 0.41 (`kern.rs`: "ignore the length of the last subtable") all read the last subtable to the
  end of the table. Both oracles return the correct values for all 8 diffed probes; pion is wrong on 5.
  (FreeType's `ttkern.c` trusts the length too; HarfBuzz's `hb-ot-kern-table.hh` ignores it for the last
  subtable for exactly this reason.)
* Fix: for the last subtable (or when `nTables == 1`) use `kern_len - pos` as the subtable length.

### P1-2 `cmap`: a Mac Roman (1,0) subtable is indexed with the Unicode code point

* Case: `redteam_p1_2_mac_roman_cmap_unicode`; fixtures `cmap_mac_roman_only`, `cmap_mac_roman_fmt6_only`.
* `cmap_subtable_priority` ranks (1,0) format 0 / 6 as a "Mac Roman fallback" and `Face::glyph_index(cp)`
  looks `cp` up in it directly. A (1,0) subtable maps *Mac Roman bytes*, so for U+0080..U+00FF the result is the
  glyph of a different character: `glyph_index(U+00E9 'é') = glyph of byte 0xE9 'È'`, `U+00A0` -> `'†'`,
  `U+00DB 'Û'` -> `'€'`, and the C1 controls U+0080 / U+008E get `'Ä'` / `'é'`; real Mac Roman characters
  outside Latin-1 (U+2020 `'†'`, U+20AC `'€'`) are not found at all.
* Legacy Mac-only TrueType fonts (only a (1,0) table) still circulate; returning a wrong glyph is worse than
  returning none. ttf-parser and skrifa/FreeType ignore (1,0) for Unicode lookups; HarfBuzz uses it only after
  converting the code point Unicode -> Mac Roman.
* Fix: either drop (1,0) from `glyph_index`, or convert Unicode -> Mac Roman first (the inverse of
  `mac_roman_high_to_unicode`, already in `src/reader.pion`) and only then index the byte table. The case
  accepts both. (The package's own test `cmap formats 0, 6, 10, 13` builds its format 0 table under (1,0) and
  looks up 'A'; that stays valid with the converting fix, and needs (0,3) with the dropping fix.)

## P2

### P2-1 One out-of-bounds table record rejects the whole face

`Face::parse` returns `InvalidTableDirectory` as soon as *any* record has `offset + length > file length`,
including tables it never reads (`DSIG`, `GPOS`, a vendor table) and u32-wrapping records. FreeType
(`check_table_dir` skips invalid entries, clips `hmtx`/`vmtx`), ttf-parser and read-fonts parse such fonts.
Truncated downloads and padded last tables make this a real availability issue. Case
`redteam_p2_1_oob_table_rejects_face` (fixtures `sfnt_oob_unused_table`, `sfnt_u32_wrap_record`).
Fix: skip (or keep but never slice) invalid records; fail only when a required table is invalid.

### P2-2 `normalize_variation_coords` is off by one F2Dot14 unit against the spec algorithm

The OpenType spec ("Coordinate scales and normalization") normalizes in 16.16 fixed point, applies `avar` in
16.16 and converts to F2Dot14 by "add 0x00000002 and sign-extend shift right by 2". Pion computes in `Double`
and rounds half away from zero once. Results differ from skrifa / FreeType / HarfBuzz by one unit:
`-2^-15` on a [-1, 0, 1] axis gives -1 (spec 0); axis [0, 10, 5] at 1 gives -14746 (spec -14745); and on real
fonts: **43 of 252 coordinates probed on the macOS variable fonts** (e.g. `SFNS*.ttf` / `ADTNumeric.ttc`
`wght 250.75` -> -6129, spec and skrifa -6128). gvar/HVAR interpolation then uses a different instance than
every other engine (sub-unit, but not reproducible against them). Case `redteam_p2_2_norm_not_spec_fixed_point`.

### P2-3 `glyph_index` maps surrogate code points

`glyph_index` accepts any `0..=0x10FFFF`; a format 12 group spanning U+D7FF..U+E000 maps all 2,048 surrogates
(`U+D800 -> 11`). Surrogates are not Unicode scalar values (ttf-parser takes `char`, skrifa never maps them).
Case `redteam_p2_3_surrogates_mapped`. Fix: return `None` for `0xD800..=0xDFFF`.

### P2-4 `glyph_index` returns `Some(0)` on format 4 idDelta segments only

Formats 0, 4 (glyphIdArray), 6, 10, 12 and 13 return `None` for glyph 0, but the format 4 idDelta path returns
`Some(0)`, so every font's U+FFFF sentinel segment (`idDelta = 1`) reports U+FFFF as "mapped" to `.notdef`.
Callers that test `Some(_)` for coverage get a wrong answer. Case `redteam_p2_4_notdef_some0`.

### P2-5 Composite placement flags are ignored: anchor-point matching and `SCALED_COMPONENT_OFFSET`

With `ARGS_ARE_XY_VALUES` clear, the arguments are point numbers (parent point, child point) and the component
must be moved so the two coincide; pion uses offset (0, 0). `SCALED_COMPONENT_OFFSET` (bit 11) requires the
offset to be transformed by the component matrix; pion never applies it. Both produce misplaced components
(skrifa/FreeType implement both; ttf-parser shares the gap). Case `redteam_p2_5_compound_point_matching`
(parent point 3 = (600, 0): pion places the child at (0, 0); scaled offset (100, 100) x 0.5: pion uses (100, 100)).

### P2-6 `outline_glyph` leaves partial output in the builder on `Err`

On a cycle, depth / component / point limit or truncated component, `outline_glyph` returns `Err` but the
commands emitted by the components decoded so far stay in the caller's builder (2,550 commands for the diamond
bomb, 6 for `glyf_cycle_after_leaf`). A renderer that appends several glyphs into one builder draws garbage.
Case `redteam_p2_6_outline_partial_on_error`. Fix: truncate `builder.commands` back to its length on entry.

### P2-7 `Face::tables()` hands out the face's own mutable directory

`Face` is documented as an immutable value, but `tables()` returns the internal `Array[TableRecord]`:
`face.tables().clear()` makes every later `table_data` / `table_data_by_name` of that face return `None`, and
overwriting a record makes `table_data` return an unrelated (empty) slice. Case `redteam_p2_7_tables_alias`.
Fix: return a copy (or a read-only view). (Related, information: `Face` and `OutlineBuilder` are not `Send`
in the `portability` probe, so a parsed face cannot be shared with a spawned task; AGENTS.md 1.1 asks for
immutable `Send` values "where possible".)

### P2-8 `fvar` `postScriptNameID = 0xFFFF` is returned as `Some(65535)`

The fvar spec: a postScriptNameID of 0xFFFF means no PostScript name for the instance. `named_instances()`
returns `Some(65535)`; read-fonts returns `None`. Case `redteam_p2_8_fvar_ps_name_ffff`.

### P2-9 Every `cmap` lookup re-walks every encoding record (linear amplification)

`cmap_glyph_index` re-reads all `numTables` encoding records on every call, twice (selection, then the
fallback loop that re-runs a lookup for every other Unicode record). An 8 KiB font with 901 records aliasing one
subtable (`bombs/cmap_many_records`) makes a full code-point sweep take 11-15 s native / 12-13 s wasm32
(≈ 10-13 µs per `glyph_index`, ~300x Arial). Bounded by file size (no hang); ttf-parser has the same pattern
(7.1 s), skrifa and HarfBuzz resolve the subtable once per face. `kerning()` is similarly O(`nTables`) per pair.
Gate: `dos` section (budget 3 s). Fix: resolve the subtable(s) once in `Face::parse` and store offsets.

### P2-10 README.md / process claims not backed

Each item is re-evaluated from `README.md` at run time (`docs` section):
* the "Throughput (MB/s)" column multiplies the *whole file size* by the iteration count (9,500-17,000 MB/s on
  Arial) although a lazy parse plus 256 lookups and 64 outlines reads a few KiB; it is not a throughput;
* "Full-sweep differential checks cover ... `glyf` outline command stream digest": the shipped oracle outlines
  only gid < 512 and kerns only gid < 256, and covers no `name`, `vmtx`, UVS, named instance or `avar` output;
  the "0 deviations" claim is therefore much narrower than stated (this audit found P1-1 / P1-2 / P2-2 there);
* 8 package tests; none of ttf-parser 0.25.1's own test vectors (`tests/tables/{cmap,glyf,hmtx,maxp}.rs`) were
  ported (AGENTS.md 1.1);
* the "Mac Roman fallback" advertised under `cmap` is P1-2.
* information only (printed as `INFO`, not gated): the root `BENCHMARKS.md` has no `opentype` section yet
  (AGENTS.md 1.3). Package fix branches may not touch repository root files; that section is appended when the
  release is merged into `main`.
The benchmark ratios themselves reproduce (0.61-0.65x / 0.73-0.76x measured in three runs vs 0.59x / 0.71x
documented, same stdout SHA-256), and the wasm32 sizes are within 0.1 % (76,211 / 76,618 B measured vs
76,279 / 76,686 B, most likely embedded source paths).

### P2-12 `Face::parse` is quadratic in the number of `cmap` encoding records (introduced by the P2-9 fix)

Found while re-reviewing `e88e6f09`, not present in 8f9e048 (whose parse is lazy). `cmap_parse_subtables`
de-duplicates every encoding record against every subtable kept so far (O(n²) over up to 65,535 records) and
keeps all of them. A 513 KiB font whose 65,535 records each point at themselves (platformID 0 or 14 reads as
format 0 or 14) makes `Face::parse` take 0.7-1 s native (`bombs/cmap_records_parse`, budget 100 ms; 8f9e048:
0 ms). Gate: `dos` section. Fix: bound the kept list (see P2-9) so de-duplication is O(n).

### P2-11 Symbol (3,0) fonts: no U+F000 remap

For a Windows Symbol `cmap` (Wingdings, Webdings and Symbol on this machine) pion maps only U+F020..U+F0FF;
`glyph_index('A')` is `None`. HarfBuzz and skrifa (FreeType-compatible) also map U+0020..U+00FF to
U+F020..U+F0FF, which is how browsers render these fonts. Case `redteam_p2_11_symbol_cmap_remap`.

## Fix compatibility (checked)

The gate was run against a scratch copy of the package with straightforward fixes for P1-1, P1-2, P2-1, P2-3,
P2-4, P2-6, P2-7, P2-8 and P2-11 (never pushed): those nine red-team cases turn PASS, every control stays PASS,
the diff gate reports 0 unexplained divergences, and all 5 injected bugs are still caught, without changing a
byte under `audit/`. Injection targets are matched loosely and reported as SKIPPED (not failed) if a fix
rewrites them.

## What holds (controls, all modes)

* No input crashed, trapped or hung: 152 synthesized fonts, 553 system faces, 20,000 mutated files, in-memory
  mutation of 4 real fonts, 16 bombs. All `Bytes` reads are bounds-checked before use (verified by reading every
  index expression in `src/` and by the fuzzers).
* Cycle and bomb guards: self / mutual / 6-cycles return `Err`; the 2^20 and 16^8 diamond DAGs stop at
  `max_compound_components = 1024` in < 30 ms (ttf-parser 0.25.1 has no total cap: the 16^8 DAG runs > 20 s,
  and > 20 GiB with a storing pen); 65,536-point glyphs and `REPEAT_FLAG` overflows are bounded.
* `cmap`: idDelta modulo 65536, idRangeOffset glyphs >= 0x8000 (correct where ttf-parser drops them, e.g.
  `DecoTypeNastaleeqUrdu.ttc` U+0611), format 12 glyph overflow, 0xFFFFFFFF counts, UVS default ranges including
  the u24 + additionalCount overflow, unsorted table directories.
* `name`: UTF-16BE lone / trailing surrogates -> U+FFFD (same as read-fonts), all 128 Mac Roman high bytes equal
  Python's `mac_roman` codec and read-fonts, name format 1 (ttf-parser mis-parses it).
* `kern` override / minimum / cross-stream / vertical / AAT variation bits per spec; `hmtx`/`vmtx` last-advance
  reuse; OS/2 version-dependent fields.

## Oracle notes (why some divergences are not pion bugs)

Each rule is in `diff/compare.py` and is applied only when the other oracle agrees with pion on the same key.
* ttf-parser 0.25.1: format 4 glyphIdArray values >= 0x8000 are cast to `i16` and dropped
  (`format4.rs: u16::try_from(i16)`); name format 1 records are read after the lang-tag array (spec: before);
  `HIDDEN_AXIS` is read from bit 3 (spec: bit 0); Fixed axis values are `f32`; Mac Roman / lone-surrogate names
  are `None`; normalization truncates instead of rounding (so `norm` is compared against skrifa only); a 3/10
  subtable must be format 12/13; iteration stops at the first unparsable `cmap` subtable; absolute coordinates
  wrap at int16; no outline for a zero-area glyph; no total component cap (DoS above).
* skrifa 0.44.0 / read-fonts 0.41.0: outlines are translated so that xMin = lsb (undone by the oracle) and
  transformed composite points are rounded to integer units (FreeType); code points are mapped only through
  formats 4/12/13 and Symbol subtables are preferred and remapped; **read-fonts 0.41.0 panics** (`glyf.rs:244`,
  index out of bounds) on a `numberOfContours = 0` glyph with trailing data (fixture `glyf_zero_contours`; the
  case runs against ttf-parser only).
* pion f64 vs ttf-parser f32 composite transforms differ by at most 1/16 unit on 5 real glyphs (Athelas, Bodoni,
  Iowan); re-dumped and accepted within 1/16 unit.

## Files

* `run_audit.sh`: the gate (sections above); `STRICT=1` fails on any open P1/P2.
* `src/main.pion`, `src/cases.pion`: dump / stress / fuzz CLI and the red-team + control cases (4 modes).
* `diff/gen.py`: SFNT/TTC writer, 152 synthesized fonts, 16 bombs, 20,000-font mutation corpus, system font list
  and per-font queries (kern pairs, UVS, variation coordinates read from each font).
* `diff/oracle/`: ttf-parser 0.25.1 + skrifa 0.44.0 oracle (`Cargo.lock` committed, built `--locked`).
* `diff/compare.py`, `diff/dos.py`, `diff/claims.py`: attribution, DoS gate, README claim checks.

## Re-review: `feat/pkg-opentype-fix @ e88e6f09`

Base: `41e8570` (this audit, unchanged: `git diff 41e8570..e88e6f09 -- packages/opentype/audit/` is empty).
7 files changed, all under `packages/opentype/` (README, `bench/rust_bench`, `src/{cmap,face,glyf,kern_var}`,
33 tests); no repository root file, no font binary.

Independent run of the 41e8570 gate on e88e6f09: `STRICT=1 sh packages/opentype/audit/run_audit.sh` ->
**EXIT=0, 0 OPEN** (16/16 cases in 4 modes, 33/33 package tests, 0 unexplained divergences on 152 synthesized
fonts and 553 system faces, P2-2 43/252 -> 0/252, 20,000 + 1,600 fuzz inputs clean, 5/5 injections caught).

Every changed function was then read line by line, with these extra probes against the fixed code:

| Finding | Verdict on e88e6f09 |
| --- | --- |
| P1-1 kern | fixed: the last OpenType subtable is read to the end of the table (HarfBuzz / read-fonts rule) |
| P1-2 Mac Roman | fixed: (1,0) is no longer a `glyph_index` candidate |
| P2-1 OOB record | fixed: invalid records are skipped; `head`/`maxp` still required |
| P2-2 normalization | fixed: 16.16 `fixed_div` / `fixed_mul_div`, skrifa-compatible `avar` mapping, `(v + 2) >> 2`; NaN / ±inf / ±1e300 inputs give the same clamped results in all 4 modes (no wasm trap) |
| P2-3, P2-4, P2-8, P2-11 | fixed as specified |
| P2-5 composites | fixed: points are collected per glyph, child transform then point-matching / scaled offset (FreeType's `hypot` scaling), out-of-range point numbers fall back to offset 0; total work stays bounded by `max_glyph_points` x depth |
| P2-6 rollback, P2-7 copy | fixed |
| P2-10 docs | fixed (whole-file MB/s column removed, oracle caps stated, 33 tests incl. ported ttf-parser vectors) |
| **P2-9 lookup cost** | **partly fixed**: aliasing records are de-duplicated, but every *distinct* candidate subtable is still kept and tried on every miss. `bombs/cmap_distinct_records` (64 KiB, 8,000 self-referencing records): 20,000 + 20,000 lookups take 0.40-0.56 s (~21 µs per `glyph_index`, a full code-point sweep ~24 s); `bombs/uvs_distinct_records` (65,535 format 14 candidates, 513 KiB): 5.0-5.5 s (~250 µs per UVS lookup). 8f9e048 takes 1.9-2.1 s / 14-18 s on the same inputs, so this is an improvement, not a regression. Budget 100 ms per 40,000 lookups. |
| **P2-12 parse cost (new)** | **open**: O(n²) de-duplication in `Face::parse`: 0.69-0.97 s for `bombs/cmap_records_parse` (513 KiB; 8f9e048: 0 ms) |

Suggested fix for both: keep the best subtable plus at most a small constant number of distinct fallbacks
(e.g. the best per encoding class: Unicode full, Unicode BMP, Symbol), and at most one format 14 subtable (the
spec allows exactly one). With a bounded list the de-duplication is O(n) and every lookup costs O(1) subtables,
as in HarfBuzz and skrifa.

Gate update (this commit): `dos` now also runs the three size-amplification bombs above (< 1 MiB, budgets
100 ms); on e88e6f09 `STRICT=1` exits 1 with `OPEN: P2-9` and `OPEN: P2-12`, on 8f9e048 the same bombs report
P2-9 (P2-12 does not exist there). **Not signed off** until both are closed; everything else is verified.
