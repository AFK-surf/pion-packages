# `asn1` — Pure Pion Strict ASN.1 DER, PEM & X.509 v1/v3 Engine

A pure Pion, zero-C-dependency, Native + Wasm32 compatible implementation of **ITU-T X.690 strict DER**, **RFC 7468 PEM** (built directly on `packages/base64`), **RFC 5280 X.509 v1/v3 certificates**, **RFC 6125 / RFC 9525 hostname & IP verification**, and **SPKI / RFC 5958 PKCS#8** public/private key envelopes, modeled on **Go `encoding/asn1` + `encoding/pem` + `crypto/x509`** and **Rust `der` + `x509-parser`**.

Designed with a **Sans-IO** architecture: no `World` dependency, zero-copy `DerReader` cursor views over `Bytes` (returned `Bytes` fields such as `tbs_bytes`, `raw`, keys, signatures, and extension values are owned slices produced by `Bytes::slice`), 100% iterative `DerElement` tree parsing & O(N) encoding capped at `max_safe_depth = 2048` (safe from stack overflow in recursive RC teardown on both Native and Wasm32), fast zero-allocation well-known OID matching, O(1) duplicate-extension detection, and hardened defenses against depth bombs, length OOM bombs, DER malleability, algorithm substitution, `[3]` extension smuggling, and SAN/hostname confusion.

## Features

- **Strict ASN.1 DER (`DerReader`, `DerWriter`, `DerElement`, `DecodeLimits`)**:
  - **Tags**: Universal, Application, Context-Specific, and Private classes; primitive and constructed flags; short tags (`0..30`) and base-128 high tag numbers (`>= 31`) with strict minimal encoding (rejects leading `0x80` and high-form tags `< 31`). Generic tree decoding rejects `UNIVERSAL 0` (EOC) and primitive `SEQUENCE`/`SET` (`0x10`/`0x11`).
  - **Lengths**: Definite lengths up to 4 octets (`< 2 GiB`). Strictly rejects BER indefinite length (`0x80`), non-minimal encodings (`0x81 0x05`, `0x82 0x00 0x80`), >4-octet lengths, and out-of-bounds lengths with zero allocation.
  - **Primitives & Constructed Types**:
    - `BOOLEAN` (DER `0x00` / `0xFF` only; rejects `0x01`, `0x7F`, non-1-byte length).
    - `INTEGER` (arbitrary-precision minimal two's-complement big-endian bytes + `Int64` / `UInt64`; strictly rejects empty integers and redundant leading `0x00` / `0xFF`).
    - `BIT STRING` (validates `unused_bits ∈ 0..=7`, empty bit string requires `unused_bits == 0`, trailing unused bits must be zero).
    - `OCTET STRING`, `NULL` (must have length 0), `OBJECT IDENTIFIER` (full base-128 parse/format + fast table for common X.509/crypto OIDs + arbitrary-precision >64-bit arcs such as X.667 `2.25.<128-bit UUID>`; rejects leading `0x80` and truncated subidentifiers).
    - `UTF8String` (strict RFC 3629 UTF-8), `PrintableString`, `IA5String`, `VisibleString`, `NumericString`, `BMPString` (UTF-16BE rejecting surrogates), `UniversalString` (UTF-32BE rejecting surrogates/invalid scalars), `T61String` (`read_any_string`).
    - `UTCTime` (RFC 5280 `YYMMDDHHMMSSZ`, `YY >= 50 → 19YY`, `YY < 50 → 20YY`) and `GeneralizedTime` (`YYYYMMDDHHMMSSZ`) with leap-year calendar validation to Unix seconds (`Int64`).
    - `SEQUENCE`, `SET`, explicit context-specific `[n]`, and `write_set_of_sorted` (ITU-T X.690 §11.6 canonical lexicographical sorting).
  - **Iterative Tree Codec**: `parse_der_element` / `parse_der_element_with_limits` and `encode_der_element` (2-pass pre-order O(N) linear time, single exact-sized allocation) run 100% iteratively with configurable `DecodeLimits` (`max_depth = 64`, hard-capped at `max_safe_depth = 2048` to prevent recursive RC drop stack overflow on Wasm32/Native; `max_elements = 65536`, `max_bytes = 16 MiB`).
- **RFC 7468 PEM (`parse_pem`, `parse_pem_all`, `encode_pem`)**:
  - Strict RFC 7468 §3 label grammar (`label = [ labelchar *( ["-" / SP] labelchar ) ]`, rejecting consecutive separators like `X  Y` / `X--Y` and supporting the legal empty label), `-----BEGIN LABEL-----` / `-----END LABEL-----` matching, 64-column line wrapping on encode, preamble/comment skipping, CRLF/LF normalization, multi-block chain bundles, and strict Base64 decoding via `packages/base64`.
- **RFC 5280 X.509 v1/v3 & SPKI / PKCS#8**:
  - `parse_x509_der`, `parse_x509_der_with_limits`, `parse_x509_pem`, `parse_x509_pem_chain`: parses `version` (v1/v2/v3, rejecting explicit default `[0] 0`), non-negative `serial_number`, inner/outer `signature_algorithm` (enforcing byte-exact equality per RFC 5280 §4.1.1.2), `issuer` & `subject` `DistinguishedName` (`CN`/`O`/`OU`/`C`/`ST`/`L` + full attribute list, enforcing non-empty RDN `SET`s, Go-compatible `*`/`&` in DN `PrintableString`, `NumericString`, `UniversalString`, and RFC 4514 `#<hex>` preservation for non-string DN values), `not_before` / `not_after`, `subject_public_key_info`, strict `[1]? [2]? [3]?` optional TBS ordering (primitive BIT STRING `uniqueID`s on v2+, single `[3]` extensions block on v3+), exact `tbs_bytes`, and `signature_bytes`.
  - **v3 Extensions**: `SubjectAlternativeName` (non-empty `SIZE(1..MAX)`, primitive `[1]`/`[2]`/`[6]`/`[7]` with strict IA5String validation), `BasicConstraints` (`is_ca`, `path_len_constraint`, rejecting explicit `cA = FALSE`), `KeyUsage` (all 9 flags, enforcing minimal named BIT STRING per X.690 §11.2.2), `ExtKeyUsage` (`SIZE(1..MAX)`), `SubjectKeyIdentifier`, `AuthorityKeyIdentifier`, rejecting explicit `critical = FALSE`, and O(1) amortized duplicate-OID rejection (hybrid linear ≤ 16 + open-addressing hash table over DER OID slices).
  - **Hostname & IP Verification (`verify_hostname`)**: RFC 6125 / RFC 9525 SAN matching — strict DNS label validation for both presented host and SAN patterns (no trailing dot on SAN patterns, no empty labels such as `*..example.net`, rejects invalid host characters `*`, spaces, `/`, `:`, `%`, NUL), case-insensitive DNS, leftmost single-label wildcard (`*.example.com`) only, plus exact IPv4, IPv6, and RFC 4291 IPv4-embedded IPv6 (`::ffff:198.51.100.7`) matching; zoned IPv6 literals never fall back to `dNSName`.
  - **Key Envelopes**: `parse_spki_der`, `encode_spki_der`, `parse_pkcs8_der`, `encode_pkcs8_der` with strict trailing-field rejection and byte-exact DER roundtrip across RSA, ECDSA P-256/P-384, Ed25519, X25519, and RFC 5958 PKCS#8 v2 (`[0] attributes` + `[1] publicKey`, rejecting `[1] publicKey` on v1).

## Quick Start

```pion
import "asn1"

// Parse a PEM-encoded X.509 v3 certificate and verify hostname
match asn1::parse_x509_pem(cert_pem) {
  Ok(cert) => {
    let ok = asn1::verify_hostname(cert, "api.example.com")
    let _ = ok
    let _ = cert.tbs_bytes
    let _ = cert.subject_public_key_info.public_key
  }
  Err(e) => {
    let _ = asn1::asn1_error_message(e)
  }
}

// Strict DER encode & decode
let w = asn1::DerWriter::new()
w.write_int64(42L)
w.write_bool(true)
let _ = w.write_oid_str(asn1::oid_sha256_with_rsa)
let seq = asn1::DerWriter::new()
seq.write_sequence(w.to_bytes())
let der = seq.to_bytes()
```

## Verification

- **Compliance & Red-Team Test Suite**: `pionc test --json packages/asn1` — **44 / 44 passing** (21/21 `asn1` tests + 23/23 dependency `base64` tests).
- **Wave 10 Red-Team Audit Suite**: `pionc test --json packages/asn1/audit` — **30 / 30 audit tests passing** (19/19 P1/P2 finding tests + 11/11 control tests; 74/74 total including package + `base64` tests), 9,040-vector 3-way differential (Pion vs Go 1.27 vs Rust, `8,323` byte-identical, `0` value mismatches, `0` Pion-only accepts on typed-DER/X.509/hostname/PEM/PKCS#8), 4-mode Wasm32 byte-identical (`sha256:93aa00eae45eb8a1…`), and `deep` probe `0` SIGSEGV / `0` RangeError up to `n = 100,000` on both Native and Wasm32.
- **Dual-Target Wasm32 Smoke (`packages/asn1/wasm_smoke`)**: All 4 build modes (Native debug/release + Wasm32 debug/release executed on `node` with `pion_wasm_rt.mjs`) exit `0` with byte-identical non-empty stdout (`sha256:b288d45fcb867c782303a0be5cf5cd29b02e5ae56f44415561f1609e376e0fbc`).
- **Formatting & Typecheck**: `pionc fmt --check packages/asn1` and `pionc check --json packages/asn1` pass with 0 diagnostics.

## Formal Verification (Lean 4)

Run `sh packages/asn1/proofs/run_proofs.sh` (or `sh scripts/verify-lean.sh asn1`) to extract `packages/asn1/src/*.pion` via `pionc extract-lean` and machine-check **8 production theorems** (`0 sorry`, `0 admit`, `0 native_decide`, `0 bv_decide`, only `{propext, Classical.choice, Quot.sound}`):

- **X.690 DER Tag, Length, Integer & BitString (`Asn1Proofs/TagDer.lean`, 5 theorems)**: X.690 §8.1.2 identifier octet byte bounds (`[0, 255]`), full short-form tag bijection (`0 ≤ num ≤ 30`), §8.3.2 minimal two's-complement INTEGER pair rejecting redundant leading `0x00`, §8.6/§11.2.2 empty BIT STRING zero unused-bits invariant, and §8.1.3/§10.1 canonical length byte count bounds (`[1, 5]`) & monotonicity.
- **RFC 5280 Time (`Asn1Proofs/TimePem.lean`, 3 theorems)**: Gregorian 4/100/400 `is_leap_year` spec, `days_in_month` bounds (`28..31` / `0`), and Feb 29 ↔ leap year.
- **Native vs Lean Differential**: `39/39` value cases byte-identical (`diff -u` exit `0`).

## Head-to-Head Benchmarks

Measured on `Darwin arm64` via `sh packages/asn1/bench/run_bench.sh` and `sh packages/asn1/audit/run_audit.sh bench` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) comparing:
- **`pion`**: `packages/asn1` (`pionc 0.1.0 --release`)
- **`go_x509` / `go_asn1`**: Go `go1.27.3` stdlib (`crypto/x509` + `encoding/pem` + `encoding/asn1`)
- **`rust_x509` / `rust_der`**: Rust (`x509-parser 0.16.0`, `der 0.7.10`, `pem 3.0.6`, `--release --locked`)

### 1. Real PEM Cert Chain Full Parse (100 multi-algo X.509 v3 certs × 100 = 10,000 certs, 11,010,800 B)

_SHA-256 verified identical across all implementations and rounds: `3ab4b31423628fc3545d5a72b7f0da1ba3412305cd485e56ac37a732545cd923`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_x509`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 68.050 | 67.790 | 69.271 | 161.80 | 6804.99 | 3.08 MiB | 0.89x |
| `go_x509` | 60.654 | 59.571 | 62.331 | 181.54 | 6065.36 | 16.55 MiB | 1.00x (baseline) |
| `rust_x509` | 59.519 | 59.284 | 65.117 | 185.00 | 5951.85 | 2.66 MiB | 1.02x |

### 2. Pure DER X.509 v3 Parse + 3× SAN Hostname Verify (50,000 certs, 38,604,000 B)

_SHA-256 verified identical across all implementations and rounds: `63790b358ff1381909ec8b61dab2061b036ac91dfeb24a6b1d608ede566fa33e`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_x509`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 215.075 | 210.849 | 226.265 | 179.49 | 4301.50 | 2.56 MiB | 0.85x |
| `go_x509` | 182.652 | 177.559 | 199.655 | 211.35 | 3653.04 | 18.91 MiB | 1.00x (baseline) |
| `rust_x509` | 95.695 | 94.139 | 98.284 | 403.41 | 1913.90 | 2.30 MiB | 1.91x |

### 3. Generic ASN.1 DER TLV Encode + Decode Roundtrip (100,000 structures, 7,635,000 B)

_SHA-256 verified identical across all implementations and rounds: `19093852fc5c5b2e675595878a529fd55915f8af43d6e897ef276720d041cd86`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_asn1`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 120.671 | 119.352 | 122.347 | 63.27 | 1206.71 | 1.94 MiB | **1.48x** |
| `go_asn1` | 178.035 | 176.802 | 181.341 | 42.88 | 1780.35 | 16.34 MiB | 1.00x (baseline) |
| `rust_der` | 41.362 | 40.861 | 47.660 | 184.59 | 413.62 | 1.94 MiB | 4.30x |

### 4. Adversarial-Shape X.509 Benchmarks (`audit/run_audit.sh bench`)

_All stdout SHA-256 hashes verified identical across Pion, Go 1.27, and Rust in every round._

| Shape | Work | `pion` (ms) | `go_x509` (ms) | `rust_x509` (ms) | `pion` vs Go | `pion` vs Rust | Peak RSS pion / go / rust (MiB) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| `real` | 8 OpenSSL certs × 20,000 | 600.539 | 471.353 | 291.890 | 0.78x | 0.49x | 2.39 / 17.41 / 2.27 |
| `big_rsa_cert` | RSA-4096 cert × 100,000 | 410.845 | 306.991 | 192.480 | 0.75x | 0.47x | 2.23 / 16.91 / 2.22 |
| `many_rdn` | 1 cert, 4,000-RDN subject × 300 | 182.252 | 140.372 | 122.758 | 0.77x | 0.67x | 2.64 / 16.81 / 3.95 |
| `many_san` | 1 cert, 4,000 dNSName SANs × 300 | 50.075 | 42.320 | 35.189 | 0.85x | 0.70x | 2.83 / 16.08 / 2.64 |
| `many_ext` | 1 cert, 4,000 extensions × 20 | 25.863 | 26.475 | 13.979 | **1.02x** | 0.54x | 3.14 / 15.36 / 2.83 |

Single-certificate extension cliff (`N = 64,000` distinct extensions, `1.2 MB` DER): **Pion `0.01 s` CPU** vs Go `0.02 s` vs Rust `0.00 s` (down from `4.10 s` prior to O(1) duplicate-OID hashing).

### Honest Performance Notes

- **Strengths**:
  - **Generic DER TLV Roundtrip (`1.48×` Go `encoding/asn1`)**: Direct `DerWriter` / `DerReader` encoding and cursor-based decoding avoid Go's reflection overhead (`120.7 ms` vs `178.0 ms`) while using **8.4× less peak RSS** (`1.94 MiB` vs `16.34 MiB`).
  - **Adversarial Extensions (`1.02×` Go `crypto/x509`)**: Hybrid O(1) duplicate-OID hashing over raw DER slices and single-buffer OID formatting eliminate the O(N²) cliff (`many_ext` improved `16.6×`, from `0.08×` to `1.02×` Go; 64k-extension cert runs in `0.01 s` vs Go's `0.02 s`).
  - **Low Memory Footprint Across All Workloads**: Peak RSS stays at `1.94–3.14 MiB` across all benign and adversarial workloads — matching Rust (`1.94–3.95 MiB`) and using **5×–8.5× less memory** than Go (`15.36–18.91 MiB`).
  - **PEM + X.509 Pipeline**: Reaching `0.89×` Go `crypto/x509` (`161.8 MB/s`) and `0.87×` Rust `x509-parser` while strictly enforcing DER canonicality, inner/outer algorithm matching, duplicate-extension rejection, and full extension decoding.
- **Remaining Gaps**:
  - **Pure DER X.509 Parse (`0.85×` Go, `0.44×` Rust `x509-parser`)**: `Bytes::slice` copies into owned buffers for returned fields (`tbs_bytes`, `raw`, keys, signatures, DN/SAN strings), and `x509-parser` borrows `&[u8]` slices directly and lazily parses extensions without DER canonicality or duplicate-extension checks.
  - **Generic DER vs Rust `der` (`0.34×` Rust)**: Rust `der` reuses pre-allocated `Vec<u8>` buffers and pre-parsed `ObjectIdentifier` constants across iterations, whereas `DerWriter` in Workload 3 allocates per-record sequence buffers and re-encodes the OID string per iteration.
