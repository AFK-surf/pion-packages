# `packages/woff2` red-team audit

Target: `origin/feat/pkg-woff2` @ `66ac41c` (`packages/woff2` `v0.1.0`, pure Pion WOFF 2.0 / WOFF 1.0 → SFNT decoder).
References: Rust `wuff =0.2.10` (`audit/diff/rust`, same canonical output line as the Pion harness), fontTools `4.60.2` (independent WOFF2/WOFF1 *encoder* for the real-font corpus and semantic glyph comparison against the original fonts), and the W3C WOFF 2.0 / WOFF 1.0 texts.
Machine: Darwin arm64 (tokyo-mac-studio-0), `pionc 0.1.0 (arm64_apple, self-hosted)`.
Everything below can be reproduced with `sh packages/woff2/audit/run_audit.sh all`. Artifacts (binaries, Cargo target, Python venv, corpora, JSON reports) go to `$AUDIT_OUT`, default `/private/tmp/pion-woff2-audit`. Nothing is written inside the repository.

## Verdict

| Severity | Count | Summary |
| --- | ---: | --- |
| **P0** (crash / memory safety) | **2** | (1) A ~400-byte WOFF2 panics the decoder through a negative index in `extract_xmins_from_raw_glyf`; native aborts and wasm32 traps. (2) Native `--release` builds SIGSEGV on the error path of `rebuild_glyf` (44-byte trigger). Debug and wasm32 return `Err` correctly. This looks like a `pionc` release codegen bug; a standalone reproducer is in `compiler_repro/`. |
| **P1** (resource amplification, large gaps) | 3 | 284-byte → 67 MiB and 376-byte → 127 MiB peak RSS. Decompressed data past the table directory is accepted (spec MUST reject). WOFF2 decode runs at 0.24–0.31× `wuff`, and the Brotli stage is only part of that gap. |
| **P2** (spec conformance, interop, API semantics) | 8 | Rejects a valid font (`reserved != 0`). Lenient container validation. Silent Int32 coordinate wrap. `DecodeLimits` `<= 0` is inconsistent between formats. O(n²) table directory. No WOFF2 collections. `glyf` output is not byte-identical to the reference, and the bench identity check does not cover it. |

What is solid: all **110** real-font decodes (22 fonts × 5 encodings, see below) are semantically exact. Every non-`glyf` table is byte-identical to the original font. Every glyph matches fontTools on contours, points, on-curve bits, the overlap bit, instructions, composites, bbox and `hmtx`, and every whole-font checksum is `0xB1B0AFBA`. UIntBase128 / 255UInt16 / triplet / composite / bbox / short-loca handling matches the spec on every edge vector. `DecodeLimits` boundaries are exact (`exact` passes, `exact-1` fails for output, tables and glyphs). Native and wasm32 agree on every input that does not crash.

---

## P0

### P0-1 Negative / wrapped `loca` offsets index out of bounds in `extract_xmins_from_raw_glyf` (panic, native and wasm32)
* Where: `src/woff2.pion:1125-1140`. This is the path for a **transformed `hmtx` with null-transform `glyf`/`loca`**. In long-`loca` mode, `read_u32_at(...).to_int()` turns any offset `>= 0x80000000` into a negative `Int`. The guard `g_end > g_start && g_start + 4 <= glyf.len` then passes:
  * `loca = [0x80000000, 0x30, ...]` gives `g_start = Int.MIN` and the read is at `glyf.start + Int.MIN + 2`, which **panics** with `index -2147483517 out of bounds (len 217)`.
  * `loca = [0x7FFFFFFC, 0x7FFFFFFF, ...]` makes `g_start + 4` wrap to `Int.MIN`. That is `<= glyf.len`, so the code reads index `glyf.start + 0x7FFFFFFE` and **panics**.
  * `loca = [0, 0xFFFFFF9C(-100), ...]` does **not** crash. It silently reads `xMin` from bytes 98 before the `glyf` table, inside the shared decompressed buffer, and emits a wrong `lsb`. The bytes belong to a different table.
* Repro (input < 400 bytes):
  ```sh
  sh packages/woff2/audit/run_audit.sh build
  /private/tmp/pion-woff2-audit/venv/bin/python packages/woff2/audit/difftest.py vectors   # rows w2/hmtx-null-glyf-loca-*
  /private/tmp/pion-woff2-audit/bin/pion_audit file /private/tmp/pion-woff2-audit/vectors/w2_hmtx-null-glyf-loca-0x80000000.bin
  #   pion panic: index -2147483517 out of bounds (len 217)          (exit 134)
  node ~/.pion/share/pion/pion_wasm_rt.mjs /private/tmp/pion-woff2-audit/bin/pion_audit.wasm file <same file>
  #   Error: pion panic: index out of bounds: idx=-2147483517, len=217 (exit 1)
  ```
  The fuzzer found it independently: 3 of 12,000 cases (`$AUDIT_OUT/fuzz_findings/crash_*.bin` with a `pion panic: index` verdict; case numbers shift slightly between runs because the fontTools subset seeds embed timestamps).
  Unit tests: `redteam_p0_hmtx_null_glyf_loca_{int_min_must_not_panic,wrap_must_not_panic,negative_must_err}`.
* `wuff` rejects all three: it requires `glyf` to be transformed whenever `hmtx` is (see P2-2).
* Fix: keep offsets in `Int64` or `UInt`. Require `0 <= g_start <= g_end <= glyf.len`, and require monotonically non-decreasing `loca` (short and long). Return `HmtxReconstructionError` otherwise. Or reject a transformed `hmtx` when `glyf` is not transformed, as `wuff` and google/woff2 do. That removes the whole path.

### P0-2 Native `--release` SIGSEGV on the `rebuild_glyf` error path (debug and wasm32 are correct)
* Symptom: any transformed `glyf` whose stream runs out inside the glyph loop crashes the **release native** binary with SIGSEGV (exit 139). Examples are `numGlyphs` one larger than the `nContourStream`, or a composite whose bbox bit is set but whose `bboxStream` ends early. The **debug** native build and **wasm32 release** return `GlyfReconstructionError("truncated nContourStream" / "truncated composite bbox")` as intended. In the 12,000-case fuzz run, 5 cases hit this (`$AUDIT_OUT/fuzz_findings/crash_*.bin` with native `rc=-11`, wasm `ERR GlyfReconstructionError`). The synthetic vectors `w2/glyf-numGlyphs+1-empty`, `w2/glyf-numGlyphs+1-base` and `w2/composite-bbox-truncated` (≈ 300 bytes each) reproduce it deterministically.
* Root-cause evidence (bisection on a copy of `src/woff2.pion`, see `compiler_repro/`):
  * **Standalone reproducer.** `compiler_repro/` contains only `Reader`, `Writer`, `simple_glyph` and `rebuild_glyf`, copied verbatim, with no brotli/flate. The input is a 44-byte transformed `glyf` (`glyf_only.hex`):
    ```sh
    xxd -r -p packages/woff2/audit/compiler_repro/glyf_only.hex > /private/tmp/glyf_only.bin
    pionc run packages/woff2/audit/compiler_repro -- /private/tmp/glyf_only.bin            # err ... truncated nContourStream
    pionc run --release packages/woff2/audit/compiler_repro -- /private/tmp/glyf_only.bin  # SIGSEGV, exit 139
    ```
  * Returning early **before** the loop, or before the first failing read, does not crash. Neither does removing either the simple-glyph branch or the composite branch from the loop body. The crash needs the full loop body plus an `Err` coming back from `Reader::i16`, which calls `self.u16()?`.
  * Making `Reader::i16` self-contained (inline bounds check and byte reads, no nested `self.u16()?`) removes **all** SIGSEGVs: all 5 fuzz cases and all 3 vectors then return `GlyfReconstructionError`. Replacing only the `?` with an explicit `match` fixes the `nContour` case but not the composite-bbox case. Changing the call site (`rebuild_glyf(...)?` → `match`) or not storing the `Reader`s in an `Array` changes nothing.
  * Conclusion: this is a release-mode codegen/optimizer bug in the self-hosted `pionc` native backend. The likely area is register allocation or refcount handling on an early `return Err` from a large loop after a failed nested `Result` call on a struct with `mut` fields. It is not a logic bug in the decoder source. Hand it to the Pion compiler owners with `compiler_repro/`. I could not get a native backtrace: `lldb` cannot attach while Developer Mode is off on the station.
* Package-level mitigation until the compiler is fixed: make `Reader::i16` read its two bytes inline:
  ```pion
  fn Reader::i16(self : Reader) -> Result[Int, WoffError] {
    if self.at + 2 > self.end { return Err(WoffError::BoundsExceeded("unexpected EOF reading i16")) }
    let v = (self.data[self.at].to_int() << 8) | self.data[self.at + 1].to_int()
    self.at = self.at + 2
    if v >= 32768 { Ok(v - 65536) } else { Ok(v) }
  }
  ```
  With this change the 12,000-case corpus leaves only the P0-1 panics. Then re-run `run_audit.sh fuzz` and the `w2/glyf-numGlyphs+1-*` vectors against the release build. `pionc test` builds debug and cannot catch this class of bug, so the release harness (`difftest.py vectors|fuzz`) is the regression gate.

---

## P1

### P1-1 Allocation / decompression amplification from sub-KB inputs (default limits)
Measured with `run_audit.sh bombs` (`/usr/bin/time -l`, default `DecodeLimits`):

| case | input | Pion result | Pion peak RSS | wuff |
| --- | ---: | --- | ---: | --- |
| B1 transformed `glyf` `origLength = 2^31-1` (only a hint), honest header | 284 B | OK, 440-byte font | **66.7 MiB** | OK, 2.0 MiB |
| B2 60 MiB of zeros appended to the Brotli stream after the tables | 376 B | **OK** (extra data accepted) | **126.6 MiB** | rejects (exact-size check), 6.0 MiB |
| B3 200 MiB of zeros appended | 612 B | `LimitExceeded`, after decompressing 64 MiB | 104.8 MiB | rejects, 6.0 MiB |
| B4 a declared 60 MiB `name` table of zeros (legal but implausible) | 384 B | OK, 62.9 MB output | 126.6 MiB | rejects (100:1 ratio guard), 1.9 MiB |
| B5 WOFF1 60 MiB zlib `name` table | 61 KB | OK | 128.6 MiB | OK, 122.1 MiB |

* B1: `Writer::with_capacity(orig_glyf_len, max_output_bytes)` (`src/woff2.pion:950-951`) eagerly allocates `min(origLength, 64 MiB)`. `origLength` of a transformed `glyf` is attacker-controlled and is not counted in `total_stream_bytes`. `totalSfntSize` is only a hint and the attacker sets it small.
* B2/B3: `dec.brotli_decode(comp_slice, limits.max_output_bytes)` (`:1481`) lets Brotli produce up to 64 MiB. Only `all.length() < total_stream_bytes` is rejected (`:1482`), so trailing data is **accepted**. This violates the W3C `conform-mustRejectExtraData` requirement (vector `w2/stream-extra-bytes`, unit test `redteam_w2_extra_decompressed_data_must_err`). The 1.5–2× RSS over the limit comes from `OutBuf` doubling plus the final slice.
* Fix:
  1. Pass `total_stream_bytes` (the directory sum, already computed at `:1456`) as the Brotli output cap and require `all.length() == total_stream_bytes`. That fixes B2, B3 and the spec issue together, and also gives Brotli an exact initial capacity.
  2. Size the `glyf` writer from evidence, not from `origLength`. For example use `min(origLength, max_output_bytes, k × transformLength + 10 × numGlyphs)` and let it grow. `wuff` clamps every hint to `100 × input length`.
  3. Consider an opt-in plausibility ratio in `DecodeLimits` (wuff uses 100:1) for B4-type inputs.

### P1-2 Throughput 0.24–0.31× `wuff` on WOFF2: about 65 % Brotli, 35 % `glyf` reconstruction + assembly
`run_audit.sh prof` (`prof.py`, median of 7 interleaved rounds × 20 decodes, `--release`, stage = only the Brotli or zlib call on the same slice):

| input | Pion decode | wuff decode | Pion Brotli only | Rust `brotli-decompressor 6.3.2` | Pion reconstruction + assembly | wuff same |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `Arial.woff2` (bench corpus, 755 KB SFNT) | 13.36 ms (0.25×) | 3.34 ms | 9.01 ms (0.24×) | 2.17 ms | 4.35 ms | 1.16 ms |
| `Monaco.woff2` (517 KB) | 5.77 ms (0.27×) | 1.54 ms | 3.86 ms (0.27×) | 1.03 ms | 1.91 ms | 0.51 ms |
| `Arial Unicode` (23.3 MB, 50 k glyphs, fontTools glyf transform)† | 509.6 ms (0.24×) | 119.9 ms | 277.3 ms (0.28×) | 78.2 ms | **232.2 ms** | 41.7 ms |
| `SFNS` (7.9 MB variable, glyf transform)† | 94.8 ms (0.31×) | 29.1 ms | 82.8 ms (0.31×) | 25.4 ms | 12.1 ms | 3.7 ms |
| `Arial.woff` (WOFF1) | 4.38 ms (0.59×) | 2.57 ms | zlib 3.78 ms (86.3 %) | – | 0.60 ms | – |
| `Arial Unicode` null transform (assembly only)† | 393 ms | 112 ms | 364 ms | 112 ms | 28.6 ms | ≈ 0 |

Rows marked † come from an earlier `prof.py` run made while other audit jobs were running. Treat their ratios as indicative; the absolute numbers are inflated. The other rows come from the clean `run_audit.sh all` run.

Leads for the fix wave:
1. **Brotli (`packages/brotli`, 55–90 % of the time, 0.26–0.31× its Rust peer).** Every symbol goes through `PrefixCode::read -> Result[Int, _]` and `BitReader::take -> Result` (`brotli.pion:187,399`), with a refill check per call. Decode literals and commands in a fused fast loop that refills once per 56 bits and does table lookups without `Result` wrapping. Keep the checked path for the stream tail only. `OutBuf` starts at `min(4×input+256, 1 MiB)` and doubles with a byte-loop copy (`:601-660`), so the 23 MB case pays 5 copies. Add a size hint to the API: WOFF2 knows the exact size (P1-1 fix 1).
2. **`glyf` reconstruction (about 5.6× slower than `wuff` on 50 k glyphs).** Per point, `simple_glyph` makes 1–4 `Reader::u8/u16` calls, each returning `Result`, plus `sign_apply` branches. It writes `Array[Int]` / `Array[Bool]` scratch, then makes three more passes calling `Writer::u8_unchecked`, which loads and stores the `n` field and bounds-checks every byte. Use a 128-entry triplet table (byte count, x/y bits, deltas, signs) as in google/woff2 `kTriplets`. Do one bounds check per glyph for `flags` (`total` bytes) and one for the triplet payload (sum from the table). Write into a local `Bytes` with a local cursor, and use `FixedArray` scratch.
3. **Assembly (`assemble_sfnt`, 28.6 ms for 23 MB, about 0.8 GB/s).** It copies byte by byte and then does a separate checksum pass that shifts four bytes per word. Fuse copy and checksum, and use a bulk copy primitive if `Bytes` offers one. `Writer::ensure` and `copy_from` also copy with byte loops.
4. Re-measure after the P0-2 mitigation. `Reader::i16` sits on the bbox path.

### P1-3 Resource findings beyond the default limits
* `max_tables <= 0` (unlimited) plus a 393 KB WOFF2 with 65,535 empty tables takes **9.7 s** of CPU (23.2 s on a loaded machine; wuff: 0.02 s). That is the O(n²) duplicate-tag scan (`:1396-1402`) plus the O(n²) insertion `sort_tables` (`:462-476`). WOFF1 with 65,535 descending tags takes **10.1 s** (`find_table_idx` per entry plus the same sort). With the default `max_tables = 256` the input is rejected immediately. Fix: sort a copy of the tags once (O(n log n)), detect duplicates on the sorted array, and use a merge sort or similar for `sort_tables`.

---

## P2

### P2-1 Rejects valid WOFF2 files with a non-zero `reserved` field
`src/woff2.pion:1352-1354` returns `TruncatedHeader("WOFF 2.0 reserved field must be 0")`. WOFF 2.0 `conform-mustNotUseReservedValue` requires decoders to **ignore** the field (WOFF 1.0 does require rejection, and that part is correct). `wuff` accepts. The package's own `woff2_test.pion` "woff2 rejects zero tables and non-zero reserved" asserts the wrong behaviour. Fix the code and that test. Vector `w2/reserved!=0`; unit test `redteam_w2_reserved_nonzero_must_decode`; 10 fuzz cases.

### P2-2 Container validation more lenient than the spec / reference decoders
Each item below is accepted by Pion and rejected by `wuff` (google/woff2 semantics):
* `w2/length<filesize`, `w1/length<filesize`: header `length` must equal the file size (`:1355`, `:1247` only check `>`).
* `w2/loca-origLength-mismatch`: transformed `loca` `origLength` must equal the reconstructed size (`(numGlyphs+1)×2|4`). Pion never checks it (`:1518-1523`).
* `w2/glyf-null-no-loca`: a null-transform `glyf` without `loca` is accepted (`:1471` only compares the transform flags).
* `w2/hmtx-xform+null-glyf`: a transformed `hmtx` with null-transform `glyf` is accepted. This is the entry point of P0-1.
* `w1/tables-overlap`, `w1/table-inside-header`: WOFF1 table data may overlap other tables or the header and directory (offset 0 is accepted). WOFF 1.0 calls such files invalid, and OTS-based browsers reject them. Validate `off >= 44 + 20n`, 4-byte alignment, and non-overlap after sorting by offset. `wuff` also accepts these two, so this is spec-only evidence.
* Fuzz totals: Pion OK / wuff ERR on 488 of 12,000 cases, dominated by the same classes (extra data, `length`, `loca` size, wuff's 100:1 ratio guard).
Unit tests: `redteam_w2_length_field_must_match_file`, `redteam_w2_loca_origlength_must_match`, `redteam_w2_null_glyf_without_loca_must_err`, `redteam_w2_hmtx_xform_requires_xformed_glyf`, `redteam_w1_{overlapping_tables,table_inside_header,length_field}_*`.

### P2-3 Silent Int32 wrap of glyph coordinates
`simple_glyph` accumulates `x = x + dx` in `Int` (`:710-713`). 40,001 points with `dx = +65535` push the absolute x past 2^31, and the value wraps silently into a bogus but "valid" glyph. The output deltas are truncated to 16 bits anyway. `wuff` rejects this with an explicit overflow check (`glyf_decoder.rs:511`). Vector `w2/coord-int32-overflow(-compact)`, unit test `redteam_w2_coordinate_int32_overflow_must_err`. Fix: accumulate in `Int64`, or reject when `|x|` or `|y|` leaves int16 / int32.

### P2-4 `hmtx` reconstruction sizes from `maxp.numGlyphs`, `wuff` uses `glyf` `numGlyphs`
* `maxp < glyf` count (`w2/hmtx-maxp<glyf-count`): Pion emits an `hmtx` for `maxp.numGlyphs` glyphs and wuff for the `glyf` count, so the outputs differ.
* `maxp > glyf` count (`w2/hmtx-maxp>glyf-count`): Pion returns `HmtxReconstructionError("missing glyf xMin array")`. wuff accepts. This accounts for about 86 of the ~475 "Pion ERR / wuff OK" fuzz cases.
* Decide and document one rule. Rejecting a mismatch outright, in both directions, is the safest.

### P2-5 `DecodeLimits` semantics are inconsistent and use an advisory field as a hard gate
* `max_output_bytes <= 0` disables the woff2 checks and the WOFF1 zlib cap (WOFF1 decodes). The same value is then passed to `brotli::DecodeLimits` (`:102-105`), where `0` means a 0-byte cap and `< 0` is rejected. So **every WOFF2 decode fails with `LimitExceeded`** (`run_audit.sh limits`). The README does not document what `<= 0` means. Unit test: `redteam_limits_zero_max_output_consistent_across_formats`. `max_tables <= 0` and `max_glyphs <= 0` mean "unlimited", and that reaches P1-3.
* The header `totalSfntSize` is compared against `max_output_bytes` (`:1368`, `:1260`) and rejects files whose real output is tiny. Example: `w2/glyf-origLength-2^28-sfnt-sized` decodes to 440 bytes but declares 2^28. In WOFF2 the field is advisory, and wuff only uses it as a clamped capacity hint. For WOFF1, compare it with the computed size instead. That accounts for 120 fuzz cases.
* Recommendation: define `<= 0` as unlimited in one place (`DecodeLimits::normalize`) and map it to explicit large caps for brotli and flate. Or reject non-positive limits in `DecodeLimits::new`.

### P2-6 No WOFF2 collection (`ttcf`) support
`decode_woff2` returns `UnsupportedCollection` (`:1349-1351`). The WOFF 2.0 spec defines the CollectionDirectory (§4.2) and google/woff2 decodes it. The audit builds collections from `Menlo.ttc` / `Avenir.ttc` (`woff2lib.woff2_collection`). `wuff 0.2.10` also fails on those files whenever they contain transformed or null `glyf`, so there is no working reference to diff against yet. This is recorded as a capability gap, not a verified interop bug.

### P2-7 Output `glyf` is not byte-identical to the reference reconstruction; the bench identity check does not cover `glyf`/`loca`
* Pion never emits `REPEAT` flag runs. google/woff2 and wuff do. Every glyph is semantically identical (fontTools compare: 0 mismatches over 110 decodes), but `glyf` is larger: Arial +60 B, Zapfino +10.6 KB (+2.6 %), Apple Symbols +14 KB, Arial Unicode +6.4 KB, and +23 % on a synthetic repetitive-flag font (B8). `loca` differs accordingly.
* `bench/run_bench.sh`'s "SFNT semantic summary" hashes every table **except** `glyf`/`loca`, plus the 10-byte glyph headers. The README's "all table hashes … verified byte-for-byte identical" claim is therefore weaker than it reads. It is formally true only because the hash skips the two tables that differ.
* Fix (optional): run-length encode flags like the reference (`write_glyph_points`). That also cuts `glyf` writer bytes in the hot loop.

### P2-8 Minor
* The `glyf` header `version` (reserved) is ignored, and `optionFlags` bits other than 0 are ignored. Both are fine per spec, but they are untested.
* `w2/glyf-xform-no-head`: there is no `head` to patch `indexToLocFormat` in, so the output has a bad whole-font checksum (wuff does the same).
* `w1/directory-unsorted` and `w1/offset-unaligned` are accepted. Both are tolerated by wuff too.

---

## Coverage and method

| Section | What | Result |
| --- | --- | --- |
| `real` | 22 system fonts: TrueType with composites (Arial, Times New Roman, Georgia, Verdana, Geneva, Monaco), AAT/morx (Apple Chancery, Zapfino, Skia), variable `gvar` + overlap flags (SFNS, NewYork, SFNSMono, STIXTwoText), CFF/OTF (STIXGeneral, STIXTwoMath, NotoSansJavanese, LastResort), CFF2 variable (SFIndia), TTC members (Hoefler Text, Helvetica), 23 MB / 50 k-glyph Arial Unicode. Each is encoded by fontTools as WOFF2 glyf/loca transform, WOFF2 +hmtx transform, WOFF2 null transform, WOFF1 zlib and WOFF1 stored (own writer). | **110/110 PASS.** Byte-exact non-glyf tables vs the original, semantic glyph/hmtx equality, `ck=0xB1B0AFBA`, native == wasm32 (≤ 4 MB inputs). vs wuff: 76 byte-identical, 34 differ only in `glyf`/`loca` (P2-7). Collections: see P2-6. |
| `vectors` | 84 hand-built WOFF2/WOFF1 edge and malformed files (`woff2lib.py`, written from the spec, independent of `bench/gen_data.py`): UIntBase128 (leading zero, 5-byte, 6-byte, 2^32), 255UInt16 (252/253/505/506/761/762 and non-canonical forms), all 6 triplet ranges, 4 composite scale kinds + instructions, overlap bitmap, explicit bbox, short/long loca, hmtx flags 0–4, header/directory forgeries, WOFF1 zlib / offset / length forgeries. | 2 P0 (5 rows), plus the P2 rows above. |
| `limits` | `DecodeLimits` exact / exact-1 / 0 / -1 for output, tables, glyphs | Boundaries exact; `<= 0` inconsistent (P2-5). |
| `fuzz` | 12,000 cases (seed 20261123): 30 % byte mutation of WOFF2 seeds, 40 % **structure-aware** (decompress, then mutate the transformed `glyf` header, stream sizes and bytes plus `hmtx`/`hhea`/`maxp`/`head`, re-compress with Brotli so the mutation reaches reconstruction), 20 % WOFF1 directory forging and byte mutation, 10 % random. Seeds are fontTools subsets of Arial, SFNS, Times, STIXGeneral, Monaco, Zapfino in 3 transform modes, plus synthetic seeds. Each case runs on native, wasm32 and wuff; crashing cases are isolated by bisection. | **8 crashes:** 3 × P0-1 (native and wasm), 5 × P0-2 (native release only; wasm `ERR`). 0 hangs. 0 native/wasm verdict mismatches on non-crashing inputs. Pion 2.4 s, wasm 3.0 s, wuff 24.3 s for 12 k cases. Pion ERR / wuff OK on 479 cases, mostly WOFF1 cases where wuff skips checks (compLength > origLength, zlib overrun, Adler) plus P2-1/P2-4/P2-5. |
| `bombs` | B1–B8 above | P1-1, P1-3 |
| `prof` | Stage timing vs wuff / brotli-decompressor | P1-2 |
| `unit` | `redteam_test.pion` (generated by `gen_redteam_test.py`, vectors hex-embedded), each test in its own process | 14 `redteam_*` FAIL (3 by `pion panic: index …`), 21 `control_*` PASS |

## Reproduce

```sh
sh packages/woff2/audit/run_audit.sh all          # everything (~15 min)
sh packages/woff2/audit/run_audit.sh build        # Pion native release + debug + wasm32, Rust wuff harness, venv
sh packages/woff2/audit/run_audit.sh unit         # red-team / control unit tests (debug build)
sh packages/woff2/audit/run_audit.sh vectors      # spec edge vectors (release native + wasm32 + wuff)
sh packages/woff2/audit/run_audit.sh fuzz         # FUZZ_N=12000 by default
sh packages/woff2/audit/run_audit.sh real|limits|bombs|prof
```

Files: `src/main.pion` is the Pion harness CLI (`batch|file|bench|brotli|zlib`). `diff/rust/` is the wuff harness, which prints the same canonical line (per-table `tag:len:fnv64` plus whole-font checksum). `woff2lib.py` holds the independent WOFF2/WOFF1 writers and the `glyf` transform encoder. `difftest.py` holds the sections. `prof.py` does the stage timing. `gen_redteam_test.py` generates `redteam_test.pion`. `compiler_repro/` is the P0-2 standalone reproducer.
