# Red-team audit: `packages/encoding` v0.1.0

- **Target**: `origin/feat/pkg-encoding` @ `8beb28157aac663bd88a9de5419ebd6c9c5b8c69`. Audited: `packages/encoding/src/{types,labels,decoder,buf,utf,single_byte,cjk,tables,encoding_test}.pion`, `bench/`, `wasm_smoke/`, `README.md`.
- **Deliverable**: `packages/encoding/audit/` only (branch `audit/pkg-encoding`). No file outside `audit/` was changed.
- **Reproduce**: `sh packages/encoding/audit/run_audit.sh` (about 95 s warm, no network once the cargo registry holds `encoding_rs 0.8.44`). Sections: `build cases unit diff dos portability smoke bench harness docs`.
- **Exit status**: `1` while any P0 condition reproduces, `0` otherwise. Open P1/P2 findings are printed as `OPEN` and fail the run only with `STRICT=1`.
  - P0 conditions: a crash, trap or hang on any input; any divergence from `encoding_rs` that is not an open finding; any native/wasm32 or debug/release divergence; a failing `control_*` case; a P0 DoS budget breach; a `wasm_smoke` hash that differs from `README.md`; bench output that is not byte-identical; or a gate that misses an injected bug (`harness`).
  - The fixes for P1/P2 must make the `redteam_*` cases and the `dos` / `portability` / `docs` gates pass **without editing `audit/`**.
- **Toolchain**: pionc 0.1.0 (arm64_apple, self-hosted), node v24.22.2 (`pion_wasm_rt.mjs`), cargo 1.100.0 + `encoding_rs` 0.8.44 (locked `Cargo.lock`, default features), python3 stdlib, macOS arm64.

## Verdict

| Severity | # | Summary |
|---|---|---|
| **P0** | **0** | No crash, trap, hang, OOB or decode divergence. **1 348 129 decode cases + 7 766 label cases + 565 440 encode cases**, each in all 4 modes, are byte-identical across modes. Every decode case equals `encoding_rs 0.8.44` byte for byte, including output, `had_errors` and fatal/non-fatal. A one-off 640 000-case random streaming run (up to 64 B, 4 chunkings) also showed 0 divergences. The gates were checked with 4 injected decoder bugs (`harness`). |
| **P1** | 2 | **P1-1**: the legacy CJK encoders take **1.4–5.6 s per MiB** of input in the worst case, **17–33x slower than encoding_rs** with the same linear-search design. This is a CPU DoS for any server that encodes user text into Big5/GBK/gb18030/Shift_JIS/EUC-JP/ISO-2022-JP/EUC-KR. The shipped bench measures no encoder, so the weakness is not visible. **P1-2**: 4 module-level `FixedArray[Int]` tables are mutable global state. This breaks the "0 static mutable globals" red line and the README/`types.pion` claim, and the audit shows such a table is writable even from a `spawn`ed task. |
| P2 | 5 | **P2-1**: `encode_html(ISO-2022-JP)` leaves the Roman state before an NCR or a U+000E/000F/001B error (2 134 cases differ from WHATWG/encoding_rs; the decoded text is the same). **P2-2**: `had_errors()` forgets earlier chunks after `last=true`. **P2-3**: `DecodeError` offsets are relative to the chunk and can be negative (`-3`, `-1`). **P2-4**: Strings that are not valid UTF-8 are passed through, rejected or silently sent **in UTF-8** by `encode_html`. **P2-5**: README/process claims are not backed: "0 divergences … all 10 encoders" is false, no differential harness is shipped, 9 unit tests (upstream: 158 + WPT), and the wasm sizes are off by 4 KiB. |

`run_audit.sh` exit status on the baseline: **0** (`AUDIT PASS (0 P0)`, OPEN lines for P1-1, P1-2, P2-1…P2-5). `STRICT=1 sh packages/encoding/audit/run_audit.sh` exits **1**.

### What holds (all measured, all 4 modes: native debug / native release / wasm32 debug / wasm32 release)

- **Differential vs encoding_rs 0.8.44 (`diff/oracle`)**. Line protocol: Pion `audit/src/main.pion run` ⇔ Rust `diff/oracle run`. Each line is one case: decode with `[fatal|non-fatal] × [BOM removal | ignore BOM]` × chunking, BOM sniffing (`Encoding::decode`), strict encode, WHATWG/HTML encode, or label. Chunkings:
  - `w`: whole buffer;
  - `k1/k2/k3/k7`: fixed-size chunks followed by an empty last chunk;
  - `e1`: an empty non-last chunk before every byte;
  - `x`: explicit cut points;
  - `r`: dirty the state, `reset()`, decode again;
  - `u`: decoder reused after `last=true`.

  Groups (`diff/gen.py`, deterministic):
  - `labels` 7 766: all 228 encoding_rs labels × upper/title case, ±each of `09 0A 0C 0D 20` (single, double, 100-byte runs), `0B` VT, `C2A0` NBSP, `E38080` U+3000, `85`, `1C`, NUL, internal space, doubled label, and U+212A KELVIN / U+0130 / U+017F case-folding traps; also the empty label, 41-byte labels, `utf-7`, `utf-32` and `unicode-1-1-utf-7`. → 0 divergences. Only ASCII whitespace is trimmed and only ASCII case is folded. `for_label_no_replacement` rejects exactly the 6 replacement labels.
  - `single` 15 196: every byte × 28 single-byte encodings + x-user-defined, fatal/non-fatal; all-256 runs whole, 1-byte and 7-byte chunked.
  - `dbcs` 394 752: every lead `0x80..0xFF` × every trail `0x00..0xFF` for GBK, gb18030, Big5, EUC-KR, Shift_JIS and EUC-JP, followed by `A`. This checks every "restore the ASCII trail byte" (WHATWG prepend) decision, every lead at EOF, and fatal mode.
  - `threebyte` 39 048: EUC-JP `8F` + every byte + every trail `A0..FF`, `8F`+lead+bad trail, `8E`+every byte. gb18030/GBK: every first × second digit × 9 classes of third byte, plus 2- and 3-byte EOF.
  - `fourbyte` 83 557, all gb18030 4-byte paths:
    - every BMP pointer `0..39427`, ±300 around 7457 / 39419 / 189000 / 1237575, 28 000 random pointers including beyond `1237575`, and the last 50 pointers;
    - the brief's vectors (`81 30 81 20`, `E3 32 9A 36`/`35`, `84 31 A4 39`/`A5 30`, `90 30 81 30`, `FE 39 FE 39`, `81 35 F4 37`) in all 4 options × 5 chunkings, with 3-byte prefixes and ASCII tails;
    - every 4th byte after 5 valid 3-byte prefixes and every 3rd byte after their 2-byte prefixes, whole and 1-byte;
    - GB18030-2022 rows `A6 A8 A9 D7 FE` × every trail.
  - `iso2022jp` 200 960: every string of length ≤ 4 over a 16-symbol alphabet (`ESC $ ( B @ J I D SO SI ! 0 \ ~ 0x80 LF`, 69 904 strings). The first 4 368 of them follow each of the 5 mode switches. Plus every JIS X 0208 row × cell `0x20..0x7F` and 20 000 random strings × 5 chunkings.
  - `utf` 360 696:
    - UTF-8: every 1- and 2-byte string; leads `C0..FF` × 20 edge bytes² (+4 fourth bytes); every 3-byte lead `E0..EF` × every second byte `80..BF` × edge third bytes, with BOM removal on and off. The last part covers the `EF BB xx` look-alikes that the BOM machine hands back.
    - UTF-16LE/BE: every 1–3 code-unit string over 13 units (BOMs, `FFFE`, lone/paired surrogates), with an odd tail, fatal, and 1-byte chunks.
    - 20 000 random strings × 5 chunkings.
  - `bom` 157 920: 3 BOMs + 18 tails (fake BOMs `EF BB 00`, `EF BB BE`, `EF BC 80`, `EF BB C0`, `EF BF BF`, `FF FE`, `FE FF`, …) × 40 encodings × 4 options × 6 chunkings. The BOM is also cut at every position with and without an empty chunk at the cut, and every case is run through BOM sniffing.
  - `stream` 96 000: 300 random strings per encoding over that encoding's interesting bytes × 7 chunkings + random cut points.
  - `encode` 565 440:
    - every BMP scalar `U+0080..U+FFFF` and 1/257th of the astral range × 40 encodings, strict and HTML;
    - strict per code point for the 7 CJK encoders;
    - 20 000 random ISO-2022-JP strings over mode-switching characters (`\ ~ ¥ ‾ あ ｱ SO SI ESC 😀 中 − － é`).
  
  Results:
  - **All 1 348 129 decode cases and 7 766 label cases are identical to encoding_rs.**
  - The encode group has 563 306/565 440 identical cases. The other 2 134 are all P2-1: every one contains U+00A5 or U+203E, and decoding Pion's and encoding_rs's bytes gives identical text in all 2 134.
- **Streaming invariance**: in every group, every chunking gives the same output and `had_errors` (OR over chunks) as a whole-buffer decode and as encoding_rs. This includes BOMs split as `[EF]+[BB]+[BF]+A`, `[EF]+[]+[BB]+[]+[BF]`, UTF-16 `[FF]+[FE]` / `[FE]+[FF]`, `last=false` followed by bad bytes and then `last=true`, `reset()` mid-sequence, and reuse after `last=true` (the BOM is stripped again).
- **Replacement encoding** (`control_replacement`): all 6 labels, with ASCII whitespace and upper case, give `replacement`; `for_label_no_replacement` gives `None`. Any non-empty stream gives exactly one U+FFFD, even 1 byte at a time with empty chunks in between; the empty stream gives `""`; `fatal` gives `Err` once.
- **Hand-checked controls** (`control_decode_pins`, 60 pins × whole/1/2/3-byte chunks × with and without empty chunks × fatal; expectations frozen from encoding_rs):
  - gb18030: prepend for 3rd/4th byte, `E3 32 9A 36` → U+FFFD, `E3 32 9A 35` → U+10FFFF, GB18030-2022 `A6D9` → U+FE10, `84318236` → U+FE10, `FE51` → U+E816;
  - Big5: 1133/1135/1164/1166 pairs, trail `0x80` swallowed vs `0x7F` restored;
  - EUC-JP: `8E 41`, `8F A1 A1`, `8F B0 A1`;
  - Shift_JIS / EUC-KR restore rules;
  - ISO-2022-JP: `ESC $ A`, `ESC ( B ESC ( B`, `ESC $ B` at EOF, a trail at EOF, `ESC` at EOF, SO/SI, Katakana `\`, Roman `\ ~`.
- **DoS (decoder)**: 27 bombs × {whole, 1-byte chunks} × {1 MiB, 4 MiB}. Examples: gb18030 `81308120` / `81308130` / `81` / `FF`, GBK `8130817F`, ISO-2022-JP `ESC ( B` / `ESC $` / `ESC` / `SO`, UTF-8 `FF` / `F0 90` / `EF BB` / `E0`, odd UTF-16, Big5 `87`, EUC-JP `8F` / `8F A1`, Shift_JIS `81`, EUC-KR `C7 20`, x-user-defined `FF`. Worst case: 15 ms/MiB whole and 59 ms/MiB at 1 byte per call. 4 MiB costs ≤ 4.1× the 1 MiB time (linear). RSS ≤ 48 MiB. Under wasm32 (node) the 1-byte gb18030 fallback bomb takes 105 ms/MiB. There is no O(N²) and no memory blow-up; output is ≤ 3 bytes per input byte.
- **Portability**: 0 `extern "C"`, 0 `World` (both words appear only in a `types.pion` doc comment), 0 `import`, 0 `[dependencies]`, 0 `let mut` at module level. 39 module-level `String` tables, plus the 4 `FixedArray`s of P1-2.
  - Send: `Encoding`, `DecodeOptions`, decoded `String`s and `sniff_bom` results are `Send`. `Decoder` is not (stateful, expected). `encode`/`encode_html` results are not, because `Bytes` is mutable (information only).
- **wasm_smoke**: the same line in all 4 modes (`encoding_wasm_smoke: OK checks=5 fnv64=10389566807909293613`); sha256 `1bc026dd…fd225` equals `README.md`. `pionc fmt --check` and `pionc check` pass, and `pionc test` passes 9/9 on `packages/encoding`.
- **Bench integrity**:
  - `run_bench.sh` reproduces **0.35x / 0.23x / 0.40x** (README 0.33x / 0.25x / 0.37x).
  - Both sides print `MODE ITERS OUT_BYTES FNV64`. `OUT_BYTES` is summed over all 100 iterations and FNV-1a 64 covers the **full** decoded text of the last iteration, so the check is not an empty probe. The total depends on every iteration, so the work cannot be removed as dead code.
  - stdout SHA-256 is identical across implementations and rounds.
  - Rust uses `new_decoder_with_bom_removal` + `decode_to_string`, the same semantics as `encoding::decode`. Its per-iteration `String::with_capacity(max_utf8_buffer_length)` is a minor overhead that favours Pion.
  - The README note on NEON/`simdutf8` is accurate for encoding_rs 0.8.44 on aarch64 (`src/utf_8.rs:81`).
  - The weaknesses are coverage (P1-1, P2-5), not fairness.

## Findings

### P1-1 Legacy CJK encoders: 1.4–5.6 s per MiB, 17–33x encoding_rs (CPU DoS)

- **Where**:
  - every CJK encoder finds the code point with `tbl_position()` (`tables.pion:22-31`), a linear scan that calls `u16_at()` (`tables.pion:14-17`; 3 `code_unit_at` + 2 `d6()` per probe) on every entry. Examples:
    - `gb18030_encode_hanzi` (`cjk.pion:390-415`: scans the 6 768-entry GB2312 hanzi table, then `gbk_*_ideograph_encode`);
    - `big5_encode_bmp` (`cjk.pion:1298-1352`: 5 range scans over `big5_low_bits_tbl`, then a scan of the rest of the ~14 000-entry table at `:1345`);
    - `big5_encode_astral` (`:1354`);
    - `shift_jis_encode` / `euc_jp_encode` / `iso2022_jp_encode` (`cjk.pion:777`, `:1097`, `:2071`: level-1 2 965, then level-2 3 390, then IBM 360);
    - `euc_kr_encode_bmp` (`cjk.pion:1638`: hanja 4 888).
  - Unmappable code points pay for every scan before the NCR fallback.
- **Measured** (`dos` section; `encode_html` of 1 MiB of one code point, native `--release`, encoding_rs 0.8.44 default features in the same process model):

  | encoding | code point | Pion | encoding_rs | ratio |
  |---|---|---:|---:|---:|
  | Big5 | U+00E9 é (unmappable) | **5 579 ms** | 334 ms | 16.7x |
  | Big5 | U+9F98 | **5 181 ms** | 158 ms | 32.8x |
  | Big5 | U+AC00 (unmappable) | 3 771 ms | 201 ms | 18.8x |
  | gb18030 / GBK | U+9F98 | 2 521 / 2 594 ms | 89 ms | 28–29x |
  | gb18030 | U+4E2D 中 | 1 352 ms | 48 ms | 28.2x |
  | Shift_JIS / EUC-JP / ISO-2022-JP | U+9F98 | 2 471–2 500 ms | 83–88 ms | 28–30x |
  | EUC-KR | U+9F98 / U+4E2D | 1 850 / 1 361 ms | 60 / 45 ms | 30x |

  Under wasm32 (node) Big5 é takes **7.4 s/MiB**. 1 MiB of form text costs a server 1.4–7 s of CPU. HTML form submission in the page's legacy encoding is exactly what `encode_html` is for, so this is an attacker-chosen-input DoS. encoding_rs makes the same size-over-speed choice (linear search without `fast-*-encode` features) at 17–33x less cost, so the gap is the table representation, not the algorithm.
- **Hidden by the bench**: `bench/` measures 3 decoders only. There is no encoder and no streaming scenario. AGENTS.md §1.3 requires reporting weaknesses ("如实记录领先与落后项"). Pion's 1 640 ms vs 49 ms (gb18030 中) appears nowhere.
- **Fix**:
  - generate encoder-side tables sorted by code point (`String` tables of `(code point, pointer)` pairs, same 3-char packing) and binary-search them: O(log n), about 13 probes instead of up to 14 000. Alternatively build per-range direct-index tables for the CJK Unified Ideographs block (`U+4E00..U+9FFF`) as encoding_rs's `fast-*-encode` does;
  - at minimum, check the block ranges before any scan so unmappable code points (é, Hangul in Big5) fail fast;
  - add an encode scenario (and a 1-byte streaming decode scenario) to `bench/` and `BENCHMARKS.md`.
  - Gate: `dos` opens P1-1 while any encoder worst case is over 1 000 ms/MiB (P0 above 30 s/MiB).

### P1-2 Module-level mutable `FixedArray` tables

- **Where**: `cjk.pion:286` `gb18030_2022_pua`, `cjk.pion:291` `gb18030_2022_b0`, `cjk.pion:296` `gb18030_2022_b1`, `tables.pion:146` `iso2022_jp_half_width_trail` (all `let … : FixedArray[Int] = [...]`).
- **Claim broken**:
  - `types.pion:3` says "zero mutable module globals";
  - `README.md` says "zero startup initialization" and "Compact Immutable Tables";
  - the brief's red line is "0 顶层 `let mut` / 静态可变全局（含 `FixedArray`/`Array`/`Map` 顶层容器核查）".
- **Proof** (`portability` section): a module-level `FixedArray[Int]` written from inside `spawn()` compiles without a diagnostic and the write is visible afterwards (`1` → `99`), in native and wasm32. These tables are therefore shared mutable state, not constants. Pion does not reject a `tbl[0] = x` anywhere in the package, and does not flag cross-task writes.
  - Today nothing writes them, so this is a hygiene / red-line defect, not a runtime bug.
  - Every other table in the package is an immutable `String`, which shows the immutable form was available.
- **Fix**: encode the 18 + 18 + 18 + 49 values as `String` tables read through `u16_at`, or as `match`-based functions (`gb18030_2022_pua_at(k)`). Then the `portability` gate reports `module-level mutable container: 0`.

### P2-1 ISO-2022-JP `encode_html` leaves the Roman state before an NCR

- **Where**:
  - `cjk.pion:2001-2005` emits `ESC ( B` for U+000E/U+000F/U+001B whenever `state != 0`;
  - `cjk.pion:2121-2124` does the same before every NCR for an unmappable code point.
- **Spec**: WHATWG Encoding §12.2.2 ISO-2022-JP encoder:
  - step 3 errors on U+000E/000F/001B **in ASCII or Roman state without switching**;
  - step 11.1 switches to ASCII before an error **only in the jis0208 state**;
  - the `&#…;` NCR is ASCII without `\` or `~`, so it is valid in the Roman state.

  encoding_rs does the same.
- **Repro**: `encode_html(ISO-2022-JP, "¥😀")`
  - Pion: `1b284a 5c 1b2842 26233132383531323b`
  - WHATWG/encoding_rs: `1b284a 5c 26233132383531323b 1b2842`

  2 134 encode-group cases differ (100 % contain `¥` or `‾`). Decoding both outputs gives the same text in all 2 134, so the damage is limited to byte-level non-conformance (signatures, hashes, golden tests, extra escape bytes).
- **Evidence**: `redteam_p2_1_iso2022jp_roman_ncr` (4 vectors, one of them a control that must stay as is), encode group class `P2-1`.
- **Fix**: in both places use `if state == 2 { push ESC ( B; state = 0 }`.

### P2-2 `Decoder::had_errors()` forgets earlier chunks after `last=true`

- **Where**: `decoder.pion:122-127`. `if last { self.reset(); if err_flag … }` clears `had_err` and then reflects only the final chunk.
- **Repro**: `Decoder::new(UTF-8)`; `decode_chunk([FF], false)` → `had_errors()==true`; `decode_chunk([41], true)` → `had_errors()==false`. The doc comment says "Whether any malformed or truncated sequence has been replaced so far". encoding_rs returns `had_replacements` per call, so callers OR them; this API has one flag, and it is wrong exactly when a caller checks it at the end of the stream.
- **Evidence**: `redteam_p2_2_had_errors_after_last` (UTF-8, gb18030).
- **Fix**: keep the flag across the final call (reset it at the start of the next stream, or in `reset()` only).

### P2-3 `DecodeError` offsets are chunk-relative and can be negative

- **Where**:
  - `cjk.pion:264` `MalformedSequence(i - 4)`;
  - `utf.pion:342/352/366` `MalformedSequence(i - 2)`;
  - every `TruncatedSequence(n)` (`utf.pion:182/276/380`, `cjk.pion:277/741/1064/1283/1589/1963/1973`) reports the chunk length, not where the sequence started.
- **Repro** (fatal):
  - gb18030 `[84 31 A5]` then `[30]` → `MalformedSequence(-3)`;
  - UTF-16LE `[00]` then `[DC]` → `MalformedSequence(-1)`;
  - UTF-16BE `[D8]` then `[00 D8]` → `MalformedSequence(-1)`.

  `DecodeError::to_string` prints "malformed byte sequence at offset -3".
- **Evidence**: `redteam_p2_3_fatal_offsets`.
- **Fix**: track the absolute stream position in the decoder and report the first byte of the bad sequence. At minimum, clamp to `>= 0` and document the offsets as chunk-relative.

### P2-4 Strings that are not valid UTF-8 break the encoders

- `Bytes::to_string()` does not validate: `[41 FF ED].to_string()` has length 3 and `code_unit_at(1) == 255`. Such Strings reach the encoders:
  - `encode(UTF-8, s)` copies the bytes verbatim (`utf.pion:391-400`). The "UTF-8" output is not UTF-8.
  - `encode(UTF-16LE/BE, s)` replaces each bad byte with U+FFFD.
  - Every legacy encoder returns `Err(InvalidUtf8Input)` (`single_byte.pion:91/124`, `cjk.pion:444/771/1086/1392/1700/1999`), even in HTML mode.
  - `encode_html` then falls back to `(encode_utf8(s), true)` (`decoder.pion:219`). It returns the whole input as raw UTF-8 (including the bad bytes) for a document whose declared encoding is Shift_JIS/GBK/windows-1252.
- **Repro**: `encode_html(Shift_JIS, "A" + <FF> + "中")` → `41 ff e4 b8 ad` (UTF-8 mojibake in a Shift_JIS form), where WHATWG's scalar-value conversion gives `41 &#65533; 92 86`.
- **Evidence**: `redteam_p2_4_invalid_utf8_string`.
- **Fix**: decode the input String with the same maximal-subpart rule as the UTF-8 decoder, map each ill-formed subsequence to U+FFFD (unmappable → NCR `&#65533;` in HTML mode), and never fall back to UTF-8. The `InvalidUtf8Input` variant can go.

### P2-5 README and process claims that are not backed

- **"0 divergences … All 10 encoders (…, `ISO-2022-JP`) with HTML NCR fallback"** is false (P2-1).
- No differential harness ships with the package. Only `bench/` references encoding_rs, so none of the README's "0 divergences across …" numbers (7 424 / 32 256 / 15 616 / 33 417 cases) can be reproduced from the repository. This audit's `diff/` can serve as that harness.
- **AGENTS.md §1.1 (port the upstream tests first)**: `packages/encoding` has **9** tests (129 asserts). encoding_rs 0.8.44 ships 158 `#[test]`s, and the WPT `encoding/` suite (labels, `textdecoder-*`, `api-replacement-encodings`, `iso-2022-jp-decoder`, `gb18030-decoder`, …) is not ported.
- **wasm sizes**: README says 296 / 297 KB; measured **300 / 301 KiB** (native 358 / 423 match).
- **Nits**:
  - `wasm_smoke/src/main.pion:41` says "streaming decode (1-byte chunks)" but calls one-shot `decode`;
  - `checks=5` is a constant while 13 checks run;
  - before release, `BENCHMARKS.md`, the root `README.md` table and `index/encoding.toml` need entries (same as previous waves).
- **Gate**: `docs` opens P2-5 while there are < 20 package tests, the zero-divergence claim is contradicted, no harness ships, or the sizes differ.

## Files

- `run_audit.sh`: entry point (sections above).
- `src/main.pion`: Pion driver.
  - `run <casefile>`: the line protocol;
  - `time` / `enctime`: decode bombs and encode worst cases;
  - `list` / `case <name>`: red-team and control cases.
- `src/cases.pion`: `control_*` (6) and `redteam_*` (4) cases. They also run under `pionc test` via `control_test.pion` / `redteam_test.pion`.
- `diff/gen.py`: deterministic corpus (10 groups, 1.92 M cases, `STREAM_N` scales `stream`). `diff/labels.txt` holds encoding_rs's 228 labels.
- `diff/oracle/`: Rust oracle (encoding_rs `=0.8.44`, locked) for the same protocol, plus `time` / `enctime`.
- `diff/compare.py`: mode-consistency and oracle diff. Known open classes (P2-1) are separated from P0.
- `diff/dos.py`: decoder-bomb and encoder budgets.
