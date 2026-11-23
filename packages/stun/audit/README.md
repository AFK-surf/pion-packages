# Red-team audit: `packages/stun` v0.1.0

Baseline: `origin/feat/pkg-stun` @ `d31e5fd` (`packages/stun/src/{types,crypto_helpers,stun,ice}.pion`, 2,006 lines, all read in full).
Scope: RFC 8489 STUN codec and integrity, RFC 5769 vectors, RFC 8445 Sans-IO `IceAgent`, RFC 7983 demux, constant-time comparison, fuzzing, DoS, cross-implementation parity, benchmark honesty.
This directory only adds audit code. `src/` and `stun_test.pion` are untouched.

```sh
sh packages/stun/audit/run_audit.sh all       # build + unit + compare + fuzz + dos   (~2 min, Apple M-series)
sh packages/stun/audit/run_audit.sh unit      # control_* must PASS, p1_*/p2_* FAIL = finding reproduced
sh packages/stun/audit/run_audit.sh compare   # Pion vs webrtc-rs stun 0.8.0 vs stdlib-only RFC reference
sh packages/stun/audit/run_audit.sh fuzz      # 3 seeds x 20,000 packets x native/wasm32 x debug/release
sh packages/stun/audit/run_audit.sh dos       # /usr/bin/time -l measurements
sh packages/stun/audit/run_audit.sh bench     # re-run packages/stun/bench and check README numbers
```

Artefacts go to `$AUDIT_OUT` (default `/private/tmp/rt_stun_work`) and nothing is written to the worktree. Requirements: `pionc`, `node` (the wasm32 runtime), `cargo`, `python3`.

## Verdict

**There is no P0.** The codec layer is solid: on 30,126 vectors, every decode result matches the independent RFC reference. MESSAGE-INTEGRITY length patching, HMAC key hashing for keys over 64 B, FINGERPRINT placement, and the constant-time MAC compare are all correct. Fuzzing found no panic or trap, and native and wasm32 give the same results.

The serious problems are in the **ICE agent**, plus one RFC 8489 rule that the agent depends on:

| ID | Sev | Finding | Trigger |
|---|---|---|---|
| P1-1 | **P1** | Attributes **after MESSAGE-INTEGRITY** are not ignored. An on-path attacker appends `USE-CANDIDATE`, re-computes the unkeyed FINGERPRINT, and forces nomination without knowing any key. | ③ on-path, no credentials |
| P1-2 | **P1** | **No role-conflict handling**: no 487 is ever sent, a received 487 permanently fails the pair, and `role` is immutable. When both sides are controlling, both nominate. When both are controlled, ICE never completes. | ① ordinary glare / interop |
| P1-3 | **P1** | The controlled side nominates by **remote address only**, takes the first pair that matches, and marks it `Succeeded` without running its own check. With more than one local candidate it selects the wrong pair. | ① multi-homed host |
| P1-4 | **P1** | Pair indices are **positions in an array that is re-sorted** on every candidate add. After a trickle add, `selected_pair()`, `IceCheckPacket.pair_idx`, `PairSucceeded(idx)` and `mark_pair_failed(idx)` refer to the wrong pair. | ① trickle ICE |
| P1-5 | **P1** | The **checklist is unbounded** and pair formation costs **O(P²)**: 80,000 pairs took 36 s of CPU, and 2,000 × 2,000 candidates is about 26 h. | ③ hostile signalling (SDP / trickle) |
| P2-1 | P2 | A check without `PRIORITY` / `ICE-CONTROLLING` / `ICE-CONTROLLED` is answered with success instead of 400. | peer |
| P2-2 | P2 | An unknown comprehension-required attribute (< 0x8000) is silently ignored instead of returning 420 + UNKNOWN-ATTRIBUTES. | peer |
| P2-3 | P2 | The response source address is never compared with the check destination, so a non-symmetric response still succeeds the pair. | peer / NAT |
| P2-4 | P2 | ICE checks without FINGERPRINT are accepted (the RFC says MUST include). It can be stripped without a key. | on-path |
| P2-5 | P2 | The transaction ID is `tie_breaker‖counter`, which is fully predictable; RFC 8489 §6 requires a uniformly random ID. | off-path guessing |
| P2-6 | P2 | `compute_pair_priority` overflows Int64 for priorities ≥ 2³¹, and remote priority is never range-checked. | API / remote SDP |
| P2-7 | P2 | `IceAgent::new` accepts an empty or short `ice-pwd`. With an empty password, anyone can forge MESSAGE-INTEGRITY. | misconfiguration |
| P2-8 | P2 | USERNAME is not checked at all until the remote ufrag is known. Not even the local-ufrag prefix is checked. | early checks |
| P2-9 | P2 | `DecodeLimits::default().max_message_bytes = 65535`, but the largest legal message is 65,552 B. | max-size message |
| P2-10 | P2 | ERROR-CODE reason length is unbounded in both directions, text attributes are not validated as UTF-8, and there is no OpaqueString (SASLprep). | peer |
| P2-11 | P2 | A truncated MESSAGE-INTEGRITY-SHA256 (16–28 B, which RFC 8489 allows) makes **the whole message undecodable**. | RFC 8489 peers |
| P2-12 | P2 | `verify_message_integrity*` return `Ok(true)` on packets that `decode_message` rejects, because framing after the MI is never walked. This is an API-contract issue only; the ICE path is not affected. | API misuse |

Severity scale. P0 means remote compromise or bypass with no prerequisites. P1 means a security-relevant or interop-breaking defect that is reachable in normal deployments. P2 means hardening or a non-compliance with limited impact.
Trigger classes follow `security-audit`: ① default configuration or normal operation, ② a specific legal configuration or timing, ③ an attacker capability that crosses a trust boundary.

## Evidence summary (all from `run_audit.sh all`)

| Check | Result |
|---|---|
| `control_test.pion` | **11/11 PASS** (header/framing, DecodeLimits, address shapes, XOR edges, MI length patching and every-byte tamper, FINGERPRINT position and duplicates, SHA-256 MI for keys 0–200 B, RFC 2202 / RFC 1321 / CRC-32 vectors, typed attribute lengths, ICE rejection of forged / unsigned / off-path packets, priority formulas) |
| `redteam_test.pion` | **19/19 FAIL as expected**: each one reproduces a finding below. The package's own `stun_test.pion` passes 11/11. |
| Encode parity | Pion matches the reference on **48/48** specs, and matches webrtc-rs `stun` 0.8.0 on **42/42** (webrtc-rs cannot encode the other 6 specs, which use MI-SHA256). Specs cover Chrome/Meet-shaped checks (controlling / controlled, `USE-CANDIDATE`, GOOG-NETWORK-INFO `0xC057`), IPv4/IPv6 XOR-MAPPED-ADDRESS (ports 0/1/3478/65535, all-zero and all-FF addresses), ERROR-CODE 400/401/420/438/487/500 + UNKNOWN-ATTRIBUTES, long-term REALM/NONCE/UTF-8 USERNAME, and keys that are empty, 22/24/64/65/200 B, UTF-8 or MD5 long-term. |
| Decode, 10,126 vectors (RFC 5769 + 48 valid + 74 attacks + 10,000 mutations) | Pion matches the reference on all 5 fields for 9,783 vectors. **Every D (decode) difference is P2-11**, and every MI/M2 difference is P2-11 or P2-12. **0 vectors where Pion accepts an MI/FP that a reference rejects on a message Pion decodes.** Pion decodes no message that webrtc-rs rejects (0 Pion-only accepts); webrtc-rs is lazier and decodes 1,754 that Pion rejects. On the 1,829 that both decode, MI differs 0 times. FP differs 137 times, all cases where Pion correctly errors because FINGERPRINT is not last or is duplicated and webrtc-rs says `false`. XA differs 26 times, because webrtc-rs rejects a non-zero reserved byte, which RFC 8489 §14.1 says to ignore. |
| Decode, Pion fuzzer's own 20,000-packet corpus | Same picture: 0 security mismatches, 0 Pion-only accepts, MI differs from webrtc-rs 0 times. |
| Fuzz | 3 seeds × 20,000 packets run through `is_stun_packet`, `decode_message`, limits, all three `verify_*`, and `IceAgent::handle_inbound` (about 4,000 per seed carry a valid MI and about 840 per seed reach `SendResponse`). Mutations include bit flips, truncation, length patches, post-MI injection, duplicated attribute sections, random bodies, bombs of up to 16,383 attributes, 64 KiB attributes, top-bit flips, splices, and freshly signed random messages. **Exit 0 in every run, and the digests are byte-identical across native release, native debug, wasm32 release and wasm32 debug.** |
| DoS | See P1-5. A 16,383-attribute bomb is rejected by the default limits; with the limits lifted it decodes in <1 ms at 3.4 MiB RSS. A 65,552 B message takes 0.43 ms for decode + MI + FP. |
| Benchmark | The `bench/README` numbers reproduce: encode+sign 0.62× (README says 0.65×), decode+verify 0.61× (README says 0.61×). The stdout SHA-256 is identical (`eb1d673b…`, `2739a078…`). See the honesty notes at the end. |

---

## P1 findings

### P1-1 Attributes after MESSAGE-INTEGRITY are trusted (USE-CANDIDATE injection)

- **Where.** `src/stun.pion:746-760` (`verify_message_integrity`) authenticates only the prefix up to the first MI. That is correct, but nothing records where the authenticated part ends. `src/stun.pion:248-347` (`decode_message`) returns every attribute. `src/ice.pion:321-337` loops over all of `msg.attributes` for `USERNAME` and `USE-CANDIDATE`, and `src/ice.pion:406-417` takes XOR-MAPPED-ADDRESS from anywhere in the message.
- **Root cause.** RFC 8489 §14.5 says: "the agent MUST ignore all other attributes that follow MESSAGE-INTEGRITY, with the exception of the MESSAGE-INTEGRITY-SHA256 and FINGERPRINT attributes." No layer does this. FINGERPRINT is unkeyed, so it can be recomputed.
- **Attack.** An on-path attacker takes any regular-nomination check (signed, without USE-CANDIDATE), strips FP, appends `0025 0000`, fixes the header length, and re-adds FP. `verify_message_integrity` still says `true` and `verify_fingerprint` says `true`, so the controlled agent nominates the pair. With P1-3 on top, the attacker can also pick which remote address gets nominated by spoofing the source. No key is needed.
- **Tests.** `p1_use_candidate_injected_after_message_integrity_forces_nomination` and `p1_decode_message_exposes_unauthenticated_attributes_after_mi`. The compare corpus has `atk_after_mi_*` for 7 attribute kinds.
- **Fix.** In `decode_message`, stop collecting attributes after the first MESSAGE-INTEGRITY, except MI-SHA256 and FINGERPRINT, or record an `authenticated_len` / per-attribute flag. In `ice_handle_binding_request` / `_response`, look only at attributes before MI. Side effects: none for conforming peers, because legitimate stacks put nothing except FP after MI.

### P1-2 No role-conflict resolution (RFC 8445 §7.3.1.1 / §7.2.5.1)

- **Where.** `src/types.pion:428` declares `pub role : IceRole` as immutable. `src/ice.pion:305-360` never reads `IceControlling` / `IceControlled`. `src/ice.pion:389-404` turns every error response, 487 included, into `PairState::Failed`.
- **Impact.** Glare in both directions is normal: offer/answer races, ICE restarts, and two "full" agents after a lost answer.
  - Controlling vs controlling: both sides send USE-CANDIDATE and may each select a different pair.
  - Controlled vs controlled: nobody can nominate, so ICE hangs until timeout.
  - A peer that does implement the RFC replies 487, and this agent then fails the pair for good.
- **Tests.** `p1_role_conflict_controlling_vs_controlling_no_487`, `p1_role_conflict_controlled_vs_controlled_deadlock`, `p1_role_conflict_487_response_fails_pair_instead_of_switching`.
- **Fix.** Make `role` `mut`. Implement the §7.3.1.1 table, comparing tie-breakers as `UInt64`: either switch role (and recompute pair priorities, which needs a re-sort, see P1-4) or reply `ERROR-CODE 487` signed with the local password. On receiving 487, switch role, set the pair back to `Waiting` and re-queue it.

### P1-3 Controlled side nominates the wrong pair and skips its own check

- **Where.** `src/ice.pion:339-351`. The loop matches `remote_candidates[pair.remote_idx].addr == from_addr` and `break`s on the first match. `handle_inbound(packet, from_addr)` has no local-address or component argument, so the agent cannot tell which local candidate received the check. The pair is then set to `Succeeded` on the spot.
- **Impact.** With 2 or more local candidates (Ethernet + Wi-Fi, IPv4 + IPv6 on the same family, or RTP/RTCP sharing a remote), Bob selects "eth ↔ Alice" while Alice nominated "wifi ↔ Bob". Media then goes to a path that was never validated. RFC 8445 §7.3.1.4 says to send a triggered check if the pair is not already Succeeded, and §7.3.1.5 says the pair is nominated only when its own check succeeds. Peer-reflexive candidates are never created either (§7.3.1.3).
- **Tests.** `p1_controlled_nominates_wrong_pair_ignoring_local_candidate` and `p1_controlled_marks_pair_succeeded_without_its_own_check`.
- **Fix.** Add a `local_addr` (and component) argument to `handle_inbound`. Look the pair up by (local, remote). If it is not Succeeded, set `nominated = true` and queue a triggered check, and select it only on success. Create a prflx remote candidate when the source address is unknown.

### P1-4 Pair indices are invalidated by the insertion sort

- **Where.** `src/ice.pion:95-108` and `:145`. `ice_sort_pairs_desc(self.pairs)` runs on every `ice_form_pairs_for`, but `IceCheckPacket.pair_idx` (`src/types.pion:410`), `IceInboundResult::PairSucceeded/PairFailed(idx)`, `nominated_pair_idx` (`src/types.pion:439`), and the arguments of `nominate_pair` / `mark_pair_failed` are raw array positions.
- **Impact.** The test completes an aggressive nomination on the relay pair, then trickles in a host candidate. `selected_pair()` now returns the new host pair, which is `Waiting`, never checked and not nominated. Callers that retransmit or time out by `pkt.pair_idx` mark or nominate the wrong pair.
- **Test.** `p1_trickle_candidate_reorders_pairs_selected_pair_points_elsewhere`.
- **Fix.** Give each pair a stable ID and keep a separate priority-ordered index vector, or never reorder after the first check and instead scan for the highest-priority `Waiting` pair in `next_check`.

### P1-5 Unbounded checklist with O(P²) pair formation

- **Where.** `src/ice.pion:178-203` (no limit on remote candidates), `:111-120` (`ice_has_pair` is an O(P) scan), and `:95-108` (insertion sort, O(P) per insert). That makes O(P²) over the cross-product.
- **Measured** with `/usr/bin/time -l`, native release, M-series:

  | local × remote | pairs | wall | peak RSS |
  |---|---:|---:|---:|
  | 1 × 1,000 | 1,000 | 0.005 s | 2.0 MiB |
  | 1 × 4,000 | 4,000 | 0.08 s | 2.8 MiB |
  | 4 × 4,000 | 16,000 | 1.24 s | 4.4 MiB |
  | 10 × 4,000 | 40,000 | 8.0 s | 7.8 MiB |
  | 20 × 4,000 | 80,000 | **36.1 s** | 12.8 MiB |
  | 10 × 4,000 (wasm32) | 40,000 | 12.2 s | 57.9 MiB |
  | 2,000 × 2,000 | 4,000,000 | extrapolated **≈ 26 h** (not run) | – |

  Every authenticated response, and every request carrying USE-CANDIDATE, also does a linear scan: 100,000 responses take 0.21 s against 100 pairs and 3.4 s against 10,000 pairs.
- **Trigger.** Remote candidates come from SDP or trickle messages, which an untrusted peer controls. One `a=candidate` flood freezes the event loop, which in a Sans-IO agent usually means the caller's thread.
- **Test.** `p1_checklist_unbounded_remote_candidate_flood` gives 800 pairs from 400 candidates with no limit.
- **Fix.** RFC 8445 §6.1.2.5 / §14 cap the checklist (default 100 pairs; libwebrtc also caps candidates per m-line). Reject or prune beyond the cap, deduplicate with a hash set, and insert with a binary search.

## P2 findings

| ID | Where | RFC | Test | Fix |
|---|---|---|---|---|
| P2-1 | `src/ice.pion:305-337` | 8445 §7.1.1–7.1.3, §7.3: a check MUST carry PRIORITY and ICE-CONTROLLING or -CONTROLLED. | `p2_check_without_priority_or_role_attribute_accepted` | Reply 400 when either is missing. The PRIORITY value is also needed for prflx candidates (P1-3). |
| P2-2 | `src/stun.pion:341-343` (everything else becomes `Attribute::Unknown`), `src/ice.pion:305` | 8489 §6.3.1 / §5: unknown comprehension-required → 420 + UNKNOWN-ATTRIBUTES; in a response, fail the transaction. | `p2_unknown_comprehension_required_attribute_ignored` | Have the decoder report unknown types `< 0x8000`; the agent then replies 420. |
| P2-3 | `src/ice.pion:363-425`, `:459-460` (`from_addr` is not passed to the response path) | 8445 §7.2.5.2.1: a non-symmetric response fails the pair. | `p2_response_from_wrong_source_address_succeeds_pair` | Compare `from_addr` with `remote_candidates[pair.remote_idx].addr`. |
| P2-4 | `src/ice.pion:436-447` (FINGERPRINT optional) | 8445 §7.2.2: checks MUST include FINGERPRINT. Without it, STUN/RTP/DTLS demux of a stripped packet becomes ambiguous. | `p2_check_without_fingerprint_accepted` | Require FINGERPRINT on ICE checks and responses. |
| P2-5 | `src/ice.pion:206-217` | 8489 §6: the transaction ID MUST be uniformly random from 0..2⁹⁶-1 (CSPRNG). The tie-breaker is also sent in clear in ICE-CONTROL*. | `p2_transaction_id_is_tie_breaker_plus_counter` | Take 96 random bits from the caller (Sans-IO: an RNG callback or bytes passed to `next_check`). The 32-bit counter also wraps. |
| P2-6 | `src/ice.pion:27-34` (`mn << 32` in Int64), `:178-196` | 8445 §5.1.2: priority is 1..2³¹-1. | `p2_pair_priority_int64_overflow_and_unchecked_remote_priority` | Reject remote priority 0 or ≥ 2³¹, and compute in `UInt64` (the result fits in 63 bits). Inside the agent, local priorities stay below 2³¹, so the overflow is reachable only through the public function. |
| P2-7 | `src/ice.pion:61-82`, `:311` | 8445 §5.3: ice-pwd ≥ 128 bits (22 chars); ufrag ≥ 24 bits. | `p2_empty_local_password_accepted_and_forgeable` | Validate in `new` / `set_remote_credentials` (return `Result`). |
| P2-8 | `src/ice.pion:318-329` | 8445 §7.3: USERNAME = `<local ufrag>:<remote ufrag>`. Before the answer arrives, at least the local prefix must match. | `p2_username_not_checked_before_remote_credentials` | Always check `local_ufrag + ":"` as the prefix. MI with `local_pwd` still guards this, which is why it is only P2. |
| P2-9 | `src/types.pion:135-137` | 8489 §5: the 16-bit length allows 20 + 65,532 B. | `p2_default_limits_reject_largest_legal_message` | Default `max_message_bytes = 65552`. |
| P2-10 | `src/stun.pion:284-294`, `:375-381`, `:58-60`; `src/crypto_helpers.pion:281-288` | 8489 §14.8 (reason < 128 chars, ≤ 509 B encode / 763 B decode), §14.3/§14.14 UTF-8, §9.2.2 OpaqueString | `p2_error_reason_and_text_attributes_unbounded_unvalidated` | Bound reason/USERNAME/REALM/NONCE/SOFTWARE lengths, validate UTF-8, and document that `long_term_key_*` expects an already-prepared password. |
| P2-11 | `src/stun.pion:331-335`, `:763-777` | 8489 §14.6: MI-SHA256 may be truncated to 16..32 B in multiples of 4. | compare: `mi256_trunc_{16,20,24,28}` give pion `D=err`, ref `ok`/`M2=true` | Accept lengths 16–32 in steps of 4 and compare the truncated MAC. |
| P2-12 | `src/stun.pion:710-743` (`find_attr_offset` returns at the first match) | API contract | compare: 100 + 179 vectors where verify says `true` but decode says `err` | Validate the whole TLV chain before returning, or document that `verify_*` must be paired with `decode_message`. `IceAgent` already does both. |

## Controls: attacks that are defeated (and must stay that way)

- Header framing. Top bits 01/10/11 (RTP/DTLS/TURN-channel first byte), a wrong cookie (RFC 3489), `len % 4`, declared length larger than the datagram, trailing garbage, fewer than 20 B, a truncated attribute header, a 0xFFFF attribute length, and missing padding are all rejected. `is_stun_packet` agrees with the decoder.
- `DecodeLimits`. Negative values give `InvalidLimits`, `0` really means 0, and exact limits pass.
- Addresses. Wrong IPv4/IPv6 lengths and families 0/3/0xFF are rejected, and the reserved byte is ignored. XOR round trips at ports 0/1/0x2112/65535 and with all-zero, all-FF, loopback and cookie-equal addresses. RFC 5769 §2.2/§2.3 bytes match exactly.
- MESSAGE-INTEGRITY. The HMAC covers the header with the length patched to the end of MI, so FINGERPRINT does not change the MI (byte-identical with and without FP). This matches webrtc-rs and the reference on every vector, including `atk_mi_over_outer_length`, which applies the classic wrong-length bug and correctly yields `MI=false`. Flipping any single byte breaks MI. Wrong and empty keys give `false`. MI of 19 or 21 B and MI-SHA256 of 20 B give an error.
- Crypto. Keys over 64 B are hashed first (RFC 2202 #6, and 64/65 B against Python `hmac`). The HMAC-SHA256 MI round-trips for every key length 0–200. MD5 matches RFC 1321 and the 55/56/63/64/65/119/120-byte boundaries, and the RFC 5769 §2.4 long-term key verifies. CRC-32 gives `CBF43926`. The MAC compare goes through `crypto::constant_time_eq`, which is branch-free over the bytes; only the public length is checked early.
- FINGERPRINT. It must be last, so a duplicate FP or an attribute after it is an error. A bad CRC gives `false`. `handle_inbound` checks FP before decoding.
- Typed lengths. PRIORITY ≠ 4, USE-CANDIDATE ≠ 0, ICE-CONTROL* ≠ 8, an odd-length UNKNOWN-ATTRIBUTES, and ERROR-CODE shorter than 4 B or with class 2/7 or number 100 are all rejected. Reserved ERROR-CODE bits are masked. The encoder refuses code 700, a 13-bit method, and a short transaction ID.
- ICE authentication. A forged MI (wrong password), an unsigned request, the wrong USERNAME, a response with an unknown transaction ID (off-path), a response with the right transaction ID but a bad MI, a bad FP, and RTP first bytes all leave every pair state untouched. Responses are only produced after MI verifies, and they are the same size as the request, so there is no amplification.

## Benchmark honesty (`packages/stun/bench/`)

- The numbers reproduce within noise (0.62× / 0.61× against 0.65× / 0.61× in the README). The stdout SHA-256 is identical between Pion and webrtc-rs and matches the README prefixes. The inputs are the same 100,000-packet three-way mix on both sides, and both sides really compute HMAC-SHA1 and CRC-32; webrtc-rs uses `ring` (`ring 0.17.14` in the build).
- Notes, none of which are cheating:
  - (a) `decode_verify` cycles 300 distinct packets, so both sides run cache-warm.
  - (b) Pion walks the packet three times (`verify_fingerprint`, `verify_message_integrity`, `decode_message`), while webrtc-rs decodes once and then checks. The comparison is fair to Rust.
  - (c) The decode stdout is a 65-byte checksum, and success is enforced by exit codes (Pion returns 2/3/4, Rust `unwrap`), which is weaker evidence than hashing every decoded field.
  - (d) `bench/rust` has no `Cargo.lock`, so `stun = "0.8"` is not pinned. The audit's own oracle pins `=0.8.0` with a lock file.
  - (e) The repository's root `BENCHMARKS.md` has no `stun` row yet (AGENTS.md §1.3).
  - (f) There is no MI-SHA256, IPv6-heavy or long-key workload.

## Layout

```
audit/
  run_audit.sh            all | build | unit | compare | fuzz | dos | bench
  pion.toml, src/helpers.pion
  control_test.pion       11 control_* (must PASS)
  redteam_test.pion       19 p1_*/p2_* (FAIL = evidence; turn green when fixed, do not weaken)
  oracle/                 Pion oracle: decode | encode | fuzz | dos
  diff/stunref.py         stdlib-only RFC reference + corpus generator (gen | decode)
  diff/rust/              webrtc-rs stun =0.8.0 oracle (Cargo.lock pinned)
  diff/compare.py         3-way differential report
```
