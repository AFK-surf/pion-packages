# `dns` (`v0.1.0`)

Pure Pion, zero-dependency, Sans-IO DNS wire protocol codec and domain name engine (`Native` + `Wasm32`, no `World` dependency).

Designed alongside Go [`miekg/dns`](https://github.com/miekg/dns) and Rust [`hickory-proto`](https://github.com/hickory-dns/hickory-dns), covering RFC 1035, 2782, 2915, 3596, 4034, 4343, 5952, 6891 (EDNS0), 7830, 7871 (ECS), 7873 (Cookies), 8484 (DoH), 8659 (CAA), and 9460 (SVCB/HTTPS).

## Features

- **Complete DNS Message & Header Codec**: Full 12-byte header (`id`, `qr`, `opcode`, `aa`, `tc`, `rd`, `ra`, `z`, `ad`, `cd`, `rcode`, `qdcount`, `ancount`, `nscount`, `arcount`) and all 4 sections (`questions`, `answers`, `authorities`, `additionals`), with `val struct` `Header`, `Ipv4Addr`, and `Ipv6Addr`.
- **RFC 1035 §4.1.4 Domain Name Engine**:
  - Canonical uncompressed wire storage (`<= 255` wire bytes, labels `1..=63` bytes).
  - Case preservation + RFC 4343 ASCII case-insensitive comparison (`eq_ignore_case`, `to_lowercase`, `is_subdomain_of`).
  - Presentation parsing & formatting with RFC 1035 §5.1 escapes (`\.`, `\\`, `\DDD`).
  - **Encoder**: Standard RFC 1035 suffix compression (`EncodeOptions::default()` / `EncodeOptions::uncompressed()`) using an allocation-light open-addressing hash table, strictly respecting RFC 3597 §4 (compressing only RFC 1035 well-known RDATA names; keeping `SRV`, `NAPTR`, `SVCB`, `HTTPS`, `RRSIG`, `NSEC` target names uncompressed).
  - **Decoder**: Iterative, stack-safe, CVE-hardened decompression.
- **18 Structured Resource Record Types**:
  - Core RFC 1035: `A`, `NS`, `CNAME`, `SOA`, `PTR`, `MX`, `TXT` (multi-chunk character-strings).
  - Modern & Service Discovery: `AAAA` (with RFC 5952 canonical IPv6 formatting), `SRV`, `CAA`, `NAPTR`, `SVCB` & `HTTPS` (RFC 9460 `Mandatory`, `Alpn`, `NoDefaultAlpn`, `Port`, `Ipv4Hint`, `Ech`, `Ipv6Hint`, `Unknown` with strictly ascending key validation).
  - EDNS0 (RFC 6891): `OPT` pseudo-RR with UDP payload size, 12-bit extended RCODE (`Message::extended_rcode()`), EDNS version, DO bit, `Ecs` (RFC 7871), `Cookie` (RFC 7873), `Padding` (RFC 7830), and `Unknown` option passthrough.
  - DNSSEC (RFC 4034): `DS`, `DNSKEY`, `RRSIG`, `NSEC` (multi-window Type Bit Maps).
  - Unknown RR passthrough: `RData::Unknown(rtype, Bytes)`.
- **Builders, Formatting & Transport Framing**:
  - `Message::query(id, name, qtype)` and `Message::response_for(req, rcode)`.
  - Zone-file and `dig`-style `ResourceRecord::to_text()` / `Message::to_text()`.
  - RFC 1035 §4.2.2 TCP 2-byte length-prefixed framing (`encode_tcp`, `decode_tcp` with `Complete` / `Incomplete` streaming status).
  - RFC 8484 §4.1 DoH GET `dns=` base64url (no padding) codec (`encode_doh_get_param`, `decode_doh_get_param`, `doh_media_type`).

## Security & Day-1 Red-Team Defenses

All malformed packets return explicit `Err(DnsError)` with **0 panics** and **0 Wasm32 traps**:

- **Compression Pointer Hardening**: Strictly decreasing backward pointer ceiling rejects self-pointers (`0xC0 0x0C`), 2-node mutual cycles, and forward pointers in $O(1)$ memory; rejects pointers into the 12-byte header or out of bounds; enforces `DecodeLimits::max_pointers` (rejects 7,000+ hop pointer chains) and `<= 255` wire bytes (rejects compression amplification bombs).
- **Zero-OOM Count Defense**: Never pre-allocates `Array` capacity from untrusted `qdcount`/`ancount`/`nscount`/`arcount`; truncated packets claiming `65535` records fail immediately with `UnexpectedEof` and zero wasted allocations.
- **Strict Wire Validation**: Rejects reserved label types (`0x40`, `0x80`), out-of-bounds `rdlength`, truncated character-strings/options, unsorted/duplicate SVCB SvcParam keys, invalid NSEC bitmap windows, and (under `DecodeLimits::strict()`) trailing bytes.

## Quick Start

```pion
import "dns"

let name = match dns::Name::parse("www.example.com.") {
  Ok(n) => n
  Err(_) => dns::Name::root()
}
let req = dns::Message::query(0x1234, name, dns::type_a)
let wire = dns::encode_message(req)

let resp = dns::Message::response_for(req, dns::rcode_noerror)
resp.answers.push(dns::ResourceRecord::{
  name: name,
  rtype: dns::type_a,
  rclass: dns::class_in,
  ttl: 300L,
  rdata: dns::RData::A(dns::Ipv4Addr::new(93, 184, 216, 34)),
})
resp.additionals.push(dns::ResourceRecord::opt(4096, 0, 0, true, []))
```

## Verification

- `pionc fmt --check packages/dns`: PASS
- `pionc check --json packages/dns`: PASS (0 diagnostics)
- `pionc test --json packages/dns`: **22/22 PASS** (`rfc1035_wire_test.pion`, `rr_modern_test.pion`, `security_redteam_test.pion`)
- `packages/dns/wasm_smoke` 4-mode matrix:
  - Native debug: exit `0`
  - Native release: exit `0`
  - Wasm32 debug (`pionc run --target wasm32` on Node.js): exit `0`
  - Wasm32 release (`pionc run --target wasm32 --release` on Node.js): exit `0`

## Head-to-Head Benchmarks

Run with `sh packages/dns/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, mandatory stdout SHA-256 verification) on **Darwin arm64** against:
- **Go 1.27.3** `github.com/miekg/dns v1.1.63`
- **Rust 1.100.0** `hickory-proto 0.24.2` (`--release`)

### 1. Mixed DNS Response Batch Decode (200,000 packets: A/AAAA/CNAME/MX/TXT/SRV/SOA/OPT)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `57 B` (`sha256:ab256aead63a62da...`) | Input: `32627200 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_hickory) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 149.513 | 143.049 | 162.050 | 218.22 | 747.57 | 2.20 MiB | 0.84x |
| `go_miekg_dns` | 157.000 | 147.985 | 161.236 | 207.82 | 785.00 | 16.64 MiB | 0.80x |
| `rust_hickory` | 126.255 | 124.399 | 131.556 | 258.42 | 631.27 | 2.45 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `ab256aead63a62da8902f5cbe6293955e66b5e3b50a0e41bcdbe8257c3a2f3ab`._

### 2. Batch DNS Response Encode with Compression (200,000 packets)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `64 B` (`sha256:21da92da2cbb1561...`) | Input: `32627200 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_hickory) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 199.453 | 195.288 | 206.455 | 163.58 | 997.26 | 4.48 MiB | 0.78x |
| `go_miekg_dns` | 116.826 | 112.923 | 118.579 | 279.28 | 584.13 | 17.11 MiB | 1.33x |
| `rust_hickory` | 155.928 | 150.773 | 159.744 | 209.25 | 779.64 | 4.48 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `21da92da2cbb15612bc613f910aef14aff14f5d7fcd9e4bab1787b470c5746aa`._

### 3. High-Frequency DNS Query Build + Encode + Decode Roundtrip (500,000 ops)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `59 B` (`sha256:86090f4893c5869a...`) | Ops: `500000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs rust_hickory) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 105.358 | 104.750 | 114.264 | 210.72 | 1.84 MiB | 1.58x |
| `go_miekg_dns` | 89.489 | 84.649 | 94.497 | 178.98 | 16.23 MiB | 1.86x |
| `rust_hickory` | 166.298 | 160.426 | 177.370 | 332.60 | 2.22 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `86090f4893c5869a9c6c3466a25142dab3db75a70a44c8506a79bb6efcb075a2`._

### Benchmark Notes (Honest Assessment)

- **Strengths**:
  - **Query roundtrip**: Pion (`210.72 ns/op`, `1.84 MiB RSS`) is **1.58x faster than Rust `hickory-proto`** (`332.60 ns/op`) thanks to flat wire `Name` storage and a zero-table single-question fast path, while using **8.8x less peak RSS than Go**.
  - **Mixed response decode**: Pion (`218.22 MB/s`, `2.20 MiB RSS`) edges out Go `miekg/dns` (`207.82 MB/s`, `16.64 MiB RSS`) at **7.5x lower RSS**, and reaches `0.84x` of Rust `hickory-proto`.
- **Areas where Pion currently trails**:
  - **Compressed response encode**: Pion (`163.58 MB/s`) trails Rust `hickory-proto` (`0.78x`) and Go `miekg/dns` (`0.59x`). Each `encode_message_with` call currently allocates a fresh `WireWriter` (512 B buffer + 64-slot hash table + 128-element label scratch) and copies out the final trimmed `Bytes`; a reusable `Encoder` API would eliminate per-message setup overhead for high-throughput authoritative servers.
