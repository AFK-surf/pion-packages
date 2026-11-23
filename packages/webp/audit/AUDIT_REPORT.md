# Red-team audit: `packages/webp` v0.1.0

- **Target**: `origin/feat/pkg-webp` @ `97d38ff`, `packages/webp/src/{types,riff,decoder,vp8l,vp8l_huffman,vp8,vp8_bool,vp8_pred,vp8_filter,vp8_tables}.pion`, plus `bench/` and `wasm_smoke/`.
- **Deliverable**: `packages/webp/audit/` only (branch `audit/pkg-webp`). Nothing outside `audit/` was changed.
- **Reproduce**: `sh packages/webp/audit/run_audit.sh` (about 30 s warm; sections: `build cases unit vectors diff fuzz dos wasm_dos portability bench`). It exits non-zero while any finding below is present. Fixes must make it pass **without editing `audit/`**.
- **Toolchain used**: pionc 0.1.0 (arm64_apple), node v24.22.2 (wasm32 runtime `pion_wasm_rt.mjs`), go 1.27.3 + `golang.org/x/image` v0.48.0, libwebp 1.6.0 (`cwebp`/`dwebp`), macOS arm64.

## Verdict

| Severity | # | Summary |
|---|---|---|
| **P0** | 1 | Out-of-bounds read → process abort (native and wasm32) when a VP8X+ALPH file carries a VP8 frame larger than the canvas. Reachable by single-bit corruption of valid files. |
| P1 | 0 | — |
| **P2** | 5 | Two decoder differentials vs RFC 9649/libwebp in VP8L/VP8X (shared with x/image/webp); two VP8 arithmetic-width divergences from libwebp *and* Go; Huffman-table memory not bounded by `DecodeLimits` (5.3× libwebp, accepts incomplete codes both references reject). |

Everything else probed holds: 13 control cases pass in all four modes, 583/583 well-formed corpus files are byte-identical to x/image/webp (SHA-256 of RGBA8888) in all four modes, all header/canvas bombs are rejected before allocation in < 1 ms, native and wasm32 agree on all 10 000 mutants, and there were 0 hangs. Portability is clean: 0 `extern "C"`, 0 `World`, 0 module-level mutable bindings, and the 12 module-level lookup tables are never written.

## Findings

### P0-1 VP8X canvas smaller than the VP8 frame with ALPH → out-of-bounds abort

- `decoder.pion:172` decodes the ALPH plane at the **VP8X** size (`vp8x_w * vp8x_h` bytes).
- `decoder.pion:183` calls `vp8_decode_internal(..., alpha_plane, has_alpha_plane)`. That composites the plane in `vp8_yuv420_to_rgba` (`vp8_filter.pion:210, 222, 242`: `alpha[a_idx]`) at the **VP8 frame** size.
- Only after that, `decoder.pion:187-189` compares the two sizes.
- When the frame is wider or taller than the canvas, `alpha[a_idx]` runs off the plane and the whole process aborts with `pion panic: index 1 out of bounds (len 1)` (native) / `index out of bounds: idx=1, len=1` (wasm32). x/image/webp checks the frame header against VP8X *before* decoding (`webp/decode.go`, `fh.Width != widthMinusOne+1`). libwebp rejects the file too.
- **Reach**: 10 of the 552 single-bit flips of a valid 4×4 VP8X+ALPH+VP8 file abort. These are bits 192/193/216/217 (VP8X width/height) and 496–515 (VP8 width/height). Random mutation hits it too (1 in 10 000, `m00667`). Any application that decodes untrusted WebP in-process can be crashed with a ~120-byte file.
- **Evidence**: `redteam_p0_alph_plane_smaller_than_vp8_frame_{raw,vp8l}`, `redteam_p0_alph_plane_shorter_than_vp8_frame`, `redteam_p0_alph_plane_smaller_than_vp8_frame_custom_limits`, `redteam_p0_bitflip_sweep_vp8x_alph_no_abort` (all ABORT in all 4 modes), `vectors/p0_vp8x_1x1_alph_vp8_16x16.webp`, fuzz `pion_crash 1`.
- **Fix**: before decoding, parse the VP8 frame header (`vp8_parse_frame_header`) and reject a size that differs from VP8X. Also keep `vp8_yuv420_to_rgba` safe on its own: require `alpha.length() >= width * height` whenever `has_alpha`.

### P2-1 Simple prefix code with descending symbols decodes differently from RFC 9649 / libwebp

- RFC 9649 §3.7.2.1.1 defines a simple code through `code_lengths[symbol0] = 1; code_lengths[symbol1] = 1`. Canonical assignment then gives code `0` to the **smaller** symbol (libwebp: `VP8LBuildHuffmanTable`).
- `HuffTable::build_simple` (`vp8l_huffman.pion:115-123`, `e0 = sym0`) gives code `0` to the symbol **read first**. This is a faithful copy of x/image/vp8l `buildSimple`, which has the same bug.
- A file that writes `(200, 100)` therefore shows green `200,100` in Pion and Go, but `100,200` in libwebp, Chrome and Android. That is a content-spoofing decoder differential. libwebp's encoder writes ascending order, so real files are unaffected.
- **Evidence**: `redteam_p2_simple_code_descending_symbols_follow_rfc` (got `0,200,0,255 0,100,0,255`, want `0,100,0,255 0,200,0,255`), `vectors/vp8l_simple_code_descending_2x1.webp` (libwebp digest `b683…`). It is also the reason the random-VP8L generator writes ascending order: with random order, 20/200 streams differed from libwebp, and with ascending order 300/300 match libwebp and Go.
- **Fix**: in `build_simple`, map code 0 to `min(sym0, sym1)`. When `sym0 == sym1`, libwebp builds a single-symbol (0-bit) table.

### P2-2 VP8X alpha flag + VP8 without ALPH is rejected

- `decoder.pion:180-182` returns `InvalidAlpha("missing ALPH chunk before VP8")`.
- RFC 9649 §2.7.1.3 makes ALPH optional, and the VP8X `L` flag only says that alpha *may* be present. libwebp decodes such files as opaque. Pion (like x/image/webp) refuses to load them.
- **Evidence**: `redteam_p2_alpha_flag_without_alph_chunk_decodes_opaque`, `vectors/vp8x_alpha_flag_without_alph_16x16.webp` (libwebp: OK, alpha 255).
- **Fix**: treat a missing ALPH as opaque.

### P2-3 VP8 dequantized coefficients are not 16-bit (libwebp, libvpx and Go all store `int16`)

- `vp8.pion:709/745` (`c = v * q` stored as a 32-bit `Int`) and the WHT outputs at `vp8_pred.pion:694-697` keep the full value.
- libwebp, libvpx and x/image/vp8 store coefficients in `int16_t` / `int16` and wrap. Large DCT tokens (cat3–cat6 escapes times quantizers up to 284) therefore reconstruct different pixels.
- **Evidence**:
  - In random keyframes with well-formed boolean coding (`rvp8_*_b3`), 9 of 40 decoded files differ from libwebp while Go == libwebp.
  - Rebuilding x/image/vp8 with `int32` coefficients reproduces Pion byte for byte (40/40). That isolates the root cause.
  - Vector: `vectors/vp8_coeff_int16_wrap_16x16.webp` (expected `90d5…`, Pion `81da…`).
- **Fix**: wrap to 16 bits when storing (`((c << 16) >> 16)`) in `vp8_parse_residuals4` and `vp8_iwht16`, as the reference decoders do.

### P2-4 Boolean decoder overflows its 32-bit signed register on non-normalized data

- `BoolDecoder` keeps the 8-bit decode window at bits 16..23 of a signed 32-bit `Int` (`vp8_bool.pion:45-51`, `71`, and the five inlined copies in `vp8.pion:553-786`).
- On data where the coder's value exceeds its range, the register grows by `<< shift` and wraps past 2³¹ about 8 bits earlier than Go's `uint32` (window at bits 8..15). libwebp uses a 64-bit register and does not overflow. No encoder produces such data, but any byte string is a decodable partition.
- After the wrap, decisions differ. Pixels change, and EOF detection can flip: `m02459` is rejected by Go, accepted by libwebp, and accepted by Pion with different pixels.
- **Evidence**:
  - With base quantizer 0 (every coefficient fits `int16`, so P2-3 is excluded), 4 of 76 random keyframes differ while stock Go, `int32` Go and libwebp all agree.
  - Vector: `vectors/vp8_boolcoder_value_overflow_65x17.webp` (expected `7167…`, Pion `c0fb…`).
  - Together with P2-3 this accounts for all 18 corpus and 93 fuzz `both_ok_DIFFERENT` results. Every one of them carries a `VP8 ` chunk.
- **Fix**: use x/image's 16-bit field layout (still `Int`, never above 2²⁴ for normalized data) and mask the register, or use `UInt64` like libwebp.

### P2-5 Huffman-table memory is not bounded by `DecodeLimits`; incomplete codes accepted

- `DecodeLimits` is documented as the guard against "decompression bombs and OOM", but it only bounds pixel buffers.
- A 208×200 VP8L that references 2600 meta-prefix groups (the decoder's cap) of maximal codes measures:

  | File | Size | Pion RSS | libwebp RSS | x/image/webp RSS |
  |---|---|---|---|---|
  | Complete codes | 862 KB | **224 MiB** native, 264 MiB wasm | 42 MiB | 170 MiB |
  | Incomplete 15-bit codes | 125 KB | **281 MiB** native, 300 MiB wasm | rejects | rejects |

- Contributing causes:
  1. Every group's tables are built (`vp8l_huffman.pion:204`) and then copied a second time into `all_tables` (`vp8l.pion:403-495`), so peak table memory is doubled.
  2. `HuffTable::build` rejects only over-subscribed codes (`vp8l_huffman.pion:156-169`). Incomplete codes, which libwebp ("tree not full") and x/image (node-capacity check) refuse, are accepted. That lets a 7× smaller file reach the same allocation.
  3. A VP8L-compressed ALPH plane is decoded to full RGBA (`riff.pion:158-167`), 4 bytes per alpha sample, before the green channel is extracted: 82 MiB for a 16 M-pixel plane.
- **Evidence**: `dos` section, `vp8l_meta_huffman_2600_groups_{complete,incomplete}.webp` (budget: 128 MiB peak RSS, i.e. 2× the 64 MiB output cap; the incomplete variant must be rejected like both references do).
- **Fix**:
  - Build the tables directly into the flat array, without the per-group copy.
  - Reject incomplete codes (except the single-symbol case), as libwebp does.
  - Optionally charge table memory against `max_output_bytes`.

## Not findings (recorded for the developers)

- **Leniency vs libwebp (Go behaves like Pion)**: the following inputs are accepted, while libwebp rejects them:
  - ALPH reserved bits or pre-processing > 1;
  - VP8 `version > 3` or `show_frame = 0`;
  - VP8X with the animation flag and a plain VP8 chunk;
  - ICCP before VP8X.

  ALPH without the VP8X alpha flag is rejected, while libwebp decodes it. Predictor modes 14/15 follow x/image (no-op) and were not adjudicated against libwebp.
- **Time on truncated VP8**: a 46-byte VP8 4096×4096 with empty partitions decodes all 65 536 macroblocks before reporting EOF (39 ms native, 62 ms wasm). libwebp aborts at the first exhausted row. This is bounded, so it is not raised.
- **Go-only differences (not Pion bugs)**: for 16 truncated-VP8L mutants, Go accepts while Pion and libwebp reject. For 1 VP8L mutant (`m02021`), Pion accepts while both references reject it as an invalid Huffman tree (consistent with the incomplete-code acceptance in P2-5).
- **Send**: `DecodeLimits` and `probe_header` results are `Send`; `decode` results (`Bytes`) are `!Send` (`E_NOT_SEND`), the same as the gif package.
- **Benchmark (`bench/run_bench.sh`)**: the setup is fair. Both sides use the same synthetic 512² inputs, decode 30× per process, convert to RGBA every iteration, and the SHA-256 of the output is verified. Warm medians:

  | Input | Pion vs Go |
  |---|---|
  | VP8L | 1.11× (Pion faster) |
  | VP8 | 1.01× |
  | VP8X+ALPH | 0.93–0.97× (Pion slower) |

  Weaknesses: one input per format, no small-image or photographic inputs, and no `BENCHMARKS.md` entry or `index/webp.toml` yet (AGENTS.md §1.3 / §1.4 are still open for release).

## Coverage

| Section | What runs | Baseline result |
|---|---|---|
| `cases` | 20 cases, one process per case, × `native_dbg native_rel wasm_dbg wasm_rel` | 13/20 pass, identical verdicts in all modes (7 red-team FAIL/ABORT) |
| `unit` | `pionc test` of `audit/` (same 20 cases) + package's own 10 tests | 10/10 own; 13 controls PASS, 7 red-team FAIL |
| `vectors` | 5 files with libwebp-adjudicated digests (`vectors/EXPECTED`), 4 modes | 5 FAIL (P0-1, P2-1..4) |
| `diff` | 622-file deterministic corpus × 4 modes vs x/image/webp; libwebp tie-break | 583 identical, 21 both-reject, 18 VP8 divergences (P2-3/4) |
| `fuzz` | 10 000 mutants (bit/byte flips, truncation, size-field edits, splices) × native_rel + wasm_rel | 1 crash (P0-1), 93 VP8 divergences (P2-3/4), 0 hangs, native == wasm on all 10 000 |
| `dos` | 12 bombs with verdict, time and peak-RSS budgets (native) | 10 ok, 2 FAIL (P2-5) |
| `wasm_dos` | same bombs under wasm32 release | information only |
| `portability` | `extern "C"`, `World`, module-level mutable state, table writes, Send probe | clean |
| `bench` | `bench/run_bench.sh` + warmup/rounds gate | pass |

**Corpus** (`webpdiff gen`, seed 1):

| Group | Files | Content |
|---|---|---|
| cwebp matrix | 178 | 88 lossless (`-z 0/3/6/9`, `-q 0..100 -m 0..6`, `-exact`, `-near_lossless`, `-alpha_cleanup`) and 90 lossy (`-q 1..100`, `-f 0..100`, `-sharpness 0..7`, `-strong/-nostrong`, `-segments 1/4`, `-sns`, `-af`, × `-alpha_method 0/1 -alpha_filter none/fast/best -alpha_q`). Sizes 1×1, 2×2, 3×5, 5×3, 7×1, 1×9, 15×15, 15×17, 16×16, 17×13, 31×33, 33×31, 64×48, 100×75, 129×67. Patterns: 2/3/4/5/16/17/256-colour palettes, gradient, noise, smooth; opaque/binary/gradient/noise alpha. |
| VP8X+ALPH composites | 72 | 4 filters × raw/VP8L (`-z 0/9`), on 1×1, 3×5, 17×13, 15×17, 31×33, 64×3 |
| Odd and unknown chunks | 12 | odd-length metadata and unknown chunks |
| Random VP8 keyframes | 160 | explicit headers (1/2/4/8 partitions, segmentation with absolute or delta values and map, simple/normal filter, levels, sharpness 0–7, LF deltas, quant deltas) with random, EOB-heavy, large-token raw or large-token well-formed boolean-coded partitions |
| Random VP8L streams | 160 | every transform order and subset (palette 1–256, packed widths), colour cache 1–11 bits, meta-prefix codes including the ≥ 1000 remap path with unused groups, canonical codes up to 15 bits (secondary tables), RLE 16/17/18, `max_symbol`, LZ77 across tiles |
| Random VP8L ALPH planes | 40 | headerless VP8L alpha planes over a cwebp VP8 frame |

**Controls that pass** (regression guards):
- RIFF/WEBP magic, size and truncation edges, odd padding, 4096 empty chunks.
- VP8X duplicate, wrong size, canvas mismatches both ways, 2²⁴ and 16384² canvases, animation without a still image, ALPH misuse.
- Raw ALPH with all 4 filters on 1×1, 3×5, 17×13, 15×17, 16×1, 1×16 (exact alpha).
- ALPH compression 2/3, truncated raw and truncated VP8L ALPH.
- Huffman: empty, over-subscribed, `max_symbol` > alphabet, RLE past alphabet, out-of-range simple symbol.
- LZ77: `dist > pos`, `len` past end, distance code 39.
- Colour cache bits 0..15.
- ColorIndexing with 2/3/4/5/16/17 colours × widths 1/3/5/7/9/17 (exact).
- Duplicate transforms, five transforms, `max_transform_depth` −5/0/2/3.
- `DecodeLimits` ±1 on each field, zero, negative and `Int` max.
- VP8 interframe, sync code, first-partition overrun, every truncation.
- Truncation and bit-flip sweeps of VP8L and plain VP8.
- `probe_header`.

## Files

```
audit/
  run_audit.sh              one-shot runner (exit 1 while findings exist)
  pion.toml                 webp_audit (depends on ../ and ../../crypto)
  src/main.pion             CLI: list | case | selftest | digest | rgba | samples | time | gen_dos
  src/cases.pion            red-team + control cases, DoS corpus builders
  src/build.pion            RIFF / VP8X / VP8L bit-writer builders
  redteam_test.pion         7 FINDING tests (fail on baseline)
  control_test.pion         13 CONTROL tests (pass on baseline)
  vectors/*.webp, EXPECTED  libwebp-adjudicated regression vectors
  diff/go/                  webpdiff: x/image/webp oracle, libwebp tie-break, corpus generator, mutator
  diff/compare.py           differential driver (crash/hang isolation, 3-way adjudication)
  diff/vectors.py           vector checker
  diff/dos.py               bomb verdict / time / RSS budgets
```
