# `mp4` (`v0.1.0`)

Pure Pion implementation of an **ISO/IEC 14496-12 (ISO BMFF / MP4 / fMP4)** demuxer and **W3C MSE ISO BMFF Byte Stream Format** segment parser with zero external dependencies, zero `extern "C"`, and no `World` requirement.

## Features

- **Strict Box / Atom Traversal**:
  - Standard 32-bit sizes, 64-bit `largesize` (`size == 1`), `size == 0` (to container EOF, no infinite loop), and 16-byte `uuid` extended box types.
  - Stack-allocated `RawBox` internal fast path with compile-time 32-bit FourCC dispatch (zero per-box string allocations).
- **Traditional MP4 (`moov`) Full Demuxing**:
  - `ftyp`, `mvhd` (v0/v1), `trak` → `tkhd` (v0/v1, 16.16 fixed-point dimensions), `edts` → `elst` (v0/v1 edit lists applied to track `dts`/`pts`), `mdia` → `mdhd` (v0/v1, ISO-639-2 language), `hdlr` (`vide`/`soun`/`subt`), `minf` → `stbl`.
  - `stsd` codec configuration extraction:
    - Video: `avc1`/`avc3` (`avcC`), `hev1`/`hvc1` (`hvcC`, including `general_profile_space`), `av01` (`av1C`), `vp09`/`vp08` (`vpcC`).
    - Audio: `mp4a` (`esds` ES_Descriptor / DecoderConfigDescriptor / `AudioSpecificConfig`, including QuickTime `wave` wrapper and MP3 OTI `0x69`/`0x6B`), `Opus` (`dOps`), `fLaC` (`dfLa`), `.mp3`/`mp3 `.
  - Full sample table synthesis (`stts` full u32 deltas, `ctts` v0/v1 signed 32-bit offsets, `stsc`, `stsz`/`stz2` 4/8/16-bit, `stco`/`co64`, `stss` with absent-means-all-sync semantics) into zero-copy `Sample` ranges (`offset`, `size`, `dts`, `pts`, `duration: Int64`, `is_sync`).
  - `mvex` → `trex` default fragment parameters.
- **fMP4 / MSE Initialization & Media Segments**:
  - `parse_init_segment(data, limits)`: validates `ftyp` + `moov` (+ `mvex`/`trex`).
  - `parse_media_segment(init, data, limits)`: parses `styp`, `sidx` (v0/v1 with `earliest_presentation_time` & SAP subsegment references), and one or more `moof` + `mdat` pairs (`mfhd`, `traf`, `tfhd` with all flags including `base-data-offset`, `default-base-is-moof`, `duration-is-empty`, multi-`traf` chaining, strict declared-`track_id` check against `init.tracks`, `tfdt` v0/v1 rejecting `>= 2^63`, multi-`trun` v0/v1 with signed 32-bit CTO, `first-sample-flags`, ISO 14496-12 `sample_flags` keyframe detection, `elst` offset application, strict `offset + size <= data.length()` bounds validation, and overflow-free floor/ceil `[start_pts_ms, end_pts_ms]` media timeline range).
- **Utilities**:
  - `probe_codec_string(track)`: RFC 6381 / ISO 14496-15 Annex E / MSE codec strings (`avc1.64001f`, `hvc1.A1.6.L93.90`, `av01.0.04M.08`, `vp09.00.10.08`, `vp08`, `mp4a.40.2`, `opus`, `fLaC`, `mp3`).
  - `find_sync_sample_at(samples, target_pts)`: finds the nearest sync sample at or before `target_pts` safely even under non-monotonic B-frame PTS reordering.

### `DecodeLimits` Semantics & Security Guards

- Any negative field (`< 0`) is rejected immediately with `Err(Mp4Error::LimitExceeded(...))`.
- A `0` limit allows zero items of that category (never unlimited).
- Effective sample budget is bounded by `min(limits.max_samples, 2 * data.length())` **before** table allocation to defeat both `trun` zero-byte sample amplification bombs and overlapping `stco` chunk amplification bombs (verified < 2 MiB Native RSS on 679 B and 8.7 KB bomb vectors).
- Guards against `largesize < 16` integer underflow, invalid sizes in `2..7`, `uuid` header underflow, `tfdt >= 2^63`, undeclared `traf.track_id`, and out-of-bounds sample offsets.

## Public API

```pion
pub val struct DecodeLimits {
  pub max_boxes : Int
  pub max_depth : Int
  pub max_tracks : Int
  pub max_samples : Int
  pub max_moof_fragments : Int
}

pub val struct Sample {
  pub offset : Int64
  pub size : Int
  pub dts : Int64
  pub pts : Int64
  pub duration : Int64
  pub is_sync : Bool
}

pub val struct EditEntry {
  pub segment_duration : Int64
  pub media_time : Int64
  pub media_rate_integer : Int
  pub media_rate_fraction : Int
}

pub enum Mp4Error {
  Truncated(String)
  InvalidBoxSize(String)
  InvalidSyntax(String)
  LimitExceeded(String)
  Unsupported(String)
}

pub fn read_box_header(data : Bytes, offset : Int64, end : Int64) -> Result[BoxHeader, Mp4Error]
pub fn parse_top_level_boxes(data : Bytes, limits : DecodeLimits) -> Result[Array[BoxHeader], Mp4Error]
pub fn parse_mp4(data : Bytes) -> Result[Mp4File, Mp4Error]
pub fn parse_mp4_with_limits(data : Bytes, limits : DecodeLimits) -> Result[Mp4File, Mp4Error]
pub fn Mp4File::extract_samples(self : Mp4File, track_id : UInt) -> Result[Array[Sample], Mp4Error]
pub fn parse_init_segment(data : Bytes, limits : DecodeLimits) -> Result[InitSegment, Mp4Error]
pub fn parse_media_segment(init : InitSegment, data : Bytes, limits : DecodeLimits) -> Result[MediaSegment, Mp4Error]
pub fn probe_codec_string(track : Track) -> String
pub fn find_sync_sample_at(samples : Array[Sample], target_pts : Int64) -> Option[Int]
```

## Verification

- **Unit & Spec Suite**: `sh scripts/verify.sh packages/mp4` — **8 / 8 passing**, 0 diagnostics, `pionc fmt --check` clean.
- **Red-Team Audit Suite (`packages/mp4/audit/`)**:
  - `unit`: **22 / 22 passing** (13/13 `redteam_*` + 9/9 `control_*` + 8/8 upstream).
  - `compare`: **37 / 37** real FFmpeg MP4/fMP4/DASH & BMFF-rewritten inputs match `ffprobe` exactly on `pos`, `size`, `keyframe`, `duration`, `dts`/`pts` (with `elst` applied), and RFC 6381 codec strings.
  - `seek`: **0** mismatches vs linear reference across all corpus tracks.
  - `fuzz`: **12,000** structure-aware & mutation cases on Native `--release` and Wasm32 `--release` — **0** crashes, **0** timeouts, **0** Native↔Wasm32 divergences.
  - `dos`: P1-1 (`679 B`) and P1-2 (`8,763 B`) amplification bombs rejected in `0 ms` at **1.9 MiB** Native peak RSS.

### 4-Mode `wasm_smoke` Verification

All four modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with byte-identical stdout SHA-256 (`4c1fad121164cefcae71cda368642c00f1e899fabe5a490a18cda450c8869d58`):

```sh
pionc run packages/mp4/wasm_smoke
pionc run --release packages/mp4/wasm_smoke
pionc run --target wasm32 packages/mp4/wasm_smoke
pionc run --target wasm32 --release packages/mp4/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/mp4/bench/run_bench.sh` against the independent pure-Rust **`symphonia-format-isomp4 0.5.5`** (`--release`), with mandatory **`ffprobe` ground-truth verification** (all 4 corpora verified exact on `pos/size/dts/pts/dur/key`, including a 2-`trun`/1-`traf` multi-`trun` fMP4 segment) and byte-for-byte stdout SHA-256 verification across all rounds:

| Workload | `pion` Median (`µs/iter`) | `rust_symphonia` Median (`µs/iter`) | `pion` Peak RSS | `rust_symphonia` Peak RSS | Speedup vs `rust_symphonia` | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Standard MP4 Demux (H.264 720p B-frames + AAC-LC, 309 samples × 1,000) | 18.043 ms (`18.04 µs/iter`) | 894.839 ms (`894.84 µs/iter`) | 8.86 MiB | 9.80 MiB | **49.60×** | `4d2ee24b3c8a09ff...` |
| YouTube MSE fMP4 Video (`sidx`+`moof`+`mdat`, 60 samples, init+seg × 1,000) | 13.992 ms (`13.99 µs/iter`) | 373.335 ms (`373.33 µs/iter`) | 5.30 MiB | 7.69 MiB | **26.68×** | `e65578c1240d7bf2...` |
| Multi-`trun` fMP4 Video (2 `trun`s/`traf`, 60 samples, init+seg × 1,000) | 11.052 ms (`11.05 µs/iter`) | 392.389 ms (`392.39 µs/iter`) | 5.30 MiB | 7.67 MiB | **35.50×** | `e65578c1240d7bf2...` |
| YouTube MSE fMP4 Audio (AAC-LC 48kHz, 92 samples, init+seg × 2,000) | 14.700 ms (`7.35 µs/iter`) | 43.697 ms (`21.85 µs/iter`) | 2.05 MiB | 2.66 MiB | **2.97×** | `5564d952aa7922c1...` |

- **In-process fMP4 microbench (`mp4_audit prof-fmp4`, 300k iters on `yt_init_0.m4s` + `yt_seg_0_1.m4s`)**: `parse_init_segment` = **0.83 µs/iter** (`250 ms / 300k`), `parse_media_segment` = **0.87 µs/iter** (`262 ms / 300k`).
- **Honest notes**:
  - The fMP4 microbenchmarks parse both the initialization segment and the media segment on every iteration and are reported in `µs/iter` rather than `mdat`-inflated `MB/s`, since neither parser decodes media payload bytes.
  - `symphonia-format-isomp4`'s `next_packet()` copies packet payload bytes out of `mdat` into per-packet `Vec<u8>` buffers, whereas `packages/mp4` is a zero-copy demuxer returning `(offset, size)` ranges into the caller's `Bytes` buffer; the speedup reflects both pure-Pion metadata parsing efficiency and zero-copy packet indexing.
