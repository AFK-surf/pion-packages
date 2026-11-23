# `stun` (`v0.1.0`)

100% pure Pion implementation of **RFC 8489 STUN**, **RFC 5769 Test Vectors**, **RFC 7983 Demux**, and **RFC 8445 ICE** (Sans-IO connectivity check & nomination state machine) — zero `extern "C"`, zero `World` dependency.

Directly reuses `packages/crypto` (`v0.2.0`) for `Sha1` / `sha1`, `sha256`, `HmacSha256`, and `constant_time_eq`. Because `packages/crypto` does not expose `hmac_sha1`, IEEE CRC-32, or MD5, `packages/stun/src/crypto_helpers.pion` implements RFC 2104 HMAC-SHA1 (on top of `crypto::Sha1` / `crypto::sha1`), a 256-entry LUT IEEE 802.3 CRC-32 (`FINGERPRINT`), and RFC 1321 MD5 (for RFC 5769 §2.4 / RFC 8489 §10.2.2 long-term credential key derivation) in pure Pion.

## Features

- **RFC 8489 STUN Wire Codec**:
  - Strict 20-byte header validation (top 2 bits `00`, Magic Cookie `0x2112A442`, 4-byte-aligned message length matching packet size, 12-byte `transaction_id`).
  - Full `MessageClass` (`Request`, `Indication`, `SuccessResponse`, `ErrorResponse`) and 12-bit `MessageMethod` (`Binding`, TURN `Allocate`/`Refresh`/`Send`/`Data`/`CreatePermission`/`ChannelBind`, and arbitrary `Other(Int)`).
  - Full attribute support with 4-byte padding alignment: `MAPPED-ADDRESS` (`0x0001`), `XOR-MAPPED-ADDRESS` (`0x0020`, IPv4 & IPv6), `USERNAME` (`0x0006`), `REALM` (`0x0014`), `NONCE` (`0x0015`), `SOFTWARE` (`0x8022`), `ERROR-CODE` (`0x0009`), `UNKNOWN-ATTRIBUTES` (`0x000A`), `PRIORITY` (`0x0024`), `USE-CANDIDATE` (`0x0025`), `ICE-CONTROLLED` (`0x8029`), `ICE-CONTROLLING` (`0x802A`), `MESSAGE-INTEGRITY` (`0x0008`), `MESSAGE-INTEGRITY-SHA256` (`0x001C`), `FINGERPRINT` (`0x8028`), and `Unknown(Int, Bytes)`.
  - RFC 8489 §14.5 / §14.6 `MESSAGE-INTEGRITY` (HMAC-SHA1) and `MESSAGE-INTEGRITY-SHA256` (HMAC-SHA256) with exact header-length adjustment and constant-time comparison (`crypto::constant_time_eq`).
  - RFC 8489 §14.7 `FINGERPRINT` (`CRC-32 XOR 0x5354554E`) verification and signing.
  - Passes all four **RFC 5769 official test vectors** (§2.1 Sample Request, §2.2 IPv4 Response, §2.3 IPv6 Response, §2.4 Long-Term Credentials including byte-for-byte re-encoding).
- **Defensive `DecodeLimits`**:
  - Any negative limit (`max_message_bytes < 0`, `max_attributes < 0`, `max_attribute_bytes < 0`) is immediately rejected with `StunError::InvalidLimits`.
  - `0` strictly means 0 allowed (e.g., `max_attributes == 0` accepts 0-attribute packets and rejects any packet with `>= 1` attribute).
- **RFC 7983 Demux**:
  - `is_stun_packet(data)` quickly distinguishes STUN (`0..3` + Magic Cookie + length) from DTLS (`20..63`) and RTP/RTCP (`128..191`) on multiplexed WebRTC UDP sockets.
- **RFC 8445 Sans-IO ICE State Machine (`IceAgent`)**:
  - `compute_candidate_priority(type_pref, local_pref, component_id)` (§5.1.2.1) and `compute_pair_priority(controlling_prio, controlled_prio)` (§6.1.2.3).
  - Local/remote candidate management, pair formation, deduplication, descending priority sorting, `Waiting -> InProgress -> Succeeded / Failed` transitions, regular and aggressive nomination (`USE-CANDIDATE`), inbound Binding Request authentication & Binding Success Response generation with `XOR-MAPPED-ADDRESS`.

## Public API Summary

```pion
// Core STUN codec & demux
pub fn is_stun_packet(data : Bytes) -> Bool
pub fn encode_message_type(msg_class : MessageClass, method : MessageMethod) -> Result[Int, StunError]
pub fn decode_message_type(raw_type : Int) -> Result[(MessageClass, MessageMethod), StunError]
pub fn decode_message(data : Bytes) -> Result[Message, StunError]
pub fn decode_message_with_limits(data : Bytes, limits : DecodeLimits) -> Result[Message, StunError]
pub fn encode_message(msg : Message) -> Result[Bytes, StunError]
pub fn encode_message_signed(
  msg : Message,
  integrity_key : Option[Bytes],
  use_sha256 : Bool,
  with_fingerprint : Bool,
) -> Result[Bytes, StunError]
pub fn verify_message_integrity(raw : Bytes, key : Bytes) -> Result[Bool, StunError]
pub fn verify_message_integrity_sha256(raw : Bytes, key : Bytes) -> Result[Bool, StunError]
pub fn verify_fingerprint(raw : Bytes) -> Result[Bool, StunError]

// Crypto / credential helpers
pub fn hmac_sha1(key : Bytes, data : Bytes) -> Bytes
pub fn crc32_ieee(data : Bytes, start : Int, end : Int) -> UInt
pub fn md5(data : Bytes) -> Bytes
pub fn long_term_key_md5(username : String, realm : String, password : String) -> Bytes
pub fn long_term_key_sha256(username : String, realm : String, password : String) -> Bytes

// RFC 8445 ICE
pub fn compute_candidate_priority(type_pref : Int, local_pref : Int, component_id : Int) -> Result[UInt, StunError]
pub fn compute_pair_priority(controlling_prio : UInt, controlled_prio : UInt) -> Int64
pub fn IceAgent::new(role : IceRole, tie_breaker : UInt64, local_ufrag : String, local_pwd : String, aggressive_nomination : Bool) -> IceAgent
pub fn IceAgent::set_remote_credentials(self : IceAgent, ufrag : String, pwd : String) -> Unit
pub fn IceAgent::add_local_candidate(...) -> Result[Int, StunError]
pub fn IceAgent::add_remote_candidate(...) -> Result[Int, StunError]
pub fn IceAgent::next_check(self : IceAgent) -> Result[Option[IceCheckPacket], StunError]
pub fn IceAgent::nominate_pair(self : IceAgent, pair_idx : Int) -> Result[IceCheckPacket, StunError]
pub fn IceAgent::handle_inbound(self : IceAgent, packet : Bytes, from_addr : SocketAddr) -> Result[IceInboundResult, StunError]
pub fn IceAgent::mark_pair_failed(self : IceAgent, pair_idx : Int) -> Result[Unit, StunError]
pub fn IceAgent::selected_pair(self : IceAgent) -> Option[CandidatePair]
```

## Verification

```sh
sh scripts/verify.sh --allow-dirty packages/stun
```

### 4-Mode `wasm_smoke` Verification

All four build/run modes (`native debug`, `native --release`, `wasm32 debug`, `wasm32 --release`) exit `0` with identical stdout SHA-256 (`d027b13e7d5347a88e54e515425364eb398397b135b8571dbb4fa3fd2d5d40eb`):

```sh
pionc run packages/stun/wasm_smoke
pionc run --release packages/stun/wasm_smoke
pionc run --target wasm32 packages/stun/wasm_smoke
pionc run --target wasm32 --release packages/stun/wasm_smoke
```

## Head-to-Head Benchmarks (`Darwin arm64`, `warmup=1`, `rounds=5`)

Run via `sh packages/stun/bench/run_bench.sh` against Rust **`webrtc-rs/stun` `v0.8.0` (`--release`, backed by `ring` ASM SHA-1)** on 100,000 real WebRTC ICE STUN packets (3-way mix: Binding Request with `USERNAME` + `PRIORITY` + `ICE-CONTROLLING` + `USE-CANDIDATE` + `MESSAGE-INTEGRITY` + `FINGERPRINT`; Binding Success Response IPv4 with `XOR-MAPPED-ADDRESS` + `MESSAGE-INTEGRITY` + `FINGERPRINT`; Binding Success Response IPv6 with `XOR-MAPPED-ADDRESS` + `MESSAGE-INTEGRITY` + `FINGERPRINT`).

All 100,000 encoded wire packets and all decoded/verified checksums are verified **100% byte-for-byte identical** via SHA-256:

| Workload | `pion` Median (`ns/op`) | `rust_webrtc_stun` Median (`ns/op`) | `pion` Peak RSS | `rust_webrtc_stun` Peak RSS | `pion` vs `rust_webrtc_stun` | Stdout SHA-256 (Identical) |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Encode + Sign (`MI` + `FP`, 100k pkts) | 239.998 ms (`2399.98 ns/op`) | 156.428 ms (`1564.28 ns/op`) | 1.84 MiB | 2.06 MiB | **0.65x** | `eb1d673bb93fca8f...` |
| Decode + Verify `FP` + Verify `MI` (100k pkts) | 199.714 ms (`1997.14 ns/op`) | 122.517 ms (`1225.17 ns/op`) | 1.88 MiB | 2.11 MiB | **0.61x** | `2739a0786b801d32...` |
