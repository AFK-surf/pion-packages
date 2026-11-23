# `packages/gif` red-team audit (RT-gif)

Target: `origin/feat/pkg-gif` @ `2599585` (pure Pion GIF87a/GIF89a decoder, `v0.1.0`): `src/{types,lzw,decoder}.pion`, `bench/`, `wasm_smoke/`.
Reference: Go `image/gif` + `compress/lzw` (go1.27.3) with a browser-semantics compositor (`diff/go/main.go`), plus an independent Pion reference compositor (`src/build.pion::rt_ref_composite`) for cases Go rejects (clipping, out-of-range indices).
Machine: Darwin arm64 (tokyo-mac-studio-0), `pionc 0.1.0`, node v24.22.2.

Reproduce: `sh packages/gif/audit/run_audit.sh` (about 6 min; sections `build selftest unit diff fuzz dos wasm_dos portability bench`, e.g. `run_audit.sh dos` after one `build`). Artifacts go to `$AUDIT_OUT` (default `/private/tmp/pion-gif-audit`); nothing is written inside the repository. **The script exits non-zero while any finding below is open.** A fix is complete when `run_audit.sh` prints `AUDIT PASS` with `audit/` byte-for-byte unchanged.

## Verdict

| Severity | Count | Summary |
| --- | ---: | --- |
| **P0** (memory unsafety / crash / OOM / infinite loop reachable from GIF bytes under default limits) | **0** | 0 panics, 0 aborts, 0 OOM over 439 corpus files, 30,000 mutants and every bomb, in native debug/release and wasm32 debug/release. The only hang needs a caller-chosen `max_output` above 1 GiB (P1-2). |
| **P1** | **2** | **P1-1** a frame whose LZW stream ends early (EOI) is composited from the previous frame's leftover indices (cross-frame data leak, 4 red tests). **P1-2** `lzw_decode` with `max_output > 1 GiB` (e.g. `Int` max as "no limit") overflows the 32-bit capacity doubling and degrades to quadratic copying: a 512 KiB input never finishes (killed after 30 s; > 3 GiB RSS). |
| **P2** | **2** | **P2-1** sub-frame LZW work is not charged to any limit in the RGBA path: 256 × 4096² sub-frames on a 1×1 canvas (2.2 MB file) take 5.4 s, 4096 frames ≈ 80 s. **P2-2** a short *first* frame fabricates opaque `palette[0]` pixels (`decode` / `decode_first_frame`), and `decode_indexed` zero-fills short frames silently. |
| Info | 5 | Out-of-range palette indices → opaque black (Go: error); README "Send-clean" is only true of `DecodeLimits`; eager 64 MiB canvas allocation for a 13-byte header; `lzw_decode` peaks at ~2.5× its output; leniencies vs Go (by design). |

Everything else held: the LZW state machine (KwKwK, Clear+KwKwK, first-code-not-literal, `code > next_code`, Deferred Clear at 4096, `min_code_size` 0/1/9/12/255, 2..8), sub-block framing, every limit boundary (`max_frames` ±1, `max_total_bytes` ±1 byte, negative, zero and `Int`-max limits, 65535² canvas and 65535² sub-frame with no 32-bit wrap), all disposal methods (frame-0 RestoreToPrevious, consecutive RestoreToPrevious, RestoreToBackground clipped at right/bottom, 4..7 = Unspecified), interlace 1×1 … 8×17 and clipped, GCE scoping (Plain Text reset, last GCE wins, no inheritance), and **byte-exact RGBA SHA-256 agreement with Go `image/gif` on all 439 corpus files and on all 3,024 mutants both accept**. The bench is fair and passes its gates.

---

## P1-1 Early EOI composites the previous frame's pixel indices (cross-frame leak)

* **Where.** `decoder.pion:595` allocates `idx_buf` once per decode; `:674-676` only reallocates it when a frame is *larger*, and never clears it. `lzw.pion:282-283` treats EOI as a normal end and returns `Ok((out_pos, …))` with `out_pos < expected_pixels` (`lzw.pion:295`). `decoder.pion:677` discards that count (`let (_, next_p) = …`) and `composite_frame` (`:699`, `:739`, `:771`) reads all `fw * fh` entries of `idx_buf`, so every pixel past the EOI is drawn with **the previous frame's index** at that position, through the **current** frame's palette.
* **Inconsistent with the decoder itself.** Running out of *bits* before the frame is full is an error (`lzw.pion:145-148`, `UnexpectedEof`); running into EOI is silently accepted.
* **Trigger.** ③ untrusted input only: any multi-frame GIF where a later frame's LZW stream emits EOI early. Default limits, every API that composites (`decode`, `decode_with_limits`). Mutation fuzz hit this class 278 times in 30,000 mutants (`gif: not enough image data` in Go, `OK` in Pion).
* **Impact.** Pixel data from frame *N−1* reappears in frame *N* at positions that frame *N* never encoded, rendered with frame *N*'s LCT (`redteam_p1_early_eoi_leak_across_lct`: a "secret" frame of index 3 re-emerges as `200,100,50` from the public frame's palette). Applications that composite per-region content from different sources into one GIF, or that crop/redact a frame, can leak the previous frame's content. The output also depends on the *previous* frame's size (buffer is only reallocated when growing), so equal frames decode differently depending on history.
* **Red tests** (`redteam_test.pion`, all FAIL now; native and wasm `selftest` print the same):

  | Test | Path | Evidence |
  | --- | --- | --- |
  | `redteam_p1_early_eoi_leaks_previous_frame_pixels` | normal compositor | frame 1 pixel (1,1) = `255,0,0,255` (frame 0's red) though the stream was `Clear, 2, EOI` |
  | `redteam_p1_early_eoi_leak_restore_previous_path` | RestoreToPrevious branch (`decoder.pion:734-767`) | same pixel, same leak |
  | `redteam_p1_early_eoi_leak_interlaced` | interlaced compositor, after RestoreToBackground cleared the canvas | (1,0) = `255,0,0,255` |
  | `redteam_p1_early_eoi_leak_across_lct` | LCT on both frames | (1,0) = `200,100,50,255` = old index 3 in the new LCT |

* **Accepted fixes** (the tests accept either): return an error like Go (`errNotEnough`), or leave the undecoded pixels untouched like Chromium/Firefox, which draw only the rows that were decoded. Use the returned `written` count; do not rely on clearing `idx_buf` (that turns the leak into P2-2's palette-0 pixels). Keep `decode_indexed` consistent with the choice (see P2-2).
* **Side effects of the fix.** An error choice rejects truncated real-world GIFs that browsers show partially; the untouched choice needs `composite_frame` to stop at `written` (interlaced rows map through the pass table).

## P1-2 `lzw_decode` capacity doubling overflows 32-bit `Int` above 1 GiB → quadratic copying (hang)

* **Where.** `lzw.pion:326-334` sizes the first buffer at `in_len * 2`; `lzw.pion:400` doubles it with `let mut new_cap = out_cap * 2`. `Int` is 32-bit on every target (`1 << 40 == 256`, `2147483647 + 1 == -2147483648`), so once `out_cap >= 2^30` the product wraps negative, `:401-402` replaces it with `out_pos + k`, and from then on **every code reallocates and copies the whole ≥ 1 GiB buffer** (`:407-411`, `slice` + `concat`).
* **Trigger.** ② the caller passes `max_output > 2^30` (natural for "no limit": `2147483647`), and ③ an input whose output passes the doubling point. `dos/lzw_bomb_1088MiB.lzw` is a valid 512 KiB LZW stream (zero-padded after EOI so the first capacity is exactly 1 MiB → 2^30 after 10 doublings) that expands to 1,140,850,688 bytes.
* **Evidence** (`run_audit.sh dos`, native release):

  | Probe | Verdict | Time | Max RSS |
  | --- | --- | ---: | ---: |
  | `lzw_bomb_1000MiB.lzw`, `max_output = 2147483647` (control, stays below 2^30) | `OK 1048576000` | 1.9 s | 2,568 MiB |
  | `lzw_bomb_1088MiB.lzw`, `max_output = 2147483647` | **TIMEOUT**, killed after 30 s (budget 20 s) | ∞ (≈16,000 copies of ≥ 1 GiB remain) | > 3 GiB |

* **Fix.** Do the capacity arithmetic in `Int64` (or cap at `max_output` before doubling) and grow with one copy (`concat` of the live prefix only). Better: decode into a buffer sized `min(max_output, ...)` growing geometrically without the `slice().concat()` double copy, which is also what drives Info-4's 2.5× peak.

## P2-1 Sub-frame LZW work is not charged to any limit (CPU amplification)

* **Where.** `decoder.pion:629-632` charges only `canvas_bytes` per frame to `max_total_bytes`; `:643-649` checks the sub-frame only against `max_width/max_height/max_pixels`, not against the canvas; `:674-687` then decodes the *whole* sub-frame. On a 1×1 canvas each frame may still be 4096×4096 = 16 M indices. (`decode_indexed` charges `frame_pixels`, `:916`, so it is bounded.)
* **Trigger.** ③ untrusted input, default limits. `subframe_bomb_1x1_256f_4096sq.gif`: 2.2 MB, 256 frames, each an LZW bomb filling a 4096² sub-frame at (0,0) of a 1×1 canvas. Go rejects the first frame in microseconds (`gif: frame bounds larger than image bounds`).
* **Evidence.** `OK 256` in **5.4 s** native release (budget 1.5 s; 7.7 s on wasm32), 20 MiB RSS: 4 GiB of LZW output decoded to produce 1 KiB of RGBA. With `max_frames = 4096` the same construction is a 35 MB file that runs ≈ 80 s. Per-input-byte cost is ~1,800× that of a normal GIF.
* **Fix options.** Reject frames that do not fit the canvas (Go/spec), or charge `max(frame_pixels, canvas_pixels)` per frame to the budget, or stop decoding once the last visible row is done and skip the remaining sub-blocks.

## P2-2 Short first frame fabricates `palette[0]`; `decode_indexed` zero-fills silently

* **Where.** Same root cause as P1-1 on the first frame: `idx_buf` is fresh (`decoder.pion:675`), so undecoded pixels are index 0 and are composited as opaque `palette[0]`. `decode_indexed` (`decoder.pion:945-957`) returns zero indices for the undecoded tail with no signal.
* **Red test.** `redteam_p2_short_first_frame_fabricates_palette0`: a 4×1 frame with stream `Clear, 1, EOI` yields pixel (1,0) = `255,0,0,255` (`palette[0]`) in both `decode` and `decode_first_frame`. Go returns `gif: not enough image data`; browsers leave the pixels transparent.
* **Fix.** Falls out of P1-1's fix. For `decode_indexed`, either return the same error or expose the decoded pixel count, so callers can tell real index 0 from missing data.

---

## Info (not counted as defects; no red line)

1. **Out-of-range palette indices render opaque black** (`decoder.pion:122-149`, `fill_palette_1024`). GIF89a leaves this undefined; Go returns `errBadPixel`, except that it pads the palette with *transparent* entries up to an out-of-range transparent index. This was the only source of digest mismatches in fuzzing (all 9 mismatches of a first 30,000-mutant run were this class), so `diff/go` marks such inputs `SKIP oob-palette-index`. `control_palette_edges` pins Pion's choice (index 7 in a 4-colour LCT, index 255, out-of-range transparent index 200).
2. **"Send-clean" in `README.md`** holds for the brief's meaning (0 module-level mutable state, 0 `World`, 0 `extern "C"`; checked by `run_audit.sh portability`), but the result types are `!Send`: `GifImage`/`GifFrame`/`GifHeader`/`GifIndexed*` hold `Bytes`. The `spawn` probe reports `E_NOT_SEND` for `decode(...)` and `probe_header(...)` values; only `DecodeLimits` is `Send`. Suggest rewording the README.
3. **Eager canvas allocation.** `decoder.pion:586` allocates `w*h*4` before any frame is read. A 13-byte header with a 4096×4096 screen allocates and zero-fills 64 MiB and returns `OK 0` (within limits). Allocating lazily on the first image descriptor costs nothing.
4. **`lzw_decode` peak memory ≈ 2.5× output** (1000 MiB output → 2,568 MiB RSS), from `slice(0, out_pos).concat(pad)` copying twice per growth.
5. **Leniencies vs Go, by design (browser-like)**, counted in fuzzing as "Go ERR, Pion OK": missing trailer (608), too much image data (455), out-of-bounds frames clipped (287), not enough image data (278: P1-1/P2-2), `0x00` between blocks (52), out-of-range pixel (32), a GCE whose terminator is non-zero (27), no frames (26), unknown extension labels skipped (11) (for a non-zero GCE terminator (the GCE fields are used and the rest is skipped as sub-blocks). The reverse never happens outside the default limits: Pion never rejects an input Go accepts (296 mutants with an enlarged screen hit `LimitExceeded`; all of them are over `DecodeLimits::default()`).

---

## Coverage

| Area | What ran | Result |
| --- | --- | --- |
| Red-team / control cases (`src/cases.pion`) | 5 `redteam_*` + 15 `control_*` (each control is a matrix: 7 malformed LZW streams, 5 bad + 7 good `min_code_size`, 4 sub-block framings, 9 limit boundaries + 4096/4097 frames, 5 canvas/sub-frame bombs, 4 disposal scenarios, 10 interlace sizes, 16 container edge cases, 6 loop extensions, 120 random structured GIFs) | via `pionc test` and `gif_audit selftest` in native_dbg, native_rel, wasm_dbg, wasm_rel: identical output, 15/20 pass, the 5 red tests fail |
| Reference compositor sensitivity | breaking the reference (no RestoreToPrevious / no transparency / wrong interlace order) | controls fail as expected, so the controls are not vacuous |
| Differential corpus (`diff/go gen`, seed 1) | 439 GIFs: 8 disposal values, frame-0 / consecutive RestoreToPrevious, transparency in and out of the palette, interlace 1×1…33×2, `min_code_size` 2..8, 256×256 noise and 300×300 runs under 6 LZW modes (Clear-at-full, Deferred Clear, literal-only, no leading Clear, no EOI, frequent Clears), random sub-block sizes, LCT-only, `image/gif`'s own encoder, 400 random animations (up to 400×400, 8 frames, random LCT/GCT/transparency/interlace/disposal/delay/loop) | **439/439 byte-identical SHA-256** (frames + loop + delay + disposal + RGBA) in all four modes |
| Mutation fuzz (`diff/go mutate`, seed 7) | 30,000 mutants (bit flips, magic bytes, truncation, insertion, deletion, duplication, header edits) | 0 crashes, 0 hangs; 3,024 both-OK all identical; 24,147 both-ERR; 1,776 lenient (Info-5); 757 skipped for `image/gif` quirks (image without its own GCE, Plain Text before an image, NETSCAPE sub-block ≠ 3, out-of-range index); 296 limit policy. Identical counts under wasm_rel |
| DoS (`diff/dos.py`) | 65535² canvas, 4096-frame 4 MiB-canvas bomb, 4096² canvas LZW bomb, sub-frame bombs, 1000/1088 MiB standalone LZW bombs | see P1-2 / P2-1; everything else is `LimitExceeded` or done in ≤ 54 ms |
| Portability | `extern "C"`, `World`, module-level mutable bindings in `src/` | 0 / 0 / 0 |
| Bench (`bench/run_bench.sh`) | see below | fair, gates pass |

### `image/gif` behaviour the oracle has to work around
* `image/gif` does not reset `disposalMethod` after an image (`reader.go:482-486` resets only delay and transparency), so a frame without its own GCE inherits the previous disposal. Every generated frame carries a GCE; mutants with a GCE-less image are skipped.
* `image/gif` applies a pending GCE across a Plain Text extension (the spec resets it, and so does Pion: `control_gce_scoping`).
* No-EOI streams are only accepted by `image/gif` when the final padding is narrower than one code; the generator emits EOI otherwise.

## Bench fairness (`packages/gif/bench`)

Both sides do the same work: `decode_first` = Go `gif.Decode` (first frame only) + palette→RGBA8888 vs Pion `decode_first_frame`; `decode_all` = Go `gif.DecodeAll` + `compositeGoGif` (same clip / transparency / disposal semantics, one snapshot per frame) vs Pion `decode`. Both write every frame's RGBA to stdout, and `bench_compare.py` checks SHA-256 equality on every round. No skipped work and no cached results across iterations. Both sides make one full-canvas copy per frame; Go additionally saves the frame rectangle for RestoreToPrevious, which Pion avoids by compositing onto the snapshot (a legitimate design choice, not a shortcut).

| Bench | Pion median (min / p95) | Go median | Speedup | Gate (≥ 40 ms, ≥ 1.0×) |
| --- | --- | --- | ---: | --- |
| Static 512×512 ×60 | 76.2 ms (75.1 / 93.7) | 84.3 ms | 1.11× | pass |
| Animated 256×256×24f ×30 | 57.5 ms (56.6 / 58.0) | 67.5 ms | 1.17× | pass |

Caveat: both bench inputs come from Go's encoder (Clear-at-full LZW, no interlace, no LCT), so the bench does not exercise the interlaced or Deferred-Clear paths. Correctness for those is covered by the differential corpus, not by the bench.

## Files

| File | Purpose |
| --- | --- |
| `run_audit.sh` | one-shot runner, non-zero exit while a finding is open |
| `pion.toml`, `src/build.pion` | GIF/LZW stream builders (explicit code sequences at decoder-exact widths, LZW bombs) and the reference compositor |
| `src/cases.pion` | every red-team and control case (shared by tests and `selftest`) |
| `src/main.pion` | `gif_audit` CLI: `selftest`, `digest`, `dump`, `time`, `lzwtime`, `gen_dos` |
| `redteam_test.pion`, `control_test.pion` | `pionc test` entry points |
| `diff/go/` | Go oracle: corpus generator with its own LZW encoder, mutator, `image/gif` digest |
| `diff/compare.py`, `diff/dos.py` | differential classifier, DoS budgets |
