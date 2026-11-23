# `packages/asn1` red-team audit (Wave 10 · RT-asn1)

Baseline: `origin/feat/pkg-asn1` @ `f3ea1ff` (package untouched; everything lives in `packages/asn1/audit/`).
References: Go 1.27.3 `crypto/x509` + `encoding/asn1` + `encoding/pem` + `x/crypto/cryptobyte` v0.58.0 ·
Rust `der` 0.7.10 / `spki` 0.7.3 / `pkcs8` 0.10.2 / `x509-parser` 0.16.0 / `pem` 3.0.6 / `rustls-webpki` 0.103 ·
OpenSSL 3.5.9 (real keys and certificates) · `pionc 0.1.0` (`AFK-surf/pion@c375cee`), node v24.22.2.

Reproduce everything: `sh packages/asn1/audit/run_audit.sh` (or `build | tests | diff | wasm | probe | bench`).
Artefacts go to `/private/tmp/rt-asn1` (`AUDIT_OUT` overrides); the worktree stays clean.

## Summary

| Severity | # | Findings |
|---|---:|---|
| P0 | 0 | — |
| P1 | 4 | inner/outer `signatureAlgorithm` mismatch accepted · several `[3]` extensions blocks merged (parser differential vs Go) · O(N²) duplicate-extension check: one 2.4 MB certificate burns ~15 s CPU · recursive RC drop of `DerElement` overflows the stack (wasm32 at ~12k levels, native SIGSEGV at ~60k) |
| P2 | 16 | DER DEFAULT values accepted · negative serial · unique IDs unchecked · SIZE(1..MAX) · KeyUsage non-minimal · email/URI SAN not IA5 · constructed `[2]` dNSName · Go-compatible PrintableString `*`/`&` rejected · non-DirectoryString DN values reject the cert · OID arcs > UInt64 rejected · IPv4-embedded / zoned IPv6 literals fall back to DNS SANs · wildcard matches invalid hosts · malformed SAN patterns honoured · PKCS#8 trailing fields + v2 publicKey lost · generic tree accepts primitive SEQUENCE / EOC · PEM label grammar · `encode_der_element` O(depth²) |
| Controls | 11 tests, ~8.3k identical differential vectors | trailing garbage, DER header/primitive malleability, integer/OID/time boundaries, strings, X.509 structural attacks, tbs/SPKI raw slices, 30+ RFC 6125 vectors, PEM/base64 strictness, SPKI/PKCS#8 byte-exact round trip, default depth limit |

`pionc test --json packages/asn1/audit`: **30 audit tests — 19 FAIL (p1/p2 evidence), 11 PASS (controls)**; the 43 package + `base64` tests still pass.

Differential: **9,040 vectors** (5,878 typed-DER incl. 5,460 seeded mutations, 336 tree, 1,086 X.509 incl. 960 mutated
OpenSSL certificates, 1,056 hostname, 36 PEM, 648 SPKI/PKCS#8), **8,322 byte-identical across Pion / Go / Rust**;
every divergence is classified in `diff.md` (excerpts below). Pion is **never** the only implementation to accept a
typed-DER or X.509 vector (`PION_ONLY_ACCEPTS` = 0 for all of them); the two PKCS#8/SPKI "Pion-only" accepts are
valid DER with OIDs the references do not know (`2.16277.110`).

Wasm32: native debug / native release / wasm32 debug / wasm32 release produce **byte-identical output on all 9,040
vectors** (`sha256 17e973e4…`), 0 traps.

---

## P1

### P1-1 Inner/outer signature algorithm mismatch accepted
`src/x509.pion:487` parses `TBSCertificate.signature`, `src/x509.pion:636` parses `Certificate.signatureAlgorithm`;
they are never compared. RFC 5280 §4.1.1.2 requires them to be identical; Go rejects
(`x509: inner and outer signature algorithm identifiers don't match`). The parser hands back two different
`AlgorithmIdentifier`s, so a verifier keyed on `outer_signature_algorithm` checks the signature under an algorithm the
CA never committed to in the signed bytes (the classic algorithm-substitution precondition). The mutation fuzzer hit
it naturally: `x509.realmut.1.59` / `2.39` (one flipped bit) — Go: mismatch error, Pion: OK.

```
test p1_inner_outer_signature_algorithm_mismatch_accepted
  2 violation(s): outer ecdsa-with-SHA256 vs inner Ed25519 accepted |
                  outer Ed25519+NULL params vs inner Ed25519 (absent params) accepted
diff x509.sigalg_mismatch   pion=OK  go=ERR:x509: inner and outer signature algorithm identifiers don't match  rust=OK
```
Fix: after parsing the outer AlgorithmIdentifier, compare its raw TLV byte-for-byte with the inner one.

### P1-2 Multiple `[3]` extensions blocks are merged (parser differential)
`src/x509.pion:528-633` loops over every remaining TBS element; each `[3]` block (`:541`) is parsed and appended, and
`[1]`/`[2]` may appear anywhere, any number of times (`:533`). TBSCertificate has exactly one optional `[3]`.
Go reads the first `[3]` only and ignores the rest; x509-parser rejects. A SAN placed in a second block is therefore
invisible to Go-based tooling (CA linters, CT monitors, cfssl/zlint-style policy checks) yet honoured by Pion:

```
test p1_multiple_extensions_blocks_parser_differential
  two [3] extensions blocks accepted; verify_hostname(victim.example.com)=true
diff x509.two_ext_blocks  pion=OK:…ext=3:san=1  go=OK:…ext=2:san=0  rust=ERR
```
Fix: enforce the ASN.1 order `[1]? [2]? [3]?`, each at most once, then require `tbs.is_eof()`.

### P1-3 Duplicate-extension check is O(N²): CPU exhaustion from one certificate
`src/x509.pion:565-573` scans the whole `extensions` array (string compares) for every new extension. Default
`DecodeLimits.max_bytes` is 16 MiB and there is no extension-count limit, so a single peer certificate can pin a CPU
for minutes (TLS allows 16 MiB certificates). Go uses a map, x509-parser does not check at all.

`run_audit.sh bench` (one cert, N distinct unknown extensions, CPU seconds, loaded shared machine):

| N | DER bytes | pion | go | rust |
|---:|---:|---:|---:|---:|
| 1,000 | 19 KB | 0.00 s | 0.00 s | 0.00 s |
| 16,000 | 302 KB | 0.23 s | 0.00 s | 0.00 s |
| 64,000 | 1.2 MB | 4.10 s | 0.02 s | 0.00 s |
| 128,000 | 2.4 MB | 15.24 s | 0.06 s | 0.00 s |

Quadratic fit ⇒ ~800k extensions in 16 MiB ≈ 10 min CPU per certificate. Adversarial shape `many_ext`
(4,000 extensions, 20 parses): **Pion 0.08× Go, 0.04× Rust** (table in Fairness).
Fix: hash set of extension OID bytes (or sort + adjacent compare), plus an optional `max_extensions` limit.

### P1-4 `DerElement` teardown recurses: stack overflow on wasm32 / native when `max_depth` is raised
The README claims "100% iterative … immune to stack overflow on both Native and Wasm32". Parsing *is* iterative, but
dropping the resulting tree is the runtime's recursive reference-count release (`pion_rc_dec_slow` →
`pion_drop_struct_*` → `pion_rc_dec_slow` …). With `DecodeLimits.max_depth` raised (a public, documented knob):

```
run_audit.sh probe   (deep <n> <n+1> parse  = parse, print, drop)
native  n=50000   rc=0    parsed, dropped ok
native  n=60000   rc=139  parsed            <- SIGSEGV in drop
wasm    n=8000    rc=0    parsed, dropped ok
wasm    n=12000   rc=1    parsed  RangeError: Maximum call stack size exceeded
          at pion_rc_dec_slow / p_asn1__pion_drop_struct_… (built with --wasm-names)
```
The same applies to any `DerElement` tree a caller builds by hand and to `encode_der_element` inputs. With the default
`max_depth = 64` the tree never gets deep (control `control_default_depth_limit_blocks_deep_trees`).
Fix: give `DerElement` an iterative teardown (move children into an explicit stack before release) or cap
`max_depth` at a value proven safe on wasm32 (≤ 4,000 here) and document it; ideally fix recursive drop in the
Pion runtime.

---

## P2

| ID | Finding | Root cause | Evidence (test / diff) | References |
|---|---|---|---|---|
| P2-1 | DER DEFAULT values accepted: explicit `version [0] 0`, `critical FALSE`, BasicConstraints `cA FALSE` (X.690 §11.5) → malleable TBS / fingerprints | `x509.pion:464`, `:579`, `:317` | `p2_explicit_default_values_accepted` (3 violations) | Go, Rust accept too |
| P2-2 | Negative serial accepted (RFC 5280 §4.1.2.2); 0 and 21-byte serials also accepted | `x509.pion:483` | `p2_negative_serial_accepted`; `x509.serial_negative` go=`ERR negative serial number` | Go rejects negative |
| P2-3 | issuer/subjectUniqueID: order, count, primitive form unchecked (after `[3]`, duplicated, constructed) | `x509.pion:533-540` | `p2_unique_ids_unvalidated_order_and_count` (3) ; `x509.dup_issuer_uid` go sees 0 ext, rust ERR | Rust rejects 2/3 |
| P2-4 | SIZE (1..MAX) not enforced: empty extensions, empty SAN, empty RDN SET | `x509.pion:549`, `:255`, `:90` | `p2_size_1_to_max_not_enforced` (3) | Go/Rust equally lax (low) |
| P2-5 | KeyUsage named bit list not minimal (trailing zero octet, empty) | `x509.pion:340` | `p2_key_usage_named_bit_list_not_minimal` (2) | Go/Rust lax (low) |
| P2-6 | rfc822Name / URI not validated as IA5String: bytes ≥ 0x80 and invalid UTF-8 end up in a `String` (`byte[8]=255`) | `x509.pion:263-287` (only dNSName checks ASCII) | `p2_san_ia5string_not_validated_for_email_and_uri`; `x509.san_uri_invalid_utf8` go=`ERR …malformed` | Go rejects |
| P2-7 | Constructed `[2]` (0xA2) surfaces as `DnsName` containing the raw inner TLV | `x509.pion:269` checks number, not the constructed bit | `p2_san_constructed_tag_treated_as_dns_name`; `x509.san_dns_constructed` go san=0 | Go ignores |
| P2-8 | PrintableString `*` / `&` rejected → whole cert rejected (Go allows both deliberately for wildcard CNs; Rust accepts) | `der_reader.pion:417` | `p2_dn_go_compatible_printable_asterisk_ampersand_rejected` (2) | interop |
| P2-9 | DN values that are NumericString / UniversalString / non-string reject the whole certificate | `der_reader.pion:625`, `x509.pion:99` | `p2_dn_non_directory_string_values_reject_whole_certificate` (3); `x509.realmut.3.7`, `3.70` | Go 1.27 + Rust accept |
| P2-10 | OID arcs > UInt64 (X.667 `2.25.<uuid>`) rejected; any cert carrying one in an extension / EKU / DN fails | `oid.pion:269` | `p2_oid_arcs_beyond_uint64_rejected` (2); `hand.oid.25` go=`OK:2.25.1490…` | Go `x509.OID`, x509-parser accept |
| P2-11 | `verify_hostname`: `x:…:d.d.d.d` and zoned IPv6 literals are not parsed as IPs and fall back to dNSName matching (`fe80::1%eth0` matches dNSName `fe80::1%eth0`; `::ffff:198.51.100.7` misses its own iPAddress) | `x509.pion:778` `parse_ipv6` | `p2_hostname_ipv4_embedded_ipv6_and_zone_literals_fall_back_to_dns` (3); `host.ip_in_dns.63`, `host.mapped.68` | Go/webpki |
| P2-12 | Wildcard path never validates the presented host: `x*.`, `a b.`, `evil/x.`, `a:443.` all match `*.example.com` | `x509.pion:960-972` | `p2_hostname_wildcard_matches_syntactically_invalid_hosts` (4); `host.std.8/9` | Go `validHostnameInput`, webpki `DnsName` |
| P2-13 | SAN patterns not validated: `*..example.net` matches `x..example.net`; `trailing.example.com.` pattern matches the dotless host | `x509.pion:898-972` | `p2_hostname_malformed_san_patterns_honoured`; `host.dots.26/29` | Go/webpki false |
| P2-14 | PKCS#8: SEQUENCE never checked for end after `privateKey` (garbage, v1 + `[1]` accepted); v2 `[1] publicKey` neither exposed nor re-encoded (round trip loses 35 bytes) | `x509.pion:189-219` | `p2_pkcs8_trailing_fields_unchecked` (2), `p2_pkcs8_v2_public_key_lost_on_roundtrip`; `pkcs8.inner_trail_null.*` rust=`ERR` | RustCrypto rejects; Go lax |
| P2-15 | Generic tree accepts primitive SEQUENCE/SET (0x10/0x11) and UNIVERSAL 0 (EOC) | `der_reader.pion:724-800` | `p2_generic_tree_accepts_primitive_sequence_and_eoc` (4); `tree.hand.16/17/26/27` | `der` rejects; Go accepts |
| P2-16 | PEM label grammar: `X  Y`, `X--Y` accepted, empty label (legal per RFC 7468 §3) rejected | `pem.pion:5` | `p2_pem_label_grammar` (3) | — |
| P2-17 | `encode_der_element` is O(depth²): each level re-copies the whole child encoding | `der_writer.pion:396` | bench: n=10k 0.34 s, 20k 1.28 s, 40k 5.26 s CPU (183 KB input); parse alone 0.00 s | needs raised `max_depth` |

Informational (not counted): legacy RFC 1421 PEM headers (`Proc-Type`) and non-ASCII labels rejected (Go/Rust accept);
GeneralizedTime before 2050 / UTCTime after-2049 rules are not enforced (nobody enforces them);
`Bytes.slice` copies, so every returned `Bytes` (TBS, SPKI raw, key, signature, extension values) is a fresh copy —
"zero-copy" in the README holds for `DerReader` positions only; SPKI/PKCS#8 contents (curve points, Ed25519 key length,
RSA/Ed25519 parameters) are structural only — Go validates them (`x509.spki_ed25519_short_key`, `realmut … point not on curve`).

---

## Controls (Pion holds, often stricter than a reference)

All `control_*` tests pass. Highlights from the differential (`identical_3way` = 8,322 / 9,040):

* **Trailing garbage**: 1 byte after the certificate, a TLV after `signatureValue`, inside TBS, after the
  validity / BasicConstraints / SAN / AKI values, inside SPKI, after PKCS#8 — all rejected. Go accepts 7 of these
  (`trailing_inside_cert`, `trailing_inside_tbs`, `ext_value_trailing`, `san_trailing_after_seq`, `spki.inner_trail.*`,
  `pkcs8.trail1.*`, `aki_trailing`), x509-parser 5.
* **DER header/primitive malleability**: indefinite length, `81 05`/`82 00 80`/`84 …`/`85+` lengths, high-tag < 31 and
  `0x80` leading octets, BOOLEAN ∉ {00,FF}, non-minimal/empty INTEGER, BIT STRING unused-bit rules, non-empty NULL,
  OID `0x80` sub-identifiers, constructed primitives — 0 Pion-only accepts over 5,878 typed vectors; `der` (Rust)
  accepts 7 BIT STRINGs with non-zero padding that Pion and Go reject.
* **Boundaries**: Int64::MIN/MAX, UInt64::MAX, `0.39` / `2.999` / `0.40` / `3.x`, UTCTime 49/50 pivot, leap years
  (2000 ✓, 1900 ✗, 2100 ✗), second 60, fractions, offsets, missing seconds — Go's cryptobyte accepts `YYMMDDHHMMZ`
  and `+hhmm` offsets that Pion (correctly, RFC 5280 §4.1.2.5) rejects.
* **X.509**: duplicate extension (x509-parser misses it), v1/v2 with extensions, v1 with unique IDs, version v4/−1,
  signature BIT STRING padding (Go/Rust accept), NUL in dNSName (Go accepts), IP SAN ∉ {4,16}, universal tags in
  GeneralNames, Feb-29 in non-leap years, non-minimal serial; `tbs_bytes` and `subject_public_key_info.raw` are exact
  input slices; TBS length agrees with Go `RawTBSCertificate` and x509-parser on all 8 OpenSSL certificates
  (RSA-2048/4096, P-256/384/521, Ed25519, X25519, plain) and 884/960 of their mutations.
* **Hostname** (1,056 vectors, 945 identical 3-way): no CN fallback, no partial / multi-label / `*.com` / IDN
  wildcards, case-insensitive, trailing dot, NUL in host, IPv4 leading zeros/octal/hex/integer forms never match IP
  SANs, IP hosts never match DNS SANs, IPv6 compression and brackets. Where Pion differs from Go but agrees with webpki
  it is the stricter side (`::1%eth0`, `::ffff:192.0.2.1` vs a v4 SAN, `[192.0.2.1]`).
* **PEM/base64**: non-zero trailing bits (Go accepts both `MAMCAQV=`/`MAMCAQW=`), missing/extra/mid padding, illegal
  characters, mismatched/garbled END, unclosed, nested BEGIN, text after BEGIN/END (the Rust `pem` crate accepts four
  of these).
* **SPKI/PKCS#8**: byte-exact round trip for OpenSSL RSA-2048, P-256, Ed25519, X25519 SPKI and P-256 / Ed25519
  PKCS#8 (v1); 7 algorithms parse in the differential.
* **Depth bomb under default limits**: 50,000 nested SEQUENCEs → `DepthLimitExceeded` before allocation.
* **Wasm32**: 4 build modes byte-identical over the full corpus.

---

## Fairness and performance

Adversarial shapes (`run_audit.sh bench`, `scripts/bench_compare.py --warmup 1 --rounds 5`, stdout SHA-256 identical
for all three in every round; machine shared with other jobs, so absolute numbers are noisy, ratios are stable):

| Shape | Work | pion (ms) | go_x509 (ms) | rust_x509 (ms) | pion vs Go | pion vs Rust | Peak RSS pion / go / rust (MiB) |
|---|---|---:|---:|---:|---:|---:|---|
| `real` | 8 OpenSSL certs × 20,000 | 832.9 | 581.9 | 318.9 | 0.70× | 0.38× | 2.33 / 17.48 / 2.27 |
| `big_rsa_cert` | RSA-4096 cert × 100,000 | 599.1 | 420.3 | 230.2 | 0.70× | 0.38× | 2.19 / 17.03 / 2.22 |
| `many_rdn` | 1 cert, 4,000-RDN subject × 300 | 257.8 | 182.1 | 143.3 | 0.71× | 0.56× | 2.58 / 16.84 / 3.95 |
| `many_san` | 1 cert, 4,000 dNSName SANs × 300 | 110.8 | 44.7 | 41.2 | **0.40×** | 0.37× | 2.77 / 16.20 / 2.64 |
| `many_ext` | 1 cert, 4,000 extensions × 20 | 429.3 | 33.6 | 17.6 | **0.08×** | **0.04×** | 2.89 / 15.44 / 2.83 |

SHA-256 of stdout identical across all implementations and rounds for every shape (`0ab2fee2…`, `d807c62b…`,
`459e7794…`, `2ac1b856…`, `208a117f…`). Pion keeps Rust-level memory (2.2–2.9 MiB vs Go's 15–17 MiB) and matches
its README ratios on benign input (0.70× Go), degrades on many SANs (per-entry `String` + slice copy) and falls off
the P1-3 cliff on many extensions.

### Where the W2 (0.73× Go / 0.36× Rust) and W3 (0.32× Rust) gaps come from
`oracle phases` on the README's own 100-certificate corpus (500 passes):
`tree_ms=245 x509_ms=287 x509_host3_ms=280` — the bare strict TLV walk + tree allocation of
`parse_der_element` costs ~85 % of a full `parse_x509_der`; extension decoding and the three `verify_hostname`
calls are in the noise. The gap is per-TLV overhead (a `Result[DerHeader]` per header, `Tag::equals` via
`tag_class_equals` calls, and an allocation **plus memcpy for every returned `Bytes`** — `Bytes.slice` copies,
measured at 14.6 GB/s: 20,000 × 1 MiB slices = 1,432 ms), not the X.509 logic. OID decoding of non-table OIDs
builds an `Array[UInt64]` and a `StringBuilder` per OID (`oid.pion:245-299`).

### Fairness of `packages/asn1/bench`
* W1/W2 inputs are the package's own 100 OpenSSL certificates; every implementation prints identical stdout — fair.
* W2: the Rust side matches hostnames with a 20-line hand-written matcher equivalent to Pion's, while Go runs the full
  `VerifyHostname` (host validation, lower-casing allocations): Go is slightly handicapped. x509-parser also does less
  validation work (no DER canonicality, no duplicate-extension check, lazy failures), so "0.36× Rust" compares
  strict vs lax parsing.
* W3: the Rust side reuses three `Vec` buffers across 100,000 records (`clear()`), Pion allocates three `DerWriter`s
  and copies on every `to_bytes`; Go goes through reflection (`encoding/asn1`), which is why Pion leads Go (1.40×).
  The README states the buffer-reuse difference honestly.
* The benches only exercise benign shapes. The adversarial shapes above add the missing view: `many_ext` exposes the
  P1-3 cliff (0.08× Go), `many_san` is 0.40× Go.

---

## Files

| Path | Purpose |
|---|---|
| `pion.toml`, `redteam_test.pion` | 19 finding tests (FAIL = evidence) + 11 controls |
| `oracle/` | Pion oracle: `vectors`, `deep`, `certs`, `phases` |
| `diff/go/`, `diff/rust/` | Go 1.27 / Rust oracles with the same line format |
| `diff/derlib.py`, `diff/gen_corpus.py`, `diff/gen_bench.py` | DER builder, 9,040-vector corpus (OpenSSL keys/certs generated on the fly), adversarial bench inputs |
| `diff/compare.py` | 3-way classifier → `diff.md` |
| `run_audit.sh` | one-shot runner |
