# `sdp` (`v0.1.0`)

100% pure Pion implementation of **RFC 8866 (SDP)**, **RFC 8829 (JSEP)**, **RFC 8843 (BUNDLE)**, **RFC 8839 (ICE)**, and **RFC 8851/8853 (RID & Simulcast)** WebRTC Session Description parsing, validation, and canonical CRLF serialization — zero `extern "C"`, zero `World` dependency, explicit `Result[T, SdpError]`, and explicit `ParseLimits`.

## Features

- **Strict RFC 8866 Parsing & Lossless CRLF Serialization**:
  - Accepts both `\r\n` and `\n` input line endings; `serialize(desc)` always emits strict RFC 8866 `\r\n` line endings with 100% lossless roundtrip (`parse(serialize(parse(s))) == parse(s)`).
  - Enforces required session fields (`v=0` first, `o=`, `s=`, `t=`), `<single-lowercase-letter>=<value>` line format, rejects NUL (`0x00`), bare `\r`, and ASCII control characters, validates port ranges (`0..65535`), payload types (`0..127`), and `uint32` priority/SSRC bounds.
- **Allocation-Bomb Defense (`ParseLimits`)**:
  - Enforces `max_bytes` (default `1,048,576`), `max_lines` (default `16,384`), `max_media_sections` (default `256`), and `max_attributes_per_section` (default `4,096`).
  - **Strict Semantics**: any negative limit value is immediately rejected with `SdpError::LimitExceeded`; `0` strictly means 0 items/bytes/lines are allowed (not unlimited).
- **WebRTC / JSEP Structured Parsers**:
  - **ICE**: `parse_ice_candidate`, `format_ice_candidate`, `ice_candidates`, `ice_credentials` (JSEP media-level override with session-level fallback, Chrome `tcptype`/`generation`/`ufrag`/`network-id`/`network-cost` extensions).
  - **DTLS**: `fingerprint` (media-level preferred, session-level fallback), `dtls_setup` (`Active` / `Passive` / `Actpass` / `Holdconn`).
  - **RTP & Media**: `rtpmaps`, `fmtps`, `rtcp_fbs` (including wildcard `*`), `extmaps` (with optional direction and params), `ssrcs`, `ssrc_groups` (`FID`, `SIM`), `media_direction` (media-level -> session-level -> default `SendRecv`), `bundle_groups`, `media_mid`, `media_msids`, `has_rtcp_mux`, `has_rtcp_rsize`, `sctp_port`, `max_message_size`.
  - **Simulcast**: `rids`, `simulcast` (`send` / `recv` RID lists).
  - **High-Level Summary**: `extract_webrtc_summary(desc)` produces a complete per-m-line negotiation view for `RTCPeerConnection` Offer/Answer processing.

## Public API

```pion
pub val struct ParseLimits {
  pub max_bytes : Int
  pub max_lines : Int
  pub max_media_sections : Int
  pub max_attributes_per_section : Int
}

pub enum SdpError {
  EmptyInput
  LimitExceeded(String)
  InvalidLine(Int, String)
  InvalidSyntax(Int, String)
  MissingRequiredField(String)
}

pub fn parse(text : String) -> Result[SessionDescription, SdpError]
pub fn parse_with_limits(text : String, limits : ParseLimits) -> Result[SessionDescription, SdpError]
pub fn serialize(desc : SessionDescription) -> String
pub fn serialize_checked(desc : SessionDescription) -> Result[String, SdpError]
pub fn session_emails(desc : SessionDescription) -> Array[String]
pub fn session_phones(desc : SessionDescription) -> Array[String]
pub fn session_time_zones(desc : SessionDescription) -> Option[String]
pub fn session_encryption_key(desc : SessionDescription) -> Option[String]
pub fn parse_ice_candidate(value : String) -> Result[IceCandidate, SdpError]
pub fn format_ice_candidate(cand : IceCandidate) -> String
pub fn format_ice_candidate_checked(cand : IceCandidate) -> Result[String, SdpError]
pub fn ice_candidates(media : MediaDescription) -> Result[Array[IceCandidate], SdpError]
pub fn ice_credentials(session : SessionDescription, media_idx : Int) -> IceCredentials
pub fn fingerprint(session : SessionDescription, media_idx : Int) -> Option[DtlsFingerprint]
pub fn fingerprints(session : SessionDescription, media_idx : Int) -> Array[DtlsFingerprint]
pub fn dtls_setup(media : MediaDescription) -> Option[DtlsSetup]
pub fn rtpmaps(media : MediaDescription) -> Result[Array[RtpMap], SdpError]
pub fn fmtps(media : MediaDescription) -> Result[Array[Fmtp], SdpError]
pub fn rtcp_fbs(media : MediaDescription) -> Result[Array[RtcpFb], SdpError]
pub fn extmaps(media : MediaDescription) -> Result[Array[ExtMap], SdpError]
pub fn ssrcs(media : MediaDescription) -> Result[Array[SsrcAttr], SdpError]
pub fn ssrc_groups(media : MediaDescription) -> Result[Array[SsrcGroup], SdpError]
pub fn media_direction(session : SessionDescription, media_idx : Int) -> Direction
pub fn bundle_groups(session : SessionDescription) -> Array[BundleGroup]
pub fn media_mid(media : MediaDescription) -> Option[String]
pub fn media_msids(media : MediaDescription) -> Array[String]
pub fn has_rtcp_mux(media : MediaDescription) -> Bool
pub fn has_rtcp_rsize(media : MediaDescription) -> Bool
pub fn sctp_port(media : MediaDescription) -> Option[Int]
pub fn max_message_size(media : MediaDescription) -> Option[Int64]
pub fn rids(media : MediaDescription) -> Result[Array[Rid], SdpError]
pub fn simulcast(media : MediaDescription) -> Result[Option[Simulcast], SdpError]
pub fn extract_webrtc_summary(desc : SessionDescription) -> Result[WebRtcSummary, SdpError]
```

## Verification

```sh
sh scripts/verify.sh packages/sdp
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`99d3745ca2dd46449c415228825333d35a1cf35151244007f1d1e9e661e107a9`):

```sh
pionc run packages/sdp/wasm_smoke
pionc run --release packages/sdp/wasm_smoke
pionc run --target wasm32 packages/sdp/wasm_smoke
pionc run --target wasm32 --release packages/sdp/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/sdp/bench/run_bench.sh` against pure-Rust **`webrtc-rs/sdp 0.9.0` (`--release`)** on realistic Chrome / Google Meet Offer (`11,142 B`: audio + dual video + datachannel, BUNDLE, VP8/VP9/H.264/AV1/Opus, 12 `extmap`s, Simulcast `rid`/`simulcast`, `ssrc-group:SIM`/`FID`, 14 ICE candidates) and Google Meet SFU Answer (`9,370 B`: `ice-lite`, 10 bundled m-lines). Every workload verifies **100% byte-for-byte SHA-256 identity** on both the canonical structural summary and the full CRLF serialized SDP output:

| Workload | `pion` Median (Throughput) | `rust_sdp` Median (Throughput) | `pion` Peak RSS | `rust_sdp` Peak RSS | `pion` vs `rust_sdp` |
| --- | ---: | ---: | ---: | ---: | ---: |
| SDP Parse: Google Meet Offer (`11,142 B × 2000`) | 54.080 ms (412.06 MB/s) | 105.431 ms (211.36 MB/s) | 2.08 MiB | 2.53 MiB | **1.95x** |
| SDP Roundtrip: Google Meet Offer (`11,142 B × 2000`) | 87.608 ms (254.36 MB/s) | 127.865 ms (174.28 MB/s) | 2.30 MiB | 2.67 MiB | **1.46x** |
| SDP Roundtrip: Google Meet SFU Answer (`9,370 B × 2000`) | 85.317 ms (219.65 MB/s) | 141.306 ms (132.62 MB/s) | 2.31 MiB | 2.55 MiB | **1.66x** |

Verified SHA-256 digests:
- Offer Parse: `d03b8b7e2d4cc1fdcc47d783f29c2c1f9d336acb3b9a8c1ab2f2249af6f803d3`
- Offer Roundtrip: `0c05927a73b342f4444fec4f40c5f0f58653513106fab6110603c5ab08bee8f4`
- Answer Roundtrip: `800d9654378944c347b0d85bab2b89efb19e178517a72b5472364579cfb00669`
