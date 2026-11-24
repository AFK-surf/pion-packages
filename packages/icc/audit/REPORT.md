# Red-team audit: `packages/icc` v0.1.0

- **Target**: `origin/feat/pkg-icc` @ `04ba43cfa66cde100dc2114ad74559f909bee9c7`. Audited in full: `packages/icc/src/{types,math,parser,container,transform,srgb_lut,icc_test}.pion`, `bench/` (`run_bench.sh`, `gen_corpus.py`, `pion_bench`, `rust_bench`), `wasm_smoke/` and `README.md`.
- **Deliverable**: `packages/icc/audit/` only (branch `audit/pkg-icc`). No file outside `audit/` was changed.
- **Reproduce**: `sh packages/icc/audit/run_audit.sh`. Sections: `build cases unit diff adv trunc fuzz dos portability smoke bench`. A full run takes about 8 minutes warm, of which `dos` is about 1 minute and `bench` about 3. It needs no network once the cargo registry holds `qcms 0.3.0` and `moxcms 0.9.2`.
- **Exit status**: `1` while any P0 condition reproduces, `0` otherwise. Open P1/P2 findings are printed as `OPEN`. They fail the run only with `STRICT=1`, which therefore exits `0` only with 0 P0 and 0 OPEN.
  - P0 conditions are:
    - a crash, trap or hang on any input;
    - a P0 red-team case or DoS budget breach (250 ms or 512 MiB per parse);
    - a transform more than 1 LSB from the exact ICC float reference on well-formed input, outside a classified finding;
    - any native/wasm32 or debug/release divergence;
    - a failing `control_*` case or portability gate;
    - `wasm_smoke` output that differs between the 4 modes;
    - shipped bench output that is not byte-identical.
  - The fixes must make the `redteam_*` cases pass **without editing `audit/`**.
- **Toolchain**: pionc 0.1.0 (arm64_apple, self-hosted), node v24.22.2 (`pion_wasm_rt.mjs`), cargo 1.100.0 with `qcms =0.3.0` and `moxcms =0.9.2` (locked `Cargo.lock`), python3 stdlib, macOS arm64 (Apple M5 Max (Darwin arm64), load about 6–8).
- **Proprietary profiles**: the 11 matrix/TRC and GRAY profiles in `/System/Library/ColorSync/Profiles` are read in place when present, and never copied into the tree (the `portability` gate checks that 0 `.icc`/`.icm` files are in git). Every other profile is synthesised by `diff/gen.py`.

## Verdict

| Severity | # | Summary |
|---|---|---|
| **P0** | **1** | **P0-1**: duplicate tag signatures make `parse` cost O(tag_count × tag_size). One crafted **1 MiB** profile takes **8.0 s** to parse (native release). A 16 MiB profile, which `extract_jpeg_icc` reassembles from an ordinary JPEG, takes about 2 minutes. The same records also make the **last** duplicate win, while qcms uses the first. |
| **P1** | 3 | **P1-1**: the Scenario A claim (245× vs qcms, 44× vs moxcms) does not hold. qcms was benchmarked without its documented precached output, and the corpus is the one profile that hits a compile-time LUT shortcut. Against precached qcms, Pion is 1.6× faster on that profile. On an sRGB `curv[1024]` profile, the most common embedded one, Pion is **17× slower**, and 3–4× slower on AdobeRGB and Rec.2020. **P1-2**: the Scenario B claim (1.99× vs qcms) is **0.96×** against precached qcms. **P1-3**: the `wasm_smoke` hash in `README.md` is not what the shipped smoke prints in any mode. |
| P2 | 6 | **P2-1**: `is_srgb_like` says true for profiles whose transform moves pixels by up to 12–15 LSB, and the README idiom skips the transform. **P2-2**: the `is_identity` fast path tolerates a 0.002 matrix error, which is 6 LSB. **P2-3**: an AToB0 LUT is silently ignored (qcms and moxcms honour it). **P2-4**: WebP `ICCP` is returned without the VP8X ICC flag (libwebp ignores it). **P2-5**: the bench SHA-256 gate is identical with and without colour work. **P2-6**: nits (module-level `FixedArray` LUTs vs the README claim, non-`Send` results, raw high bytes in `desc`, no version check, uncommitted accuracy harness). |

`run_audit.sh` exit status on the baseline: **1** (`AUDIT FAIL`, P0-1). Open lines: P0-1, P1-1, P1-2, P1-3, P2-1 … P2-6.

### What holds (measured in all 4 modes: native debug / native release / wasm32 debug / wasm32 release)

- **Memory safety and robustness: 0 crash, 0 trap, 0 hang.**
  - Inputs: 149 adversarial files, the 3 system LUT profiles (CMYK, Lab, XYZ), 2 464 truncations (every prefix of a v4 P3 profile, a v2 sRGB `curv` profile, a GRAY `mluc` profile, a 3-chunk JPEG and a VP8X WebP) and 10 000 LCG mutants.
  - All 4 modes produce byte-identical records on every input: verdicts, header and tag fields, IEEE-754 bits of every decoded number, and an FNV-64 of the transform output over 1 753 probe pixels.
  - Every byte offset and integer operation of `parser.pion` / `container.pion` was read by hand:
    - tag bounds are checked in 64 bits (`off >= 128`, `size > 0`, `off <= profile_size`, `size <= profile_size - off`);
    - every type reader checks its own minimum size before reading (`XYZ` 20, `sf32` 44, `curv` 12/14/12+2n, `para` 16/24/28/32/40, `desc` 12 + count, `mluc` 16 + n·rsize with per-record `off/len` checks);
    - `read_u32_be` returns `Int64`, so nothing wraps in 32 bits.
- **Adversarial expectations: 145/149 as a correct implementation must.** The other 4 are P0-1, P2-3 and P2-4 (twice). Covered:
  - **Header**:
    - declared size 0/127/128/131, `size > len`, `0xFFFFFFFF` and trailing garbage (accepted);
    - bad `acsp`;
    - intent 4/`0x10000`/`0xFFFFFFFF` (rejected, as in qcms).
  - **Tag table**:
    - `tag_count` 0, 4096 distinct (accepted), and 4097/`0x15555556`/`0x7FFFFFFF`/`0x80000000`/`0xFFFFFFFF`;
    - `offset` 0/127 and `size` 0;
    - `off == size`, `off > size`, `end == size` (accepted) and `end == size + 1`;
    - 32-bit wraps `0xFFFFFFF0 + 0x20`, `144 + 0xFFFFFFFF`, `0x80000000 × 2`;
    - an out-of-bounds unknown tag (rejected), and a tag overlapping the table (accepted).
  - **XYZ / sf32**: short, wrong type; `s15Fixed16` `0x80000000` (−32768.0) and `0x7FFFFFFF`. These decode exactly, then are rejected by the 7.5 matrix-gain guard.
  - **curv**: `count` `0x40000000`/`0x80000000`/`0xFFFFFFFF`/65537 (rejected before any allocation); 65536 (accepted); a table short by 1 byte; a gamma with tag size 12; gamma 0 and `0xFFFF`.
  - **para**:
    - types 5 and 65535 rejected; types 0/1/4 short by one byte rejected;
    - `g = −32768`, `g = 0`, `a = 0` for types 1 and 2 (no division by zero reaches the LUT);
    - negative base in type 3, `pow(neg, frac)`, and all 7 parameters at `0x7FFFFFFF`/`0x80000000`.
  - **desc**: count 0, missing NUL, count past the tag, count `0xFFFFFFFF`, size < 12, size < 4, `text` type, inner NUL, high bytes.
  - **mluc**:
    - 0 records, 4097 records and count `0xFFFFFFFF`;
    - record size 11 and `0xFFFFFFFF`; the table past the tag;
    - string offset or length past the tag, and offset `0xFFFFFFFF`;
    - odd byte length; surrogate pair → 4-byte UTF-8;
    - unpaired high, high at end, unpaired low and reversed pair → U+FFFD;
    - trailing NULs, enUS > en* > first preference, BMP non-ASCII.
  - **JPEG**:
    - 1/3/255 chunks in order, out of order and reversed;
    - `seq 0`, `total 0`, `seq > total`, duplicate seq, total mismatch, missing chunk, two complete sets;
    - an empty chunk, and APP2 after SOS / after EOI (ignored);
    - a chunk split across SOS (rejected, not merged);
    - 1 000 fill bytes, RST/TEM, stray bytes (resynced);
    - MPF APP2, `ICC_PROFILE` without NUL, 13-byte payload;
    - segment length 0/1/past EOF, marker or length at EOF, no SOI, length 0/1, SOI only.
  - **WebP**:
    - VP8X+ICCP; odd chunk padded and unpadded at EOF; duplicate ICCP (first wins); no ICCP; ICCP past the RIFF size;
    - RIFF size `0xFFFFFFFF`/3/4; chunk size `0xFFFFFFFF` and `0xFFFFFFF7` (no wrap);
    - truncated ICCP, header only, 11 bytes, `RIFX`, `WAVE`, a partial chunk header.
  - **Transform preconditions**: GRAY with Lab PCS, GRAY without `kTRC`, RGB without `gXYZ`/`bTRC`, RGB with Lab PCS, CMYK, and the 3 system LUT profiles all return `UnsupportedProfile`.
- **Colour accuracy: ≤ 1 LSB of the exact ICC math on every well-formed profile except P2-2.** The input is 40 033 pixels: 4 × 256 ramps, a 33³ grid and 4 096 random pixels.
  - **Profiles**: 37 synthetic profiles (2 of them are the P2-2 cases) and 11 macOS ColorSync profiles.
    - sRGB `para3` / `curv[1024]` / `curv[4096]`, P3, AdobeRGB, ProPhoto, Rec.2020 (709 TRC), linear Rec.709, ACES AP0 with negative XYZ;
    - `para` 0–4, including type 1 black crush, type 2 offset and negative `b`, type 3 with `d = 0`/`1`, type 4 flare and discontinuous at `d`;
    - `curv` 2-entry linear/inverted/half, monotone 256, gamma 0.5/1/3, mixed TRCs per channel;
    - zero and singular matrices;
    - GRAY gamma / sRGB para / table / identity / para0 1.8 / para4 flare;
    - system ACEScg, AdobeRGB, DCI-P3, Display P3, both Generic Gray, Generic RGB, ITU-2020, ITU-709, ROMM, sRGB.
  - **Reference**: `compare.py` has its own ICC reader. It applies the ICC.1:2022 curve definitions with output clipping, an independently derived Bradford D50→sRGB matrix, per-channel clipping and the IEC 61966-2-1 OETF.
  - **Result**: packages/icc is at most 1 LSB from the reference on all of them, with 95.2–100 % exact and 100 % ≤ 1.
    - It is closer to the reference than either oracle: qcms 0.3.0 and moxcms 0.9.2 are each up to 2 LSB from the same reference.
    - Against the oracles directly, the max is 1 LSB vs qcms and 2 LSB vs moxcms, which reproduces the README accuracy table.
    - GRAY profiles are exact (0 LSB).
  - **Other numeric checks**:
    - The pure-Pion `pow`/`exp`/`ln` (math.pion) reproduce gamma 1.8 / 2.2 GRAY ramps exactly.
    - The hard-coded `xyz_d50_to_srgb_linear()` matrix is within 3.7e-4 of the exact Bradford inverse. It is the inverse of the s15Fixed16-rounded colorants of real sRGB profiles, so real sRGB profiles hit the identity path.
    - P3 primaries and secondaries clip exactly like the reference (`control_p3_out_of_gamut_clipping`).
- **Integer safety of the pixel loop**: `check_matrix_valid` bounds every row's L1 norm at 7.5. The Q14 accumulator is therefore at most 7.5 · 16384 · 16384 + 16384 = 2 013 282 304 < 2³¹. The output index is clamped to `[0, 8192]` before the 8193-entry LUT. Gains above 7.5 are rejected (`matrix_gain_over_limit`).
- **Buffer API** (`control_buffer_api_and_alpha`, on P3, identity sRGB and GRAY transforms):
  - every alpha value 0..255 is preserved;
  - the in-place result equals the per-pixel API over 17³ + 256 pixels;
  - `transform_gray_pixel` equals `rgb(v,v,v).r`;
  - lengths 0..8 are accepted or rejected exactly by `% 3` / `% 4`, and a rejected buffer is untouched.
- **DoS outside P0-1**: everything that is not a duplicate-tag bomb stays linear.
  - A 16 MiB `desc` parses in 34 ms. A 4096-record table with 4096 records per `mluc` parses in 49 ms.
  - 4096 distinct tags over a 1 MiB blob take 2.2 ms.
  - A 255 × 65 519-byte JPEG reassembles in 8.7 ms (34 MiB RSS).
  - 4 MiB of fill bytes, 4 MiB of stray bytes, 1 M empty JPEG segments and 1 M empty WebP chunks each take ≤ 1.2 ms.
- **Portability**:
  - 0 `extern "C"`, 0 `World`, 0 `import`, 0 `[dependencies]` in `packages/icc`, and 0 module-level `let mut`;
  - 0 `.icc` files in git; commit `04ba43c` touches only `packages/icc/**`;
  - `pionc fmt --check`, `pionc check` and `pionc test` (9/9) pass;
  - `wasm_smoke` prints the same line in all 4 modes (but see P1-3).
- **Bench mechanics**:
  - Both Scenario B workloads do real, non-identity work. Pion wall time scales with the frame count (5 → 25 frames: 36 → 139 ms, i.e. no dead-code elimination of the pixel loop).
  - The 1-frame accuracy check in `run_bench.sh` covers the full frame, including alpha.
  - `run_bench.sh` runs as shipped, and its stdout is byte-identical across implementations. The problems are what the numbers are compared against (P1-1, P1-2) and what the hash covers (P2-5).

## Findings

### P0-1 Duplicate tag signatures: O(tag_count × tag_size) parse (CPU DoS) and last-wins semantics

- **Where**: `src/parser.pion:411-496`.
  - The tag loop dispatches on the signature for every record. Every `desc`/`rXYZ`/…/`kTRC` record is decoded again, even when an earlier record had the same signature.
  - The only global limits are `max_tag_count = 4096` (`src/types.pion:5`) and the per-tag size checks.
  - There is no limit on profile size (`src/parser.pion:315-327`) and no total decoding budget.
  - 4096 records may point at the same large tag, which is legal: shared offsets are a documented feature. Each one is fully decoded: `desc` copies its whole ASCII part (`parser.pion:126-149`), `mluc` decodes the whole UTF-16 string (`:151-209`, `:85-124`), and `curv` copies up to 65 536 entries (`:271-277`).
- **Trigger**: ③ untrusted input on the default path. Any JPEG APP2 / WebP ICCP passed to `extract_*` then `parse` reaches it.
- **Evidence** (`run_audit.sh dos`; `redteam_p0_1_duplicate_tags_rejected_or_first_wins_bounded`; adversarial `dup_rtrc_conflicting`):

  | bomb | size | native release | wasm32 release |
  |---|---:|---:|---:|
  | 4096 × `desc` → one 1 MiB ASCII tag | 1 097 872 B | **7 982 ms** | 3 860 ms |
  | 4096 × `desc` → one 1 MiB `mluc` | 1 097 888 B | **8 089 ms** | 7 098 ms |
  | 4096 × `rTRC` → one 65 536-entry `curv` | 180 368 B | **948 ms** | 440 ms |
  | 4096 × `desc` → one 4 MiB ASCII tag (manual run) | 4 243 600 B | **31 737 ms** | – |

  - Time is linear in the tag size. `extract_jpeg_icc` accepts 255 × 65 519 B = 16.7 MB (dos `jpeg_255x65519_chunks`), so a single JPEG can carry a profile that parses for about **2 minutes**.
  - For comparison, qcms 0.3.0 caps profiles at 4 MiB and 1024 tags and looks up only the first record (`iccread.rs` `find_tag`). moxcms 0.9.2 is also last-wins, but it caps decoded text with `localized_text_budget` and curves at 40 000 entries.
  - `dup_rtrc_conflicting` has `rTRC` = sRGB `para` then `rTRC` = identity `curv`. packages/icc and moxcms decode the red channel as linear, while qcms (Firefox) uses the sRGB curve. The same file therefore renders differently in different engines.
- **Fix** (either option makes the red-team case pass):
  - reject a repeated signature with `InvalidTagTable` (strict, cheapest); or
  - keep the first record and skip later ones (qcms behaviour, maximally compatible).
  - In addition, add a profile-size cap (qcms: 4 MiB), or a total decoded-bytes budget across all tags, so that 4096 *distinct* known signatures cannot be combined into new amplification. Today only 12 signatures are decoded, so this is linear.
  - **Side effects**: rejection breaks only malformed profiles. First-wins changes which duplicate is used in exactly those malformed profiles.

### P1-1 Scenario A (245× vs qcms, 44× vs moxcms) is a benchmark artifact

- **Where**: `bench/rust_bench/src/main.rs:19-22`, `bench/gen_corpus.py:45`, `README.md:76-83`.
  1. **qcms is benchmarked on its slow path.** The destination is `qcms::Profile::new_sRGB()` without `precache_output_transform()`. Every `Transform::new` therefore rebuilds three output-gamma tables by curve inversion (`qcms transform.rs:1305-1342`, `build_output_lut`) and selects the generic float pipeline. Firefox and every documented qcms user precache the output profile once, and Pion's destination tables are compile-time constants (`src/srgb_lut.pion`). The fair comparison is precached qcms (`qcms_pre` in `diff/oracle`).
  2. **The corpus is the one profile with no curve work.** `gen_corpus.py:45` writes exactly the sRGB `para` type-3 parameters for all 3 channels. `transform.pion:73` (`is_exact_srgb_para3`) then returns the constant `srgb_eotf_q14`, and `tone_curve_equals` shares it. So Pion's "transform build" is a matrix product. Any other TRC needs 256 software `pow` calls per curve. A profile that is sRGB-like in fact (for example a `curv[1024]` sRGB) first runs the identity probe at `transform.pion:196-218`: 3 × 256 `srgb_oetf(eval_tone_curve)` calls, each a series `exp`/`ln` (`math.pion:51-162`).
- **Evidence** (`run_audit.sh bench`, `bench_compare.py`, warmup 1, rounds 5, interleaved, identical stdout; ns/op over 20 000 iterations, process start included):

  | profile (20 000 × parse + `to_srgb` + 1 px) | `pion_icc` | qcms as shipped | **qcms, precached output** | moxcms | Pion vs qcms as shipped | **Pion vs precached qcms** | Pion vs moxcms |
  |---|---:|---:|---:|---:|---:|---:|---:|
  | shipped `display_p3_v4` (sRGB `para3`) | 1 761 ns | 276 553 ns | 2 809 ns | 47 329 ns | 157× | **1.59×** | 26.9× |
  | sRGB IEC61966-2.1 v2 `curv[1024]` | 54 414 ns | – | 3 246 ns | 46 621 ns | – | **0.06× (16.8× slower)** | 0.86× |
  | AdobeRGB v2 `curv` gamma 563/256 | 14 593 ns | – | 5 036 ns | 53 631 ns | – | **0.35×** | 3.7× |
  | Rec.2020 `para3` (709 TRC) | 13 491 ns | – | 3 096 ns | 52 017 ns | – | **0.23×** | 3.9× |

  The shipped `run_bench.sh` reproduces its own claim shape on the same machine (150–172× vs qcms, 5.0–5.6× by moxcms at 20 000 iterations; README: 245× / 5.54×).

  - On the shipped corpus, Pion is 1.6× faster than precached qcms, not 245×.
  - On the most common embedded profile (sRGB IEC61966-2.1 v2, `curv[1024]`, the macOS `sRGB Profile.icc` layout), Pion is **17× slower than qcms and slower than moxcms**. On every non-sRGB-`para3` profile tried it is 3–4× slower than precached qcms.
- **Fix**:
  - Benchmark qcms with `dst.precache_output_transform()` (and keep the non-precached number only as a labelled extra).
  - Add the sRGB `curv[1024]`, AdobeRGB `curv` gamma and a non-sRGB `para` profile to the corpus, and report every row, including the losing ones (AGENTS.md §1.3: "如实记录领先与落后项").
  - For the slow path itself: decide identity by comparing the Q14 input LUTs against `srgb_eotf_q14` (±1) instead of 768 float `pow`s, and evaluate each distinct curve once.

### P1-2 Scenario B (1.99× vs qcms) compares against qcms' non-precached float path

- **Where**: `bench/rust_bench/src/main.rs:56-57`, `README.md:86-93`.
  - Without a precached destination, qcms selects `qcms_transform_data_rgba_out_lut` (float matrix plus output interpolation per pixel).
  - With precache it uses `qcms_transform_data_rgba_out_lut_precache`. This is still scalar, because qcms' `neon` feature is off by default and in the lock.
- **Evidence** (1080p RGBA8, `ICC_BENCH_FRAMES` frames, same bench protocol):

  | 1080p RGBA8 × 20 frames, Display-P3 → sRGB | median | ns/px | peak RSS | Pion speed-up |
  |---|---:|---:|---:|---:|
  | `pion_icc` (scalar) | 117.9 ms | 2.84 | 20.5 MiB | – |
  | qcms as shipped (no precache, float path) | 237.2 ms | 5.72 | 10.1 MiB | 2.01× (README: 1.99×) |
  | **qcms, precached output (scalar precache path)** | **113.1 ms** | **2.73** | 10.2 MiB | **0.96×** |
  | moxcms 0.9.2 | 63.5 ms | 1.53 | 18.3 MiB | 0.54× |

  - Against the configuration Firefox ships (precached output), pure-scalar Pion is **at parity or slightly slower**, not 1.99× faster.
  - The README sentence "1.99x faster than `rust_qcms`" and the 357 MP/s claim need the qcms configuration stated next to them.
- **Fix**: precache the qcms destination in `rust_bench` (or report both rows, labelled), and rewrite README Scenario B.

### P1-3 README `wasm_smoke` evidence is not reproducible

- **Where**: `README.md:58`.
  - The README says `icc_wasm_smoke: OK pixels=216 fnv64=8497055218630584498`.
  - The shipped `wasm_smoke` prints `fnv64=10050272235678599435` in all four modes.
  - That value equals an independent FNV over the audit binary's own transform of the same 216 pixels.
  - The README value matches neither the untransformed buffer (`4943025184395460673`) nor the exact-reference output (`8000171919812848290`).
- **Impact**: the 4-mode agreement the README claims is true, but the published artefact was not produced by this commit. A reviewer comparing against it is misled.
- **Fix**: regenerate the line from the shipped smoke. `run_audit.sh smoke` gates it.

### P2-1 `is_srgb_like` says true for profiles whose transform moves pixels by up to 12–15 LSB

- **Where**: `src/parser.pion:531-573`.
  - The tolerances are 0.005 per matrix element and 0.004 in **linear light** per curve sample. Near black, linear light is perceptually very non-uniform: 0.004 linear is 12 sRGB code values.
  - Only `i = 0, 8, …, 248` are sampled, so 255 is never checked.
  - The README usage block (`README.md:31`) and the API name invite skipping `Transform::to_srgb` when it returns true.
  - `Transform::to_srgb` itself uses a different, stricter test (exact 8-bit round trip, `transform.pion:193-218`), so the two disagree.
- **Evidence** (`redteam_p2_1_is_srgb_like_implies_identity_within_1_lsb`):
  - sRGB primaries + sRGB `para` type 4 with 0.35 % flare (`e = f = 0.0035`): `is_srgb_like() == true`, but the transform maps `(0,0,0) → (12,12,12)`.
  - sRGB `para3` with the red primary leaking 0.45 % into green: `is_srgb_like() == true` and `(255,0,0) → (255,14,0)` per the exact reference.
  - Controls: AdobeRGB, Display P3, sRGB primaries with gamma 2.2, ProPhoto and the system profiles all correctly report false (`S 0` in every dump).
- **Fix**: define `is_srgb_like` as "the 8-bit transform is the identity within ±1 LSB". Reuse the identity test of `to_srgb` (after P2-2) or compare in the encoded domain over all 256 levels, with a matrix tolerance of about 1e-4.

### P2-2 `is_identity` fast path tolerates a 0.002 matrix error (up to 6.6 LSB)

- **Where**: `src/transform.pion:194-218`.
  - `eps = 0.002` per element of `M_pcs→srgb · M_profile`. The curve check is exact, but an off-diagonal 0.002 is 0.002 linear light in a channel that should be 0.
  - That is `0.002 × 12.92 × 255 = 6.6` code values, and saturated colours are copied unchanged.
- **Evidence**:
  - `diff`: `srgb_offdiag_0019` gives `(243,0,0) → (243,0,0)`, where the exact reference gives `(243,6,0)` and qcms/moxcms agree within 2. That is 6 LSB.
  - `srgb_offdiag_0010` is 3 LSB off.
  - `redteam_p2_2_identity_fast_path_within_1_lsb`.
  - These are the only >1 LSB deviations in the differential run.
- **Fix**: tighten `eps` to about 1e-4 (≤ 0.33 LSB), or verify the Q14 integer matrix and LUTs on the cube corners and ramps before declaring identity. Real sRGB profiles (s15Fixed16 colorants) stay well inside 1e-4 (`sRGB Profile.icc`: `id=1`).

### P2-3 An AToB0 LUT is silently ignored when colorants and TRCs are also present

- **Where**: `src/transform.pion:171-276`. The engine never looks at `A2B0`/`A2B1`/`mAB`.
  - The README (`:20`) says CLUT profiles are cleanly rejected. That is true only when the colorant tags are absent.
  - Display and camera profiles from profilers commonly carry both a LUT and colorant tags.
  - ICC CMMs give the LUT precedence for the requested intent, and so do both oracles.
- **Evidence** (`redteam_p2_3_atob0_not_silently_ignored`, adversarial `a2b0_with_matrix_trc`): a P3 matrix/TRC profile plus an `mft2` AToB0 that maps everything to PCS white.
  - qcms 0.3.0 and moxcms 0.9.2 output `(255,255,255)` for every pixel.
  - packages/icc outputs `(0,0,0)` for black, through rXYZ + TRC.
- **Fix**: until LUT tags are implemented, return `UnsupportedProfile` when `has_tag("A2B0")`/`"A2B1"` (and the colour space is RGB/GRAY), so callers fall back the same way as for LUT-only profiles.

### P2-4 WebP `ICCP` is returned without the VP8X ICC flag, and in simple-format files

- **Where**: `src/container.pion:164-207`. The loop returns the first `ICCP` chunk anywhere in the RIFF.
- **Spec**: in the WebP container spec, ICCP is valid only in the extended format, with the VP8X `ICC profile` flag (`0x20`) set.
- **Reference**: libwebp's demuxer stores it only then (`libwebp-sys 0.9.6 vendor/src/demux/demux.c:501`: `store_chunk = !!(dmux->feature_flags_ & ICCP_FLAG)`). `webpmux -get icc` refuses both files.
- **Evidence** (`redteam_p2_4_webp_iccp_needs_vp8x_icc_flag`, adversarial `webp_iccp_without_vp8x_flag`, `webp_iccp_in_simple_format`): packages/icc returns the 440-byte profile, so the image is colour-managed differently from Chromium/libwebp.
- **Fix**: require the first chunk to be `VP8X` with bit `0x20` set before returning `ICCP`, and return `Ok(None)` otherwise.

### P2-5 The bench SHA-256 gate does not observe the colour work

- **Where**:
  - `bench/pion_bench/src/main.pion:56,111,124` and `bench/rust_bench/src/main.rs:45,61,78,84`.
  - Scenario A prints the sum of one probe pixel `(128,128,128)`. Mid-grey maps to itself for every sRGB-like profile, Display P3 included.
  - Scenario B prints the alpha of two pixels, which no colour transform touches.
- **Evidence**: `run_audit.sh bench`. With the identity sRGB profile, which does no colour work, the stdout SHA-256 equals the Display-P3 run in both scenarios (`4b52194c…` and `3e7fab89…`). The "byte-identical stdout" required by AGENTS.md §1.3 therefore verifies nothing about the transform.
  - The 1-frame tolerance check in `run_bench.sh` is real. It is not tied to the timed runs.
- **Fix**:
  - Have every timed run dump its final frame, and apply the existing ≤ 1 / ≤ 2 LSB comparator to those dumps.
  - Or print a tolerance-stable digest, for example the per-channel histogram of `value >> 2` over the final frame. A digest of the unmodified output cannot be identical across engines that legitimately differ by 1 LSB.
  - For Scenario A, probe a saturated pixel such as `(255,0,0)` → `(255,0,0)` and `(0,255,0)`.

### P2-6 Nits (spec / API / documentation)

- **Module-level `FixedArray` LUTs**:
  - `src/srgb_lut.pion:4` (`srgb_eotf_q14 : FixedArray[Int]`) and `:23` (`srgb_oetf_8193 : FixedArray[Byte]`) are mutable containers at module level. Every `Transform` aliases them (`transform.pion:74,254`).
  - Nothing writes them (checked by the `portability` gate), and the fields are private, so there is no race today.
  - The README's "zero mutable module globals" (`README.md:3`) is literally false, and it is one `lut[i] = …` away from shared-state corruption. Prefer an immutable array type, or copy on build.
- **Not `Send`**: `parse`, `extract_*` and `Transform::to_srgb` results cannot cross a `spawn` boundary (`E_NOT_SEND`). Only `IccError` and `Xyz` can. Multi-threaded tile transforms must re-parse per thread. AGENTS.md §1.1 asks for `Send` values where possible.
- **`desc` high bytes**: `desc` ASCII bytes ≥ 0x80 are copied raw into a Pion `String` (adversarial `desc_high_bytes` → bytes `ff fe 80`). The ICC text is 7-bit. Map them to U+FFFD, or to Latin-1 → UTF-8.
- **No version check**: the profile version is not validated. v5 (iccMAX) and v0/v255 headers are parsed and transformed as v2/v4 matrix/TRC profiles.
- **Doc vs code**: the `xyz_d50_to_srgb_linear` comment says "exact inverse of the … Bradford-adapted sRGB D50 primaries". It is the inverse of the s15Fixed16-rounded colorants (3.7e-4 from exact Bradford). The choice is good, the comment is not.
- **README accuracy table**:
  - The ROMM row reads "max 2 LSB … 100.00 % ≤ 1 LSB" (a rounded 99.99x %).
  - The 33³ harness that produced the table is not committed. `audit/diff/compare.py grid` now reproduces it.
- **Registry**: no `index/icc.toml` and no `BENCHMARKS.md` section yet (expected at release time per AGENTS.md §1.3–1.4).

## Files

| Path | Purpose |
|---|---|
| `run_audit.sh` | the gate (sections above, `STRICT=1`) |
| `src/cases.pion` | red-team and control cases, with an in-memory ICC/JPEG/WebP writer; run per mode by `icc_audit case` and by `pionc test` |
| `redteam_test.pion`, `control_test.pion` | `pionc test` wrappers (`redteam_*` fail until fixed, `control_*` must pass) |
| `src/dump.pion`, `src/main.pion` | mode-independent dump: IEEE bits, transform FNV over the probe set. CLI: `dump`, `dumplist`, `grid`, `time`, `list`, `case` |
| `diff/gen.py` | deterministic corpus: 37 well-formed, 149 adversarial with expectations, 2 464 truncations, N mutants, 12 DoS bombs, 40 033-pixel grid |
| `diff/compare.py` | crash-resumable runner, mode comparator, adversarial classifier, exact ICC float reference and differential table |
| `diff/dos.py` | per-bomb verdict, ms/parse and peak RSS (`wait4`) |
| `diff/oracle/` | Rust `qcms =0.3.0` + `moxcms =0.9.2` (locked): `grid`, `gray`, `verdict`, `build` (`qcms`/`qcms_pre`/`moxcms`), `rgba` |
