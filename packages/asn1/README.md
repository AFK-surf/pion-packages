# `asn1` — Pure Pion Strict ASN.1 DER, PEM & X.509 v1/v3 Engine

A pure Pion, zero-C-dependency, Native + Wasm32 compatible implementation of **ITU-T X.690 strict DER**, **RFC 7468 PEM** (built directly on `packages/base64`), **RFC 5280 X.509 v1/v3 certificates**, **RFC 6125 / RFC 9525 hostname & IP verification**, and **SPKI / RFC 5958 PKCS#8** public/private key envelopes, modeled on **Go `encoding/asn1` + `encoding/pem` + `crypto/x509`** and **Rust `der` + `x509-parser`**.

Designed with a **Sans-IO** architecture: no `World` dependency, zero-copy `DerReader` slicing over `Bytes`, 100% iterative `DerElement` tree parsing & encoding (immune to stack overflow on both Native and Wasm32), fast zero-allocation well-known OID matching, and hardened Day-1 defenses against depth bombs, length OOM bombs, DER malleability, duplicate X.509 extensions, and SAN NUL injection.

## Features

- **Strict ASN.1 DER (`DerReader`, `DerWriter`, `DerElement`, `DecodeLimits`)**:
  - **Tags**: Universal, Application, Context-Specific, and Private classes; primitive and constructed flags; short tags (`0..30`) and base-128 high tag numbers (`>= 31`) with strict minimal encoding (rejects leading `0x80` and high-form tags `< 31`).
  - **Lengths**: Definite lengths up to 4 octets (`< 2 GiB`). Strictly rejects BER indefinite length (`0x80`), non-minimal encodings (`0x81 0x05`, `0x82 0x00 0x80`), >4-octet lengths, and out-of-bounds lengths with zero allocation.
  - **Primitives & Constructed Types**:
    - `BOOLEAN` (DER `0x00` / `0xFF` only; rejects `0x01`, `0x7F`, non-1-byte length).
    - `INTEGER` (arbitrary-precision minimal two's-complement big-endian bytes + `Int64` / `UInt64`; strictly rejects empty integers and redundant leading `0x00` / `0xFF`).
    - `BIT STRING` (validates `unused_bits ∈ 0..=7`, empty bit string requires `unused_bits == 0`, trailing unused bits must be zero).
    - `OCTET STRING`, `NULL` (must have length 0), `OBJECT IDENTIFIER` (full base-128 parse/format + fast table for common X.509/crypto OIDs; rejects leading `0x80`, truncated subidentifiers, and `UInt64` overflow).
    - `UTF8String` (strict RFC 3629 UTF-8), `PrintableString`, `IA5String`, `VisibleString`, `BMPString` (UTF-16BE rejecting surrogates), `T61String` (`read_any_string`).
    - `UTCTime` (RFC 5280 `YYMMDDHHMMSSZ`, `YY >= 50 → 19YY`, `YY < 50 → 20YY`) and `GeneralizedTime` (`YYYYMMDDHHMMSSZ`) with leap-year calendar validation to Unix seconds (`Int64`).
    - `SEQUENCE`, `SET`, explicit context-specific `[n]`, and `write_set_of_sorted` (ITU-T X.690 §11.6 canonical lexicographical sorting).
  - **Iterative Tree Codec**: `parse_der_element` / `parse_der_element_with_limits` and `encode_der_element` run 100% iteratively with configurable `DecodeLimits` (`max_depth = 64`, `max_elements = 65536`, `max_bytes = 16 MiB`).
- **RFC 7468 PEM (`parse_pem`, `parse_pem_all`, `encode_pem`)**:
  - Strict `-----BEGIN LABEL-----` / `-----END LABEL-----` matching, 64-column line wrapping on encode, preamble/comment skipping, CRLF/LF normalization, multi-block chain bundles, and strict Base64 decoding via `packages/base64`.
- **RFC 5280 X.509 v1/v3 & SPKI / PKCS#8**:
  - `parse_x509_der`, `parse_x509_der_with_limits`, `parse_x509_pem`, `parse_x509_pem_chain`: parses `version` (v1/v2/v3), `serial_number`, `signature_algorithm`, `issuer` & `subject` `DistinguishedName` (`CN`/`O`/`OU`/`C`/`ST`/`L` + full attribute list), `not_before` / `not_after`, `subject_public_key_info` (RSA, ECDSA P-256 & P-384, Ed25519, X25519), exact `tbs_bytes` slice for signature verification, and `signature_bytes`.
  - **v3 Extensions**: `SubjectAlternativeName` (`DnsName`, `IpAddress` v4/v6, `Uri`, `Email`), `BasicConstraints` (`is_ca`, `path_len_constraint`), `KeyUsage` (all 9 flags), `ExtKeyUsage`, `SubjectKeyIdentifier`, `AuthorityKeyIdentifier`, plus strict duplicate-OID rejection (RFC 5280 §4.2).
  - **Hostname & IP Verification (`verify_hostname`)**: RFC 6125 / RFC 9525 SAN matching — case-insensitive DNS, leftmost single-label wildcard (`*.example.com`) only (rejects partial wildcards `a*.example.com`, multi-label matches, single-label/TLD wildcards `*.com`, and NUL bytes), plus exact IPv4 and compressed/expanded IPv6 matching (no IP wildcards).
  - **Key Envelopes**: `parse_spki_der`, `encode_spki_der`, `parse_pkcs8_der`, `encode_pkcs8_der` with byte-exact DER roundtrip across RSA, ECDSA P-256, ECDSA P-384, Ed25519, and X25519.

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

- **Compliance & Red-Team Test Suite**: `pionc test --json packages/asn1` — **43 / 43 passing** (20/20 `asn1` tests + 23/23 dependency `base64` tests), covering ITU-T X.690 DER primitives/high tags/`SET OF` sorting, RFC 7468 PEM bundles/rejections, real OpenSSL 3.5.9 RSA-2048/ECDSA P-256/ECDSA P-384/Ed25519/X25519 X.509 v1/v3 & SPKI/PKCS#8 vectors, RFC 6125/9525 hostname & IPv4/IPv6 matching, 50,000-level nested `SEQUENCE` depth bomb, 2 GiB length OOM bomb, all classic DER malleability vectors, duplicate X.509 extensions, and SAN NUL injection.
- **Dual-Target Wasm32 Smoke (`packages/asn1/wasm_smoke`)**: All 4 build modes (Native debug/release + Wasm32 debug/release executed on `node v24.22.2` with `pion_wasm_rt.mjs`) exit `0` with byte-identical non-empty stdout (`sha256:b288d45fcb867c782303a0be5cf5cd29b02e5ae56f44415561f1609e376e0fbc`).
- **Formatting & Typecheck**: `pionc fmt --check packages/asn1` and `pionc check --json packages/asn1` pass with 0 diagnostics.

## Head-to-Head Benchmarks

Measured on `Darwin arm64` via `sh packages/asn1/bench/run_bench.sh` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification) comparing:
- **`pion`**: `packages/asn1` (`pionc 0.1.0 --release`)
- **`go_x509` / `go_asn1`**: Go `go1.27.3` stdlib (`crypto/x509` + `encoding/pem` + `encoding/asn1`)
- **`rust_x509` / `rust_der`**: Rust `1.100.0` (`x509-parser 0.16.0`, `der 0.7.10`, `pem 3.0.6`, `--release --locked` via `packages/asn1/bench/rust/Cargo.lock`)

### 1. Real PEM Cert Chain Full Parse (100 multi-algo X.509 v3 certs × 100 = 10,000 certs, 11,011,600 B)

_SHA-256 verified identical across all implementations and rounds: `3bd83096d9b55510edb072a9860a8083dd907704fa48a85b55dbc0840ca63fda`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_x509`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 75.679 | 72.792 | 85.126 | 145.50 | 7567.87 | 3.03 MiB | 0.80x |
| `go_x509` | 60.902 | 58.658 | 62.830 | 180.81 | 6090.23 | 16.59 MiB | 1.00x (baseline) |
| `rust_x509` | 58.951 | 56.853 | 87.404 | 186.79 | 5895.10 | 2.64 MiB | 1.03x |

### 2. Pure DER X.509 v3 Parse + 3× SAN Hostname Verify (50,000 certs, 38,606,000 B)

_SHA-256 verified identical across all implementations and rounds: `c44c0dc97792c4843491cc49c318941c7a32180d954b123d9c92cb59a514f669`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_x509`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 271.827 | 261.744 | 315.869 | 142.02 | 5436.55 | 2.52 MiB | 0.73x |
| `go_x509` | 199.324 | 192.102 | 314.243 | 193.68 | 3986.47 | 18.03 MiB | 1.00x (baseline) |
| `rust_x509` | 99.084 | 97.507 | 103.166 | 389.63 | 1981.68 | 2.28 MiB | 2.01x |

### 3. Generic ASN.1 DER TLV Encode + Decode Roundtrip (100,000 structures, 7,635,000 B)

_SHA-256 verified identical across all implementations and rounds: `19093852fc5c5b2e675595878a529fd55915f8af43d6e897ef276720d041cd86`._

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `go_asn1`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 138.159 | 131.196 | 148.738 | 55.26 | 1381.59 | 1.95 MiB | **1.40x** |
| `go_asn1` | 193.051 | 190.150 | 195.302 | 39.55 | 1930.51 | 16.48 MiB | 1.00x (baseline) |
| `rust_der` | 44.614 | 43.094 | 50.609 | 171.13 | 446.14 | 1.94 MiB | 4.33x |

### Honest Performance Notes

- **Strengths**:
  - **Generic DER TLV Roundtrip (`1.40×` Go `encoding/asn1`)**: Direct `DerWriter` / `DerReader` encoding and zero-copy slice decoding avoid Go's reflection overhead (`138.2 ms` vs `193.1 ms`) while using **8.5× less peak RSS** (`1.95 MiB` vs `16.48 MiB`).
  - **Low Memory Footprint Across All Workloads**: Peak RSS stays at `1.95–3.03 MiB` across all three workloads — matching Rust (`1.94–2.64 MiB`) and using **5.5×–8.5× less memory** than Go (`16.48–18.03 MiB`).
  - **PEM + X.509 Pipeline**: Reaching `0.80×` Go `crypto/x509` (`145.5 MB/s`) and `0.78×` Rust `x509-parser` while strictly enforcing DER canonicality, duplicate-extension rejection, and full extension decoding.
- **Remaining Gaps**:
  - **Pure DER X.509 Parse (`0.73×` Go, `0.36×` Rust `x509-parser`)**: `x509-parser` borrows `&[u8]` slices directly with zero heap allocations for strings and lazily parses extensions on demand, whereas `packages/asn1` eagerly parses all standard extensions (`SAN`, `BasicConstraints`, `KeyUsage`, `ExtKeyUsage`, `SKI`, `AKI`) and allocates owned `String` values for DN attributes and SAN entries.
  - **Generic DER vs Rust `der` (`0.32×` Rust)**: Rust `der` reuses pre-allocated `Vec<u8>` buffers and pre-parsed `ObjectIdentifier` constants across iterations, whereas `DerWriter` in Workload 3 allocates per-record sequence buffers and re-encodes the OID string per iteration.
