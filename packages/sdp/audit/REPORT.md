# Red-team audit: `packages/sdp` v0.1.0

- **Target**: `origin/feat/pkg-sdp` @ `7a4994824efcacbc8aef1b912a91d533a26ed162`
  (`packages/sdp/src/{types,sdp,jsep}.pion`, 287 + 745 + 879 lines, all read in full).
- **Branch**: `audit/redteam-sdp`. Only `packages/sdp/audit/` was added; `src/`, `sdp_test.pion`
  and the rest of the repository are untouched.
- **Oracles** (`--release`, exact pins): webrtc-rs [`sdp` =0.9.0](https://crates.io/crates/sdp)
  and Mozilla/Firefox [`webrtc-sdp` =0.3.17](https://crates.io/crates/webrtc-sdp).
- **Toolchain**: `pionc 0.1.0 (arm64_apple, self-hosted)`, cargo 1.100.0, node v24.22.2, macOS
  arm64 (`tokyo-mac-studio-0`).
- **Reproduce**: `sh packages/sdp/audit/run_audit.sh all` (about 30 s; everything is written to
  `/private/tmp/pion-sdp-audit`, and `git status --porcelain --ignored` stays empty).

## Verdict

| Severity | Count | Summary |
|---|---|---|
| **P0** | 1 | Under the default `ParseLimits`, an 800 KB remote SDP makes `extract_webrtc_summary` keep 102 M strings: **4.9 GB RSS natively, and a wasm32 OOM trap**. |
| **P1** | 4 | Fingerprint copy amplification (×256); `serialize` CRLF injection (a forged `a=fingerprint` can win); RFC 8853 simulcast `,` and `~` returned as fake RID ids. |
| **P2** | 18 | RFC strictness and lossiness gaps, missing validation, and diagnostics (see the list). |
| Sound | 8 control groups | No panic, trap, hang or overflow. Limits are exact, parsing is linear, the four build modes agree byte for byte, 18,000 fuzz cases pass the round-trip invariants. |

`redteam_test.pion` result: 31 tests in total. The 23 `redteam_*` tests **fail**, and each
failure is evidence of a defect. All 8 `control_*` tests pass. The package's own
`sdp_test.pion` still passes (9/9).

---

## P0

### P0-1 `extract_webrtc_summary` amplifies session-level `a=ice-options` by O(media × tokens)

- **Where**: `src/jsep.pion:279` (`let mut options = extract_ice_options(session.attributes)`),
  `:253-273` (`split_ws` allocates a new string for every token), and `:291-294` (the
  session-level array is kept whenever the m-line has no `ice-options` of its own). It is called
  once per m-line by `extract_webrtc_summary` at `:857` (`ice: ice_credentials(desc, i)`).
- **Causal chain**: one session line `a=ice-options:x x x …` holds T tokens and is followed by
  M m-lines. Every `MediaSummary.ice.options` is a freshly split copy, so the summary holds
  M·T `String` objects (about 48 B each). `ParseLimits::default()` allows 1 MiB of input and
  256 m-lines, so T ≈ 400 k and M = 256 both fit.
- **Trigger**: ① default configuration. Any remote offer or answer that reaches the usual
  `parse` → `extract_webrtc_summary` flow is enough, and the remote SDP comes from the untrusted
  peer.
- **Evidence** (`run_audit.sh amp`):

  | m-lines | input bytes | summary option strings | summary ms | max RSS |
  |---|---|---|---|---|
  | 1 | 800,069 | 400,001 | 5 | 28.6 MB |
  | 16 | 800,234 | 6,400,016 | 79 | 319 MB |
  | 64 | 800,762 | 25,600,064 | 303 | 1.25 GB |
  | 256 | 802,874 | **102,400,256** | 1,201 | **4.95 GB** |
  | 256 (wasm32 --release) | 802,874 | — | — | `RangeError: WebAssembly.Memory.grow(): Unable to grow instance memory` (exit 1) |

  Minimal reproduction: `redteam_p0_summary_ice_options_amplification` (1,000 tokens × 256
  m-lines gives 256,000 summary entries from 4,892 input bytes).
- **Oracles**: neither builds a per-m-line expanded view. Mozilla rejects `ice-options` tokens
  that are not ICE options, and webrtc-rs keeps a single attribute string.
- **Fix**:
  1. Bound `ice-options` to RFC 8839 §5.6 `ice-option-tag` syntax and a small count, for
     example 32 tokens or 256 bytes, and fail the summary past that bound.
  2. Split the session-level value **once** in `extract_webrtc_summary` and share that one
     array among the m-lines that inherit it.

  Either change alone removes the ×M factor. Side effect: none for real browsers, which send
  one or two tokens (`trickle`, `renomination`).

---

## P1

### P1-1 Session-level `a=fingerprint` is copied for every m-line, with no length check

- **Where**: `src/jsep.pion:300-323`. `find_fingerprint` slices the value, which copies it,
  every time `fingerprint(desc, i)` is called, and that happens once per m-line (`:858`).
- **Evidence**: an 800 KB fingerprint with 256 m-lines produces **204,800,000** summary bytes
  and 210 MB RSS, against 4.5 MB for 1 m-line. `redteam_p1_summary_fingerprint_amplification`
  shows 1,024,000 bytes from 6,901 input bytes.
- **Trigger**: ① default configuration. It is linear in M (×256), so it is P1 rather than P0.
- **Oracle**: Mozilla decodes the hex into `Vec<u8>` and rejects lengths that do not match the
  hash (`fp_wrong_length_sha256`: `ERR …fingerprint has…`).
- **Fix**: validate against RFC 8122 §5 (`2UHEX *(":" 2UHEX)`, with the length matching the
  algorithm: sha-1 is 20 bytes, sha-256 32 and sha-512 64), which caps a value at 191
  characters. Also resolve the session-level fallback once. The validation also fixes P2-6
  and P2-7.

### P1-2 `serialize` writes caller fields verbatim: CRLF injection forges SDP lines

- **Where**: `src/sdp.pion:626-745` (`serialize`) and `:612-623` (`write_attribute`). Every
  `String` field is passed to `sb.write_string` with no check for `\r`, `\n` or `\0`. The same
  holds for `format_ice_candidate` (`src/jsep.pion:153-213`).
- **Causal chain**: when an application builds or edits a `SessionDescription`, for example an
  SFU or signaling server that sets `session_name` from a room title or `a=msid` from
  client-chosen track ids, a value such as `"s t\r\na=fingerprint:sha-256 EV:IL"` becomes a real
  line. `find_attr_value` returns the **first** attribute that matches (`src/jsep.pion:238-249`).
  An injected media-level fingerprint placed before the genuine one therefore **replaces the
  DTLS fingerprint** that the receiving peer will pin, which is a man-in-the-middle primitive.
- **Trigger**: ③ the caller puts untrusted strings into a hand-built description. Values that
  come out of `parse()` cannot contain line breaks (`control_parsed_values_cannot_carry_line_breaks`),
  so a plain parse → serialize relay is safe.
- **Reproductions**: `redteam_p1_serialize_crlf_injection_session_name` (an injected
  session-level `a=fingerprint` is returned by `fingerprint()`) and
  `redteam_p1_serialize_crlf_injection_media_attr_overrides_fingerprint` (`EV:IL` wins over the
  genuine sha-256 value).
- **Fix**: give `serialize` a validating form that returns
  `Result[String, SdpError]` (or add `serialize_checked`). It should reject
  `\0`/`\r`/`\n` in every field, `:` and space in `Attribute.key`, and space in single-token
  fields (`media_type`, `protocol`, formats, origin fields, `bwtype`). It should also reject
  `version != 0` and an empty `session_name`, which `parse` would not read back. Side effect:
  this is an API change, but parsed descriptions always pass.

### P1-3 RFC 8853 simulcast alternatives (`,`) and paused ids (`~`) come back as RID ids

- **Where**: `src/jsep.pion:770` splits each list on `;` only. `send 1,2;~3` returns
  `send_rids = ["1,2", "~3"]`. No `a=rid` line matches either string, and the paused state is
  lost.
- **Spec**: RFC 8853 §5.1: `sc-str-list = sc-alt-list *(";" sc-alt-list)`,
  `sc-alt-list = sc-id *("," sc-id)`, `sc-id = [sc-id-paused] rid-id`,
  `sc-id-paused = "~"`.
- **Oracle**: Mozilla returns `send:1,2;3` structured as alternatives, and `~q` with
  `paused=true` (`sim_alternatives_comma`, `sim_paused_tilde`,
  `browser_safari_answer_simulcast_paused`).
- **Trigger**: ① any standards-conformant simulcast offer or answer that uses alternatives or
  pausing. A consumer that maps simulcast layers to `a=rid` restrictions gets ids that do not
  exist, and drops or mis-routes those layers.
- **Reproduction**: `redteam_p1_simulcast_alternatives_and_paused_ids`.
- **Fix**: model each `Simulcast` list as `Array[Array[SimulcastId { id, paused }]]`. Validate
  each `rid-id` (`1*(ALPHA / DIGIT / "-" / "_")`) and require at most one `send` and one `recv`
  (see P2-14).

---

## P2

Each item has a failing `redteam_p2_*` test unless marked "report only".

| # | Finding | Where | Reproduction / oracle |
|---|---|---|---|
| P2-1 | `format_ice_candidate` does not escape tokens. `ufrag = "abcd raddr 6.6.6.6"` re-parses as `raddr 6.6.6.6`. | `jsep.pion:153-213` | `redteam_p2_format_ice_candidate_token_smuggling` |
| P2-2 | An `Attribute.key` that contains `:` re-splits on the round trip (`setup:active x` becomes key `setup`). | `sdp.pion:612-623` | `redteam_p2_serialize_attribute_key_resplit` |
| P2-3 | The `extmap` id range is wrong: 1..4095 is accepted, which includes 256..4095, ids that are never valid on the wire (a consumer that narrows to u8 maps 257 onto 1). The RFC 8285 offer-only range 4096..4351 is rejected. | `jsep.pion:482, 488` | `redteam_p2_extmap_id_range`. Mozilla accepts any u16 id and rejects 65536. Fix: valid ids are 1..255, with 4096..4351 allowed only in offers. |
| P2-4 | `fingerprint` is not validated: `sha-256 zz:zz` and `sha-256 AA:BB` are returned as usable. | `jsep.pion:300-312` | `redteam_p2_fingerprint_not_validated`. Mozilla rejects both. |
| P2-5 | A malformed media-level `a=fingerprint` (no value) is skipped silently, and the session-level fingerprint is used instead. | `jsep.pion:304-305, 316-322` | `redteam_p2_fingerprint_malformed_media_falls_back_to_session`. Mozilla rejects the document. |
| P2-6 | With several fingerprints, only the first is exposed, so a leading sha-1 hides the sha-256 one (RFC 8122 §5, RFC 8827 §6.5). | `jsep.pion:238-249, 300` | `redteam_p2_fingerprint_only_first_of_several`. Mozilla keeps all of them. |
| P2-7 | The README promises a "100% lossless roundtrip", but `e=`, `p=`, `r=`, `z=` and `k=` are dropped, so repeat times and time-zone offsets disappear. | `sdp.pion:536-540` | `redteam_p2_roundtrip_drops_r_z_k_e_p`. webrtc-rs keeps them (`repeat_times`, `time_zones`). |
| P2-8 | TAB and DEL are rejected in `s=`, `i=` and `a=` values. RFC 8866 §9 `byte-string` allows everything except NUL, CR and LF. | `sdp.pion:365` | `redteam_p2_text_fields_reject_tab_and_del`. Both oracles accept. |
| P2-9 | A trailing empty line rejects the whole document. | `sdp.pion:373` | `redteam_p2_trailing_empty_line_rejected`. Both oracles accept. |
| P2-10 | The RFC 8866 §5 field order is not enforced (`t=` before `o=`, `a=` before `s=`), and `serialize` reorders silently. | `sdp.pion:392-541` | `redteam_p2_field_order_not_enforced`. Both oracles reject. |
| P2-11 | A duplicate `i=` overwrites the first one. Several media-level `c=` (allowed for layered multicast) keep only the last. | `sdp.pion:431-438, 448-455` | `redteam_p2_duplicate_i_and_c_silently_overwritten`. webrtc-rs rejects the duplicate `i=`; Mozilla rejects the duplicate `c=`. |
| P2-12 | `e=`, `p=`, `r=` and `z=` inside a media section are accepted and dropped. | `sdp.pion:536-540` | `redteam_p2_session_only_fields_in_media_accepted`. Both oracles reject. |
| P2-13 | The JSEP-layer errors are all `InvalidSyntax(0, …)`, so the caller cannot locate the bad line. | `jsep.pion:70-763` | `redteam_p2_jsep_errors_have_no_line_number` |
| P2-14 | Simulcast with a duplicate `send` direction, or with empty lists (`send ;;`), is accepted. | `jsep.pion:761-787` | `redteam_p2_simulcast_duplicate_direction_and_empty`. Mozilla rejects both. |
| P2-15 | All or nothing: one malformed attribute anywhere, even on a rejected m-line (port 0), fails the entire summary, and the error does not say which m-line. | `jsep.pion:813-848` | `redteam_p2_summary_all_or_nothing`. Mozilla drops the bad candidate and records a warning. Fix: record per-m-line errors and skip `port == 0` m-lines. |
| P2-16 | Port plus count can overflow: `65535/2` is accepted. | `sdp.pion:245-258` | `redteam_p2_port_count_overflow` |
| P2-17 | `ice-ufrag` (4..256) and `ice-pwd` (22..256) lengths and character set are not checked (RFC 8839 §5.4). | `jsep.pion:276-297` | `redteam_p2_ice_credentials_not_validated` |
| P2-18 | `a=sctp-port:65536` and an overflowing `a=max-message-size` silently become `None`, which looks the same as "absent". The legacy `a=sctpmap:5000 webrtc-datachannel 1024` is not recognised. | `jsep.pion:702-715` | `redteam_p2_sctp_values_out_of_range_become_absent`. Mozilla rejects both out-of-range values. |

Report only (no test, because the API cannot express the fix without a design decision):

- `bundle_groups` accepts empty groups, duplicate mids (`BUNDLE 0 0 9`) and mids that name no
  m-line. `WebRtcSummary.bundle_mids` merges several BUNDLE groups into one list, so the group
  boundaries are lost (`jsep.pion:631-656, 797-807`).
- A duplicate `a=mid` across m-lines is not detected (`mid_duplicate_across_media`). Conflicting
  direction attributes (`a=sendonly` + `a=recvonly`) are resolved first-wins with no error
  (`jsep.pion:599-614`).
- A missing `c=`, both at session level and in an m-line, is accepted (RFC 8866 §5.7 requires
  one or the other). webrtc-rs is just as lenient, and Mozilla rejects it.
- `parse_ice_candidate` strips a second `candidate:` prefix
  (`a=candidate:candidate:1 …` is accepted). `a=setup:ACTPASS` returns `None`.
- The package's own `sdp_test.pion` has only 9 tests for 2,548 lines of code.

---

## Differential summary (`run_audit.sh diff`, 78 named cases, with the full table in `$AUDIT_OUT/diff.md`)

- **Browser corpora** (Chrome/Meet offer with mDNS, IPv6, TCP, `network-cost`, `b=AS`/`TIAS`,
  `extmap-allow-mixed`, `3/sendonly`, `rtcp-fb:*`, RID and simulcast, FID/SIM, SCTP over IPv6;
  the same with LF-only line ends; a Firefox offer with `49170/2`, `{uuid}` msids,
  `end-of-candidates` and `UDP`/`TCP` in upper case; a Safari answer with IPv6 and `~l`): Pion's
  `m=`/`sa=`/`ma=` attribute counts equal webrtc-rs's exactly, and the parse is accepted
  by all three implementations. Pion's summary differs from Mozilla's only on the simulcast
  structure (P1-3).
- **Cases where Pion is stricter than an oracle and correct** (controls): NUL and bare CR
  (webrtc-rs accepts both), `a=`, `a=:x`, `a=x y`, `m=` with double spaces, `m=…/0`, candidate
  priority above `uint32`, and component 0.
- **Cases where Pion is laxer than both oracles**: field order (P2-10), `e=` in a media section
  (P2-12) and duplicate `i=` (P2-11). Pion also accepts Latin-1 bytes in `s=`, which both
  oracles reject (webrtc-rs with `stream did not contain valid UTF-8`, Mozilla as not UTF-8).
  Accepting them is intended (byte-string), so it is not a finding.
- 43 of the 78 cases show some accept/reject disagreement with at least one oracle. Each one
  falls into one of four groups:
  - a finding above;
  - a deliberate strictness choice listed as a control;
  - webrtc-rs having no typed attribute layer (it accepts at parse time anything that Pion
    rejects in `extract_webrtc_summary`, such as pt 128 or ssrc 2³²);
  - Mozilla-only policies: it requires `c=` (`m_port_count_2`, `legacy_sctpmap`), it validates
    the `o=` address (the `x` address in `t_start_gt_stop`), it refuses `k=`, and it accepts an
    upper-case `A=` with a warning.

## Fuzz and Native ↔ Wasm32 parity (`run_audit.sh fuzz`, `run_audit.sh diff`)

- **Structure-aware mutation fuzz**: 3 seeds × 6,000 = **18,000 cases per target** on both
  Native `--release` and Wasm32 `--release` (node), so 36,000 runs in total.
  - **Mutation sources**: Chrome/Meet, Firefox and Safari seeds; replacing one digit run with
    an extreme value (0, −1, 127, 128, 255, 256, 4095, 4096, 65535, 65536, 2³¹, 2³², 2⁶³,
    10²⁰ and others); inserting, replacing or deleting control and delimiter bytes
    (`\0 \t \r \n : / ; , ~ = *`, DEL and bytes ≥ 0x80); inserting, duplicating, deleting or
    swapping lines; a dictionary of 70 adversarial lines; random printable lines; LF-only line
    ends; truncation; and 1/16 raw random bytes after `v=0`.
  - **Invariant checked for every accepted input**: `serialize(parse(x))` re-parses, `serialize`
    is idempotent, and the structure digest and the summary digest are both preserved.
  - **Result** for seeds 1, 2 and 3 (parse ok / summary ok): 2946/2237, 2935/2294 and
    3010/2296. **0 round-trip violations, 0 panics, 0 traps, 0 hangs** (each run is capped at
    600 s, and a full run takes under 3 s).
  - **Parity**: the Native and Wasm32 outputs are byte-identical, including the per-seed FNV-64
    over all verdict strings (`03348e2155753a93`, `f02b159f7e7ffde4`, `957980bfc4af35f4`).
- **Differential verdicts in 4 modes** (native release and debug, wasm32 release and debug):
  all four produce the same SHA-256 (`cc154f25…9dfd`).

## Complexity (`run_audit.sh perf`, 5 repetitions per phase, ms)

| shape | n | parse | summary | serialize |
|---|---|---|---|---|
| `a=rtcp-fb` × n in one m-line | 16k / 64k / 256k | 4 / 15 / 62 | 8 / 31 / 135 | 1 / 5 / 20 |
| m-lines × n | 16k / 64k / 256k | 22 / 81 / 336 | 46 / 181 / 726 | 5 / 18 / 67 |
| `a=candidate` × n | 16k / 64k / 256k | 6 / 27 / 112 | 23 / 97 / 425 | 3 / 9 / 37 |
| `a=group:BUNDLE` with n mids | 16k / 64k / 256k | 1 / 2 / 7 | 1 / 4 / 19 | 0 / 1 / 2 |

Every phase grows by about 4× for each 4× step in n, so parsing, the summary and `serialize`
(which uses a `StringBuilder`) are linear. There is no O(n²) path. The only super-linear
behaviour is the **cross-term** of session-level attributes × m-lines (P0-1, P1-1).

## Controls (attack surface probed and found sound)

- `ParseLimits`: max_bytes, max_lines, max_media_sections and max_attributes_per_section each
  behave correctly at the exact value, at exact−1, at 0 and at −1
  (`control_parse_limits_exact_boundaries`).
- Integer bounds never overflow or panic: port 65536 and 10²⁰, port count 0, `b=` and `t=`
  above `Int64`, pt 128 and −1, ssrc 2³² (with 2³²−1 accepted), candidate priority 2³²
  (2³²−1 accepted), candidate port 65536, extmap 0, and `max-message-size` = `Int64` max.
- Line structure: NUL, bare CR, unknown or upper-case field type, `v=` not first, duplicate
  `v=`/`o=`/`s=`, `v=1`, a 5-field `o=`, a negative session id, a missing or negative `t=`,
  and `o=`/`s=`/`t=`/`u=` inside a media section are all rejected.
- UTF-8 and high bytes are kept verbatim and survive the round trip, and nothing is truncated.
- A value produced by `parse` cannot carry a line break, so a parse → serialize relay is
  injection-free.
- ICE credentials: a media-level value overrides the session-level one, the session-level value
  is the fallback, and an out-of-range or negative `media_idx` is safe.

## Fix priority

1. P0-1 (with P1-1 in the same change): resolve session-level fallbacks once, and bound and
   validate `ice-options` and `fingerprint`.
2. P1-2: add a validating `serialize` (`Result`) and `format_ice_candidate` (also fixes P2-1
   and P2-2).
3. P1-3 together with P2-14: model simulcast per RFC 8853 (alternatives, paused ids, single
   direction).
4. P2: decide on strictness against RFC 8866 (field order and the TAB/trailing-line leniency),
   then return line numbers from the JSEP layer and per-m-line errors from the summary.
