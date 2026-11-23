# `webm` (`v0.1.0`)

100% Pure Pion implementation of **RFC 8794 EBML**, **Matroska / WebM** container demuxing, and **W3C Media Source Extensions (MSE) WebM Byte Stream Format** parsing — with zero `extern "C"`, zero `World` dependency, and zero-copy frame indexing (`Frame { offset, size, pts_ns, pts_ms, ... }`).

## Features

- **RFC 8794 EBML Primitives (`src/ebml.pion`)**:
  - `read_vint_id(data, offset, end)`: 1–4 byte Element IDs with marker bit preserved, rejecting `0x00`, >4-byte IDs, and forbidden all-0 / all-1 `VINT_DATA`;
  - `read_vint_size(data, offset, end)`: 1–8 byte unsigned VINT sizes with exact all-ones **unknown-size** detection (`0xFF`, `0x7FFF`, `0x01FFFFFFFFFFFFFF`, etc.) so streaming unknown-size containers never trigger huge allocations;
  - `read_signed_vint(data, offset, end)`: 1–8 byte EBML signed VINT deltas for EBML lacing;
  - `read_be_uint`, `read_be_sint` (0–8 bytes with sign extension), and exact IEEE 754 `read_be_float` (0, 4, or 8 bytes).
- **Matroska / WebM Container Demuxer (`src/webm.pion`)**:
  - **EBML Header (`0x1A45DFA3`)**: `DocType` (`webm` / `matroska`), `DocTypeVersion`, `DocTypeReadVersion`;
  - **Segment (`0x18538067`)**: definite-size and streaming unknown-size Segments;
  - **Info (`0x1549A966`)**: `TimestampScale` (default `1_000_000` ns), float32/float64 `Duration` + `duration_ms`, `MuxingApp`, `WritingApp`;
  - **Tracks (`0x1654AE6B`)**: `TrackEntry` (`TrackNumber`, `TrackUID`, `TrackType`, `FlagDefault`, `FlagLacing`, `DefaultDuration`, `Language`/`LanguageBCP47`, `CodecID`, `CodecPrivate`, `CodecDelay`, `SeekPreRoll`), `Video` (`PixelWidth`/`Height`, `DisplayWidth`/`Height`, `AlphaMode`), `Audio` (`SamplingFrequency`, `OutputSamplingFrequency`, `Channels`, `BitDepth`);
  - **Cues (`0x1C53BB6B`)**: `CuePoint` → `CueTime` + `CueTrackPositions` (`CueTrack`, `CueClusterPosition`, `CueRelativePosition`);
  - **Cluster (`0x1F43B675`)**: definite-size and unknown-size Clusters, `Timestamp`, `SimpleBlock`, and `BlockGroup` (`Block`, `BlockDuration`, `ReferenceBlock`, `DiscardPadding`), with all **4 lacing modes** (None, Xiph, Fixed-size, EBML) and strict bounds checks;
  - **Zero-copy `Frame` output**: `offset`, `size`, `pts_ns`, `pts_ms`, `duration_ns`, `is_keyframe` (including `BlockGroup` without `ReferenceBlock`), `invisible`.
- **W3C MSE WebM Byte Stream Format**:
  - `parse_init_segment(data, limits)` (supports unknown-size streaming Segments);
  - `parse_media_segment(init, data, limits)` (parses one or more standalone `Cluster` segments and computes `[start_pts_ms, end_pts_ms]`);
  - `probe_codec_string(track)` (`vp8`, `vp9`, `av01`, `avc1`, `hev1`, `opus`, `vorbis`, `mp4a.40.2`, `flac`);
  - `find_keyframe_at(frames, track_number, target_pts_ms)` (binary-search nearest keyframe at or before target PTS).
- **Hardened `DecodeLimits`**:
  - Any negative limit is immediately rejected with `WebmError::InvalidLimits`;
  - `0` strictly means 0 items/bytes allowed (`max_tracks`, `max_clusters`, `max_frames`, `max_cues`, `max_laced_frames`, `max_codec_private_bytes`, `max_string_bytes`, `max_elements`, `max_depth`);
  - Rejects unknown-size leaf elements, truncated payloads, oversized declared lengths, and malformed lacing headers without allocation bombs.

## Public API

```pion
pub val struct DecodeLimits {
  pub max_tracks : Int
  pub max_clusters : Int
  pub max_frames : Int
  pub max_cues : Int
  pub max_laced_frames : Int
  pub max_codec_private_bytes : Int
  pub max_string_bytes : Int
  pub max_elements : Int
  pub max_depth : Int
}

pub fn read_vint_id(data : Bytes, offset : Int, end : Int) -> Result[VintId, WebmError]
pub fn read_vint_size(data : Bytes, offset : Int, end : Int) -> Result[VintSize, WebmError]
pub fn read_signed_vint(data : Bytes, offset : Int, end : Int) -> Result[SignedVint, WebmError]
pub fn read_be_uint(data : Bytes, offset : Int, size : Int) -> Result[Int64, WebmError]
pub fn read_be_sint(data : Bytes, offset : Int, size : Int) -> Result[Int64, WebmError]
pub fn read_be_float(data : Bytes, offset : Int, size : Int) -> Result[Double, WebmError]

pub fn parse_webm(data : Bytes) -> Result[WebmFile, WebmError]
pub fn parse_webm_with_limits(data : Bytes, limits : DecodeLimits) -> Result[WebmFile, WebmError]
pub fn parse_init_segment(data : Bytes, limits : DecodeLimits) -> Result[WebmInitSegment, WebmError]
pub fn parse_media_segment(init : WebmInitSegment, data : Bytes, limits : DecodeLimits) -> Result[WebmMediaSegment, WebmError]
pub fn probe_codec_string(track : TrackEntry) -> String
pub fn find_keyframe_at(frames : Array[Frame], track_number : Int64, target_pts_ms : Int64) -> Option[Int]
pub fn build_keyframe_index(frames : Array[Frame], track_number : Int64) -> KeyframeIndex
pub fn KeyframeIndex::find_at(self : KeyframeIndex, target_pts_ms : Int64) -> Option[Int]
```

## Verification

```sh
sh scripts/verify.sh packages/webm
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`8d8bfd8d095b7fb0b9051027e5013b04c03dc9cca7a384e0eb1cdecf15ec4c2d`):

```sh
pionc run packages/webm/wasm_smoke
pionc run --release packages/webm/wasm_smoke
pionc run --target wasm32 packages/webm/wasm_smoke
pionc run --target wasm32 --release packages/webm/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/webm/bench/run_bench.sh` against pure-Rust **`matroska-demuxer 0.6.1` (`--release`)** on real `ffmpeg`-encoded WebM corpora (VP9 + Opus, pure Opus audio, AV1 + Opus, and YouTube-style MSE Init + standalone Cluster Media Segment). Every track metadata line and every frame (`track_number`, `size`, `pts_ns`, `pts_ms`, `is_keyframe`, and per-frame payload FNV-1a 64-bit hash) is verified **100% byte-for-byte identical** via full-stdout SHA-256 across all rounds:

| Workload | `pion` Median (Throughput) | `rust_matroska` Median (Throughput) | `pion` Peak RSS | `rust_matroska` Peak RSS | `pion` vs `rust_matroska` | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| VP9 + Opus 12s WebM (563 KB × 200) | 12.852 ms (8761.93 MB/s) | 21.545 ms (5226.74 MB/s) | 3.39 MiB | 2.86 MiB | **1.68x** | `63ce66873b5cadea...` |
| Pure Opus 60s Audio WebM (959 KB × 200) | 17.994 ms (10653.33 MB/s) | 31.679 ms (6051.33 MB/s) | 4.25 MiB | 3.31 MiB | **1.76x** | `265c035f8bbcce75...` |
| AV1 + Opus 10s WebM (360 KB × 200) | 13.200 ms (5454.25 MB/s) | 19.635 ms (3666.69 MB/s) | 2.97 MiB | 2.59 MiB | **1.49x** | `5b30808c7978885e...` |
| YouTube MSE Init + Clusters (562 KB × 200) | 13.249 ms (8490.17 MB/s) | 20.020 ms (5618.56 MB/s) | 3.39 MiB | 3.30 MiB | **1.51x** | `90ce627eec08617d...` |
