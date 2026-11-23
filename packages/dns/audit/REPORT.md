# `packages/dns` red-team audit (target `45399ac`, branch `feat/pkg-dns`)

Scope: black-box + source audit of the pure-Pion DNS codec against Go 1.27.3
`github.com/miekg/dns v1.1.63` and Rust `hickory-proto =0.24.2`
(`default-features = false`, the same feature set as `packages/dns/bench/rust`).
Pion toolchain: `pionc 0.1.0` from `~/.pion` (`AFK-surf/pion@8d110a3`), Darwin arm64.

Every finding below is backed by an executable artefact in this directory. No file
outside `packages/dns/audit/**` was changed.

| artefact | what it does | how to run |
| --- | --- | --- |
| `*_test.pion` (+ `src/lib.pion`) | 47 Pion tests. `p0_*` / `p1_*` / `p2_*` assert the RFC-correct or upstream-equivalent behaviour, so they **fail on `45399ac`**. Each failure is one confirmed finding. `control_*` tests are the control group and pass. | `pionc test packages/dns/audit` |
| `diff/` | Pion / Go / Rust drivers with the same output format, a seeded case generator (hand-written RFC edge cases, the bench corpus, 6,000 structure-aware mutants), and a comparator. It also diffs Pion native against Pion wasm32. | `sh packages/dns/audit/diff/run_diff.sh` |
| `bench/` | Adversarial head-to-head benchmarks through `scripts/bench_compare.py`: interleaved runs, SHA-256 of stdout checked identical across all three implementations. Covers a hash-collision workload and large responses. | `sh packages/dns/audit/bench/run_adv_bench.sh` |

Build outputs, Go/Cargo caches, corpora and results all go to `$RT_DIR`
(default `/private/tmp/rt-dns`). The Go and Rust harnesses commit `go.sum` and
`Cargo.lock` and build with `--locked`.

## Result summary

`pionc test --json packages/dns/audit`: **69 total, 40 passed, 29 failed**.
- The 22 tests of the `dns` package itself pass.
- In the audit package, all 18 `control_*` tests pass.
- All 29 failures are deliberate finding tests: **5 × P0, 14 × P1, 10 × P2**.

Two more P1 findings come from the benchmark harness, not from failing tests:
- #P1-14: small-message encode cost (A1 / D1 measurements).
- #P1-15: the `packages/dns/bench` methodology.

The SHA-256 check passes on every adversarial benchmark (A1–A7).

The differential run covers 10,178 cases: msg 6,389, name 1,548, ip6 635, tcp 806, doh 800.
- **Native vs wasm32: 10,178 / 10,178 byte-identical outputs, 0 panics and 0 traps on either target.**
- 1,385 messages are accepted by all three libraries. Pion's decoded owner/type/class/TTL and A/AAAA/NS/CNAME/PTR/MX RDATA match miekg in all 1,385 and hickory in all 1,385.
- Pion re-encodes every message it accepts, and its own decoder reads every result back (0 failures). miekg has 2 such failures.

## P0: encoder returns `Ok(bytes)` that are corrupt on the wire

Common pattern: `encode_message` checks only the RDATA total (≤ 65,535) and TXT /
ALPN / NAPTR string lengths. Every other field of `SvcbData`, `EdnsOption`, … is
written verbatim. The result is `Ok(wire)` that Pion's own `decode_message` rejects.
These are reachable only through values the caller builds. The decoder never
produces them. But the API contract promises an explicit `Err(DnsError)` for
invalid input, and here the failure is silent and lands on the wire.

| # | test | failing input → wire | upstream |
| --- | --- | --- | --- |
| P0-1 | `p0_edns_padding_negative_length_emits_corrupt_opt` | `EdnsOption::Padding(-1)` writes option length `0xFFFF` followed by 0 data bytes. The OPT RDATA is truncated, and the decoder fails with "truncated EDNS option data". | miekg/hickory take `[]byte`/`Vec`, so a negative length is impossible |
| P0-2 | `p0_svcb_unsorted_and_duplicate_svcparams_emitted` | `[Port, Alpn]` is emitted unsorted. `[Port(443), Port(8443)]` is emitted with a duplicate key. RFC 9460 §2.2 says MUST be strictly increasing. | miekg `packDataSVCB` sorts the keys and returns "repeated SVCB keys are not allowed" |
| P0-3 | `p0_svcb_aliasmode_with_params_emitted` | `priority = 0` plus `port=443` is emitted. Pion's own decoder treats that as fatal (see P1-2). | n/a |
| P0-4 | `p0_svcb_empty_list_params_emitted` | `Alpn([])`, `Mandatory([])`, `Ipv4Hint([])`, `Ipv6Hint([])` emit zero-length values. All four are rejected by Pion's decoder. | n/a |
| P0-5 | `p0_edns_cookie_and_ecs_invalid_lengths_emitted` | A Cookie with a 3-byte client cookie (RFC 7873 §4 requires exactly 8) is emitted. ECS family 1 `/33` with 5 address bytes is emitted. | n/a |

## P1: RFC deviations, interoperability, integer truncation, panics, real performance gaps

| # | test / evidence | finding | upstream comparison |
| --- | --- | --- | --- |
| P1-1 | `p1_rfc2136_update_zero_rdlength_rrs_rejected`; diff `hand_update_rfc2136_empty_rdata`, `hand_rdlen0_*` | **Pion cannot decode RFC 2136 Dynamic UPDATE messages.** Prerequisite and delete-RRset RRs carry `CLASS=ANY, RDLENGTH=0`. Pion rejects RDLENGTH 0 for A, AAAA, CNAME, MX, SRV, CAA, SVCB, NSEC, RRSIG and SOA ("A record must be 4 bytes", …), and rejects the whole message with it. In the diff, the `pion=ERR miekg=OK hickory=OK` mutants are dominated by this case and by P1-2. | miekg and hickory both accept (empty RDATA) |
| P1-2 | `p1_svcb_aliasmode_params_must_be_ignored_not_fatal`; diff `hand_svcb_alias_with_port` | An AliasMode HTTPS/SVCB record that carries SvcParams makes **the entire message** fail to decode. RFC 9460 §2.4.2 says recipients MUST ignore such SvcParams, so one sloppy HTTPS record poisons a whole response. | both accept |
| P1-3 | `p1_ecs_unknown_family_and_overlong_address_accepted`; diff pattern `pion=OK miekg=ERR hickory=ERR` (24 cases, 21 of them ECS family) | ECS accepts family 3, and family 0 with a non-zero prefix. It accepts more address bytes than ⌈prefix/8⌉ and non-zero bits past the prefix. RFC 7871 §6 requires the address to be truncated to the prefix with zero padding. | miekg "bad address family"; hickory "Invalid family type." |
| P1-4 | `p1_caa_tag_charset_and_length_not_validated`; diff `hand_caa_*` | A CAA tag with a space, a 16-byte tag, and a non-ASCII or invalid-UTF-8 tag are all accepted (RFC 8659 §4.1: 1–15 ASCII letters and digits). The tag is then printed raw (P1-6). | hickory rejects; miekg accepts |
| P1-5 | `p1_name_to_string_does_not_escape_zone_file_specials` | `Name::to_string` escapes only `.`, `\` and non-printable bytes. `; ( ) " @ $ '` are printed bare. | miekg escapes `. space ' @ ; ( ) " \` |
| P1-6 | `p1_to_text_zone_injection_via_unescaped_fields` | **Zone-file injection through `to_text()`.** Four unescaped fields: an owner `;evil` comments out the rest of the line; a CAA tag containing `\n` injects a whole `evil.example. 60 IN A 6.6.6.6` line; an ALPN id `h2",evil` breaks out of the quotes; `mandatory=...` is printed as a literal placeholder, so the output is lossy and cannot be parsed back. With P1-4, a hostile authoritative answer that is decoded and re-printed can forge zone lines. | miekg escapes all of these |
| P1-7 | `p1_ipv6_parse_rejects_embedded_ipv4_form`; diff ip6: 31 of the 34 differences | `Ipv6Addr::parse` rejects the RFC 4291 §2.2(3) forms `::ffff:192.0.2.1`, `64:ff9b::192.0.2.33`, `1:2:3:4:5:6:1.2.3.4`, … | Go `netip` and Rust `std::net` both accept |
| P1-8 | `p1_decode_message_at_out_of_range_bounds_panics`, `…_negative_start_panics` | The public `decode_message_at(buf, start, end, …)` does not check `0 ≤ start ≤ end ≤ buf.length()`. It raises `index 19 out of bounds (len 19)` / `index -4 out of bounds`, which is a native panic and a wasm32 trap. This contradicts the README's "0 panics". `packages/dns/bench/pion_bench` calls it with lengths read from the corpus without a bounds check, so a truncated corpus crashes the bench. With `end > len` and a short message it can instead return `Ok` for bytes that do not exist. | n/a (Go slicing panics the same way, but the Go API never takes raw offsets) |
| P1-9 | `p1_u16_fields_silently_truncated_on_encode` | Out-of-range `Int` fields are masked without error. SRV port 70000 is written as 4464; MX preference −1 as 65535; SvcParam port 65536 as 0; rtype 65537 as **type A**; TTL 2³² decodes as 0; `header.id` `0x12345` as `0x2345`. | not representable there (`uint16`/`uint32`) |
| P1-10 | `p1_nsec_type_out_of_range_lands_in_wrong_window` | NSEC `types: [1, 65536]` encodes 65536 into window 0, bit 0. The decoded NSEC then claims type 0 exists, which is wrong denial-of-existence data. | `[]uint16` |
| P1-11 | `p1_name_wire_invariant_not_enforced_pub_field` | `Name { pub wire }` is not validated by the encoder. A 150-label, 301-byte "name" is emitted verbatim by the uncompressed path. | names are validated strings or types |
| P1-12 | `p1_name_wire_invariant_compressed_path_panics` | The same name through the compressing path panics with `index 128 out of bounds (len 128)`: the `lbl_starts` scratch array has a fixed 128 slots. | n/a |
| P1-13 | `p1_svcb_mandatory_semantics_not_validated` | `mandatory` may list key 0, may be unsorted, and may reference absent keys. RFC 9460 §8 says the RR MUST then be considered malformed. **The same gap exists in miekg and hickory** (all three accept these in the diff), so this is a spec deviation, not a regression against upstream. | same gap |
| P1-14 | bench A1 + D1 | **Small-message encode is the slowest of the three.** For 1 question + 1 A: **Pion 409.6 ns/op, Go 200.3, Rust 275.8.** The same loop with `EncodeOptions::uncompressed()` takes **187.6 ns/op** (D1). So about 220 ns per message, more than half of the cost, is compression set-up: `WireWriter::new` allocates four `Array[Int]` (64 + 64 + 128 + 128 slots) plus a 512-byte buffer, and copies again in `to_bytes()`. This is the main source of the README's W2 gap (0.59x Go, 0.78x Rust). The single-question fast path skips it, which is why the query round-trip (W3) looks fast. | |
| P1-15 | bench methodology (read-only review of `packages/dns/bench`) | See [Fairness](#fairness-and-benchmark-audit): no lockfiles, a SHA check that does not cover encoded bodies, and lossy decode hashes. | |

## P2: minor edges and behavioural differences

| # | test / evidence | finding |
| --- | --- | --- |
| P2-1 | `p2_case_insensitive_compression_rewrites_owner_case` | Pion compresses suffixes case-insensitively, so an answer owner `WWW.EXAMPLE.ORG` is decoded back as `www.example.org.` (the question's case). miekg and hickory compress only byte-identical suffixes and keep the case. Not illegal, but observable, and the bench SHA check cannot see it. |
| P2-2 | `p2_srv_target_not_registered_for_glue_compression`; diff size table | A name written uncompressed (an SRV target, per RFC 2782) is never added to the compression table, so later glue A owners cannot point at it. The bench-corpus message `seed_0297` is **217 B in Pion vs 205 B in miekg and hickory**. Over the 300-message bench corpus Pion emits **+1.52 % bytes** (60 messages, each +12 B). Over all 1,385 messages the three libraries accept, Pion is the largest output in 206 of them. miekg inserts such names into its compression map even when it does not compress them. |
| P2-3 | `p2_opt_placement_not_validated`; diff `hand_opt_twice`, `hand_opt_owner_nonroot` | Two OPT records, OPT in the answer section, and OPT with a non-root owner are all accepted (RFC 6891 §6.1.1). `extended_rcode()` silently uses the first OPT. hickory rejects ("more than one edns record present", "label must be the root label"). |
| P2-4 | `p2_nsec_trailing_zero_bitmap_octets_accepted` | Trailing zero bitmap octets and all-zero windows are accepted (RFC 4034 §4.1.2 MUST omit them). miekg accepts them too. |
| P2-5 | `p2_txt_empty_rdata_accepted_and_emitted` | TXT with RDLENGTH 0 is accepted and `TXT([])` is emitted (RFC 1035 §3.3.14 requires ≥ 1 character-string). All three libraries accept it. |
| P2-6 | `p2_svcb_ech_empty_value_accepted` | A zero-length `ech` value is accepted. miekg accepts it too; hickory rejects. |
| P2-7 | `p2_pointer_into_same_name_overlap_accepted`; diff `hand_ptr_overlap_own_label` | A pointer back into the name's own label bytes (`01 00 C0 0D`) is accepted and re-read with a different label structure. hickory requires every pointer target to be before the start of the name (`PointerNotPriorToLabel`). This is a parser-differential surface. No loop is possible, because Pion's strictly decreasing target ceiling still holds. |
| P2-8 | bench A4 vs A3, A6 vs A5 | **Hash-collision complexity attack.** The compression hash is unseeded. `go_bench gen collide` brute-forces owners whose suffix hash shares its low 14 bits, so every insert and lookup walks one linear-probe cluster. Encode becomes **3.9× slower** (A4 1,117 ms vs A3 288 ms, 2,000 owners) and **4.4× slower** at maximum message size (A6 1,444 ms vs A5 326 ms, 2,750 owners). Amplification is bounded: only offsets < 16,384 are inserted. Even under attack Pion stays faster than hickory's normal case, whose `get_label_pointer` is a linear scan (O(n²) on every large response). miekg uses Go maps (seeded), so it is unaffected. Relevant to a resolver that re-encodes owner names chosen by an attacker-controlled authority. |
| P2-9 | `p2_doh_get_param_no_size_cap_before_allocation` | A 400,000-character `dns=` parameter is decoded into a 300,000-byte buffer before failing with "message size 300000 exceeds limit". RFC 8484 messages are ≤ 65,535 B (≤ 87,380 base64url chars), so the size can be rejected before allocating. |
| P2-10 | `p2_ipv6_ipv4_mapped_not_printed_in_mixed_notation`; diff ip6: 3 differences | `::ffff:c000:201` is printed instead of `::ffff:192.0.2.1` (RFC 5952 §5 RECOMMENDED form). Go and Rust both print the mixed form. |
| P2-11 | `p2_malformed_pub_name_wire_panics_in_accessors` | `Name { wire: [5, 'a'] }.to_string()` panics (`index 2 out of bounds`). Same root cause as P1-11. |
| P2-12 | diff `hand_svcb_key65535` | SvcParamKey 65535 (RFC 9460 §14.3.2 "Invalid key") is accepted as `Unknown`. miekg rejects it ("bad SVCB key"). |

## Control group: where Pion is correct, and sometimes better than upstream

All `control_*` tests pass:
- **14-bit pointer ceiling:** a 1,500-CNAME, ~45 KiB response whose targets reuse owners written past offset 16,383 round-trips bit-exactly. `table_insert` refuses offsets ≥ 16,384, so the high pointer bits are never truncated (`control_14bit_pointer_ceiling_large_response_roundtrips`).
- **Messages over 65,535 B:** Pion returns `Err(MessageTooLarge)`, and `encode_tcp` cannot wrap its 2-byte prefix (`control_message_over_65535_bytes_is_rejected_not_truncated`). With 2,900 owners:
  - Pion errors out.
  - **miekg's `Pack()` returns a 66,644-byte message**, which cannot be framed over TCP.
  - **hickory silently drops 49 of 2,900 records** (65,530 B).

  Pion is the only one of the three that is correct here.
- **Length fields:** RDATA > 65,535, a TXT chunk > 255, and 65,536 questions are rejected, never truncated.
- **RFC 3597 §4:** SRV, NAPTR, SVCB/HTTPS and NSEC targets are not compressed. hickory 0.24.2 does compress SRV targets (`srv.rs` calls `emit_with_lowercase` on the compressing path).
- **Decoder shape checks:** SVCB value shapes, Cookie lengths and NSEC window rules are enforced. Pointers into RDATA are legal. A pointer onto label bytes, into the header, forward, self-referencing, or 2-cycle is rejected. Pion allows 128 pointer hops (miekg 126).
- **Names:** `\000`, `\.`, `\\` and binary labels round-trip. `\256`, `\999`, a truncated `\12`, a dangling `\` and empty labels are rejected. The 63/64-byte label and 255/256-byte name boundaries are exact. RFC 4343 case folding is ASCII-only (0xC4 and 0xE4 stay distinct; `[`/`{` and `@`/`` ` `` are not folded). `is_subdomain_of` respects label boundaries.
- **IPv6, DoH, TCP:** RFC 5952 output passes, including equal zero runs (leftmost wins) and a single `:0:` that must not be compressed. DoH matches the RFC 8484 §6 vector and rejects padding, `+`, `/` and stray trailing bits. TCP framing handles empty input, 1-byte and half frames, 0-length frames and glued frames.
- **Name parsing differential:** Pion is stricter than miekg, which accepts `a\256.`, `a\1x.` and `a\12` as literals. Pion matches Go or Rust on 1,538 of the 1,548 name cases; the remaining 10 are rejected by Pion on purpose.
- **Large-response decode (A7):** 146 ms for Pion vs 168 ms for Go and 160 ms for Rust.
- **Large-response encode (A2, A3):** Pion is 2.9–4.9× faster than hickory but 1.5–2.0× slower than Go.

## Fairness and benchmark audit

1. **Lockfiles.** `packages/dns/bench/go` has no `go.sum` and `packages/dns/bench/rust` has no `Cargo.lock`; the run script uses `go mod tidy` and an unlocked `cargo build`. The harnesses here commit both and use `--locked`.
2. **The SHA check does not cover encoded output.** W2 (encode) hashes only the 12 header bytes of each encoded message, plus a decode hash on round 0. Pion's encoded bodies really differ from the other two: +1.52 % bytes on the same corpus (P2-2), and lost case under compression (P2-1). So the "SHA-256 identical" label on W2 does not mean equal work. In A1–A7 here, the hash covers the whole first encoded wire, and the three outputs are byte-identical.
3. **The decode hash is lossy.** `hash_rr` folds names into their label count, AAAA into 2 of 8 groups, and TXT into its total length. A decoder that corrupted label bytes would still match.
4. **Different work in decode.** Go's `Unpack` turns every name into presentation text, while Pion keeps raw wire bytes. That is a legitimate API difference, but it flatters Pion in W1 and A7.
5. **Where the W2 gap comes from.** Mostly per-message compression set-up; see P1-14 and D1. Large-response encode is not hash-bound: A2/A3 are 1.5–2× behind Go but far ahead of hickory's quadratic encoder.
6. **Noise.** All numbers come from one shared Darwin arm64 machine (median of 5 interleaved rounds, 1 warm-up). Individual medians drifted up to ~2× between runs for hickory A3. The ratios quoted above come from a single full run.

Raw tables are written to `$RT_DIR/bench-results/*.md` and `$RT_DIR/out/summary.md`.

### Adversarial benchmark (`run_adv_bench.sh`, final run)

| workload | Pion | Go miekg | Rust hickory |
| --- | ---: | ---: | ---: |
| A1 small response encode, ns/op | 409.6 | **200.3** | 275.8 |
| A2 500-owner encode, µs/msg | 70.2 | **46.7** | 200.4 |
| A3 2,000-owner encode (crosses 16 KiB), µs/msg | 287.7 | **140.7** | 1,397.4 |
| A4 2,000 **colliding** owners encode, µs/msg | 1,117.4 | **131.4** | 1,917.6 |
| A5 2,750-owner encode (~62 KiB), µs/msg | 326.4 | **157.7** | 1,587.0 |
| A6 2,750 **colliding** owners encode, µs/msg | 1,444.1 | **164.3** | 2,587.3 |
| A7 2,000-owner decode, µs/msg | **146.1** | 167.9 | 160.4 |
| D1 = A1 with `uncompressed()` (Pion only), ns/op | 187.6 | | |

Peak RSS: Pion 1.8–3.3 MiB, hickory 2.1–3.7 MiB, Go 15.5–17.1 MiB.

## Message differential: verdict patterns (final run, 6,389 cases)

| pion / miekg / hickory | cases | dominant causes (examples) |
| --- | ---: | --- |
| ERR / ERR / ERR | 4,424 | malformed mutants |
| OK / OK / OK | 1,385 | 0 content mismatches between Pion and either upstream |
| ERR / OK / ERR | 354 | Header counts that claim more records than the buffer holds: miekg returns the partial message without error, Pion (`UnexpectedEof`, or `TooManyRecords` when the counts exceed 4,096) and hickory reject. Also forward pointers, which miekg accepts. |
| ERR / OK / OK | 72 | **RFC 2136 RDLENGTH 0 (P1-1)**, **AliasMode params (P1-2)**, malformed Cookie lengths (Pion fails the whole message; RFC 7873 §5.3 makes clients discard such replies, so this is acceptable), empty ALPN id |
| OK / OK / ERR | 60 | hickory is stricter: CAA tag, OPT placement, empty `ech`, pointer overlap, strict RDLENGTH checks |
| ERR / ERR / OK | 48 | SVCB shape checks, NSEC window rules, pointer chains > 128 hops |
| OK / ERR / ERR | 24 | **ECS family not 1 or 2 (P1-3)**; HINFO / type 255 handled as opaque Unknown, which is RFC 3597-legitimate |
| OK / ERR / OK | 22 | SvcParamKey 65535 (P2-12), 127/128-hop chains (miekg limit 126), HINFO |

🤖 Generated with [Claude Code](https://claude.com/claude-code)
