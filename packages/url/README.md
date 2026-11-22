# `url` — Pure-Pion WHATWG URL Standard Library

Zero-dependency, pure-Pion implementation of the [WHATWG URL Standard](https://url.spec.whatwg.org/) modeled after [`servo/rust-url`](https://github.com/servo/rust-url), including full URL parsing/resolution, Punycode (RFC 3492) + UTS #46 / IDNA domain processing, IPv4/IPv6 parsing & RFC 5952 serialization, percent-encoding, setters, and `QueryParams` (`URLSearchParams`).

## Compliance & Test Results

- **WPT `urltestdata.json`**: **869 / 869 (100.0%)** verbatim from `servo/rust-url` (`wpt_urltestdata_test.pion`)
- **WPT `setters_tests.json`**: **274 / 274 (100.0%)** verbatim from `servo/rust-url` (`wpt_setters_test.pion`)
- **`QueryParams` & Percent-Encoding**: **7 / 7 (100.0%)** (`query_params_test.pion`, including UTF-16 code-unit `sort()`)
- **Day-1 Red-Team Security Suite**: **8 / 8 (100.0%)** (`redteam_test.pion` — O(N) linear 20K `/a/..` paths, 10K `@` authority flood, IPv4/IPv6/Punycode/port integer overflow bounds, zero raw C0/CR/LF/TAB smuggling)
- **Wasm32**: `pionc build --release --target wasm32 packages/url/wasm_smoke` builds cleanly (114 KiB `.wasm`, validated via Node.js `WebAssembly.compile`)

## Features

- **Parsing & Resolution**: `Url::parse`, `Url::parse_with_base`, `url.join(rel)` for special (`http`, `https`, `ws`, `wss`, `ftp`, `file`) and non-special schemes (both hierarchical and opaque paths), default port elision, credentials, dot-segment normalization (`.`, `..`, `%2e`), backslash handling, and `file:` Windows drive letter rules.
- **Host Parser**:
  - **Domain**: Pure-Pion RFC 3492 Punycode (`punycode_encode` / `punycode_decode`) + UTS #46 non-transitional IDNA (`domain_to_ascii` / `domain_to_unicode`) with fast ASCII path.
  - **IPv4**: WHATWG 1–4 part decimal/octal/hex parser with strict `Int64` overflow checks and single trailing dot support.
  - **IPv6**: Full `::` compression, embedded IPv4, RFC 5952 canonical lowercase hex serialization.
  - **Opaque Host**: Forbidden host code point validation + `Controls` percent-encoding.
- **Percent-Encoding**: `percent_encode` (`Controls`, `Fragment`, `Query`, `SpecialQuery`, `Path`, `Userinfo`, `Component`), `percent_decode`, `percent_decode_str` (with WHATWG UTF-8 replacement `U+FFFD`).
- **Getters & Setters**: `as_str`/`href`, `scheme`/`protocol`, `username`, `password`/`password_str`, `has_host`, `host`, `host_str`/`hostname`, `host_and_port`, `port`/`port_str`/`port_or_known_default`, `path`/`pathname`, `query`/`search`, `fragment`/`hash`, `origin`, `cannot_be_a_base`, and full mutators (`set_scheme`, `set_protocol`, `set_username`, `set_password`, `set_host`, `set_host_and_port`, `set_hostname`, `set_port`, `set_port_str`, `set_path`, `set_pathname`, `set_query`, `set_search`, `set_fragment`, `set_hash`, `set_href`).
- **`QueryParams` (`URLSearchParams`)**: `parse`, `parse_raw`, `get`, `get_all`, `has`, `set`, `append`, `delete`, `sort` (stable UTF-16 code-unit order), `pairs`, `to_string`.

## Quick Start

```pion
import "url"

pub fn example() -> String {
  let u = match url::Url::parse("https://faß.ExAmPlE:443/a/b/../c?q=pion+url&k=1#top") {
    Ok(v) => v
    Err(e) => return e.to_string()
  }
  let qp = u.query_params()
  qp.append("lang", "pion")
  qp.sort()
  u.set_query(Some(qp.to_string()))
  u.as_str()
}
```

## Head-to-Head Benchmarks (Pion Native vs Rust `url v2.5.9 --release`)

Measured on `Darwin arm64` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification). Run with `sh packages/url/bench/run_bench.sh`.

### Workload 1: Mixed URL Batch Parse + Join + Serialize (200,000 ops)

Input: `14,278,136 B` (100,000 mixed HTTP/HTTPS/WS/FTP/IPv4/IPv6/IDN/dot-segment/relative-`join` URLs × 2 steady-state rounds)
Stdout SHA-256 (verified identical): `fca6fb3c1d9083d88088188f61cf4c5826e7590a91413844c11058010c4ae9fa`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_url`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **117.450** | 115.001 | 134.923 | **121.57** | **587.25** | 20.62 MiB | **1.06x** |
| `rust_url` (`v2.5.9 --release`) | 124.417 | 119.374 | 160.982 | 114.76 | 622.08 | 10.59 MiB | 1.00x (baseline) |

### Workload 2: `URLSearchParams` Parse + Mutate + Sort + Serialize (200,000 ops)

Input: `16,996,736 B` (100,000 query strings × 2 steady-state rounds: `parse` + `delete` + `set` + `append` + `sort` + `to_string`)
Stdout SHA-256 (verified identical): `6d553a71ae368c6396941bb3e9f9675f928965d8ecc500d7ea840461612832d0`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_url`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 250.036 | 248.026 | 252.271 | 67.98 | 1250.18 | 22.75 MiB | **0.98x** |
| `rust_url` (`v2.5.9 --release`) | **245.921** | 237.793 | 247.068 | **69.11** | **1229.61** | 11.75 MiB | 1.00x (baseline) |

> **Hotspot note on Workload 2 (`0.98x`)**: Pion matches Rust `url` (`-O3 + LTO`) within 1.7% (4.1 ms over 200k ops). The remaining ~20 ns/op gap is the compiler/runtime RC overhead on `String` slice allocations and `FixedArray[String]` slot moves during insertion sort (16 refcounted strings per query × 200k ops = 3.2M RC objects), whereas Rust moves owned `String` values inside `Vec<(String, String)>` with zero refcount traffic.

## Verification

```sh
pionc fmt --check packages/url
pionc check --json packages/url
pionc test --json packages/url
pionc build --release --target wasm32 -o /tmp/url_wasm_smoke.wasm packages/url/wasm_smoke
sh packages/url/bench/run_bench.sh
```
