# Red-team audit: `packages/rtp` v0.1.0 (`origin/feat/pkg-rtp` @ `dfd410cd`)

Scope: `packages/rtp/src/{types,crypto_prim,rtp,rtcp,srtp}.pion` (2,685 lines, read in full), the
package README claims and `bench/`. Nothing outside `packages/rtp/audit/` was modified.

```sh
sh packages/rtp/audit/run_audit.sh            # all (≈20 s on an M-series Mac, + first cargo build)
sh packages/rtp/audit/run_audit.sh unit       # control_test (must pass) + redteam_test + whitebox
sh packages/rtp/audit/run_audit.sh compare    # bidirectional interop vs Rust webrtc-rs
sh packages/rtp/audit/run_audit.sh fuzz       # 12,000 inputs, Native --release vs wasm32 --release vs webrtc-rs
sh packages/rtp/audit/run_audit.sh dos        # /usr/bin/time -l state-growth / amplification probes
```

All builds, corpora and logs go to `$RT_RTP_WORK` (default `/tmp/rt_rtp_work`); the worktree stays
clean. Needs `pionc`, `cargo`, `python3`, `node`. The script exits 0 only when every control passes
and exactly the documented red-team tests fail.

## Summary

| ID | Sev | Finding | Reproduced by |
| --- | --- | --- | --- |
| P1-1 | **P1** | Unauthenticated packets create permanent per-SSRC state in an unbounded, linearly searched `Array` → remote memory growth + quadratic CPU DoS | `wb_redteam_P1_1_*`, `dos` |
| P1-2 | **P1** | SRTCP replay window / index is one per context instead of one per SSRC → genuine RTCP of a 2nd sender SSRC is dropped as "replay" (interop break with libsrtp/webrtc-rs/Chrome) | `redteam_P1_2_*`, `compare` (`rs_rtcp_two_ssrc_*`) |
| P2-1 | P2 | `encrypt_rtp` re-encrypts an already used (SSRC, ROC, SEQ) → AES-CM keystream / AES-GCM nonce reuse | `redteam_P2_1_*` |
| P2-2 | P2 | `from_session_keys` accepts a 0/1-byte HMAC key for the HMAC-SHA1 profiles (fail-open authentication) | `redteam_P2_2_*` |
| P2-3 | P2 | `marshal_rtp` truncates the extension word count to 16 bits → header/payload desync | `redteam_P2_3_*` |
| P2-4 | P2 | `marshal_rtp` / `marshal_rtcp` silently truncate out-of-range `sequence_number`, `extension_profile`, NACK `packet_id`, RTCP `packet_type` | `redteam_P2_4_*` |
| P2-5 | P2 | REMB decode `mantissa << exp` overflows `UInt64` for `exp >= 47` (2^64 bps decodes as 0 bps) | `redteam_P2_5_*` |
| P2-6 | P2 | SRTCP 31-bit index and 32-bit ROC wrap silently on the send side → nonce/keystream reuse (no re-key barrier) | `wb_redteam_P2_6_*` |
| P2-7 | P2 | Table-driven AES S-box and 4-bit GHASH table: secret-indexed memory lookups (cache-timing side channel) | review |
| P2-8 | P2 | Doc / process: README claims per-SSRC replay protection for SRTCP and "verify before updating state"; package not in workspace `members`, `index/`, `BENCHMARKS.md` | review |

No P0 (no authentication bypass, no forgery, no crash/trap, no state corruption by forged packets):
every verified defence is pinned by a `control_*` / `wb_control_*` test (see "Verified to hold").

---

## P1-1 — Forged packets grow an unbounded SSRC table with O(n) lookup (remote DoS)

- **Where**: `src/srtp.pion:403` (`decrypt_rtp`) calls `get_or_create_ssrc_state` **before** the
  tag check at `:443` / `:458`; `src/srtp.pion:167-184` appends a new `SsrcState` to
  `ctx.ssrc_states : Array[SsrcState]` (`src/types.pion:326`) for every unseen SSRC and never removes
  one; every lookup (`get_or_create_ssrc_state`, `get_roc` `:187-196`) is a linear scan.
- **Trigger**: tier ③ — anyone who can get UDP datagrams onto the media 5-tuple (spoofed source,
  on-path relay, or a misbehaving peer). No key needed: 12-byte RTP header + garbage tag.
- **Impact** (measured, `run_audit.sh dos`, Apple Silicon, `/usr/bin/time -l`): after 100,000
  forged packets the receiver keeps 100,000 entries forever and every genuine packet scans them:
  10,000 genuine packets take **10.0 s vs 0.03 s** (≈1 ms/packet → one core saturated at a normal
  1,000 pkt/s video rate); RSS +7 MiB. Cost is quadratic in the attack length. webrtc-srtp also
  creates state pre-auth but uses a `HashMap` (0.06 s for the same run).
- **Fix**: look the state up read-only before authentication and insert only after the tag
  verifies (keep `has_seq=false` probing on a stack copy); use a hash map keyed by SSRC; cap the
  number of SSRC states (e.g. configurable `max_ssrcs`, LRU eviction of states that never
  authenticated). Side effect: none for valid traffic (a new SSRC is still created on its first
  authenticated packet).

## P1-2 — SRTCP replay state shared by all SSRCs

- **Where**: `src/types.pion:327-330` (`srtcp_index`, `srtcp_max_index`, `srtcp_has_index`,
  `srtcp_replay_mask` are fields of `SrtpContext`, not of `SsrcState`); used by
  `decrypt_rtcp` `src/srtp.pion:591-600` (check) and `:699-713` (commit), and by `encrypt_rtcp`
  `:498-499` (one counter for all SSRCs).
- **RFC**: RFC 3711 §3.2.3 (crypto context per SSRC) and §3.4 (the SRTCP index is maintained per
  context). libsrtp, webrtc-srtp (`srtcp_ssrc_states: HashMap`) and browsers keep one index per
  sending SSRC.
- **Trigger**: tier ① for any normal multi-SSRC peer (audio + video RTCP senders, RTX, simulcast):
  once SSRC A has sent > 64 more RTCP packets than SSRC B, **every** RTCP packet of B is rejected as
  `ReplayDetected("SRTCP packet older than 64-packet replay window")` — SR/RR/NACK/PLI/REMB of that
  sender are lost (no lip-sync, no loss recovery, no congestion feedback). Reproduced with real
  webrtc-srtp ciphertext in `compare` (3/3 profiles) and in `redteam_P1_2_*`.
- **Fix**: move SRTCP index / high-water mark / mask into the per-SSRC state (keyed by the SRTCP
  sender SSRC at bytes 4..8), and keep one send counter per SSRC. Combine with P1-1 (create SRTCP
  state only after authentication).

## P2-1 — `encrypt_rtp` allows index reuse

- **Where**: `src/srtp.pion:320-340` — the sender estimates `v` and encrypts unconditionally; no
  check that the packet index `(v << 16) | seq` was already used.
- **Impact**: an application that re-sends a *different* payload under the same SSRC/SEQ (RTX
  done in-band, seq reset after restart, `set_roc` rollback) gets `C1 ⊕ C2 = P1 ⊕ P2`
  (reproduced for AES-CM and AES-GCM); for GCM a repeated nonce also leaks the GHASH key `H`
  (universal forgery for that session key). Tier: application misuse, but the API offers no guard.
  libsrtp refuses (`srtp_err_status_replay_fail`) unless `allow_repeat_tx`.
- **Fix**: keep a send-side replay window (same 64-bit mask) and return an error for a repeated
  index unless an explicit `allow_repeat_tx` flag is set and the plaintext is identical.

## P2-2 — Empty HMAC key accepted

- **Where**: `src/srtp.pion:128-139` validates `enc_key` (16) and `salt` only; `auth_key` is passed to
  `hmac_sha1_pads` (`:144-145`) whatever its length.
- **Impact**: `from_session_keys(Aes128CmHmacSha1_80, {auth_key: b""})` succeeds; every tag is then
  computable by anyone (HMAC under a known empty key) — fail-open authentication for callers that
  build keys from a mis-parsed keying-material export. `SrtpContext::new` itself is fine.
- **Fix**: require `auth_key.length() == 20` for the HMAC-SHA1 profiles (and `== 0` or ignore for GCM).

## P2-3 — `marshal_rtp` extension length truncation

- **Where**: `src/rtp.pion:358-362` writes `ext_words >> 8 & 0xFF, ext_words & 0xFF` with no
  `ext_words <= 65535` check (two-byte elements allow 1,100 × 257 B = 282,700 B).
- **Impact**: the produced packet (len 282,720) declares a much shorter extension block; a receiver
  parses the tail of the extension data as RTP payload (desync / smuggling of chosen payload bytes,
  and the SRTP AAD/payload split differs from the sender's intent). Local API input only.
- **Fix**: reject `ext_buf.length() > 65535 * 4`.

## P2-4 — Silent truncation in marshal

- **Where**: `src/rtp.pion:334-335` (`sequence_number`), `:359-360` (`extension_profile`);
  `src/rtcp.pion:569-570` (NACK `packet_id` / `lost_packets`, via `push_u16_be`), `:592` (FIR
  `sequence_number`), `:469` (`pt & 0xFF` in `wrap_rtcp_header`).
- **Impact**: seq 65543 is sent as 7; `UnknownRtcp{packet_type: 456}` is emitted as PT 200 (an SR
  header!). `payload_type` is range-checked (`:248`) so the inconsistency is a contract bug.
- **Fix**: range-check every field to its wire width and return `InvalidArgument`.

## P2-5 — REMB exponent overflow

- **Where**: `src/rtcp.pion:395-397` — `bitrate = mantissa << exp`, `exp` up to 63, mantissa 18 bits.
- **Impact**: `exp=47, mantissa=2^17` (2^64 bps, i.e. "unlimited") decodes to **0 bps**; other
  values wrap to arbitrary small numbers. A congestion controller consuming it collapses to its
  floor. webrtc-rs decodes to `f32` (saturating, never 0).
- **Fix**: if `exp > 46` (or `mantissa << exp` overflows) saturate to `UInt64::MAX` or reject.

## P2-6 — Send-side index wrap without re-key barrier

- **Where**: `src/srtp.pion:498-499` (`srtcp_index` `0x7FFFFFFF → 0`), `:221` (`st.roc + 1U` wraps
  `0xFFFFFFFF → 0`; the commit at `:334-339` then never advances again, so every later packet
  re-uses ROC 0).
- **Impact**: reproduced white-box: the SRTCP packet after index `0x7FFFFFFF` is byte-identical to
  the one at index 0 (GCM nonce reuse); the RTP packet after ROC `0xFFFFFFFF` + seq wrap equals the
  packet at index 0. Needs 2^31 RTCP / 2^48 RTP packets or `set_roc`, hence P2. RFC 3711 §9.2
  requires re-keying before the index space is exhausted.
- **Fix**: return an error ("re-key required") instead of wrapping.

## P2-7 — Cache-timing side channel in AES / GHASH

- **Where**: `src/crypto_prim.pion:63-66, 111-129, 181-200` (S-box lookups indexed by key/state
  bytes); `:397-402, :408-413` (4-bit Shoup table: index is a nibble of `Y ⊕ C`, table content is a
  function of `H`).
- **Impact**: classic table-AES leakage to a co-resident attacker (same core / browser tab running
  the wasm build next to attacker JS). Not remotely exploitable over the network in practice.
- **Fix**: bitsliced/constant-time AES and a constant-time GHASH (or wait for hardware-backed
  `packages/crypto` AES-GCM); at minimum document it.

## P2-8 — Documentation / process gaps

- `README.md:25` claims a "64-packet sliding replay window for both SRTP and SRTCP" per SSRC and
  "verification before … updating replay state": false for SRTCP (P1-2) and for state creation
  (P1-1).
- `packages/rtp` is not listed in the root `pion.toml` `members`, has no `index/rtp.toml`
  and no `BENCHMARKS.md` entry (AGENTS.md §1.3 / §1.4).
- First SRTCP index sent is 0 (webrtc-srtp starts at 1): legal, noted because it makes SRTCP
  ciphertexts differ in byte-for-byte comparisons.
- `DecodeLimits` has no bound for FIR entries / REMB SSRCs / TWCC & unknown payload bytes. Measured
  harmless (64 × FIR = 256 KiB compound → 32,640 entries in < 1 ms, 3 MiB RSS) because the input
  length bounds it; consider a `max_fci_entries` for consistency with `max_nacks`.

---

## Verified to hold (controls, all PASS)

Black-box `control_test.pion`:
- **Verify-then-decrypt & no state pollution**: every single-bit flip of a full SRTP packet (header,
  CSRC, one-byte extensions, payload, tag) rejected for all 3 profiles; forged packets with seq
  moved to `+32767`, `65535`, `1`, … are `AuthenticationFailed` and leave ROC / `s_l` / window
  untouched; the genuine packet is accepted afterwards (white-box: state bytes identical after 676
  forgeries).
- **ROC (RFC 3711 App. A)**: wrap `65535 → 0` and late `65535`; ROC 0 with `s_l=10` then `65535`
  does **not** underflow to `0xFFFFFFFF` (`src/srtp.pion:212-216` clamps; analysed as benign: the
  accepted packet must still authenticate under ROC 0); jumps of exactly 32767 / 32768.
- **Replay window**: delta 0 (dup), age 63 accepted, 64 / 65 rejected; per-SSRC isolation for SRTP.
- **SRTCP**: E-flag and index are authenticated (flip → `AuthenticationFailed`), all truncations
  `0 .. len-1` rejected without trap, replay rejected; RFC 3711 §3.4 **E=0** (unencrypted,
  authenticated) built independently with an audit-side HMAC-SHA1 is accepted and a forged E=0 is
  rejected (CM profiles); RFC 7714 E=0 for GCM accepted / forged rejected (white-box).
- **KDF input validation**: master key must be 16 B, salt 14 B (CM) / 12 B (GCM); every other length
  0..33 / 0..20 rejected.
- **RTP / RTCP parsing**: padding 0 / overrun, CSRC / extension overruns, one-byte ID 15
  terminator, two-byte length overrun, marshal rejection of ID 0 / 15 / 256 and lengths 0 / 17 / 256;
  RTCP length `0xFFFF`, truncations, SDES without END, padding mismatch, version ≠ 2;
  `DecodeLimits` negative → `LimitExceeded`, 0 → zero items.
- **RFC 7983 demux**: all 256 first bytes and all 256 second bytes.

White-box `whitebox/whitebox_test.pion` (sources copied to `$RT_RTP_WORK/whitebox_pkg`):
- FIPS 197 Appendix B and C.1 AES-128 vectors, key expansion `w[4]`, `w[43]`.
- McGrew–Viega / SP 800-38D AES-128 GCM test cases 1–4 (empty P + empty AAD, one zero block,
  64-byte P, 60-byte P with 20-byte AAD — non-aligned GHASH tails).
- IV construction checked against RFC 7714 §8.1 / §9.1 and RFC 3711 §4.1.1 / §3.4 by reading
  `build_srtp_*_iv` / `build_srtcp_*_iv` (`src/srtp.pion:228-307`) and confirmed end-to-end by the
  byte-identical interop below; KDF label at byte 7 for both salt sizes (`:44`) matches libsrtp /
  webrtc-srtp (RFC 7714 §13: 96-bit salt right-padded to 112 bits).

## Interop vs Rust webrtc-rs (`compare`)

`rtp 0.12.0`, `rtcp 0.12.0`, `webrtc-srtp 0.14.0` (`Cargo.lock` pinned), 3 profiles × 10 cases per
side: plain, one-byte ext + CSRC + marker, two-byte ext (ID 200, zero-length element), padding +
15 CSRCs, ROC wrap `65530 … 65535, 1, 0, 2 … 5`, 5,000-byte payload (CTR / `inc32` carry into the
second counter byte), empty payload, SR+SDES+BYE, RR+NACK+PLI+FIR+REMB, 70 × RTCP.

| Direction | Packets | Decrypt | Ciphertext | Codec |
| --- | ---: | --- | --- | --- |
| Pion → webrtc-rs | 282 | 282 / 282 OK | RTP 66 / 66 **byte-identical**; SRTCP differs only by index base | 276 identical, 3 padded (webrtc-rs re-pads, n/a), 3 SDES (webrtc-rs quirk) |
| webrtc-rs → Pion | 492 | 489 OK, **3 rejected = P1-2** | RTP 63 / 63 byte-identical | 489 identical, 3 SDES (quirk) |

Upstream notes found by the oracle (not Pion defects; Pion behaves correctly in each case):
- **webrtc-srtp 0.14 AES-CM `decrypt_rtcp` returns E=0 packets without checking the tag**
  (`cipher_aes_cm_hmac_sha1/ctrcipher.rs:194-197`): any unauthenticated RTCP is accepted. 950 of
  3,000 fuzzed SRTCP inputs hit this; Pion rejects all of them.
- webrtc-rs `Packet::unmarshal` panics on 50 RTP/SRTP and 148 RTCP/SRTCP inputs (`copy_to_bytes`
  past the end); does not check RTP version; writes the pad count into SDES chunk padding.

## Fuzz (`fuzz`)

12,000 deterministic inputs (`tools/gen_corpus.py`, seed 3711; 3,000 each of RTP / RTCP / SRTP /
SRTCP, mutated from the interop packets: bit flips, boundary bytes, truncation, extension,
length-field tampering, V/P/X/CC, PT, forced extension blocks, padding, splicing, 1% random).

- Native `--release`: exit 0, 0 panics; wasm32 `--release` (node): exit 0, 0 traps;
  verdict files **byte-identical** (sha256 `773ab22cbae648a9…`).
- vs webrtc-rs: every disagreement is classified by `tools/fuzz_compare.py` (the script fails on an
  unexplained one): Pion stricter on RFC 3550 padding / version, RFC 8285 element overruns and RTCP
  padding; Pion parses two-byte appbits `0x1001..0x100F` (RFC 8285 §4.3) where webrtc-rs treats them
  as raw; webrtc-rs maps unknown RTCP PT to 0; webrtc-rs panics; webrtc-srtp E=0 bypass. No input
  is accepted by Pion and rejected for an authentication reason by webrtc-rs.

## DoS (`dos`, `/usr/bin/time -l`)

| Probe | Pion | webrtc-rs |
| --- | --- | --- |
| 0 forged + 10k genuine SRTP | 0.03 s, 1.9 MiB | 0.02 s, 2.2 MiB |
| 10k forged SSRCs + 10k genuine | 0.26 s, 2.7 MiB | 0.02 s, 4.5 MiB |
| 50k forged SSRCs + 10k genuine | 3.0 s, 5.6 MiB | 0.04 s, 12.1 MiB |
| 100k forged SSRCs + 10k genuine | **10.0 s**, 9.1 MiB | 0.06 s, 19.3 MiB |
| 256 KiB compound RTCP (64 × FIR, default limits) × 200 | 0.03 s, 3.0 MiB | — |
| 65535-word RFC 5285 block (limits raised) × 50 | 0.13 s, 12.4 MiB (default limits reject it) | — |

(The host had load average ≈ 25 from other jobs; absolute times are noisy, the ratios are not.)

## Benchmark check (`bench/run_bench.sh`, re-run on the same host)

All four stdout SHA-256 digests reproduce exactly (`1490e46b…`, `5727aeb0…`, `3a80d94a…`,
`9709ef15…`). Ratios vs Rust: RTP 0.34× (README 0.30×), RTCP 0.74× (README 0.86×), SRTP CM 0.41×
(0.39×), SRTP GCM 0.46× (0.44×) — within noise except RTCP, where the README figure is ~15 %
optimistic under this load. The Rust side runs without replay protection (`None` options) while
Pion always checks — a small bias against Pion, not in its favour. Workloads are otherwise
identical (same packets, same iteration counts, same checksum).

## Files

- `control_test.pion`, `redteam_test.pion` — black-box tests (`pionc test packages/rtp/audit`),
  helpers in `src/lib.pion`.
- `whitebox/whitebox_test.pion` — white-box tests, run from a copy of `../src`.
- `probe/` — Pion driver (`gen`, `verify`, `fuzz`, `dos-ssrc`, `dos-rtcp`, `dos-ext`), Native + wasm32.
- `rust/` — webrtc-rs oracle (`gen`, `verify`, `fuzz`, `dos-ssrc`), `Cargo.lock` pinned.
- `tools/gen_corpus.py`, `tools/fuzz_compare.py`, `tools/interop_summary.py`.
