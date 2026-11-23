# `rtp` (`v0.1.0`)

100% pure-Pion implementation of **RFC 3550 RTP / RTCP**, **RFC 5285 RTP Header Extensions**, **RFC 4585 / RFC 5104 / REMB RTCP Feedback**, **RFC 3711 SRTP / SRTCP**, **RFC 7714 AEAD-AES-128-GCM**, and **RFC 7983 RTP/RTCP Demux** — zero `extern "C"`, zero `World`, portable across Native and `wasm32`.

## Features

- **RFC 3550 & RFC 5285 RTP Codec (`src/rtp.pion`)**:
  - Strict 12-byte fixed header validation (`version == 2`, padding, extension, marker, CSRC count, payload type `0..127`, 16-bit sequence number, 32-bit timestamp, 32-bit SSRC), CSRC list, and padding length validation (`1 <= pad_len <= payload_bytes`).
  - **RFC 5285 Header Extensions**: full **One-Byte (`0xBEDE`)** (including `0x00` padding and `ID=15` early terminator) and **Two-Byte (`0x1000..0x100F`)** extension parsing and marshaling (`mid`, `abs-send-time`, `transport-wide-cc`, `audio-level`, `video-orientation`, etc.).
  - **RFC 7983 / RFC 5761 Demux**: `is_rtp_packet(data)` and `is_rtcp_packet(data)` distinguishing RTP, RTCP (first byte `128..191`, second byte PT `64..95`), STUN, and DTLS.
- **RFC 3550 & RFC 4585 & RFC 5104 RTCP Compound Codec (`src/rtcp.pion`)**:
  - Multi-packet compound RTCP decode and encode:
    - **SR (`PT=200`)** with NTP/RTP timestamps, packet/octet counters, and Reception Reports (signed 24-bit `total_lost`).
    - **RR (`PT=201`)** with Reception Reports.
    - **SDES (`PT=202`)** with 32-bit aligned chunks (`CNAME`, etc.).
    - **BYE (`PT=203`)** with SSRC list and optional reason.
    - **RTPFB (`PT=205`)**: **Generic NACK (`FMT=1`)** (`NackPair::packet_list()` with 16-bit wraparound) and **TWCC (`FMT=15`)** raw FCI passthrough.
    - **PSFB (`PT=206`)**: **PLI (`FMT=1`)**, **FIR (`FMT=4`)**, and **REMB (`FMT=15`)** (exponent + 18-bit mantissa bitrate).
- **RFC 3711 SRTP / SRTCP & RFC 7714 AEAD-AES-128-GCM (`src/srtp.pion`)**:
  - **Key Derivation (RFC 3711 §4.3.1 / RFC 7714 §13)**: derives `enc_key`, `auth_key`, `salt` for SRTP (labels `0x00..0x02`) and SRTCP (labels `0x03..0x05`); verified against **RFC 3711 Appendix B.3** official test vectors.
  - **Protection Profiles**:
    - `ProtectionProfile::Aes128CmHmacSha1_80` (RFC 3711, mandatory WebRTC baseline, 10-byte auth tag).
    - `ProtectionProfile::Aes128CmHmacSha1_32` (RFC 3711, 4-byte RTP auth tag / 10-byte RTCP auth tag).
    - `ProtectionProfile::AeadAes128Gcm` (RFC 7714, Chrome / Google Meet preferred suite, 12-byte IV, header AAD, 16-byte GCM tag); verified against **RFC 7714 §16.1.1** official test vector.
  - **ROC & Replay Protection**: per-SSRC 48-bit packet index estimation (RFC 3711 Appendix A) across 16-bit sequence wraparound, 64-packet sliding replay window for both SRTP and SRTCP, and constant-time MAC/tag verification via `crypto::constant_time_eq` before decrypting or updating replay state.

### Cryptographic Dependencies & In-Package Primitives

- Reuses `packages/crypto` (`v0.2.0`): `crypto::Sha1`, `crypto::sha1`, `crypto::constant_time_eq`, `crypto::bytes_to_hex`, `crypto::hex_to_bytes`.
- Because `packages/crypto` `v0.2.0` does not yet expose AES-128, AES-128-CTR, AES-128-GCM, or HMAC-SHA1, `packages/rtp/src/crypto_prim.pion` provides 100% pure-Pion implementations of FIPS 197 AES-128, AES-128-CTR, NIST SP 800-38D AES-128-GCM (with a per-context 4-bit Shoup GHASH table), and RFC 2104 HMAC-SHA1 (built on `crypto::Sha1` with precomputed pads).

### `DecodeLimits` Semantics

- Any negative field (`< 0`) is rejected immediately with `Err(RtpError::LimitExceeded(...))`.
- A `0` limit strictly allows `0` items of that category (never unlimited).

## Public API

```pion
pub val struct DecodeLimits { ... }
pub enum RtpError { ... }
pub fn rtp_error_message(err : RtpError) -> String

// RFC 7983 Demux & RFC 3550/5285 RTP
pub fn is_rtp_packet(data : Bytes) -> Bool
pub fn is_rtcp_packet(data : Bytes) -> Bool
pub fn rtp_header_len(data : Bytes) -> Result[Int, RtpError]
pub fn parse_rtp(data : Bytes) -> Result[RtpPacket, RtpError]
pub fn parse_rtp_with_limits(data : Bytes, limits : DecodeLimits) -> Result[RtpPacket, RtpError]
pub fn marshal_rtp(pkt : RtpPacket) -> Result[Bytes, RtpError]
pub fn RtpHeader::get_extension(self : RtpHeader, id : Int) -> Option[Bytes]

// RFC 3550/4585/5104 RTCP
pub fn NackPair::packet_list(self : NackPair) -> Array[Int]
pub fn parse_rtcp(data : Bytes) -> Result[Array[RtcpPacket], RtpError]
pub fn parse_rtcp_with_limits(data : Bytes, limits : DecodeLimits) -> Result[Array[RtcpPacket], RtpError]
pub fn marshal_rtcp_packet(pkt : RtcpPacket) -> Result[Bytes, RtpError]
pub fn marshal_rtcp(packets : Array[RtcpPacket]) -> Result[Bytes, RtpError]

// RFC 3711 / RFC 7714 SRTP & SRTCP
pub enum ProtectionProfile { Aes128CmHmacSha1_80, Aes128CmHmacSha1_32, AeadAes128Gcm }
pub fn derive_srtp_keys(profile : ProtectionProfile, master_key : Bytes, master_salt : Bytes) -> Result[SrtpSessionKeys, RtpError]
pub fn derive_srtcp_keys(profile : ProtectionProfile, master_key : Bytes, master_salt : Bytes) -> Result[SrtpSessionKeys, RtpError]
pub fn SrtpContext::new(profile : ProtectionProfile, master_key : Bytes, master_salt : Bytes) -> Result[SrtpContext, RtpError]
pub fn SrtpContext::from_session_keys(profile : ProtectionProfile, srtp_keys : SrtpSessionKeys, srtcp_keys : SrtpSessionKeys) -> Result[SrtpContext, RtpError]
pub fn SrtpContext::get_roc(self : SrtpContext, ssrc : UInt) -> UInt
pub fn SrtpContext::set_roc(self : SrtpContext, ssrc : UInt, roc : UInt) -> Unit
pub fn SrtpContext::encrypt_rtp(self : SrtpContext, plaintext_rtp : Bytes) -> Result[Bytes, RtpError]
pub fn SrtpContext::decrypt_rtp(self : SrtpContext, srtp_packet : Bytes) -> Result[Bytes, RtpError]
pub fn SrtpContext::encrypt_rtcp(self : SrtpContext, plaintext_rtcp : Bytes) -> Result[Bytes, RtpError]
pub fn SrtpContext::decrypt_rtcp(self : SrtpContext, srtcp_packet : Bytes) -> Result[Bytes, RtpError]
```

## Verification

- **Unit & Official RFC Vectors**: `sh scripts/verify.sh packages/rtp` — **10 / 10 `rtp` tests** (+ 69 / 69 `crypto` tests = **79 / 79 passing**), 0 diagnostics, `pionc fmt --check` clean.
  - RFC 3711 Appendix B.3 key derivation vector: **exact match** (`c61e7a93...`, `30cbbc08...`, `cebe321f...`).
  - RFC 7714 §16.1.1 `AEAD_AES_128_GCM` SRTP vector: **exact match** (ciphertext + 16-byte GCM tag).
  - 16-bit sequence wraparound ROC (`65534 -> 65535 -> 0 -> 1` + late `65535`), 64-packet replay window boundary, duplicate replay rejection, and ciphertext/AAD tamper rejection: **all passing**.

### 4-Mode `wasm_smoke` Parity

All four modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with byte-identical stdout SHA-256 (`c3a2d66488cca9c4081842e59c038cd64b9f3e05289e0b76307f48fcafe9d27f`):

```sh
pionc run packages/rtp/wasm_smoke
pionc run --release packages/rtp/wasm_smoke
pionc run --target wasm32 packages/rtp/wasm_smoke
pionc run --target wasm32 --release packages/rtp/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/rtp/bench/run_bench.sh` against Rust **`webrtc-rs`** (`rtp 0.12.0`, `rtcp 0.12.0`, `webrtc-srtp 0.14.0`, `--release`), strictly interleaved with mandatory byte-for-byte stdout SHA-256 verification across all rounds (proving exact wire and cryptographic interoperability):

| Workload | Pion Median (ms) | Rust `webrtc-rs` Median (ms) | Pion Rate / Throughput | Pion Peak RSS | Rust Peak RSS | Speedup vs Rust | Stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| RTP Parse + Marshal (1,200 B + 3 RFC 5285 1-byte exts × 50,000) | 67.424 | 20.408 | 1,348.47 ns/op | 1.81 MiB | 2.08 MiB | 0.30x | `1490e46b1e6d14d1…` (exact) |
| RTCP Compound Parse + Marshal (SR + PLI + NACK × 50,000) | 40.725 | 34.992 | 814.50 ns/op | 1.84 MiB | 2.23 MiB | 0.86x | `5727aeb0e46e2972…` (exact) |
| SRTP `AES128_CM_HMAC_SHA1_80` Protect + Unprotect (5,000 × 1,200 B = 12 MB) | 197.334 | 77.116 | 60.81 MB/s | 1.86 MiB | 2.08 MiB | 0.39x | `3a80d94aed49bb1f…` (exact) |
| SRTP `AEAD_AES_128_GCM` Protect + Unprotect (5,000 × 1,200 B = 12 MB) | 180.782 | 79.465 | 66.38 MB/s | 1.84 MiB | 2.11 MiB | 0.44x | `9709ef15a59a9dfc…` (exact) |

**Honest runtime & hardware notes**:
- On RTCP compound parse + marshal, pure Pion reaches **0.86×** of Rust `webrtc-rs/rtcp` while using lower Peak RSS (`1.84 MiB` vs `2.23 MiB`).
- On RTP 1,200 B parse + marshal, Rust `webrtc-rs/rtp` uses reference-counted zero-copy `bytes::Bytes::slice()` for the 1,172-byte payload, whereas Pion's `parse_rtp` currently copies the payload into an owned `Bytes` slice (`0.30×`).
- On SRTP `AES128_CM_HMAC_SHA1_80` (`60.81 MB/s`, `0.39×`) and `AEAD_AES_128_GCM` (`66.38 MB/s`, `0.44×`), Rust `webrtc-srtp` uses the `aes`/`aes-gcm`/`sha1` crates with ARMv8 hardware AES/PMULL/SHA1 intrinsics on Apple Silicon, whereas `packages/rtp` runs 100% pure-Pion portable scalar code (identical on Native and `wasm32`) and still sustains **>60 MB/s** (>480 Mbps — over 100× a typical 4 Mbps 1080p Google Meet video stream).
