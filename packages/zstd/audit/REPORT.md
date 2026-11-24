# Red-team audit: `packages/zstd` v0.1.0 (RFC 8878 Zstandard + xxHash64)

Auditor: independent red team (`RT-zstd`), 2026-11-24. Audited commit: `2f0490f` (`origin/feat/pkg-zstd`).
Nothing under `packages/zstd/src`, the package tests, `pion.toml`, the package `README.md`, `bench/`, `wasm_smoke/`
or any repository-root file is changed by the audit; everything lives in `packages/zstd/audit/`.

```sh
sh packages/zstd/audit/run_audit.sh            # exit 1 while any P0 condition reproduces
STRICT=1 sh packages/zstd/audit/run_audit.sh   # exit 1 while any P0 / P1 / P2 finding is open
```

Requirements: `pionc`, `node` (wasm32 runtime), the official `zstd` CLI (v1.5.7 was used), `cargo` (oracle crates
`ruzstd =0.9.0`, `zstd =0.13.3` / libzstd 1.5.7, `twox-hash =2.1.5`, `--locked`, offline from the crate cache when
possible) and `python3` (stdlib only, always run as `python3 -I -B`). Artifacts go to `$AUDIT_OUT` (default
`/private/tmp/pion-zstd-audit`, or `/tmp/pion-zstd-audit` where `/private/tmp` does not exist); nothing is written
into the repository and no `__pycache__` is left (both are checked by the summary step).

## SIGN-OFF: `2f0490f` (`origin/feat/pkg-zstd`)

**`packages/zstd` v0.1.0 at `2f0490f` is signed off by the independent red team (`RT-zstd`), 2026-11-24.**

No P0, P1 or P2 finding was opened. All seven dimensions of the brief were checked and hold; the differences to
the official decoders that remain are all on the RFC side (Pion is stricter than libzstd where libzstd tolerates
malformed input, and agrees with the independent RFC model everywhere) and are listed as INFO below.

**Final run (see "Run record" at the end):** `STRICT=1 sh packages/zstd/audit/run_audit.sh` → `EXIT=0`, 0 P0,
0 OPEN; `sh packages/zstd/audit/run_audit.sh` → `EXIT=0`.

| ID | Sev | Status | Summary |
| --- | --- | --- | --- |
| — | — | — | no P0 / P1 / P2 finding |
| I-1 | INFO | documented | default `ZstdLimits` (8 MiB window) reject valid frames that need a larger window; libzstd defaults to 128 MiB |
| I-2 | INFO | by design | an offset larger than `Window_Size` is rejected (RFC 8878); libzstd and ruzstd accept it |
| I-3 | INFO | by design | Pion rejects malformed Huffman streams / an empty `Compressed_Block` that libzstd 1.5.7 tolerates |
| I-4 | INFO | by design | 4-stream literals with `Regenerated_Size` 3 or 4 are accepted (RFC allows); libzstd requires ≥ 6 |
| I-5 | INFO | open question for the author | compressor ratio is below `zstd -1` at every level (only Predefined / RLE sequence codes, Direct Huffman weights) |
| I-6 | INFO | README | benchmark section omits min / p95 / peak RSS (AGENTS.md §1.3); measured values below |
| I-7 | INFO | memory profile | peak RSS ≈ 1.8–2.4 × the decompressed size, bounded by `max_output_bytes` |
| I-8 | INFO | release integration | root `catalog.json`, `README.md`, `BENCHMARKS.md`, `THIRD_PARTY_NOTICES.md`, `index/zstd.toml` do not list `zstd` yet |
| I-9 | INFO | oracle note | `ruzstd 0.9.0` accepts many malformed frames (reserved bit, FCS / checksum mismatch, …); its "agree" counts are not a correctness bar |

## Gate results

Machine: `Linux x86_64` (8 vCPU shared box), `pionc 0.1.0` (abi `pionc-v0.19`), node v24.22.1, zstd CLI v1.5.7,
cargo / rustc stable, Python 3.13.5. The first full run was repeated on a second, idle `Linux x86_64` box for the
benchmark numbers; every gate gave the same result on both.

| Gate | Result |
| --- | --- |
| static | license MIT, 0 dependencies, 0 `extern "C"` / imports / `World` / module-level `let mut` / non-scalar module-level bindings / `Double` / `Float` / `panic` / `abort` / `unwrap`, 0 internal host names or personal paths (package and `audit/`); `Send` probe: `ZstdLimits`, `ZstdError`, `Int64` are `Send`, `Bytes` and `Result[Bytes, ZstdError]` are `!Send` (`E_NOT_SEND`) — exactly the README.md table; the README pattern (capture a `String`, compress inside `spawn`) type-checks |
| unit | package 8/8; `scripts/verify.sh packages/zstd` passes `fmt --check`, `check`, `test`; audit `pionc test`: 16/16 control |
| cases | 16/16 control cases in native debug / release and wasm32 debug / release, identical results |
| xxhash | `xxhash64()` = independent model = Rust `twox-hash 2.1.5` on 81 inputs (0–1024 B, stripe and every tail path, `0xFF` / high-bit bytes) × 7 seeds (0, 1, 2654435761, −1, −2⁶³, 2⁶³−1, −2654435761): 2,268 Pion comparisons in 4 modes + 567 model-vs-twox-hash, 0 mismatches |
| valid | 1,159 / 1,159 valid streams byte-exact (official CLI `--fast=5`…`-19`, `--ultra -20/-22`, `--long`, `wlog=10/11`, strategies 1/3/6/9, `-T2 -B`, `--no-check`, stdin without FCS; libzstd bulk −5…22; ruzstd Uncompressed / Fastest; multi-frame + skippable), 2 of them with raised limits (I-1) |
| crafted | 222 hand-built RFC 8878 frames (77 must decode, 138 must fail, 7 compared only): Pion 222/222 as the RFC requires; independent model 222/222 |
| fuzz | 7,000 inputs (1,000 random *valid* frames from the model's writer + 6,000 mutations of official / crafted frames and random bytes behind a magic): Pion = model on 7,000/7,000 (OK/ERR and content), Pion = libzstd on 6,966/7,000, the 34 differences all in I-1 / I-2 / I-3; 0 panic, 0 trap, 0 hang (all 7,000 in about 1 s in one process) |
| determinism | 8,381 corpus records decoded in all 4 modes: byte-identical result files |
| encoder | 960 Pion frames (48 inputs × levels 0–9 × checksum on/off), byte-identical in all 4 modes; 960/960 decoded byte-exact by libzstd, ruzstd, Pion, `zstd -t` and `zstd -d`; 920/920 by the strict model (inputs > 300 KB skipped there); 960/960 obey the frame rules (FCS present and exact, checksum flag as requested, no reserved / unused / dictionary bits, every `Compressed_Block` strictly smaller than its content); invalid levels −1, 10, 22, 2³¹−1, −2³¹ → `InvalidLevel` |
| dos | 27 bombs native = wasm32, all within time and RSS budget (table below); decompression scales ×2.5–×4.6 for 4× output; compressor ×1.4–×5.4 for 4× input at levels 0–9 on zeros / 2-byte / 3-byte periods / a 4-byte hash-collision chain / random / text |
| smoke | `wasm_smoke` 4 × `f0c876d5…acd` (146 B) = README.md |
| bench | `bench/run_bench.sh`: 193 / 193 parity cross-checks (= README.md), compressed sizes `83,790 / 107,496 / 100,949` and `262,088 / 352,983 / 323,238` B reproduced exactly, stdout SHA-256 identical across implementations; speed ratios see I-6 |
| inject | 25/25 injected real bugs caught by the control tests |

## Dimension 1 — RFC 8878 frames, boundaries, reserved bits, checksum

All frame cases are in `diff/gen.py` (`F*`, `B*`, `X*`), each with the RFC expectation, decoded by Pion, the model,
ruzstd and libzstd. Highlights (Pion result = RFC in every case):

- **Magic / skippable:** `0x184D2A50..5F` all 16 nibbles; empty skippable frames; skippable frames before, between
  and after standard frames; a stream of only skippable frames decodes to empty output; a skippable size past the
  end, `0xFFFFFFFF`, a truncated size field → `UnexpectedEof`; neighbours `0x184D2A4F`, `0x184D2A60`, `0xFD2FB527`
  → `InvalidMagic`; 1 / 3 / 4 bytes of trailing garbage → error; skippable frames count against `max_frames`.
- **Frame_Header_Descriptor:** `Reserved_bit` (bit 3) → `InvalidFrameHeader`. The `Unused_bit` (bit 4) is
  ignored, as RFC 8878 §3.1.1.1.1 requires ("a decoder compliant with this specification version shall not
  interpret this bit") and as libzstd does. All `FCS_flag` forms: 1-byte single-segment FCS 0 / 1 / 255, the 2-byte
  `+256` form at 256, 257, 4000 and its maximum 65,791, 4- and 8-byte FCS (also non-minimal 8-byte values),
  `FCS_flag = 0` without single segment (no FCS). `Dictionary_ID` 0 in 1 / 2 / 4 bytes decodes (0 means "no
  dictionary"), any non-zero id (1, 0x8000, 0xFFFF, 0xFFFFFFFF) → `UnsupportedDictionary`.
- **Frame_Content_Size vs. content:** −1, +1, declared 0 with 1 byte, declared 5 with 0, single-segment mismatch,
  compressed-block mismatch → `ContentSizeMismatch` (or `InvalidBlockHeader` when the block already exceeds the
  single-segment window). `FCS = 100 GiB` / `2⁶⁴−1` with a 1-byte body → `LimitExceeded` before any allocation;
  `FCS = 60 MiB` with a truncated body → pre-allocation capped at 4 MiB (6.3 MiB peak RSS).
- **Window_Descriptor:** 1 KiB (exponent 0) with a 1,024-byte block OK / 1,025 rejected, mantissa 7 = 1,920 OK /
  1,921 rejected, 8 MiB exactly OK, 9 MiB and exponent 31 → `LimitExceeded`; single-segment `FCS = 9 MiB` →
  `LimitExceeded` (window), single-segment `FCS = 0` with an empty block OK and with 1 byte rejected.
- **Content checksum:** every bit flip of the 4 checksum bytes tested, payload bit flips, truncation by 1–4 bytes,
  two frames each with their own checksum. xxHash64: see the gate table (both 32-byte stripe and every 8 / 4 / 1-byte
  tail path, seeds with the sign bit set — a signed-shift implementation would fail `control_xxhash`, which the
  injection gate proves with I-2 of `diff/inject.py`).
- Every prefix of a valid frame with checksum (`F26_*`, 16 cuts) is rejected.

## Dimension 2 — blocks, literals, Huffman, FSE, sequences

- **Blocks:** `Block_Type = 3` (with and without payload) → `InvalidBlockHeader`; Raw / RLE blocks of exactly
  128 KiB OK, 128 KiB + 1 rejected; a `Compressed_Block` larger than `Block_Maximum_Size`, of size 0 (I-3), truncated
  Raw / RLE blocks, an RLE block exceeding a single-segment window, missing `Last_Block` → error.
- **Literals:** Raw / RLE in all `Size_Format`s (including the 1-byte alias `sf = 2` and 20-bit sizes up to 100 KB),
  literals larger than `Block_Maximum_Size`, truncation; Compressed literals 1-stream and 4-stream with Direct and
  FSE-compressed weights, 5-byte headers, 128 direct weights, 255 FSE weights (256 symbols), `Max_Number_of_Bits = 1`.
  Rejected: leftover not a power of two, weight 12 / 15, `Max_Number_of_Bits = 12`, all weights 0, FSE weights that
  decode to more than 255 weights, a jump table past the literals, a stream whose last byte is 0, unconsumed bits,
  underflow, regenerated size too large / too small, `Regenerated_Size` > block maximum, compressed size past the
  block, 4 streams with regenerated size 1 / 2 / 5.
- **Treeless:** first block of a frame → `InvalidLiteralsHeader`; after a Compressed block in the same frame OK
  (1- and 4-stream); **across frames → rejected** (the table is per frame); after an intermediate Raw-literals block
  the table persists (as in libzstd).
- **Sequences:** 1 / 2 / 3-byte counts (32,513 sequences in one block), a non-canonical 2-byte count, trailing bytes
  after a 0-sequence header, reserved mode bits, RLE symbols LL 36 / OF 32 / ML 53, Repeat_Mode on the first block for
  each of LL / OF / ML, **Repeat_Mode across frames → rejected**, Repeat after RLE keeps the RLE table, Repeat after
  a 0-sequence block, FSE tables at the maximum accuracy log (LL 9, OF 8, ML 9) OK and one above rejected, a
  truncated table description, a zero-run past symbol 31.
- **Repeat offsets (RFC 8878 §3.1.1.5):** the initial `[1, 4, 8]` for every code with `LL > 0` and `LL == 0`
  (`offset_value 1 → rep2`, `2 → rep3`, `3 → rep1 − 1`); **`rep1 == 1, LL == 0, offset_value == 3` → `InvalidOffset`**,
  also reached in two steps (`rep1 = 2 → 1 → 0`); repeat offsets persist across blocks (also across a Raw block) and
  are reset at each frame.
- **Match copy:** offset larger than the output, larger than `Window_Size` even when more history exists (I-2),
  equal to `Window_Size` (OK), offsets 1 / 2 / 7 with long overlapping matches, matches into the previous block,
  offsets into the previous frame (rejected), literal-length overrun, block output exceeding the block maximum by a
  match or by the trailing literals, a block filled exactly to the maximum, a missing sentinel, unconsumed / missing
  sequence bits, a trailing byte, `ML = 131,074`, offset codes 30 / 31.
- 1,000 random valid frames from `rand_frame` in `diff/gen.py` combine all of the above (random block / literal
  types, Direct and FSE weights, Treeless, all four modes per stream, new offsets and every repeat code) and decode
  identically in Pion, the model and libzstd.

Format features exercised (counted by the model's decoder): official / library frames — `hw_fse` 195,
`huf_4stream` 81, `lit_treeless` 24, `ll/of/ml_fse`, `ll/of/ml_rep`, every repeat code, 2-byte sequence counts,
multi-block, window descriptors and single segment; crafted frames add `fcs_8`, `dictid_field`, `fhd_unused_bit`,
`nseq_0/3b`, every RLE mode, `lit_rle`; random frames add ~80 of each repeat code and Repeat modes on all three
streams.

## Dimension 3 — DoS, zip bombs, OOM, complexity

`diff/dos.py`, native `--release` and wasm32 `--release`, peak RSS of the native process (Linux `VmHWM`, sampled
after `exec`), in-process microseconds (`clock_monotonic_us`) for the scaling gates, minimum of 3 runs:

| Bomb | Result | native s | RSS MiB |
| --- | --- | ---: | ---: |
| FCS 100 GiB / 2⁶⁴−1, 1-byte body | `LimitExceeded` | 0.005 | 1–2 |
| FCS 60 MiB, truncated | `UnexpectedEof` | 0.02 | 6.3 |
| 1 MiB of RLE blocks claiming 32 GiB, default limits | `LimitExceeded` at 64 MiB | 0.3–1.0 | 117 |
| same, `max_output_bytes` 1 KiB / 64 KiB | `LimitExceeded` | 0.01 | 2–4 |
| exactly 64 MiB of RLE | OK | 0.4–0.8 | 116 |
| match bomb (one 131,071-byte match per 12-byte block) default / 64 KiB | `LimitExceeded` | 0.2–0.9 / 0.01 | 116 / 2 |
| 1,024 frames × 2 MiB default / 1 KiB | `LimitExceeded` | 0.3–0.7 / 0.01 | 116 / 2 |
| 200,000 skippable frames | `LimitExceeded` (`max_frames`) | 0.01 | 4 |
| 1,024 / 100,000 (raised) empty frames | OK | 0.01–0.02 | 2–4 |
| window exponent 31, skippable size 4 GiB | `LimitExceeded` / `UnexpectedEof` | 0.01 | 1–2 |
| 43,690 sequences in one block / 98,046 | OK / error | 0.02 / 0.01 | 3 / 2 |
| 4-stream Huffman 128 KiB × 64 / × 512 / × 512 with 1 MiB limit | OK / OK / `LimitExceeded` | 0.2 / 1.5 / 0.1 | 26 / 157 / 34 |

The output limit is checked before every write (`OutBuf::ensure`), so a bomb is stopped at the first block that
would cross the limit — output never grows past `max_output_bytes`. Decompression scales linearly (RLE ×2.4–2.9,
matches ×2.5–3.4, Huffman ×4.0–4.6 for 4× the output). The compressor is linear on every degenerate input at
levels 0–9 (worst: the hash-collision chain at level 9, 0.09 s → 0.33–0.40 s for 256 KiB → 1 MiB); level 0 is a
copy of ~1 ms whose 256 KiB → 1 MiB ratio is timer noise and is held to an absolute budget instead. `ZstdLimits`
with a negative field → `LimitExceeded`; `0` is enforced exactly (`max_output_bytes = 0` still decodes an empty
frame); invalid compression levels → `InvalidLevel`.

## Dimension 4 — official zstd / libzstd / ruzstd differential

See the valid, crafted, fuzz and encoder gates. Pion frames are additionally checked against the frame rules a
decoder need not enforce (FCS exactness, checksum flag, reserved / unused / dictionary bits, `Compressed_Block`
strictly smaller than its content) and by the strict model (offsets within the declared window, exact bitstream
consumption, no trailing bytes). Compressed sizes (bytes):

| Input | Pion L0 / L1 / L3 / L6 / L9 | zstd −1 / −3 / −19 |
| --- | --- | --- |
| text 1,024 B | 1,034 / 516 / 500 / 498 / 498 | 424 / 414 / 402 |
| text 131,073 B | 131,089 / 57,061 / 52,199 / 45,968 / 42,637 | 36,343 / 34,968 / 28,610 |
| html 1 MiB | 1,048,610 / 174,059 / 164,640 / 140,095 / 136,706 | 103,610 / 108,042 / 76,961 |
| binlog 1 MiB | 1,048,610 / 354,979 / 344,104 / 315,840 / 298,429 | 242,909 / 233,386 / 166,320 |
| random 128 KiB | 131,084 (all levels) | 131,088 |
| 200,000 × `0x5a` | 18 | 29–30 |

## Dimension 5 — purity, `Send`, 4-mode smoke, verify, benchmarks

See the static, unit, smoke and bench gates. The `wasm_smoke` binaries are 185–189 KB / 439 KB (native debug /
release) and 108–109 KB / 113–114 KB (wasm32); README.md does not state sizes.

Benchmark re-run (`bench/run_bench.sh`, warmup 1, 5 interleaved rounds, median ms / ratio):

| Workload | README.md | box A, load ≈ 7.8 / 8 | box B, load ≈ 2–4 / 8 | box B final run, load 2 → 12 |
| --- | --- | --- | --- | --- |
| web decompress vs ruzstd | 44.9 ms, 0.60x | 123.6 ms, 0.30x | 123.6 ms, 0.76x | 123.9 ms, 0.52x |
| web compress L3 vs libzstd | 33.4 ms, 0.33x | 93.1 ms, 0.27x | 80.1 ms, 0.68x | 109.9 ms, 0.41x |
| binlog decompress vs ruzstd | 75.5 ms, 0.47x | 209.0 ms, 0.40x | 181.8 ms, 0.63x | 239.4 ms, 0.48x |
| binlog compress L3 vs libzstd | 99.2 ms, 0.22x | 173.8 ms, 0.21x | 195.1 ms, 0.31x | 245.1 ms, 0.29x |

On the least-loaded run every ratio is at or above the README value, so the README does not overstate Pion's
standing; on a saturated box the ratios move by up to 2×, in both directions.
Absolute times differ by machine. Peak RSS (idle box, `/usr/bin/time`): pion 5.1–6.1 MiB, ruzstd 8.5–9.8 MiB,
libzstd 5.4–6.0 MiB.

## Dimension 6 — mutation proof

`diff/inject.py` copies the package, applies one real bug at a time and runs `pionc test` on the audit package;
every one of the 25 is caught by at least one control test (`control_*` in `src/cases.pion`, vectors in
`src/vectors.pion`, generated by `diff/mkcases.py`):

xxHash64 rotation, xxHash64 arithmetic shift, Reserved_bit accepted, Block_Type 3 decoded as Raw, offset >
Window_Size accepted, offset > decoded history accepted, Treeless with a default tree, Repeat_Mode falling back to
Predefined, tables / repeat offsets carried across frames, `LL == 0` shift ignored, offset 0 accepted, output limit
off, 4-stream segment rounding, FSE weight tail from the wrong state, FCS mismatch accepted, skippable frames not
recognised, checksum not verified, non-zero Dictionary_ID accepted, 2-byte FCS without `+256`, window mantissa
ignored, Block_Size off by one, sequence bitstream not required to be consumed, Huffman stream not required to be
consumed, `max_frames` off by one, and a compressor bug (repeat code 2 instead of 1 for rep2 at `LL == 0`).

## INFO items (not blocking)

- **I-1 Default window limit.** `ZstdLimits::default()` allows an 8 MiB window — the value RFC 8878 §3.1.1.1.2
  recommends decoders support — while libzstd defaults to 128 MiB. Valid frames from `zstd --ultra -20…-22` or
  `--long` whose window is not reduced to the content size (streamed from stdin, or content > 8 MiB) fail with
  `LimitExceeded` until the caller raises `max_window_bytes` (reproduced: `cli-ultra-22-stdin-*`, `cli-long27-stdin_*`
  decode byte-exact with a 1 GiB window limit). README.md lists the defaults; a sentence naming this consequence
  would help users.
- **I-2 Offsets beyond `Window_Size`.** Pion (and the model) reject an offset larger than the frame's window even when
  that much history has been decoded (crafted `S12b` / `S12d`, 2 fuzz inputs). The window is the frame's declared
  memory bound, so this is the RFC reading; libzstd's one-shot decoder and ruzstd keep the whole output and accept
  such frames. No conforming encoder emits them.
- **I-3 Stricter than libzstd 1.5.7.** A 4-stream Huffman stream whose last byte is 0, which is not consumed exactly
  or which underflows is rejected by Pion, the model and (mostly) ruzstd, but libzstd's fast 4-stream decoder returns
  data (29 fuzz inputs, crafted `L16a`). An empty `Compressed_Block` (`B06`) is likewise rejected.
- **I-4 4-stream literals with 3 or 4 symbols** are accepted (the RFC defines the split for any size where the last
  stream is not negative); libzstd 1.5.7 requires at least 6 (`MIN_LITERALS_FOR_4_STREAMS`). ruzstd agrees with Pion.
  An encoder never emits these.
- **I-5 Compression ratio.** Levels 1–9 stay above `zstd -1` on every corpus (table in dimension 4): sequences use
  only Predefined / RLE codes, literals only Direct Huffman weights (symbols ≤ 128, so binary literals stay raw) and
  4 streams from 1,024 literals. The README's 1 MiB sizes are exact; this is a quality item for a later version.
- **I-6 Benchmark report.** README.md gives median and throughput but not min, p95 or peak RSS (it says "N/A");
  AGENTS.md §1.3 asks for all of them. The numbers measured here can be used. Speed ratios depend heavily on machine
  load (table in dimension 5).
- **I-7 Memory.** Peak RSS is ≈ 1.8 × the output for RLE / match output (the output buffer grows by copying) and
  ≈ 2.4 × for literal-heavy output, plus the input itself; always bounded by `max_output_bytes`.
- **I-8 Root files** (`catalog.json`, `README.md`, `BENCHMARKS.md`, `THIRD_PARTY_NOTICES.md`, `index/zstd.toml`) do
  not list `zstd` yet — release integration, not this branch.
- **I-9 ruzstd as an oracle.** `ruzstd 0.9.0` (`FrameDecoder::decode_all_to_vec`) accepts the reserved FHD bit, FCS
  and checksum mismatches, oversized blocks and literals, reserved mode bits and offsets beyond the window (40 of the
  209 default-limit crafted cases), and its encoder implements only `Uncompressed` and `Fastest`. It is used for
  content comparison, not as the bar for rejections; libzstd and the RFC model are.

## Layout of `audit/`

| Path | Purpose |
| --- | --- |
| `run_audit.sh` | one-shot gate runner (sections `build static unit cases xxhash valid crafted fuzz determinism encoder dos smoke bench inject`) |
| `src/main.pion` | harness: `dec` / `enc` / `xxh` over record containers, `bomb` / `cbomb` with in-process µs, `list` / `case` |
| `src/cases.pion`, `src/vectors.pion`, `control_test.pion` | 16 control cases (13 vector groups, official frames, xxHash64, compressor) |
| `diff/zmodel.py` | independent RFC 8878 model: strict decoder with feature tracing + frame writer for any field value |
| `diff/gen.py` | corpora: raw inputs, official encoders, 222 crafted frames, random valid frames, mutations |
| `diff/compare.py` | Pion vs RFC expectation vs model vs libzstd vs ruzstd, with the INFO classes |
| `diff/encoder.py` | Pion compressor → `zstd -t` / `-d`, libzstd, ruzstd, strict model, frame rules |
| `diff/dos.py`, `diff/rss.py` | bombs, scaling and compressor complexity; peak-RSS measurement |
| `diff/inject.py` | mutation proof |
| `diff/mkcases.py` | regenerates `src/vectors.pion` from a corpus |
| `diff/readme.py` | README.md claims parsed at run time |
| `diff/rust/` | oracle (`ruzstd =0.9.0`, `zstd =0.13.3`, `twox-hash =2.1.5`, `Cargo.lock` committed) |

## Run record

Final run on the committed audit tree (this commit), `Linux x86_64`, 8 vCPU, idle at start (load 2.3 → 12 by the
end, the box had just rebooted), `pionc 0.1.0` (amd64_sysv), node v24.22.1, zstd CLI v1.5.7, cargo 1.100, Python
3.13.5, `FUZZ_N=6000`:

```text
==> build      corpus: 48 raw 1159 valid 222 crafted 7000 fuzz
==> static     internal machine names / paths: 0 (package), 0 (audit/); Send table = README.md
==> unit       packages/zstd 8/8; audit 16 pass, 0 red-team open, 0 control failing; scripts/verify.sh --allow-dirty packages/zstd: exit 0
==> cases      16/16 in native_dbg, native_rel, wasm_dbg, wasm_rel
==> xxhash     2268 Pion comparisons + 567 model-vs-twox-hash, 0 mismatching
==> valid      Pion 1159/1159 byte-exact
==> crafted    Pion 222/222 as the RFC requires
==> fuzz       7000 inputs, Pion == model 7000/7000, Pion == libzstd 6966/7000 (29 I-3, 3 I-1, 2 I-2)
==> determinism valid / crafted / fuzz results byte-identical in 4 modes
==> encoder    960 frames 4-mode identical; libzstd + ruzstd + Pion 960/960; zstd -t / -d 960/960; model 920/920; rules 960/960
==> dos        27 bombs + 3 scaling pairs + 35 compressor cases, 0 problems
==> smoke      4 x f0c876d54108186eaaf54a5145f74b569db0d110e91656ba5d44707b49903acd = README.md
==> bench      193 parity cross-checks; 1 MiB sizes reproduced exactly
==> inject     injected bugs caught: 25/25
==> summary    P0 conditions: none   OPEN: 0   STRICT=1   EXIT=0
```

Follow-up (same day): the host-name scan of the `static` gate no longer spells any host name in this public
repository; it checks this machine's own `hostname -s` / `hostname`, personal home-directory paths and an optional
`$AUDIT_FORBIDDEN_NAMES` regex. `STRICT=1 sh packages/zstd/audit/run_audit.sh static` on the committed tree →
`EXIT=0`; the other gates are unchanged.

Default mode differs from `STRICT=1` only in how OPEN findings count; with 0 OPEN and no P0 condition it exits 0
as well (its `static` section was re-run separately on the same tree: `EXIT=0`). `scripts/verify.sh` ran with
`--allow-dirty` because the run directory is a synced copy without git metadata; in this git checkout the audit
tree is committed and `git status --porcelain --ignored` is clean.
