# `rtp` (`v0.1.0`)

100% pure-Pion implementation of **RFC 3550 RTP / RTCP**, **RFC 5285 RTP Header Extensions**, **RFC 4585 / RFC 5104 / REMB RTCP Feedback**, **RFC 3711 SRTP / SRTCP**, **RFC 7714 AEAD-AES-128-GCM**, and **RFC 7983 RTP/RTCP Demux** — zero `extern "C"`, zero `World`, portable across Native and `wasm32`.

## Features

- **RFC 3550 & RFC 5285 RTP Codec (`src/rtp.pion`)**:
  - Strict 12-byte fixed header validation (`version == 2`, padding, extension, marker, CSRC count, payload type `0..127`, 16-bit sequence number, 32-bit timestamp, 32-bit SSRC), CSRC list, and padding length validation (`1 <= pad_len <= payload_bytes`).
  - **RFC 5285 Header Extensions**: full **One-Byte (`0xBEDE`)** (including `0x00` padding and `ID=15` early terminator) and **Two-Byte (`0x1000..0x100F`)** extension parsing and marshaling (`mid`, `abs-send-time`, `transport-wide-cc`, `audio-level`, `video-orientation`, etc.). `marshal_rtp` validates field wire widths (`sequence_number`, `extension_profile`) and rejects extension blocks exceeding the 16-bit word limit (`65535 * 4` bytes).
  - **RFC 7983 / RFC 5761 Demux**: `is_rtp_packet(data)` and `is_rtcp_packet(data)` distinguishing RTP, RTCP (first byte `128..191`, second byte PT `64..95`), STUN, and DTLS.
- **RFC 3550 & RFC 4585 & RFC 5104 RTCP Compound Codec (`src/rtcp.pion`)**:
  - Multi-packet compound RTCP decode and encode with strict wire-width range validation on marshal:
    - **SR (`PT=200`)** with NTP/RTP timestamps, packet/octet counters, and Reception Reports (signed 24-bit `total_lost`).
    - **RR (`PT=201`)** with Reception Reports.
    - **SDES (`PT=202`)** with 32-bit aligned chunks (`CNAME`, etc.).
    - **BYE (`PT=203`)** with SSRC list and optional reason.
    - **RTPFB (`PT=205`)**: **Generic NACK (`FMT=1`)** (`NackPair::packet_list()` with 16-bit wraparound) and **TWCC (`FMT=15`)** raw FCI passthrough.
    - **PSFB (`PT=206`)**: **PLI (`FMT=1`)**, **FIR (`FMT=4`)**, and **REMB (`FMT=15`)** (exponent + 18-bit mantissa bitrate with `UInt64` overflow saturation).
- **RFC 3711 SRTP / SRTCP & RFC 7714 AEAD-AES-128-GCM (`src/srtp.pion`)**:
  - **Key Derivation (RFC 3711 §4.3.1 / RFC 7714 §13)**: derives `enc_key`, `auth_key`, `salt` for SRTP (labels `0x00..0x02`) and SRTCP (labels `0x03..0x05`); verified against **RFC 3711 Appendix B.3** official test vectors. `from_session_keys` enforces exact key/salt/HMAC-key lengths (`16B` AES key, `14B`/`12B` salt, `20B` HMAC-SHA1 auth key).
  - **Protection Profiles**:
    - `ProtectionProfile::Aes128CmHmacSha1_80` (RFC 3711, mandatory WebRTC baseline, 10-byte auth tag).
    - `ProtectionProfile::Aes128CmHmacSha1_32` (RFC 3711, 4-byte RTP auth tag / 10-byte RTCP auth tag).
    - `ProtectionProfile::AeadAes128Gcm` (RFC 7714, Chrome / Google Meet preferred suite, 12-byte IV, header AAD, 16-byte GCM tag); verified against **RFC 7714 §16.1.1** official test vector.
  - **Per-SSRC ROC, Replay Protection & Re-Key Barriers**:
    - O(1) open-addressed SSRC state table (capped at 4,096 authenticated SSRCs). `decrypt_rtp` and `decrypt_rtcp` perform read-only lookup and constant-time tag verification (`crypto::constant_time_eq`) **before** allocating or mutating any per-SSRC state, defeating unauthenticated SSRC-flood DoS.
    - Per-SSRC 48-bit packet index estimation (RFC 3711 Appendix A) across 16-bit sequence wraparound and per-SSRC 64-packet sliding replay windows for **both** SRTP and SRTCP (with independent per-SSRC SRTCP send counters).
    - Send-side replay/nonce-reuse guard (`encrypt_rtp` refuses re-encrypting an already-used `(SSRC, ROC, seq)`) and hard re-key barriers when 32-bit SRTP ROC (`0xFFFFFFFF`) or 31-bit SRTCP index (`0x7FFFFFFF`) is exhausted.

### Cryptographic Dependencies & Side-Channel Note

- Reuses `packages/crypto` (`v0.2.0`): `crypto::Sha1`, `crypto::sha1`, `crypto::constant_time_eq`, `crypto::bytes_to_hex`, `crypto::hex_to_bytes`.
- Because `packages/crypto` `v0.2.0` does not yet expose AES-128, AES-128-CTR, AES-128-GCM, or HMAC-SHA1, `packages/rtp/src/crypto_prim.pion` provides 100% pure-Pion implementations of FIPS 197 AES-128, AES-128-CTR, NIST SP 800-38D AES-128-GCM (with a per-context 4-bit Shoup GHASH table), and RFC 2104 HMAC-SHA1 (built on `crypto::Sha1` with precomputed pads).
- **Side-channel disclosure**: AES-128 S-box lookups and the 4-bit GHASH Shoup table are pure-software table-driven implementations (no hardware AES-NI / PMULL intrinsics). While MAC/tag comparison is constant-time (`crypto::constant_time_eq`), table-indexed AES/GHASH is subject to local cache-timing side channels against a co-resident attacker sharing the same CPU cache; hardware-backed or bitsliced primitives should be substituted if co-resident cache adversaries are in scope.

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
- **Red-Team Audit Suite (`sh packages/rtp/audit/run_audit.sh all`)**:
  - `unit`: **22 / 22 passing** (14 / 14 controls + 8 / 8 red-team regressions P1-1, P1-2, P2-1..P2-6 all fixed).
  - `compare`: bidirectional interop with Rust `webrtc-rs` (`rtp 0.12.0`, `rtcp 0.12.0`, `webrtc-srtp 0.14.0`) — **282 / 282** Pion → Rust and **492 / 492** Rust → Pion OK.
  - `fuzz`: **12,000** malformed inputs (seed 3711) on Native `--release` and Wasm32 `--release` — **0** crashes, **0** traps, byte-identical verdicts (`sha256: 773ab22cbae648a9`).
  - `dos`: 100,000 forged unauthenticated SSRCs + 10,000 genuine SRTP packets complete in **0.24 s** at **1.9 MiB** Peak RSS (0 MiB state growth vs 19.3 MiB in `webrtc-rs`).

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
| RTP Parse + Marshal (1,200 B + 3 RFC 5285 1-byte exts × 50,000) | 82.330 | 32.447 | 1,646.61 ns/op | 1.80 MiB | 2.08 MiB | 0.39x | `1490e46b1e6d14d1…` (exact) |
| RTCP Compound Parse + Marshal (SR + PLI + NACK × 50,000) | 72.339 | 62.501 | 1,446.79 ns/op | 1.84 MiB | 2.20 MiB | 0.86x | `5727aeb0e46e2972…` (exact) |
| SRTP `AES128_CM_HMAC_SHA1_80` Protect + Unprotect (5,000 × 1,200 B = 12 MB) | 271.028 | 131.295 | 44.28 MB/s | 1.88 MiB | 2.08 MiB | 0.48x | `3a80d94aed49bb1f…` (exact) |
| SRTP `AEAD_AES_128_GCM` Protect + Unprotect (5,000 × 1,200 B = 12 MB) | 247.303 | 120.209 | 48.52 MB/s | 1.86 MiB | 2.11 MiB | 0.49x | `9709ef15a59a9dfc…` (exact) |

**Honest runtime & hardware notes**:
- On RTCP compound parse + marshal, pure Pion reaches **0.86×** of Rust `webrtc-rs/rtcp` while using lower Peak RSS (`1.84 MiB` vs `2.20 MiB`).
- On RTP 1,200 B parse + marshal, Rust `webrtc-rs/rtp` uses reference-counted zero-copy `bytes::Bytes::slice()` for the 1,172-byte payload, whereas Pion's `parse_rtp` copies the payload into an owned `Bytes` slice (`0.39×`).
- On SRTP `AES128_CM_HMAC_SHA1_80` (`44.28 MB/s`, `0.48×`) and `AEAD_AES_128_GCM` (`48.52 MB/s`, `0.49×`), Rust `webrtc-srtp` uses hardware AES/PMULL/SHA1 intrinsics on Apple Silicon and runs without replay protection (`None`), whereas `packages/rtp` runs 100% pure-Pion portable scalar code with full send/receive replay protection enabled and still sustains **>44 MB/s** (>350 Mbps).
