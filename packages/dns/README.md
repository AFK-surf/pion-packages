# `dns` (`v0.1.0`)

Pure Pion, zero-dependency, Sans-IO DNS wire protocol codec and domain name engine (`Native` + `Wasm32`, no `World` dependency).

Designed alongside Go [`miekg/dns`](https://github.com/miekg/dns) and Rust [`hickory-proto`](https://github.com/hickory-dns/hickory-dns), covering RFC 1035, 2782, 2915, 3596, 4034, 4343, 5952, 6891 (EDNS0), 7830, 7871 (ECS), 7873 (Cookies), 8484 (DoH), 8659 (CAA), and 9460 (SVCB/HTTPS).

## Features

- **Complete DNS Message & Header Codec**: Full 12-byte header (`id`, `qr`, `opcode`, `aa`, `tc`, `rd`, `ra`, `z`, `ad`, `cd`, `rcode`, `qdcount`, `ancount`, `nscount`, `arcount`) and all 4 sections (`questions`, `answers`, `authorities`, `additionals`), with `val struct` `Header`, `Ipv4Addr`, and `Ipv6Addr`.
- **RFC 1035 §4.1.4 Domain Name Engine**:
  - Canonical uncompressed wire storage (`<= 255` wire bytes, labels `1..=63` bytes), validated on both decode and encode paths (`0` panics even on manually constructed malformed `Name.wire`).
  - Case preservation + RFC 4343 ASCII case-insensitive comparison (`eq_ignore_case`, `to_lowercase`, `is_subdomain_of`).
  - Presentation parsing & formatting with RFC 1035 §5.1 / zone-file escaping (`\.`, `\\`, `\;`, `\(`, `\)`, `\"`, `\@`, `\$`, `\'`, and `\DDD`).
  - **Encoder**: Standard RFC 1035 case-preserving suffix compression (`EncodeOptions::default()` / `EncodeOptions::uncompressed()`, plus reusable `Encoder`) using a zero-allocation 8-slot inline table for small messages that lazily spills to a per-message seeded open-addressing hash table (immune to hash-collision DoS), strictly respecting RFC 3597 §4 while registering uncompressed target names (`SRV`, `NAPTR`, `SVCB`, `HTTPS`, `RRSIG`, `NSEC`) so subsequent glue RRs compress byte-identically to `miekg/dns` and `hickory-proto`.
  - **Decoder**: Iterative, stack-safe, CVE-hardened decompression rejecting self-overlapping pointers (`PointerNotPriorToLabel`).
- **18 Structured Resource Record Types**:
  - Core RFC 1035: `A`, `NS`, `CNAME`, `SOA`, `PTR`, `MX`, `TXT` (non-empty multi-chunk character-strings), plus RFC 2136 Dynamic UPDATE `RDLENGTH=0` (`CLASS=ANY`/`NONE`/UPDATE) support.
  - Modern & Service Discovery: `AAAA` (with RFC 4291 §2.2(3) embedded-IPv4 parsing and RFC 5952 §5 canonical IPv6 formatting including `::ffff:d.d.d.d`), `SRV`, `CAA` (RFC 8659 §4.1 tag validation), `NAPTR`, `SVCB` & `HTTPS` (RFC 9460 `Mandatory` semantics, `Alpn`, `NoDefaultAlpn`, `Port`, `Ipv4Hint`, non-empty `Ech`, `Ipv6Hint`, `Unknown` rejecting key `65535`, ignoring AliasMode SvcParams on decode per §2.4.2, sorting keys and rejecting duplicates on encode).
  - EDNS0 (RFC 6891): `OPT` pseudo-RR (enforcing Additional-only, root owner, at most 1 OPT per §6.1.1) with UDP payload size, 12-bit extended RCODE (`Message::extended_rcode()`), EDNS version, DO bit, `Ecs` (RFC 7871 §6 family/prefix/host-bit validation), `Cookie` (RFC 7873 §4 length validation), `Padding` (RFC 7830), and `Unknown` option passthrough.
  - DNSSEC (RFC 4034): `DS`, `DNSKEY`, `RRSIG`, `NSEC` (multi-window Type Bit Maps rejecting trailing zero octets / all-zero windows per §4.1.2).
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
- `pionc test --json packages/dns`: **23/23 PASS** (`rfc1035_wire_test.pion`, `rr_modern_test.pion`, `security_redteam_test.pion`)
- `pionc test --json packages/dns/audit`: **70/70 PASS** (23 package tests + 29 red-team finding tests + 18 control tests, 0 FAIL)
- `packages/dns/audit/diff/run_diff.sh`: **10,178/10,178 Native == Wasm32** byte-identical (0 diffs, 0 panics/traps); **635/635 IPv6** exact match with Go `netip` & Rust `std::net`
- `packages/dns/wasm_smoke` 4-mode matrix:
  - Native debug: exit `0`
  - Native release: exit `0`
  - Wasm32 debug (`pionc run --target wasm32` on Node.js): exit `0`
  - Wasm32 release (`pionc run --target wasm32 --release` on Node.js): exit `0`

## Head-to-Head Benchmarks

Run with `sh packages/dns/bench/run_bench.sh` via `scripts/bench_compare.py --warmup 1 --rounds 5` (strictly interleaved, locked `go.sum` / `Cargo.lock`, mandatory full-body & full-wire stdout SHA-256 verification) on **Darwin arm64** against:
- **Go 1.27.3** `github.com/miekg/dns v1.1.63` (`-mod=readonly`)
- **Rust 1.100.0** `hickory-proto 0.24.2` (`--release --locked`)

### 1. Mixed DNS Response Batch Decode (200,000 packets: A/AAAA/CNAME/MX/TXT/SRV/SOA/OPT)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `57 B` (`sha256:3fa1bb3a9936a8b8...`, full-name / full-AAAA / full-TXT checksum) | Input: `32627200 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_hickory) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 268.973 | 267.223 | 270.015 | 121.30 | 1344.86 | 2.22 MiB | 0.91x |
| `go_miekg_dns` | 264.416 | 257.589 | 266.582 | 123.39 | 1322.08 | 16.58 MiB | 0.93x |
| `rust_hickory` | 245.879 | 244.680 | 249.039 | 132.70 | 1229.39 | 2.44 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `3fa1bb3a9936a8b80bf0945297eff59e73ad20396ee8f34c21e721c9e0e9b402`._

### 2. Batch DNS Response Encode with Compression (200,000 packets)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `85 B` (`sha256:1fa867834398d9f1...`, full encoded wire bytes + full round-trip checksum) | Input: `32627200 B` | Ops: `200000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs rust_hickory) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 100.887 | 100.177 | 102.464 | 323.40 | 504.43 | 4.50 MiB | 1.52x |
| `go_miekg_dns` | 97.707 | 93.693 | 101.225 | 333.93 | 488.54 | 16.86 MiB | 1.57x |
| `rust_hickory` | 152.929 | 150.142 | 155.991 | 213.35 | 764.65 | 4.52 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `1fa867834398d9f1cd6c69513bc75a70fe5e66eaa0b34c3eecd7e3a9f7ff4b5b`._

### 3. High-Frequency DNS Query Build + Encode + Decode Roundtrip (500,000 ops)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `59 B` (`sha256:86090f4893c5869a...`) | Ops: `500000`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs rust_hickory) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 109.090 | 107.476 | 112.043 | 218.18 | 1.86 MiB | 1.49x |
| `go_miekg_dns` | 78.874 | 76.821 | 81.206 | 157.75 | 16.23 MiB | 2.07x |
| `rust_hickory` | 162.928 | 161.232 | 163.773 | 325.86 | 2.23 MiB | 1.00x (baseline) |

_SHA-256 verified identical across all implementations and rounds: `86090f4893c5869a9c6c3466a25142dab3db75a70a44c8506a79bb6efcb075a2`._

### 4. Adversarial Benchmarks (`packages/dns/audit/bench/run_adv_bench.sh`)

| Workload | Pion | Go `miekg/dns` | Rust `hickory-proto` | Pion vs Rust |
| --- | ---: | ---: | ---: | ---: |
| A1 small response encode (1M msgs), ns/op | **161.74** | 172.06 | 253.22 | **1.57x** |
| A2 500-owner encode, µs/msg | 60.80 | **41.48** | 197.39 | **3.25x** |
| A3 2,000-owner encode (>16 KiB), µs/msg | 223.19 | **121.69** | 1202.71 | **5.39x** |
| A4 2,000 **colliding** owners encode, µs/msg | 232.10 | **120.64** | 1758.90 | **7.58x** |
| A5 2,750-owner encode (~62 KiB), µs/msg | 296.30 | **147.65** | 1547.98 | **5.22x** |
| A6 2,750 **colliding** owners encode, µs/msg | 305.60 | **150.93** | 2537.59 | **8.30x** |
| A7 2,000-owner decode, µs/msg | **177.39** | 214.09 | 189.91 | **1.07x** |

### Benchmark Notes (Honest Assessment)

- **Strengths**:
  - **Small & mixed response compressed encode**: With the zero-allocation 8-slot inline compression table, Pion beats both Rust and Go on A1 (`161.74 ns/op` vs Go `172.06 ns`, Rust `253.22 ns`; `1.84 MiB` RSS vs Go `16.86 MiB`) and leads Rust by **1.52x** on W2 (`323.40 MB/s` vs Rust `213.35 MB/s`, within 3% of Go `333.93 MB/s`) with byte-identical encoded wire output.
  - **Collision resistance & large responses**: Per-message seeded hashing eliminates hash-collision DoS (`A4/A3 = 1.04x`, `A6/A5 = 1.03x`), while outperforming Rust `hickory-proto` by **3.25x–8.30x** on large responses and beating both Go and Rust on A7 large-response decode (`177.39 µs/msg`).
  - **Query roundtrip**: Pion (`218.18 ns/op`, `1.86 MiB RSS`) is **1.49x faster than Rust `hickory-proto`** (`325.86 ns/op`) at **8.7x lower RSS than Go**.
- **Areas where Pion currently trails**:
  - **Very large response encode (A2/A3/A5) vs Go**: Pion is ~1.5–2.0x slower than Go `miekg/dns` on 500–2,750-owner responses, though 3.25x–5.39x faster than Rust `hickory-proto` and ~5–8x lower peak RSS than Go.
  - **Mixed response decode (W1)**: Pion (`121.30 MB/s`, `2.22 MiB RSS`) is `0.91x` of Rust `hickory-proto` (`132.70 MB/s`) and `0.98x` of Go (`123.39 MB/s`, `16.58 MiB RSS`).
