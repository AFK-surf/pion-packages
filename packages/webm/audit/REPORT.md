# Red-team audit: `packages/webm` v0.1.0

* Target: `origin/feat/pkg-webm` @ `2b37d0b0b521b272e619a5564b24add75fa39ef1` (`src/types.pion`, `src/ebml.pion`, `src/webm.pion`, read in full).
* Toolchain: `pionc 0.1.0 (arm64_apple, self-hosted)`, Native `--release` and Wasm32 `--release` (node + `~/.pion/share/pion/pion_wasm_rt.mjs`).
* Oracles: Rust `matroska-demuxer =0.6.1` and `symphonia-format-mkv =0.5.5` (both `--release`, `diff/rust`), `ffprobe` 9.0.2 (`/opt/homebrew/bin`), and libwebm `mkvparser/mkvparser.cc` @ `1f795141` for the lacing rules quoted below.
* Reproduce everything: `sh packages/webm/audit/run_audit.sh all` (about 12 min on the Tokyo Mac Studio under load). Sections: `build unit diff vectors bombs fuzz perf`. All artifacts go to `/private/tmp/pion-webm-audit`; the repository stays clean (`git status --ignored` is empty apart from this directory).
* Every number below comes from that script. Wall-clock times are from a shared, loaded machine (load average 12–20 on 18 cores), so treat them as ratios, not absolutes.

## Summary

| ID | Severity | Finding | Test |
| --- | --- | --- | --- |
| P0-1 | **P0** | Non-finite or huge `Duration` → `Double::to_int64` **traps on Wasm32** (process abort); Native saturates `duration_ms` to `i64::MAX` | `redteam_p0_duration_infinite_must_not_saturate_or_trap` |
| P1-1 | **P1** | `find_keyframe_at` binary-searches frames in file order, which are not sorted by pts → returns the previous GOP on ordinary ffmpeg files | `redteam_p1_find_keyframe_at_unsorted_interleave` |
| P1-2 | **P1** | Zero-byte frames accepted in all 3 lacing modes: a 28.8 KB file builds 1,048,576 `Frame`s and 106.7 MiB RSS (≈3,880×) | `redteam_p1_zero_byte_laced_frames_rejected` |
| P2-1 | P2 | EBML lacing with lace count 1 reads a size VINT and silently drops the rest of the block | `redteam_p2_ebml_lacing_single_frame_drops_bytes` |
| P2-2 | P2 | Every frame of a lace gets the Block timestamp (ffmpeg adds `k × DefaultDuration`) | `redteam_p2_laced_frames_share_block_timestamp` |
| P2-3 | P2 | `Int64` timestamp products wrap silently; a `u64` Cluster Timestamp ≥ 2^63 turns negative | `redteam_p2_timestamp_overflow_wraps_silently` |
| P2-4 | P2 | `EBMLReadVersion` / `DocTypeReadVersion` never checked | `redteam_p2_unsupported_read_versions_accepted` |
| P2-5 | P2 | Frames indexed for undeclared track numbers; `TrackNumber 0` accepted | `redteam_p2_frames_for_undeclared_or_zero_tracks` |
| P2-6 | P2 | Cues (and Clusters) before Info / Tracks use the default scale / no DefaultDuration | `redteam_p2_cues_before_info_use_default_scale` |
| P2-7 | P2 | `CueTrackPositions` are not bounded by `max_cues`; empty CuePoints/Clusters amplify 10–40× | `redteam_p2_cue_track_positions_not_limited` |
| P2-8 | P2 | A truncated file (partial download) returns no frames at all | `redteam_p2_truncated_file_returns_no_frames` |
| P2-9 | P2 (perf) | `find_keyframe_at` backward scan is O(n) per query: 0.12–0.3 ms/query at 200k frames | `run_audit.sh perf` (perf 4) |
| P2-10 | P2 (perf) | Pure Opus 0.68×: per-element `Result`-returning VINT helpers (~8 ns/call) dominate; a fast path saves ~45 % | `run_audit.sh perf` (perf 2/3) |
| P2-11 | P2 (nits) | MSE `end_pts_ms` is max pts, not pts + duration; `max_depth` means different things in `parse_webm` and `parse_media_segment`; `BlockDuration 0` falls back to `DefaultDuration`; `TrackType` truncated with `to_int()`; negative `pts_ms` rounds toward zero | — |

What was checked and found clean:

* **Fuzz, 12,000 cases × 3 APIs** (`parse_webm`, `parse_init_segment`, `parse_media_segment`), Native `--release` vs Wasm32 `--release`: **0 native panics or SIGSEGV, 0 hangs, 0 Native≠Wasm32 result lines, 0 frames whose `[offset, offset+size)` lies outside the input.** The only defect class is the P0-1 Wasm32 trap (391 cases, every one attributed to a non-finite or huge `Duration`). By contrast, `matroska-demuxer` panicked on 216 cases and aborted on a multi-PB allocation on 68.
* **Real ffmpeg corpus, 18 files / 16,911 frames** (VP8/VP9/AV1/H.264 B-frames + Opus/Vorbis/AAC/FLAC/PCM, multi-Cluster with Cues, live/unknown-size Segment, Xiph/fixed/EBML lacing, BlockGroup + BlockDuration + ReferenceBlock + DiscardPadding, unknown-size Segment + Clusters) plus 2 MSE init+media pairs (sized and YouTube-style unknown-size Clusters):
  * vs `matroska-demuxer`: 100 % identical track tables (number, type, CodecID, CodecPrivate FNV, DefaultDuration) and 100 % identical frames (track, size, `pts_ns`, `pts_ms`, keyframe where it reports one, payload FNV-64, which proves every `offset`).
  * vs `ffprobe`: packet count, track, size and keyframe flag identical for every packet of every file. `pts_ms` differs only by the constant CodecDelay shift ffmpeg applies (Opus 7 ms, AAC 21 ms), except inside laces (P2-2).
  * vs `symphonia-format-mkv` (audio-only files): identical packet sizes and payload hashes.
  * `probe_codec_string` gives `vp8`/`vp9`/`av01`/`avc1`/`opus`/`vorbis`/`mp4a.40.2`/`flac`/raw CodecID as documented.
  * Native and Wasm32 dumps are byte-identical on every file.
* VINT edges: `0x00` lead byte, 5-byte IDs, all-ones IDs, 8-byte `0x01FFFFFFFFFFFFFF` unknown-size, `2^56-2`, truncated 8-byte, minimum 8-byte signed VINT, child larger than its parent, unknown-size Cluster inside an unknown-size Segment ended by Tags / a chained EBML header. All are rejected or terminate correctly; no loop can fail to advance (every iteration consumes ≥ 2 bytes or returns). See `control_vint_edges` and `control_unknown_size_nesting_terminates`.
* Malformed lacing: Xiph `0xFF` runs past the payload, fixed-size payload not divisible by the count, EBML deltas going negative, EBML sizes exceeding the payload. All are rejected. Xiph/EBML size sums cannot overflow `Int` (each partial sum is bounded by the block length before it grows).
* `DecodeLimits`: **all 9 fields** checked at exact / exact−1 / 0 / −1 on one sample (2 tracks, 2 Clusters, 6 frames, 2 CuePoints, 3-frame lace, 5-byte CodecPrivate, 10-byte string, 56 visited elements, depth 4; counted independently by `diff/gen_redteam_test.py`). Results: exact → `Ok`; exact−1 and 0 → `LimitExceeded`; −1 → `InvalidLimits`. See `control_limits_exact_minus_one_zero_negative_all_9_fields`.
* `TimestampScale == 0` (and ≥ 2^63, read as negative) is rejected. A `Duration` of NaN, −Inf or a negative value gives `duration_ms = 0`. A `Duration` length other than 0/4/8 is rejected (`matroska-demuxer` does the same; ffmpeg skips the element).
* `rel_ts = -32768` at Cluster Timestamp 0 gives `pts_ms = -32768` without overflow. `matroska-demuxer` errors on this input and ffprobe clamps it. Pion's behaviour is consistent and documented here; it is not filed as a defect.
* `Int64 → Int` truncation: every `offset`/`size` is bounded by `data.length()` before `.to_int()` (`resolve_definite_end` compares in `Int64`), so a size ≥ 2^31 is rejected and never becomes a negative index (vector `vint_size_8byte_max`).

---

## P0

### P0-1 Non-finite / huge `Duration` traps Wasm32 (`float unrepresentable in integer range`), saturates on Native
* Where: `src/webm.pion:369-373`
  ```pion
  let duration_ms : Int64 = if has_duration && duration > 0.0 {
    (duration * timestamp_scale.to_double() / 1000000.0).to_int64()
  ```
  `+Inf` and NaN-free huge values pass the `> 0.0` guard. On Wasm32 `Double::to_int64` lowers to a trapping `i64.trunc_f64_s`, so the whole module aborts: no `Result`, and the host cannot recover. Native saturates and reports `duration_ms = 9223372036854775807`. The same function runs inside `parse_init_segment`, so a 4-byte float32 `+Inf` in an MSE init segment kills a Wasm32 player.
* Minimal inputs (≈ 120 bytes each, `diff/vectors.py`): `dur_pos_inf` (f64 `+Inf`), `dur_f32_inf` (`44 89 84 7f 80 00 00`), `dur_1e19` (finite f64 `1e19`, scale 1e6).
  ```sh
  sh packages/webm/audit/run_audit.sh build
  B=/private/tmp/pion-webm-audit/bin; V=/private/tmp/pion-webm-audit/vectors
  $B/pion_audit dump $V/dur_f32_inf.webm | head -1
  #   OK doc=webm scale=1000000 tracks=1 clusters=1 cues=0 frames=1 dur_ms=9223372036854775807
  node ~/.pion/share/pion/pion_wasm_rt.mjs $B/pion_audit.wasm dump $V/dur_f32_inf.webm
  #   RuntimeError: float unrepresentable in integer range   (exit 1)
  ```
* Reference behaviour on the same inputs: `matroska-demuxer` accepts `+Inf` and `1e19` and rejects `-Inf` (`PositiveValueIsNotPositive`). `ffprobe` demuxes every packet and ignores the bad duration.
* Fuzz: 391 of 12,000 cases trap on Wasm32. The fuzzer re-reads the `Duration` of every trapping case and all 391 are non-finite or > 1e12, so there is no other trap site.
* Fix: compute in `Double`, then reject or clamp before converting. For example: `if !(d >= 0.0 && d < 9.2e18) { 0L } else { d.to_int64() }`, with the NaN-safe comparison order. Also flag this in the Pion toolchain: Native saturates while Wasm32 traps on the same `to_int64`, so every package that converts untrusted doubles has the same cross-target split. A saturating `Double::to_int64` (`i64.trunc_sat_f64_s`) on Wasm32 would make the targets agree.

## P1

### P1-1 `find_keyframe_at` assumes frames are sorted by `pts_ms`; they are in file order
* Where: `src/webm.pion:1661-1693`. An upper-bound binary search over `frames[mid].pts_ms` is followed by a backward scan from `lo - 1`. `frames` is in muxing order. With interleaved tracks (an audio packet at 1001 ms muxed before the video keyframe at 1000 ms, which ffmpeg does routinely) or B-frames (`pts` non-monotonic), the search lands before the keyframe the caller asked for. The function then returns an **earlier GOP**, or `None` when an earlier keyframe does not exist.
* Evidence: brute-force oracle over every frame pts ±1 ms (`diff/compare.py`, `pion_audit kf`):

  | file | queries | wrong answers | first wrong answer |
  | --- | ---: | ---: | --- |
  | `vp9_opus_cues.webm` (plain ffmpeg VP9 + Opus) | 3,846 | 8 | video @ 1000 ms → frame pts 0 (want pts 1000) |
  | `av1_opus.webm` | 1,446 | 4 | video @ 800 ms → pts 0 (want 800) |
  | `h264_bframes_aac.mkv` | 1,854 | 211 | audio @ 199 ms → pts 149 (want 192) |
  | `unknown_seg_cluster.webm`, `blockgroup_*` | — | 8 / 211 | same pattern |

  An exact seek to a keyframe's own timestamp misses that keyframe and returns the one a GOP (1 s here) earlier.
* Minimal input: 4 frames `V0(key) A0 A1001 V1000(key)` → `find_keyframe_at(frames, 1, 1000)` returns `0` instead of `3` (`redteam_p1_find_keyframe_at_unsorted_interleave`).
* Fix: build a per-track keyframe index sorted by `pts_ms` (stable by file order) once after parsing, and binary-search that. Or scan linearly, which is correct but see P2-9. Do not binary-search the mixed `frames` array.

### P1-2 Zero-byte frames accepted in every lacing mode → ≈3,880× memory amplification within default limits
* Where: `src/webm.pion:1003-1018` (fixed: `each = rem / num_frames` may be 0), `970-1002` (Xiph: size bytes `00` allowed), `1019-1070` (EBML: `first_v.size == 0` and `cur_sz == 0` allowed, line 1048 tests only `< 0`), and the unlaced path `939-953` (`size: block_end - pos` may be 0).
* A 7-byte SimpleBlock `a3 85 81 00 00 84 ff` (fixed lacing, count 256, empty payload) appends 256 `Frame` records. 4,096 of them, a 28,812-byte file, reach the default `max_frames = 1,048,576` (`types.pion:11`):

  | input (`run_audit.sh bombs`) | size | frames / items | Native peak RSS | time |
  | --- | ---: | ---: | ---: | ---: |
  | `opus_audio_60s.webm` (baseline) | 673,243 B | 3,001 | 3.6 MiB | <1 ms |
  | `bomb_fixed_lace_1m_frames` | **28,812 B** | 1,048,576 frames | **106.7 MiB** | 17 ms |
  | `bomb_xiph_lace_1m_frames` | 1,077,388 B | 1,048,576 frames | 107.8 MiB | 19 ms |

  Every `parse_webm` call on that file costs ≈ 100 MiB, so N concurrent requests cost N × 100 MiB from 29 KB each. Wasm32 completes the same inputs (36–38 ms) inside its linear memory. This is the WebM analogue of the `mp4` zero-byte `trun` amplification.
* Reference: libwebm `Block::Parse` returns `E_FILE_FORMAT_INVALID` for `frame_size <= 0` in all four paths (`mkvparser.cc` @ `1f795141`, lines 7878, 7945/7972, 8005, 8039/8108/8152). `matroska-demuxer` accepts the frames. `ffprobe` drops them (no packets).
* Fix: reject a frame size of 0 in all four lacing paths and in the unlaced path, as libwebm does (`InvalidBlock`). Also consider an input-relative frame budget (for example `max_frames ≤ data.length() / 2`), so the default limit cannot be reached from a few KB.

## P2

### P2-1 EBML lacing with lace count 1 drops the tail of the block
* Where: `src/webm.pion:1020-1070`. When `num_frames == 1`, the code still reads a "first frame size" VINT. It pushes that size plus `rem - sum` and uses only `sizes[0]`. Nothing checks that the frames cover the block exactly.
* `ebml_lace_one_frame`: payload `82 aa bb cc` gives one frame of 2 bytes (`aa bb`). `cc` is silently lost. The other implementations disagree with each other: libwebm rejects (`pos != stop`, line ~8160), `matroska-demuxer` returns 2 frames, ffprobe 1 byte.
* Fix: after splitting any lace, require `frame_off == block_end` (as libwebm does), so this input becomes `InvalidBlock`. Alternatively, treat lace count 1 as one frame covering the whole remainder.

### P2-2 All frames of a lace share the Block timestamp
* Where: `src/webm.pion:931-932` computes `pts_ns` once, and `1079-1088` stamps it on every lace.
* Evidence (`run_audit.sh diff`): on `lace_xiph_opus`, `lace_ebml_opus` and `unknown_lace_ebml_opus`, 2,615 of 3,001 packets have a `pts_ms` that differs from ffprobe beyond the constant CodecDelay shift. The fixed-lace PCM file has 125 such packets and `lace_ebml_vp9_opus` 159. ffmpeg stamps lace *k* at `Block + k × DefaultDuration` (or `BlockDuration / laces`). `matroska-demuxer` behaves like Pion. Effects: duplicate pts in MSE/seeking, `find_keyframe_at` ambiguities, and an `end_pts_ms` that is too small.
* Fix: when the track has a `DefaultDuration` (or the BlockGroup has a `BlockDuration`), give lace *k* `pts_ns + k × duration`.

### P2-3 Timestamp arithmetic wraps silently
* Where: `src/webm.pion:931` `(cluster_ts + rel_ts) * timestamp_scale`, `1267` `cluster_ts * timestamp_scale`, `825` `cue_time * timestamp_scale`, `1144` `dur_ticks * timestamp_scale`. Also `ebml.pion:197-217` `read_be_uint`, which returns 8-byte values ≥ 2^63 as negative `Int64` (Cluster Timestamp, CueTime, BlockDuration).
* Results: `cluster_ts_2p55` gives `pts_ms = 2305843009213` (ffprobe: 36028797018963968). `cluster_ts_u64max` gives `pts_ms = -1`. `scale_2p62` (TimestampScale 2^62, Cluster 4) gives `pts 0` because 4 × 2^62 wraps; ffprobe rejects the file. Native and Wasm32 wrap identically.
* Fix: checked multiply/add (or 128-bit intermediate). On overflow, or on an unsigned element ≥ 2^63, return `InvalidElementData`. Cap `TimestampScale` to a sane range.

### P2-4 `EBMLReadVersion` / `DocTypeReadVersion` are never enforced
* Where: `src/webm.pion:202-298` stores them and checks only DocType. `DocTypeReadVersion = 99` and `EBMLReadVersion = 2` are accepted. `matroska-demuxer` reports `unsupported DocTypeReadVersion: 99`, and ffprobe refuses both ("Not yet implemented"). RFC 8794 §11.2.3 and RFC 9559 say a reader must not read a document whose read version it does not support.
* Fix: reject `EBMLReadVersion > 1` and `DocTypeReadVersion > 4` (`InvalidHeader`). Consider also enforcing `EBMLMaxIDLength ≤ 4` and `EBMLMaxSizeLength ≤ 8`.

### P2-5 Blocks for undeclared tracks are indexed; `TrackNumber 0` accepted
* Where: `src/webm.pion:902-909` accepts any track VINT `> 0`. `track_default_duration` (`877-887`) silently returns 0 for an unknown track. `parse_track_entry_body` (`577-581`) accepts 0. ffmpeg drops blocks for unknown tracks ("Invalid track number 5"). `matroska-demuxer` rejects `TrackNumber 0` (`NonZeroValueIsZero`). For MSE, frames of a track absent from the init segment must be a parse error.
* Fix: build a track-number set once, drop (or `InvalidBlock`) blocks whose track is not in it, and reject `TrackNumber 0` and duplicate track numbers.

### P2-6 Element order dependence: Cues before Info, Clusters before Tracks
* Where: `src/webm.pion:1392-1410` passes `info.timestamp_scale` as known at that moment. Clusters likewise get the `tracks` parsed so far (`1428`). `cues_before_info` (CueTime 5000, scale 1000 in a later Info) gives `time_ms = 5000`; it should be 5. Level-1 element order is not mandated (RFC 9559 only recommends Info/Tracks first), and SeekHead-driven writers do reorder.
* Fix: two passes. First locate Info and Tracks among the Segment children, then parse Cues and Clusters. Or post-scale `CuePoint.time_ms` and frame durations at the end.

### P2-7 Cue and cluster amplification not covered by item limits
* Where: `src/webm.pion:815-821` pushes `CueTrackPosition` without any limit (only `max_elements` applies). An empty CuePoint (`bb 80`, 2 bytes) becomes a `CuePoint` plus an empty `Array`. An empty Cluster (`1f 43 b6 75 80`) becomes a `ClusterInfo`.

  | input | size | Native peak RSS |
  | --- | ---: | ---: |
  | 1,048,576 empty CuePoints | 2.1 MB | 84.7 MiB (≈ 40×) |
  | 1 CuePoint × 4,194,000 empty CueTrackPositions | 8.4 MB | 101.6 MiB, even with `max_cues = 1` |
  | 1,048,575 empty Clusters | 5.2 MB | 95.6 MiB |

* Fix: count positions against `max_cues` (or a new `max_cue_positions`), and reject a CuePoint without CueTime / CueTrackPositions (both are mandatory in RFC 9559).

### P2-8 A truncated file yields an error and zero frames
* Where: `resolve_definite_end` (`src/webm.pion:143-160`) on the Segment (`1342-1349`) and on each Cluster child (`1220`). A file cut at 10 %, 50 %, 90 % or 99 % (`vp9_opus_cues.webm`) gives `ERR TruncatedData`. ffprobe returns 67 / 321 / 577 / 633 of 641 packets; `matroska-demuxer` also returns nothing. A demuxer for progressive downloads and MSE `appendBuffer` chunks needs partial results.
* Fix: either return the clusters and frames parsed so far together with a `truncated` flag, or offer an incremental API that reports how many bytes it consumed.

### P2-9 `find_keyframe_at` is O(n) per query
* Where: the backward scan at `src/webm.pion:1682-1691` walks over every non-keyframe and every other-track frame. On a 200,000-frame single-track file with one keyframe, 2,000 queries take **245–602 ms (0.12–0.30 ms each, across runs on the loaded host)**. Building a seek table over every frame would be quadratic (25–60 s). The same 2,000 queries on the 641-frame real file take < 1 ms. The P1-1 per-track keyframe index fixes this too: O(log k) per query.

### P2-10 Why Pure Opus 60 s is 0.68× Rust
`run_audit.sh perf`, parse only, without the process start and output that `bench_compare.py` includes:

| file | Pion `parse_webm` | `matroska-demuxer` (parses and **copies** every payload) |
| --- | ---: | ---: |
| `opus_audio_60s.webm` (3,001 frames of about 220 B) | 175 µs (median of 5 × 2,000) | 115 µs |
| `vp9_opus_cues.webm` (641 frames, large) | 42 µs | 49 µs |
| `av1_opus.webm` (241 frames) | 19 µs | 40 µs |

* Pion's cost is per element, not per byte. Large VP9 frames make Rust's `memcpy` dominate and Pion wins; tiny Opus frames expose Pion's fixed per-element overhead.
* `pion_audit micro`: `read_vint_id` and `read_vint_size` cost ≈ 8 ns per call even for a 1-byte VINT, mostly building and matching a `Result[VintId/VintSize, WebmError]`. Each SimpleBlock takes 5 such calls (`count_element`, `read_vint_id`, `read_vint_size`, `resolve_definite_end` in the Cluster loop, plus `read_vint_size` for the track).
* Stage attribution with patched package copies (`diff/prof_variants.py`, 2,000 parses × 7 alternating rounds):

  | variant | saving |
  | --- | ---: |
  | no `frames.push` | ≈ 0 % (the `Array[Frame]` growth is not the problem) |
  | no `count_element` | 1–6 % |
  | no DefaultDuration lookup | 2.5–6 % |
  | Result-free fast path for `0xA3` + 1/2-byte size in `parse_cluster_body` | **≈ 45 %**, output byte-identical; Pion beats Rust on Opus |

* Recommendation:
  1. Add an inline fast path for the 1-byte SimpleBlock/BlockGroup IDs and 1–2-byte sizes in the Cluster loop.
  2. Have internal readers return the decoded length or `-1` instead of `Result`, and keep the `Result`-returning public API on top.
  3. Look up the per-track DefaultDuration once per Cluster, not per block.

### P2-11 Nits
* `parse_media_segment` sets `end_pts_ms` to the maximum frame pts (`src/webm.pion:1606-1624`). An MSE coded-frame-group end is `pts + duration`, so the last frame's duration is missing. Rename the field or add the duration.
* `max_depth` counts the Cluster as depth 2 in `parse_webm` (`1430`) but depth 1 in `parse_media_segment` (`1576`), so one limit means two things.
* An explicit `BlockDuration 0` is treated as "absent" and replaced by `DefaultDuration` (`933`).
* `TrackType` is narrowed with `tt.to_int()` (`592`), so `0x1_0000_0001` reads as video.
* A negative `pts_ms` is computed with truncating division (`932`, `-1.5 ms → -1`); floor division would be monotone with `pts_ns`.

---

## Files

| path | purpose |
| --- | --- |
| `run_audit.sh` | one-shot runner (`all build unit diff vectors bombs fuzz perf`) |
| `redteam_test.pion` | 11 `redteam_*` tests (fail while the defect exists) and 8 `control_*` tests (pass). Generated by `diff/gen_redteam_test.py` and then `pionc fmt`; `build` checks it is not stale |
| `src/main.pion` | Pion harness CLI (`dump`, `mse`, `batch`, `kf`, `bench`, `micro`, `kfbench`), built for Native and Wasm32 |
| `diff/rust/` | `matroska-demuxer` / `symphonia-format-mkv` oracle (`dump`, `symph`, `batch` with panic capture, `bench`) |
| `diff/gen_corpus.py`, `diff/ebml.py` | ffmpeg corpus and EBML rewriters (relacing, BlockGroups, unknown sizes, MSE split) |
| `diff/vectors.py` | 31 adversarial vectors and 5 bombs |
| `diff/compare.py` | 4-way differential plus `find_keyframe_at` oracle |
| `diff/fuzz.py` | structure-aware Native vs Wasm32 fuzzer with crash, trap and hang resumption |
| `diff/prof_variants.py` | patched-copy stage profiler |
