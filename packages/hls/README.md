# `hls` (v0.1.0)

100% pure Pion RFC 8216 + LL-HLS (Low-Latency HLS) `.m3u8` Master (Multivariant) and Media Playlist parser, strict specification validator, ABR variant selector, timeline/key/map resolver, and deterministic injection-safe serializer — zero external dependencies, zero `extern "C"`, zero `World` dependency, zero mutable module globals (`Send`-safe and bit-identical across Native and Wasm32).

## Features

- **Auto-Classification & Strict RFC 8216 Validation (`parse_playlist`, `parse_playlist_with_limits`)**:
  - Optional UTF-8 BOM stripping, `\r\n` / `\n` line endings (rejects bare `\r` and NUL bytes), mandatory `#EXTM3U` header validation.
  - Strict Master vs Media classification: rejects playlists mixing Master-only and Media-only tags (`HlsError::MixedPlaylistTags`), missing `#EXT-X-TARGETDURATION`, duplicate singleton tags, duplicate attributes within a tag, unclosed quotes, and dangling `#EXTINF` / `#EXT-X-STREAM-INF` tags.
  - Exact integer representations for durations (`duration_us : Int64`), frame rates (`frame_rate_mhz : Int64`), start offsets (`time_offset_us : Int64`), and scores (`score_micros : Int64`) — zero `Double::to_string` usage for 100% Native/Wasm32 bit-determinism.
- **Master (Multivariant) Playlist Tags**:
  - `#EXT-X-VERSION`, `#EXT-X-INDEPENDENT-SEGMENTS`, `#EXT-X-START` (`TIME-OFFSET`, `PRECISE`), `#EXT-X-DEFINE` (`NAME`/`VALUE` with bounded `{$name}` variable substitution, `IMPORT`, `QUERYPARAM`).
  - `#EXT-X-STREAM-INF` (`BANDWIDTH`, `AVERAGE-BANDWIDTH`, `CODECS`, `RESOLUTION`, `FRAME-RATE`, `HDCP-LEVEL`, `AUDIO`/`VIDEO`/`SUBTITLES`/`CLOSED-CAPTIONS`, `SCORE`, `PATHWAY-ID`) + URI.
  - `#EXT-X-I-FRAME-STREAM-INF` (self-contained `URI` attribute, does not consume next line).
  - `#EXT-X-MEDIA` (`AUDIO | VIDEO | SUBTITLES | CLOSED-CAPTIONS`, `GROUP-ID`, `NAME`, `LANGUAGE`, `ASSOC-LANGUAGE`, `DEFAULT`, `AUTOSELECT`, `FORCED`, `INSTREAM-ID`, `CHARACTERISTICS`, `CHANNELS`, `URI`).
  - `#EXT-X-SESSION-DATA`, `#EXT-X-SESSION-KEY`.
- **Media Playlist & LL-HLS Tags**:
  - `#EXT-X-TARGETDURATION`, `#EXT-X-MEDIA-SEQUENCE`, `#EXT-X-DISCONTINUITY-SEQUENCE`, `#EXT-X-PLAYLIST-TYPE` (`EVENT | VOD`), `#EXT-X-ENDLIST`, `#EXT-X-I-FRAMES-ONLY`.
  - `#EXTINF:<duration>,[<title>]` (rejects negative/NaN/Inf durations), `#EXT-X-BYTERANGE:<n>[@<o>]` (RFC 8216 §4.3.2.2 implicit offset continuation on matching URI with overflow checks), `#EXT-X-DISCONTINUITY`, `#EXT-X-GAP`, `#EXT-X-PROGRAM-DATE-TIME` (strict ISO-8601 + leap-year calendar validation).
  - `#EXT-X-KEY` (`NONE | AES-128 | SAMPLE-AES | SAMPLE-AES-CTR`, `URI`, 128-bit `0x` hex `IV`, `KEYFORMAT`, `KEYFORMATVERSIONS`) and `#EXT-X-MAP` (`URI`, `BYTERANGE`) with segment scope inheritance.
  - `#EXT-X-DATERANGE` (`ID`, `CLASS`, `START-DATE`, `END-DATE`, `DURATION`, `PLANNED-DURATION`, `END-ON-NEXT`, `SCTE35-*`, `X-*` client attributes).
  - **LL-HLS**: `#EXT-X-SERVER-CONTROL`, `#EXT-X-PART-INF`, `#EXT-X-PART` (per-segment and trailing partial segments), `#EXT-X-PRELOAD-HINT`, `#EXT-X-RENDITION-REPORT`, `#EXT-X-SKIP`.
- **Playback & Packaging Utilities**:
  - `select_variant(master, max_bandwidth, preferred_codecs)` — adaptive bitrate (ABR) variant selection with codec prefix matching and graceful fallback.
  - `total_duration_ms(media)` / `total_duration_us(media)` & `resolve_media_sequence(media)` — computes exact per-segment media sequence, discontinuity sequence, cumulative `[start_us, end_us)`, and inherited active `EncryptionKey` & `MediaMap`.
  - `format_playlist` / `format_master_playlist` / `format_media_playlist` — deterministic round-trip serializer with CRLF/NUL/quote injection guards.
- **DoS & Security Guards (`HlsLimits`)**:
  - Explicit bounds on `max_input_bytes`, `max_lines`, `max_segments`, `max_variants`, `max_attributes`, `max_line_bytes`, and `max_custom_tags` (negative limits immediately fail with `HlsError::LimitExceeded`; `0` strictly permits 0 items; O(N) attribute scanning with zero backtracking).

## Quick Usage

```pion
import "hls"

match hls::parse_playlist(m3u8_text) {
  Ok(hls::Playlist::Master(master)) => {
    let best = hls::select_variant(master, 5000000L, ["hvc1", "avc1"])
    let _ = best
  }
  Ok(hls::Playlist::Media(media)) => {
    let dur_ms = hls::total_duration_ms(media)
    let resolved = hls::resolve_media_sequence(media)
    let _ = (dur_ms, resolved)
  }
  Err(e) => {
    let _ = hls::hls_error_to_string(e)
  }
}
```

## Verification & Benchmarks

```sh
sh scripts/verify.sh packages/hls
pionc run --target wasm32 packages/hls/wasm_smoke
sh packages/hls/bench/run_bench.sh
```

### 4-Mode Verification (`wasm_smoke`)

`packages/hls/wasm_smoke` builds cleanly and produces byte-identical output across `native debug`, `native --release`, `wasm32 debug`, and `wasm32 --release`:

- SHA-256 (all 4 modes): `a599093ca0ef7bed0c6fcfaae6679f95bca20daa6524865c212cf30cbdf60a33`
- Wasm32 binary size: `182,272 B` (debug), `179,748 B` (`--release`)

### Differential Oracle vs Rust `m3u8-rs 6.0.1`

Verified via `sh packages/hls/bench/run_bench.sh` (`bench/diff_oracle.py`) across **200** synthetic Master, Media (VOD/EVENT, explicit & implicit ByteRange, Key, Map, Discontinuity), and LL-HLS playlists (**2,350** field records):

- **Deviations**: `0 / 2,350` (**100.00% exact field match**).

### Fair Head-to-Head Benchmark vs Rust `m3u8-rs 6.0.1`

Measured on `Darwin arm64` (`sh packages/hls/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved, 3,500 playlists / 21.63 MB total input, byte-identical stdout SHA-256 `79b0e9cdc47d0b92698be972697b6d660bd8896edbf6cfc2f20e08b790d3bcce`):

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_m3u8_rs`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_hls` (`--release`) | 76.018 | 75.423 | 77.175 | 284.51 | 21719.45 | 3.91 MiB | **1.71x** |
| `rust_m3u8_rs` (`6.0.1 --release`) | 129.863 | 129.389 | 131.628 | 166.54 | 37103.57 | 3.55 MiB | 1.00x (baseline) |
