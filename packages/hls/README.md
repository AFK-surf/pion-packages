# `hls` (v0.1.0)

100% pure Pion RFC 8216 + RFC 8216bis LL-HLS (Low-Latency HLS) `.m3u8` Master (Multivariant) and Media Playlist parser, strict specification validator, ABR variant selector, timeline/key/map resolver, and deterministic injection-safe serializer — zero external dependencies, zero `extern "C"`, zero `World` dependency, zero mutable module globals (bit-identical across Native and Wasm32; scalar/value types such as `HlsLimits`, `HlsError`, `EncryptionKey`, `VariantStream`, and `ResolvedSegment` are `Send`, while container AST types holding `Array` fields — `Playlist`, `MasterPlaylist`, `MediaPlaylist`, `MediaSegment`, `DateRange` — are `!Send` per Pion's `Array` concurrency rules and can be handed to a `spawn` closure only by ownership transfer (`move`), or serialized with `format_playlist` and sent as a `String`).

## Features

- **Auto-Classification & Strict RFC 8216bis Validation (`parse_playlist`, `parse_playlist_with_limits`, `parse_playlist_with_context`)**:
  - Optional UTF-8 BOM stripping, `\r\n` / `\n` line endings (rejects bare `\r`, CR at EOF without LF, NUL, ASCII/C1 control characters), mandatory `#EXTM3U` header validation.
  - Strict Master vs Media classification: rejects playlists mixing Master-only and Media-only tags (`HlsError::MixedPlaylistTags`), missing `#EXT-X-TARGETDURATION`, duplicate singleton tags, duplicate attributes within a tag, unclosed quotes, quoted enumerated/numeric values, and dangling `#EXTINF` / `#EXT-X-STREAM-INF` tags.
  - Cross-tag MUST constraints: rounded `#EXTINF` ≤ `#EXT-X-TARGETDURATION`, `#EXT-X-MEDIA-SEQUENCE`/`#EXT-X-DISCONTINUITY-SEQUENCE` before first segment, `#EXT-X-MEDIA` group/attribute rules (`FORCED`/`INSTREAM-ID`/`CHANNELS`, unique `NAME` per group, variant group references, `CLOSED-CAPTIONS=NONE` consistency), LL-HLS `PART-INF`/`PART-HOLD-BACK`/`CAN-SKIP-UNTIL`/`HOLD-BACK` invariants, `METHOD=NONE` forbidding extra attributes, and `#EXT-X-MAP` requiring explicit `@offset`.
  - Exact integer representations for durations (`duration_us : Int64`), frame rates (`frame_rate_mhz : Int64`), start offsets (`time_offset_us : Int64`), and scores (`score_micros : Int64`) with overflow checks — zero `Double::to_string` usage for 100% Native/Wasm32 bit-determinism.
- **Master (Multivariant) Playlist Tags**:
  - `#EXT-X-VERSION`, `#EXT-X-INDEPENDENT-SEGMENTS`, `#EXT-X-START` (`TIME-OFFSET`, `PRECISE`), `#EXT-X-DEFINE` (`NAME`/`VALUE` with O(1) map lookup and aggregate-budgeted `{$name}` substitution across all quoted-string/hex fields, plus `IMPORT`/`QUERYPARAM` via `parse_playlist_with_context`).
  - `#EXT-X-STREAM-INF` (`BANDWIDTH`, `AVERAGE-BANDWIDTH`, `CODECS`, `RESOLUTION`, `FRAME-RATE`, `HDCP-LEVEL`, `AUDIO`/`VIDEO`/`SUBTITLES`/`CLOSED-CAPTIONS`, `SCORE`, `PATHWAY-ID`) + URI.
  - `#EXT-X-I-FRAME-STREAM-INF` (self-contained `URI` attribute, does not consume next line).
  - `#EXT-X-MEDIA` (`AUDIO | VIDEO | SUBTITLES | CLOSED-CAPTIONS`, `GROUP-ID`, `NAME`, `LANGUAGE`, `ASSOC-LANGUAGE`, `DEFAULT`, `AUTOSELECT`, `FORCED`, `INSTREAM-ID`, `CHARACTERISTICS`, `CHANNELS`, `URI`).
  - `#EXT-X-SESSION-DATA`, `#EXT-X-SESSION-KEY`.
- **Media Playlist & LL-HLS Tags**:
  - `#EXT-X-TARGETDURATION`, `#EXT-X-MEDIA-SEQUENCE`, `#EXT-X-DISCONTINUITY-SEQUENCE`, `#EXT-X-PLAYLIST-TYPE` (`EVENT | VOD`), `#EXT-X-ENDLIST`, `#EXT-X-I-FRAMES-ONLY`.
  - `#EXTINF:<duration>,[<title>]` (rejects negative/NaN/Inf/overflow durations), `#EXT-X-BYTERANGE:<n>[@<o>]` (implicit offset continuation on matching URI with overflow checks), `#EXT-X-DISCONTINUITY`, `#EXT-X-GAP`, `#EXT-X-PROGRAM-DATE-TIME` (ISO-8601 calendar validation with optional/basic/extended timezone offsets).
  - `#EXT-X-KEY` (`NONE | AES-128 | SAMPLE-AES | SAMPLE-AES-CTR`, `URI`, 128-bit `0x` hex `IV`, `KEYFORMAT`, `KEYFORMATVERSIONS`) supporting multi-`KEYFORMAT` (multi-DRM) coexistence and `#EXT-X-MAP` (`URI`, `BYTERANGE`) with segment scope inheritance and relative KEY/MAP ordering.
  - `#EXT-X-DATERANGE` (`ID`, `CLASS`, `START-DATE`, `END-DATE`, `DURATION`, `PLANNED-DURATION`, `END-ON-NEXT`, `SCTE35-*`, `X-*` client attributes).
  - **LL-HLS**: `#EXT-X-SERVER-CONTROL`, `#EXT-X-PART-INF`, `#EXT-X-PART` (per-segment and trailing partial segments with implicit `BYTERANGE` offset resolution), `#EXT-X-PRELOAD-HINT`, `#EXT-X-RENDITION-REPORT`, `#EXT-X-SKIP`.
- **Playback & Packaging Utilities**:
  - `select_variant(master, max_bandwidth, preferred_codecs)` — adaptive bitrate (ABR) variant selection with codec prefix matching and graceful fallback.
  - `total_duration_ms(media)` / `total_duration_us(media)`, `resolve_media_sequence(media)` (with `EXT-X-SKIP` delta MSN offset and saturating Int64 arithmetic), and `resolve_segment_keys(media)` (full per-`KEYFORMAT` multi-DRM active keys).
  - `format_playlist` / `format_master_playlist` / `format_media_playlist` — deterministic round-trip serializer with control-char/quote/reserved-tag/`X-` attribute injection guards and positional preservation of per-segment custom tags and KEY/MAP order.
- **DoS & Security Guards (`HlsLimits`)**:
  - Explicit bounds on `max_input_bytes`, `max_lines`, `max_segments`, `max_variants`, `max_attributes`, `max_line_bytes`, `max_custom_tags`, `max_expanded_bytes`, `max_parts`, `max_defines`, `max_dateranges`, `max_preload_hints`, `max_rendition_reports`, and `max_media` (negative limits immediately fail with `HlsError::LimitExceeded`; `0` strictly permits 0 items; O(N) attribute scanning and O(1) variable lookup).

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

- SHA-256 (all 4 modes): `ccb403999c3dd751365666e2813bb49a01ea55e6fd3bfe0c34a52f4ebb4fb933`
- Wasm32 binary size: `237,697 B` (debug), `235,971 B` (`--release`)

### Differential Oracle vs Rust `m3u8-rs 6.0.1`

Verified via `sh packages/hls/bench/run_bench.sh` (`bench/diff_oracle.py`) across **200** synthetic valid Master, Media (VOD/EVENT, explicit & implicit ByteRange, Key, Map, Discontinuity), and LL-HLS playlists (**2,350** field records). Note that `m3u8-rs` is a lenient parser rather than a validator and the Rust harness computes implicit byte-range offsets itself:

- **Deviations**: `0 / 2,350` (**100.00% exact field match** on the shared field subset).

### Fair Head-to-Head Benchmark vs Rust `m3u8-rs 6.0.1`

Measured on `Darwin arm64` (`sh packages/hls/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved, 3,500 playlists / 21.63 MB total input, byte-identical stdout SHA-256 `79b0e9cdc47d0b92698be972697b6d660bd8896edbf6cfc2f20e08b790d3bcce`):

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_m3u8_rs`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion_hls` (`--release`) | 110.403 | 105.946 | 119.837 | 195.90 | 31543.67 | 4.06 MiB | **1.35x** |
| `rust_m3u8_rs` (`6.0.1 --release`) | 149.593 | 147.403 | 173.834 | 144.58 | 42740.95 | 4.28 MiB | 1.00x (baseline) |

On a second corpus (`audit/diff/altbench.py` — long URLs, `EXT-X-PROGRAM-DATE-TIME` per segment, key rotation, and explicit byte ranges; byte-identical stdout SHA-256 `5435f14cac58923a0ea773283d88c4212c0bd043e4e3d5f1150582c4e6a482e4`), `pion_hls` runs at **0.84x** vs `rust_m3u8_rs` (160.646 ms / 263.23 MB/s vs 135.219 ms / 312.73 MB/s) with higher peak RSS (27.45 MiB vs 15.28 MiB) due to full strict RFC 8216bis validation, ISO-8601 checking, and per-segment metadata retention.
