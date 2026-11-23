# `mp4` (`v0.1.0`)

Pure Pion implementation of an **ISO/IEC 14496-12 (ISO BMFF / MP4 / fMP4)** demuxer and **W3C MSE ISO BMFF Byte Stream Format** segment parser with zero external dependencies, zero `extern "C"`, and no `World` requirement.

## Features

- **Strict Box / Atom Traversal**:
  - Standard 32-bit sizes, 64-bit `largesize` (`size == 1`), `size == 0` (to container EOF, no infinite loop), and 16-byte `uuid` extended box types.
  - Stack-allocated `RawBox` internal fast path with compile-time 32-bit FourCC dispatch (zero per-box string allocations).
- **Traditional MP4 (`moov`) Full Demuxing**:
  - `ftyp`, `mvhd` (v0/v1), `trak` → `tkhd` (v0/v1, 16.16 fixed-point dimensions), `mdia` → `mdhd` (v0/v1, ISO-639-2 language), `hdlr` (`vide`/`soun`/`subt`), `minf` → `stbl`.
  - `stsd` codec configuration extraction:
    - Video: `avc1`/`avc3` (`avcC`), `hev1`/`hvc1` (`hvcC`), `av01` (`av1C`), `vp09`/`vp08` (`vpcC`).
    - Audio: `mp4a` (`esds` ES_Descriptor / DecoderConfigDescriptor / `AudioSpecificConfig`, including QuickTime `wave` wrapper and MP3 OTI `0x69`/`0x6B`), `Opus` (`dOps`), `fLaC` (`dfLa`), `.mp3`/`mp3 `.
  - Full sample table synthesis (`stts`, `ctts` v0 unsigned / v1 signed, `stsc`, `stsz`/`stz2` 4/8/16-bit, `stco`/`co64`, `stss` with absent-means-all-sync semantics) into zero-copy `Sample` ranges (`offset`, `size`, `dts`, `pts`, `duration`, `is_sync`).
  - `mvex` → `trex` default fragment parameters.
- **fMP4 / MSE Initialization & Media Segments**:
  - `parse_init_segment(data, limits)`: validates `ftyp` + `moov` (+ `mvex`/`trex`).
  - `parse_media_segment(init, data, limits)`: parses `styp`, `sidx` (v0/v1 with `earliest_presentation_time` & SAP subsegment references), and one or more `moof` + `mdat` pairs (`mfhd`, `traf`, `tfhd` with all flags including `base-data-offset`, `default-base-is-moof`, `duration-is-empty`, multi-`traf` chaining, `tfdt` v0/v1, `trun` v0 unsigned / v1 signed CTO, `first-sample-flags`, ISO 14496-12 `sample_flags` keyframe detection, strict `offset + size <= data.length()` bounds validation, and `[start_pts_ms, end_pts_ms]` media timeline range).
- **Utilities**:
  - `probe_codec_string(track)`: RFC 6381 / MSE codec strings (`avc1.64001f`, `hvc1.…`, `av01.0.04M.08`, `vp09.00.10.08`, `vp08`, `mp4a.40.2`, `opus`, `fLaC`, `mp3`).
  - `find_sync_sample_at(samples, target_pts)`: binary search for nearest sync sample at or before `target_pts` for video seek.

### `DecodeLimits` Semantics & Security Guards

- Any negative field (`< 0`) is rejected immediately with `Err(Mp4Error::LimitExceeded(...))`.
- A `0` limit allows zero items of that category (never unlimited).
- Enforces `max_boxes`, `max_depth`, `max_tracks`, `max_samples`, and `max_moof_fragments` **before** table allocation to defeat nested-box bombs and crafted `stsz`/`trun`/`sidx` allocation bombs.
- Guards against `largesize < 16` integer underflow, invalid sizes in `2..7`, `uuid` header underflow, and out-of-bounds sample offsets.

## Public API

```pion
pub val struct DecodeLimits {
  pub max_boxes : Int
  pub max_depth : Int
  pub max_tracks : Int
  pub max_samples : Int
  pub max_moof_fragments : Int
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

```sh
sh scripts/verify.sh packages/mp4
```

### 4-Mode `wasm_smoke` Verification

All four modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with byte-identical stdout SHA-256 (`4c1fad121164cefcae71cda368642c00f1e899fabe5a490a18cda450c8869d58`):

```sh
pionc run packages/mp4/wasm_smoke
pionc run --release packages/mp4/wasm_smoke
pionc run --target wasm32 packages/mp4/wasm_smoke
pionc run --target wasm32 --release packages/mp4/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/mp4/bench/run_bench.sh` against **Rust `mp4` crate `0.14.0` (`--release`)** on FFmpeg-generated real media corpora (`standard_h264_aac.mp4`, DASH/MSE `yt_init_*.m4s` + `yt_seg_*_1.m4s`). Every track's metadata and every sample's `offset`, `size`, `dts`, `pts`, `duration`, and `is_sync` are verified byte-for-byte identical via mandatory stdout SHA-256:

| Workload | `pion` Median (Throughput) | `rust_mp4` Median (Throughput) | `pion` Peak RSS | `rust_mp4` Peak RSS | Speedup vs `rust_mp4` | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Standard MP4 Demux (H.264 720p B-frames + AAC-LC × 5,000) | 38.166 ms (486,524.18 MB/s) | 46.700 ms (397,625.42 MB/s) | 8.83 MiB | 5.95 MiB | **1.22×** | `f250c54f880a3cf9...` |
| YouTube MSE fMP4 Video (`sidx`+`moof`+`mdat`, H.264 720p × 20,000) | 50.477 ms (683,964.18 MB/s) | 38.617 ms (894,019.43 MB/s) | 5.28 MiB | 3.91 MiB | **0.77×** | `22c275a16d4f5a72...` |
| YouTube MSE fMP4 Audio (AAC-LC 48kHz × 20,000) | 51.126 ms (12,765.74 MB/s) | 73.534 ms (8,875.65 MB/s) | 2.03 MiB | 2.27 MiB | **1.44×** | `2744098641328acb...` |

- **Honest notes**: Pion leads Rust `mp4 0.14` on both standard MP4 `moov+stbl` demuxing (**1.22×**) and MSE fMP4 AAC audio segments (**1.44×**, with lower Peak RSS `2.03` vs `2.27 MiB`). On MSE fMP4 H.264 video segments (`0.77×`), Pion additionally parses `sidx` boxes, validates every sample's byte range against segment bounds, and computes `[start_pts_ms, end_pts_ms]` across all samples.
