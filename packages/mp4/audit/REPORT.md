# RT-mp4 red-team audit: `packages/mp4` v0.1.0

- **Target**: `origin/feat/pkg-mp4` @ `a0084452d9fc56b55b6d7ec7f786c993ece87e32` (`src/types.pion` 235 lines, `src/mp4.pion` 2240 lines, read in full).
- **Toolchain**: `pionc 0.1.0 (arm64_apple, self-hosted)`, Node v24.22.2 (wasm32 runner), FFmpeg/ffprobe 9.0.2, Python 3.9.6, Darwin arm64 (`tokyo-mac-studio-0`).
- **Reproduce**: `sh packages/mp4/audit/run_audit.sh all` (sections: `build corpus unit compare seek fuzz dos prof`). Every artifact goes to `/private/tmp/pion-mp4-audit`; `git status --ignored` stays clean.
- **Files**: `redteam_test.pion` (13 `redteam_*` + 9 `control_*`), `src/main.pion` (dump / batch / seek / prof harness), `vectors.py` (crafted inputs; it also generates the hex block in the test), `corpus.py` + `bmff.py` (FFmpeg corpus and BMFF rewrites), `difftest.py` (ffprobe diff, fuzz, DoS), `perf.py` (patched-copy timing experiments).

## Summary

| Severity | Count | Findings |
|---|---|---|
| **P0** (memory safety, panic, trap, hang) | **0** | 52,000 fuzz cases on Native `--release` and Wasm32 `--release`: no panic, trap, hang or divergence. Every header and table read is bounds-checked before it runs. |
| **P1** | **4** | Two ways to inflate tiny inputs to about 4.2 M samples and 200 to 440 MB RSS. `ctts` v0 and `trun` v0 composition offsets read as unsigned, which corrupts pts on files FFmpeg and browsers accept. |
| **P2** | **9** | MSE range overflow and truncating division, negative `tfdt` accepted, legal u32 durations rejected, fragments for undeclared tracks accepted, seek wrong when pts is not monotonic, edit lists ignored, HEVC `profile_space` dropped from the codec string, weak benchmark oracle. |

Things checked that hold up (pinned by `control_*` tests and fuzzing): `largesize` values from 0 to 15 and at or above 2^63 are rejected (`mp4.pion:281`). `size==0` runs to the end of its container. A `uuid` header too small to hold its extended type is rejected. `offset + size` cannot pass the bound (`:307`). `trun` `data_offset = -2^31` and `tfhd` `base_data_offset >= 2^63` are rejected through the `running_offset < 0` check (`:2018`). `timescale == 0` does not divide (`:2105`). `stsc` `samples_per_chunk == 0` is skipped and the loop cannot run forever, because it is bounded by `num_chunks` (`:1213`). `stz2` 4-bit tables with an odd sample count work. `stsz` and `stz2` counts are capped by `max_samples` before any table is built. The `esds` descriptor-length VLQ is capped at 4 bytes and each step is bounds-checked. Huge `stts` and `ctts` `sample_count` values cannot be used as a CPU bomb, because the expansion loop is driven by `stsz`. No container parser recurses, so `max_depth` is not needed to protect the stack.

## Differential testing (`run_audit.sh compare`)

There are 37 real inputs: 15 FFmpeg MP4s, 9 BMFF rewrites, 8 fMP4s and 4 DASH init+segment pairs, plus one `sidx` v0 rewrite of a CMAF segment.

- **Codecs**: H.264 (B-frames, `avc3`, all-intra, `negative_cts_offsets` (ctts v1), no edit list), HEVC `hvc1` and `hev1`, VP9, AV1, AAC-LC, Opus, FLAC, MP3, and Opus interleaved in small chunks.
- **Rewrites** (`bmff.py`): `stco` to `co64` (with `moov` at the start and at the end), `stz2` 16-bit and 8-bit, `mvhd`/`tkhd`/`mdhd` v1, `uuid` boxes at the top level and inside `moov`, trailing `mdat` with `size==0`, `mdat` with `largesize`, signed `ctts` v1.
- **fMP4**: `default-base-is-moof`, explicit `base-data-offset` (the whole file passed as media), CMAF with `sidx`, `trun` v1 negative CTO, audio only, all-key `separate_moof`, HEVC, VP9 plus Opus muxed together, DASH video and audio `init_*.m4s` + `seg_*_N.m4s`.

**Result: 37/37 inputs match ffprobe exactly** on every sample's byte offset (`pos`), size, keyframe flag and duration, and on dts/pts up to a constant per track. `probe_codec_string` matches an independent RFC 6381 / ISO 14496-15 Annex E derivation from the raw `avcC`/`hvcC`/`av1C`/`vpcC`/`esds` bytes on every track. The constant per-track offsets come from two places:

- **Edit lists** (`elst`, see P2-7): dts and pts are shifted by −1024 ticks on 27 tracks, −312 on 3 tracks and −1105 on 1 track.
- **FFmpeg normalization**: FFmpeg's `dts_shift` moves pts by +1024 for negative-CTO fragments and dts by −1024 for ctts v1 files. That is FFmpeg's convention and not a Pion defect.

Two ffprobe artifacts are excluded: the last MP3 packet's duration, which FFmpeg re-derives from the frame size (1152) while `stts` says 1105, and missing ffprobe durations on VP9 fragments.

I did not build an independent Rust reference: `bench/rust` reimplements Pion's own expansion algorithm on top of the `mp4` 0.14 boxes (see P2-9), so ffprobe is the oracle used here.

`run_audit.sh seek`: `find_sync_sample_at` agrees with a linear reference on every sample-pts target of every corpus track (0 mismatches). The failure in P2-6 needs crafted reordering.

## Fuzzing (`run_audit.sh fuzz`)

The fuzzer mutates real MP4/fMP4 seeds and the crafted vectors with structure awareness:

- box `size` values at the edges (0, 1, 7, 8, 15, 16, 2^31, 2^32−1, length±1);
- `largesize` values (0, 15, 2^63−1, 2^64−1);
- FullBox version/flags;
- box retyping (`moov`, `trak`, `stbl`, `moof`, `traf`, `uuid`, `stz2`, `co64`, `trun`, `esds`, `wave`);
- the first 64 u32 fields of every leaf box (`stsz`, `stsc`, `stts`, `ctts`, `trun`, `tfhd`, `sidx`, `esds` ...);
- plain byte flips, truncation, duplicated boxes and inserted bytes.

Each case runs through `parse_mp4`, `parse_init_segment` + `parse_media_segment`, or `parse_top_level_boxes`, then through `probe_codec_string` and `find_sync_sample_at`, and the result is hashed (FNV over every field).

| Run | Cases | Parsed OK / Err | Native `--release` crash/timeout | Wasm32 `--release` crash/timeout | Native↔Wasm32 divergence |
|---|---|---|---|---|---|
| seed 20261123 (default in `run_audit.sh`) | 12,000 | 5,009 / 6,991 | 0 | 0 | 0 |
| seed 7 (`FUZZ_N=40000 FUZZ_SEED=7`) | 40,000 | 16,496 / 23,504 | 0 | 0 | 0 |

No `pionc` compiler issue was hit: Int and Int64 arithmetic wraps identically on both targets (checked with a probe: `UInt(2^32−1).to_int() == -1`, `Int64::MAX + 1` wraps, and `(2^63−1)*1000` gives the same value on both).

---

## P1 findings

### P1-1: zero-byte `trun` entries inflate a 679-byte fMP4 into 4,194,304 samples
- **Where**: `mp4.pion:1932-1941` and `:1968-1974`. `sc64` is checked only against `max_samples`, and the table-length check `sc64 * per_sample_bytes > tend_i - p` always passes when `per_sample_bytes == 0` (`tr_flags` has none of 0x100, 0x200, 0x400 or 0x800). The size comes from the `trex`/`tfhd` default; with size 0, every sample passes the bound check at `:2018`.
- **Repro**: `vectors.py:v_dos_trun_zero_byte_samples` (init + `moof{tfhd(default-base-is-moof), tfdt, trun(flags=0, sample_count=4194304)}` + an empty `mdat`); run `run_audit.sh dos` or `mp4_audit file 1 /private/tmp/pion-mp4-audit/vectors/dos_trun_zero_byte_samples.bin`.
- **Measured**: 679 input bytes produce `samples=4194304` and a **195.5 MB** peak RSS on Native and **434.6 MB** on Wasm32 (node). That is about 300,000 times the input size. It is reachable from one MSE segment with `DecodeLimits::default()`, and each further segment repeats it (the budget is per call).
- **Reference**: FFmpeg also allocates per entry, but an MSE consumer feeding untrusted segments to this API trusts `DecodeLimits` to stop "crafted `trun` allocation bombs" (README). The default limit allows 4 M × 40-byte `Sample`s plus the `Array` growth slack.
- **Fix**: make sample charges proportional to the input, so each sample must use at least one byte of table or payload. For example, cap at `min(max_samples, 2 * data.length())`, or require `sc <= mdat_bytes_remaining` when `sz == 0 && per_sample_bytes == 0`. Also consider a `max_sample_bytes` (memory) limit, and reserve capacity only after that check.
- **Test**: `redteam_p1_trun_zero_byte_samples_amplification_bounded_by_input`.

### P1-2: overlapping `stco` chunks inflate an 8.7 KB MP4 into 4,194,304 samples
- **Where**: `mp4.pion:1171-1278`. The only per-sample check is `cur_offset + sz <= data_len` (`:1235`). Chunks may all point to the same bytes, so a constant `stsz` (no table bytes) × `stsc.samples_per_chunk` × `stco` entry count multiply freely up to `max_samples`.
- **Repro**: `vectors.py:v_dos_overlapping_chunks`: `stsz` constant size 1 with count 4,194,304, 1024 `stco` entries all pointing at the same 4 KiB `mdat` payload, and `stsc` with 4096 samples per chunk.
- **Measured**: 8,763 bytes produce 4,194,304 samples and a **199.5 MB** RSS on Native and **440.8 MB** on Wasm32.
- **Fix**: use the same input-proportional budget as P1-1, sized by the number of `stco`/`co64` entries plus the number of distinct payload bytes, or reject `samples_per_chunk × chunk_count` above the table bytes plus the `mdat` bytes. Related (informational): `sync_flags` (`:1177`) is allocated from the `stsz` count before chunk consistency is checked (a 555-byte input allocates a 4 MB bitmap and then fails with `InvalidSyntax`).
- **Test**: `redteam_p1_overlapping_chunks_amplification_bounded_by_input`.

### P1-3: `ctts` v0 offsets read as unsigned, so negative offsets give pts near 4.29e9
- **Where**: `mp4.pion:1002-1003` (`read_u32_be(...).to_int64() & 0xFFFFFFFF` when `ver == 0`).
- **Repro**: `v_ctts_v0_negative` (cto 80, 200, 0xFFFFFFD8, 40). ffprobe gives pts `80, 240, 40, 160`; Pion gives `80, 240, 4294967336, 160`.
- **Reference**: FFmpeg (`mov_read_ctts` reads `avio_rb32` into a signed int), Chromium and GPAC all treat the field as int32 for both versions, because many muxers write negative values into v0 boxes. Pion's pts is then about 49.7 days in the future, which breaks seek, `[start_pts_ms, end_pts_ms]` and presentation order.
- **Fix**: read the offset as `read_i32_be` for both versions (as `trun` v1 already does). If strict ISO behaviour is wanted, take the signed value when the u32 is ≥ 2^31.
- **Test**: `redteam_p1_ctts_v0_offset_is_signed`.

### P1-4: `trun` v0 composition offsets read as unsigned (MSE)
- **Where**: `mp4.pion:2001-2006`.
- **Repro**: `v_trun_v0_negative_cto` (CTO 0xFFFFFC00). ffprobe gives `pts == dts` after its +1024 `dts_shift`, which means it read −1024. Pion gives pts = dts + 4,294,966,272 and an MSE range of `4294967272..4294967312` ms.
- **Reference**: Chromium's `TrackFragmentRun` parser and FFmpeg (`mov_read_trun`) read the field as signed regardless of version. Old FFmpeg/Bento4 fragmenters emit negative values in v0. An MSE app that uses `start_pts_ms` for `SourceBuffer.timestampOffset` or for buffering decisions would be off by about 50 days.
- **Fix**: same as P1-3 (`read_i32_be` for both versions).
- **Test**: `redteam_p1_trun_v0_cto_is_signed`.

## P2 findings

### P2-1: MSE `start_pts_ms`/`end_pts_ms` overflow Int64 (`pts * 1000L`)
- **Where**: `mp4.pion:2109-2110`. `(sm.pts * 1000L) / ts` wraps for pts above about 9.2e15.
- **Repro**: `v_tfdt_huge_ms_overflow` (`tfdt` v1 = 2^62, a legal u64, with timescale 1000). Pion gives the range `0..40`; ffprobe gives pts 4611686018427387904 (the expected value is 2^62 ms).
- **Fix**: divide first and then rescale the remainder (`pts / ts * 1000 + pts % ts * 1000 / ts`), or saturate. The P2-9 floor fix uses the same code.
- **Test**: `redteam_p2_mse_range_ms_overflow`.

### P2-2: `tfdt` v1 values at or above 2^63 are accepted as negative `base_decode_time`
- **Where**: `mp4.pion:1825` (`read_u64_be` returns a negative Int64, which is not checked). The same applies to `mvhd`/`mdhd`/`tkhd`/`sidx` v1 64-bit fields, which reach public structs as negative durations.
- **Repro**: `v_tfdt_sign_bit`. ffprobe reports `pts=N/A` and the discard flag; Pion reports `dts = -9223372036854775808`.
- **Fix**: return `Err(InvalidSyntax)` (or `Unsupported`) for 64-bit time fields at or above 2^63.
- **Test**: `redteam_p2_tfdt_sign_bit_rejected`.

### P2-3: legal u32 sample durations of 2^31 or more are rejected
- **Where**: `mp4.pion:978` (`stts` delta), `:2013-2017` (`trun` duration), and `Sample.duration : Int` in `types.pion`.
- **Repro**: `v_trun_duration_2p31` and `v_stts_delta_2p31` both fail with `InvalidSyntax`; ffprobe accepts both (`duration=2147483648`).
- **Fix**: widen `Sample.duration` to `Int64` (an API change in v0.1.0, best done now) and drop the `< 0` rejections.
- **Tests**: `redteam_p2_trun_duration_ge_2p31_accepted`, `redteam_p2_stts_delta_ge_2p31_accepted`.

### P2-4: `traf` for a track the init segment does not declare is accepted silently
- **Where**: `mp4.pion:1706-1715`. `find_track_timescale` falls back to `mvhd.timescale`; `find_trex` at `:1753` falls back to defaults of 0.
- **Repro**: `v_unknown_track_fragment` (track_id 7). Pion returns one fragment and the range `5000..5040` computed in movie units. FFmpeg fails with "trun track id unknown, no tfhd was found", and the MSE spec treats it as a decode error.
- **Fix**: return an error (or skip the `traf`) when `track_id` is not in `init.tracks`.
- **Test**: `redteam_p2_unknown_track_fragment_rejected`.

### P2-5: MSE range uses truncating division for negative pts
- **Where**: `mp4.pion:2109`. Negative pts are common with `trun` v1 negative CTO when there is no edit list.
- **Repro**: `v_negative_pts_ms_trunc` (pts −1 at timescale 90000). Pion gives `start_pts_ms = 0`; flooring gives −1.
- **Fix**: use floor division for the start and ceiling division for the end, so the range always covers the media.
- **Test**: `redteam_p2_mse_range_negative_pts_floor`.

### P2-6: `find_sync_sample_at` binary-searches pts in decode order
- **Where**: `mp4.pion:2210-2240`. Pts is not monotonic in decode order once `ctts` is present, so the upper-bound search can stop before a valid sync sample. The backward scan is also O(n) per call when sync samples are sparse; ffmpeg and others search `stss` instead.
- **Repro**: `v_seek_nonmonotonic_pts` (pts 40(I), 140, 400, 180(I), 220). Target 200 should return sample 3; Pion returns 0. `mp4_audit seek` reports `target=180 got=0 want=3`. Real FFmpeg/x264 corpus tracks did not trigger it (0 mismatches), because closed GOPs keep sync pts monotonic.
- **Fix**: binary-search the sync samples only (an `stss`-style list, or a sync index built once and sorted by pts), or document that pts must be monotonic and search by dts.
- **Test**: `redteam_p2_seek_nonmonotonic_pts`.

### P2-7: edit lists (`edts`/`elst`) are ignored
- **Where**: `parse_trak` (`mp4.pion:1305-1371`) skips `edts`; there is no field for it on `Track`.
- **Effect**: on every FFmpeg/x264 B-frame MP4 and every AAC/Opus file with priming, Pion's timeline is offset from ffprobe and browsers by the `elst` `media_time` (1024 ticks = 80 ms for H.264 at 12800, 1024/48000 for AAC, 312 for Opus; see the compare section, 31 tracks). `v_edit_list_media_time`: ffprobe's first pts is 0, Pion's is 80.
- **Fix**: parse `elst` (v0 and v1) into `Track.edit_list` and either apply the first non-empty edit's `media_time` to pts, or expose it with a documented helper. MSE `start_pts_ms` should apply it the same way Chromium does for init-segment edit lists.
- **Test**: `redteam_p2_edit_list_media_time_applied`.

### P2-8: HEVC codec string drops `general_profile_space`
- **Where**: `mp4.pion:694-696` and `:2168`. The top 2 bits of `hvcC[1]` are discarded.
- **Repro**: `v_hevc_profile_space` (profile_space 1). Pion gives `hvc1.1.6.L93.90`; ISO 14496-15 Annex E gives `hvc1.A1.6.L93.90`.
- **Fix**: prefix "", "A", "B" or "C" according to `b1 >> 6`.
- **Test**: `redteam_p2_hevc_codec_string_profile_space`.

### P2-9: the benchmark oracle is not independent and only handles one `trun`/`trex` (affects the README claims)
- `bench/rust/src/main.rs` reimplements Pion's own `stsc`/`stts`/`ctts` expansion on top of `mp4` 0.14 boxes, so a matching SHA-256 shows the two implementations agree with each other, not that they are correct.
- `mp4` 0.14 also exposes only a single `traf.trun` and a single `mvex.trex` (`vec![m.trex.clone()]`). On inputs with several `trun`s per `traf`, or several tracks in one init segment, the Rust side would silently drop samples or defaults. The SHA matches today only because FFmpeg writes one `trun` per `traf`.
- **Fix**: switch to `mp4parse` (or `symphonia-format-isomp4`) and ffprobe as the oracle, and add a multi-`trun` input to the bench corpus.

---

## Performance (`run_audit.sh prof`)

The bench "fMP4 Video 0.77×" input is DASH `yt_init_0.m4s` (828 B) + `yt_seg_0_1.m4s` (1.7 MB, `sidx` + 1 `moof`, 60 samples). Each iteration parses the init segment **and** the media segment, so it is a per-call overhead microbenchmark (≈2 µs per iteration), not a throughput test. The "MB/s" figures in the README count `mdat` bytes that neither implementation reads.

| Variant (patched copy under `/private/tmp/pion-mp4-audit/perf`, same `dump-fmp4` SHA-256) | init ns/iter | media ns/iter |
|---|---|---|
| `base` (a0084452) | 813 | 890 |
| `timeline_per_fragment`: compute min/max ticks per fragment, then divide once (exact same output, because truncating division is monotone) | 807 | 877 (1.02×) |
| `timeline_skipped`: upper bound, output differs | 817 | 843 (1.06×) |

The table is the minimum of 5 interleaved rounds × 300k iterations. The host load average was 36 to 150 at the time, so absolute numbers are noisy but the ratios held across reruns; an earlier 500k run gave 1052/1178 ns and 1.04×/1.11×.

What the numbers show:
1. **About 48% of the bench time is `parse_init_segment`**, which runs again on every iteration: about 0.8 to 1.0 µs for a single-track init. In that path each `trak` does 7 eager `[]` `Array` allocations in `parse_stbl` (`:934-942`) even when the tables are empty, `String` allocations in `read_fourcc`, `decode_language` and the `hdlr` comparison chain (`:530-539`), and a `Bytes::slice` of `avcC` (a copy unless slices are views). Rust's empty `Vec`s do not allocate.
   - **Fix**: allocate tables lazily or share one empty array; compare `handler_type` as a `UInt` FourCC instead of a `String`; produce the language/fourcc `String`s only for the public `Track`; return `avcC` as an (offset, length) view.
2. The media segment costs about 15 ns per sample. **The MSE timeline loop (2 Int64 divisions per sample, `:2106-2124`) is 4 to 10% of it**, and computing it per fragment removes most of that at no semantic cost.
   - The rest goes to the `Array[Sample]` growth (no preallocation, although `sc` is known at `:1937`; use `Array::make(sc, …)` once P1-1's budget is in place), the 4 separately bounds-checked byte loads per `read_u32_be` (`:106-112`), and `find_trex`, a linear scan per `traf`.
3. **No O(n²) behaviour found.** The `stsc`, `stts` and `ctts` cursors are single-pass; the `stss` bitmap is O(n). 4,194,304 samples expand in 65 to 90 ms native (P1 vectors), about 16 to 21 ns per sample. `find_sync_sample_at` costs O(log n) plus a backward scan that is O(n) in the worst case per call (P2-6). 65,000 empty boxes parse in 1 ms.

## Reproduction commands

```sh
sh packages/mp4/audit/run_audit.sh all                  # everything below, ~1 min
sh packages/mp4/audit/run_audit.sh unit                 # 13 RED fail, 9 CTRL pass, upstream 8/8
sh packages/mp4/audit/run_audit.sh compare              # 37/37 vs ffprobe
FUZZ_N=40000 FUZZ_SEED=7 sh packages/mp4/audit/run_audit.sh fuzz
sh packages/mp4/audit/run_audit.sh dos                  # P1-1/P1-2 RSS + wall
sh packages/mp4/audit/run_audit.sh prof                 # init/media split + variants
/private/tmp/pion-mp4-audit/bin/mp4_audit file 1 /private/tmp/pion-mp4-audit/vectors/dos_trun_zero_byte_samples.bin
```
