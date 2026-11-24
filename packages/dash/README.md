# `dash` (v0.1.0)

100% pure Pion **ISO/IEC 23009-1 MPEG-DASH** (`.mpd`) manifest parser, hierarchical `BaseURL` + `SegmentTemplate`/`SegmentTimeline` URL expander, ABR representation selector, and deterministic XML serializer — zero external dependencies, zero `extern "C"`, zero `World`, zero mutable globals, zero `Double::to_string`, and Native + Wasm32 portable.

## Features

- **Security-Hardened Embedded XML Parser (`src/xml_lexer.pion`)**:
  - Explicitly rejects `<!DOCTYPE` and `<!ENTITY` declarations (`DashError::SecurityRejected`) to eliminate XXE and Billion Laughs entity-expansion attacks at the root.
  - Handles UTF-8 BOM, `<?xml ...?>`, processing instructions, comments (rejecting `--` inside comments), `<![CDATA[...]]>`, the 5 predefined XML entities (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`), decimal/hex numeric character references (`&#...;` / `&#x...;`) with strict XML 1.0 Unicode scalar validation, namespace prefixes, self-closing tags, duplicate attribute rejection, and illegal XML 1.0 control-character rejection.
  - Enforces configurable `DashLimits` (`max_input_bytes`, `max_xml_depth`, `max_elements`, `max_attributes`, `max_periods`, `max_adaptation_sets`, `max_representations`, `max_segments`, `max_timeline_entries`, `max_text_bytes`, `max_output_bytes`); negative limits immediately return `Err(DashError::LimitExceeded(_))`, and `0` strictly permits 0 items.
- **Complete ISO/IEC 23009-1 MPD Model (`src/types.pion`, `src/mpd.pion`)**:
  - `<MPD>`: `id`, `type` (`static | dynamic`), `profiles`, `mediaPresentationDuration`, `minBufferTime`, `minimumUpdatePeriod`, `availabilityStartTime`, `publishTime`, `timeShiftBufferDepth`, `suggestedPresentationDelay`, `maxSegmentDuration`, `<BaseURL>`, `<Location>`, `<UTCTiming>`.
  - `<Period>`: `id`, `start`, `duration`, `bitstreamSwitching`, `<BaseURL>`, `<SegmentBase>` / `<SegmentList>` / `<SegmentTemplate>` inheritance.
  - `<AdaptationSet>`: `id`, `group`, `contentType` (`video | audio | text | image | Other`), `mimeType`, `codecs`, `lang`, `segmentAlignment`, `subsegmentAlignment`, `bitstreamSwitching`, `minBandwidth`/`maxBandwidth`, `minWidth`/`maxWidth`, `minHeight`/`maxHeight`, `par`, `frameRate`, `sar`, `audioSamplingRate`, `startWithSAP`, `<BaseURL>`, `<Role>`, `<ContentProtection>` (`schemeIdUri`, `value`, `cenc:default_KID`, `<cenc:pssh>`), `<Accessibility>`, `<AudioChannelConfiguration>`, `<SupplementalProperty>`, `<EssentialProperty>`.
  - `<Representation>`: required `id` and positive `bandwidth` (overflow-checked), `width`/`height`, rational `frameRate` (`30` / `30000/1001`), `sar`, `codecs`, `mimeType`, `audioSamplingRate`, `startWithSAP`, `<BaseURL>`, `<ContentProtection>`, `<AudioChannelConfiguration>`, `<SegmentBase>`, `<SegmentList>`, `<SegmentTemplate>`.
- **Exact Integer Time & Rational Arithmetic (`src/time.pion`)**:
  - `parse_iso8601_duration_us` / `format_iso8601_duration_us`: exact `Int64` microsecond duration parsing (`P[nY][nM][nW][nD][T[nH][nM][n[.frac]S]]`) with overflow and negative rejection.
  - `parse_iso8601_datetime_us`: strict ISO-8601 UTC/offset calendar validation including Gregorian leap-year rules (`2024-02-29` valid, `2023-02-29` / `1900-02-29` rejected).
  - `parse_rational` / `format_rational`: exact integer `num/den` rational representation.
- **Segment Resolution & ABR Engine (`src/resolve.pion`, `src/abr.pion`, `src/format.pion`)**:
  - `resolve_url`: RFC 3986 hierarchical `BaseURL` resolution across `MPD` → `Period` → `AdaptationSet` → `Representation` → segment.
  - `expand_template`: ISO/IEC 23009-1 §5.3.9.4.4 expansion for `$$`, `$RepresentationID$`, `$Number[%0Nd]$`, `$Bandwidth[%0Nd]$`, `$Time[%0Nd]$`, with strict format-width cap (≤ 32 digits) to prevent width OOM/CPU bombs.
  - `resolve_segments`: resolves `SegmentTemplate` (both `<SegmentTimeline>` with `r=0`, `r>0`, `r<0` and duration-based templates), `SegmentList`, and `SegmentBase` with `Period` → `AdaptationSet` → `Representation` inheritance, strict `limits.max_segments` capping, and checked `Int64` accumulation.
  - `select_representation`: codec-aware ABR representation selector for `max_bandwidth` and `preferred_codecs`.
  - `format_mpd`: deterministic, injection-safe XML serializer with strict attribute/text escaping and illegal control-character rejection.

## Usage

```pion
import "dash"

let mpd = match dash::parse(mpd_xml) {
  Ok(m) => m
  Err(e) => ...
}
let aset = mpd.periods[0].adaptation_sets[0]
let rep_idx = match dash::select_representation(aset, 4000000L, ["av01", "avc1"]) {
  Some(i) => i
  None => 0
}
let track = dash::resolve_segments(mpd, 0, 0, rep_idx, dash::DashLimits::default())
```

## Verification & Differential Parity

```sh
sh scripts/verify.sh packages/dash
pionc run --target wasm32 packages/dash/wasm_smoke
sh packages/dash/bench/run_bench.sh
```

- **Unit & Red-Team Test Suite (`packages/dash/src/dash_test.pion`)**: **26** test groups passing (`pionc test --json packages/dash`), covering static VOD `SegmentBase`, dynamic live `SegmentTemplate` + `SegmentTimeline` (`r=0`, `r>0`, `r=-1`, PTO), duration-based `SegmentTemplate`, `SegmentList`, `Period`-level inheritance & timing inference, DRM `ContentProtection`/`cenc:pssh`/`mspr:pro`, ISO-8601 duration/datetime/leap years, rational frame rates, multi-codec ABR selection, namespace-aware matching, canonical XML roundtrip, and red-team DoS/security cases (XXE, Billion Laughs, `r=999999999`, `$Number%999999999d$`, deep XML nesting, `Int64` overflow, negative/zero limits, invalid numeric char refs, control characters, aggregate URL output byte cap).

## Concurrency & `Send` Guarantees

Verified with `pionc check` across a `spawn` boundary:

- **`Send` value / config types (10)**: `DashLimits` is `Send`, `DashError` is `Send`, `Rational` is `Send`, `MpdType` is `Send`, `ContentType` is `Send`, `Descriptor` is `Send`, `SegmentBase` is `Send`, `SegmentUrl` is `Send`, `SegmentTimelineEntry` is `Send`, and `ResolvedSegment` is `Send`.
- **`!Send` container types (8, holding `Array[T]`)**: `Mpd`, `Period`, `AdaptationSet`, `Representation`, `SegmentTemplate`, `SegmentList`, `ContentProtection`, and `ResolvedTrack`. To transfer these across `spawn`, transfer ownership with `move v` into the spawned closure, or serialize an `Mpd` to `String` via `format_mpd` and re-parse in the worker.
- **Differential Parity vs Rust `dash-mpd-core v0.1.0` (the core MPD parser crate of `dash-mpd v0.21.0`, locked `Cargo.lock`)**:
  - **60 / 60** synthetic MPD manifests (15 static `SegmentBase`, 15 dynamic live `SegmentTemplate`+`SegmentTimeline`, 15 multi-`Period` DRM with Widevine/PlayReady `cenc:pssh`, 15 `SegmentList`), field-by-field comparison across `MPD`, `Period`, `AdaptationSet`, `Role`, `ContentProtection`/`pssh`, `SegmentTemplate`/`SegmentTimeline`, `Representation`, `SegmentBase`, and `SegmentList`: **0 divergences**.
- **4-Mode Verification (`packages/dash/wasm_smoke`)**:
  - `native debug`, `native --release`, `wasm32 debug` (**217 KiB**), `wasm32 --release` (**210 KiB**) all compile cleanly and emit byte-identical stdout:
  - `dash_wasm_smoke:ok`
  - `summary=PT1H2M3.5S|1709209845000000|1|https://cdn.example.com/stream/av1_1080/init.mp4|https://cdn.example.com/stream/av1_1080/chunk_0004_12000.m4s|1256|xxe_blocked fnv64=c1ae0a91eab891cb`
  - SHA-256: `2ce81a010a29ef5fc9e0715fb3a1c7af049a3ebea6ed2c41549a1b08074ec625`

### Head-to-Head Benchmark vs Rust `dash-mpd-core v0.1.0` (`--release`)

Measured on `Darwin arm64` (`sh packages/dash/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved, stdout SHA-256 verified identical across all implementations and rounds: `a3b2d1251c237963f906d078a0d9db5daf1b579f080af22dc3753e1412cae7ba`):

| Workload | `pion_dash` Median (ms) | `pion_dash` Throughput / ns/op | Rust `dash-mpd-core` Median (ms) | Rust Throughput / ns/op | Speedup | Peak RSS (Pion / Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| MPEG-DASH MPD Parsing (60 manifests × 200 = 12,000 ops, 24.0 MB) | 182.990 | 131.13 MB/s (15,249.21 ns/op) | 239.811 | 100.06 MB/s (19,984.27 ns/op) | **1.31x** | **2.88 MiB** / 8.56 MiB |
