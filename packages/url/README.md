# `url` — Pure-Pion WHATWG URL Standard Library

Zero-dependency, pure-Pion implementation (`v0.1.1`) of the [WHATWG URL Standard](https://url.spec.whatwg.org/) modeled after [`servo/rust-url`](https://github.com/servo/rust-url), including full URL parsing/resolution, Punycode (RFC 3492) + full Unicode 16.0.0 UTS #46 / IDNA domain processing (Mapping, NFC, CheckBidi, CheckJoiners, P4/V1/V5/V6/V7), IPv4/IPv6 parsing & RFC 5952 serialization, percent-encoding, O(1)/O(N) slice-based setters, `QueryParams` (`URLSearchParams`), and RFC 2397 / Fetch §6 `data:` URI parsing (`parse_data_url`).

## Compliance & Test Results

- **WPT `urltestdata.json`**: **869 / 869 (100.0%)** verbatim from `servo/rust-url` (`wpt_urltestdata_test.pion`)
- **WPT `setters_tests.json`**: **274 / 274 (100.0%)** verbatim from `servo/rust-url` (`wpt_setters_test.pion`)
- **Unicode 16.0.0 `IdnaTestV2.txt` (WHATWG `domainToASCII` flags)**: **6,346 / 6,348 (99.97%)** (vs `rust-url 2.5.9` / `idna 1.1.0`: `6,339 / 6,348 = 99.86%`; remaining 2 are `V4` with `CheckHyphens=false`)
- **Red-Team Audit Suite (`packages/url/audit`)**: **31 / 31 (100.0%)** — 0 non-idempotent round-trips across 15,876 parsed URLs, 0 `PION_BUG` across `fastpath`/`fuzz`/`random`/`wpt`/`setters`/`query`/`pct`/`idnareal`
- **`QueryParams` & Percent-Encoding**: **7 / 7 (100.0%)** (`query_params_test.pion`, including UTF-16 code-unit `sort()`)
- **Day-1 Red-Team Security Suite**: **8 / 8 (100.0%)** (`redteam_test.pion` — O(N) linear 20K `/a/..` paths, O(N) `@` authority flood, Punycode length bounds 1000/2000, IPv4/IPv6/port integer overflow bounds, zero raw C0/CR/LF/TAB smuggling)
- **Wasm32**: `pionc build --release --target wasm32 packages/url/wasm_smoke` builds cleanly (`298 KiB` `.wasm` including embedded Unicode 16.0.0 UTS #46 / NFC / Bidi / JoiningType tables, validated via Node.js `WebAssembly.compile`)

## Features

- **Parsing & Resolution**: `Url::parse`, `Url::parse_with_base`, `url.join(rel)` for special (`http`, `https`, `ws`, `wss`, `ftp`, `file`) and non-special schemes (both hierarchical and opaque paths), default port elision, credentials, dot-segment normalization (`.`, `..`, `.%2e`, `%2e.`, `%2e%2e`), backslash handling, and `file:` Windows drive letter rules.
- **Host Parser**:
  - **Domain**: Pure-Pion RFC 3492 Punycode (`punycode_encode` / `punycode_decode`) + full Unicode 16.0.0 UTS #46 non-transitional IDNA (`domain_to_ascii` / `domain_to_unicode`) with NFC normalization (including algorithmic Hangul Jamo composition/decomposition), RFC 5893 CheckBidi, RFC 5892 ContextJ CheckJoiners, V1/V5/V6/V7/P4 label validation, Punycode length caps (1,000 encode / 2,000 decode), and a zero-allocation ASCII fast path.
  - **IPv4**: WHATWG 1–4 part decimal/octal/hex parser with strict `Int64` overflow checks and single trailing dot support.
  - **IPv6**: Full `::` compression, embedded IPv4, RFC 5952 canonical lowercase hex serialization.
  - **Opaque Host**: Forbidden host code point validation + `Controls` percent-encoding.
- **Percent-Encoding**: `percent_encode` (`Controls`, `Fragment`, `Query`, `SpecialQuery`, `Path`, `Userinfo`, `Component`), `percent_decode`, `percent_decode_str` (with WHATWG UTF-8 replacement `U+FFFD`).
- **Getters & Setters**: `as_str`/`href`, `scheme`/`protocol`, `username`, `password`/`password_str`, `has_host`, `host`, `host_str`/`hostname`, `host_and_port`, `port`/`port_str`/`port_or_known_default`, `path`/`pathname`, `query`/`search`, `fragment`/`hash`, `origin`, `cannot_be_a_base`, and full mutators (`set_scheme`, `set_protocol`, `set_username`, `set_password`, `set_host`, `set_host_and_port`, `set_hostname`, `set_port`, `set_port_str`, `set_path`, `set_pathname`, `set_query`, `set_search`, `set_fragment`, `set_hash`, `set_href`). High-frequency setters (`set_fragment`/`set_hash`, `set_query`/`set_search`, `set_port`, `set_username`, `set_password`) splice in place using recorded byte offsets without re-parsing the URL.
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

## Head-to-Head Benchmarks (Pion Native vs Rust `url =2.5.9 --release`)

Measured on `Darwin arm64` using `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory byte-for-byte stdout SHA-256 verification).

### Template Corpora (`sh packages/url/bench/run_bench.sh`)

#### Workload 1: Mixed URL Batch Parse + Join + Serialize (200,000 ops)

Input: `14,278,136 B` (100,000 mixed HTTP/HTTPS/WS/FTP/IPv4/IPv6/IDN/dot-segment/relative-`join` URLs × 2 steady-state rounds)
Stdout SHA-256 (verified identical): `fca6fb3c1d9083d88088188f61cf4c5826e7590a91413844c11058010c4ae9fa`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_url`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | **114.091** | 113.282 | 115.684 | **125.15** | **570.45** | 21.25 MiB | **1.05x** |
| `rust_url` (`=2.5.9 --release`) | 120.056 | 116.615 | 123.861 | 118.93 | 600.28 | 10.59 MiB | 1.00x (baseline) |

#### Workload 2: `URLSearchParams` Parse + Mutate + Sort + Serialize (200,000 ops)

Input: `16,996,736 B` (100,000 query strings × 2 steady-state rounds: `parse` + `delete` + `set` + `append` + `sort` + `to_string`)
Stdout SHA-256 (verified identical): `6d553a71ae368c6396941bb3e9f9675f928965d8ecc500d7ea840461612832d0`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | ns/op | Peak RSS | Speedup (vs `rust_url`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 244.434 | 242.438 | 246.535 | 69.54 | 1222.17 | 23.33 MiB | **0.97x** |
| `rust_url` (`=2.5.9 --release`) | **237.788** | 236.731 | 240.629 | **71.48** | **1188.94** | 11.75 MiB | 1.00x (baseline) |

### Adversarial / Non-Template Corpora (`sh packages/url/audit/run_audit.sh` §6)

Net library time (median minus matching no-op driver median; `> 1.0x` = Pion faster, all SHA-256 verified identical):

| Workload | Cases | Net Pion (ms) | Net Rust (ms) | Speedup (vs `rust_url`) |
| --- | ---: | ---: | ---: | ---: |
| `adv_ipv4` (dec / hex / octal / 32-bit) | 200,000 | **59.3** | 79.9 | **1.35x** |
| `adv_setters` (7 setters per URL) | 40,000 | 107.6 | 104.5 | **0.97x** |
| `adv_ipv6` (compressed / embedded-v4 / upper) | 200,000 | 88.3 | 78.2 | **0.89x** |
| `adv_big_url` (325 KB URLs) | 200 | 78.3 | 65.6 | **0.84x** |
| `adv_idn` (full Unicode 16.0 UTS #46 IDNs) | 100,000 | 89.0 | 66.4 | **0.75x** |
| `adv_query_sort` (8–300 pairs, mutate + sort) | 7,500 | 133.3 | 82.9 | **0.62x** |
| `adv_pct` (heavy path/query/frag + `\t` encoding) | 100,000 | 218.8 | 125.6 | **0.57x** |
| `adv_join` (varied relative refs, 4 bases) | 200,000 | 103.7 | 55.5 | **0.54x** |

### Adversarial DoS Scaling (`sh packages/url/audit/run_audit.sh` §5)

All pathological workloads scale linearly (median of 3 at `n` → `4n`):

| Workload | `4n` Input | Pion `4n` (ms) | Rust `4n` (ms) | Ratio |
| --- | --- | ---: | ---: | ---: |
| `https://` + `n×@` + `example.com/` | 78 KB | 7.8 | 4.8 | 1.6x |
| `https://u:` + `n×@` + `h/` | 78 KB | 7.7 | 4.5 | 1.7x |
| One `n`-char CJK label (Punycode encode cap) | 117 KB | 8.6 | 5.7 | 1.5x |
| `xn--` label of `n` CJK chars (Punycode decode cap) | 58 KB | 7.1 | 5.1 | 1.4x |
| `1000 × set_hash` on `n`-segment URL | 104 KB | 27.8 | 5.5 | 5.1x |
| `1000 × set_query` on `n`-segment URL | 110 KB | 25.2 | 7.9 | 3.2x |

## Verification

```sh
pionc fmt --check packages/url
pionc check --json packages/url
pionc test --json packages/url
(cd packages/url && pionc test --json audit)
pionc build --release --target wasm32 -o /tmp/url_wasm_smoke.wasm packages/url/wasm_smoke
sh packages/url/bench/run_bench.sh
```

## Formal Verification (Lean 4)

Production pure kernels in `src/types.pion`, `src/percent.pion`, and `src/idna.pion` are annotated with `#verify` and extracted directly to Lean 4 via `pionc extract-lean` (**2 types**, **7 functions**, **0 externals**):

- **Machine-checked proofs** (`proofs/UrlProofs/PunycodeAndPercent.lean`, `proofs/UrlProofs/IpAddrs.lean`): **12** `0-sorry` theorems (strict standard-axiom whitelist `[propext, Classical.choice, Quot.sound]`):
  - **RFC 3492 Punycode bootstring arithmetic**: `puny_threshold` bounds `[1, 26]` & monotonicity in `k`; 36-digit encode→decode roundtrip, case-insensitive `'A'..'Z'` decoding, and exact validity iff.
  - **WHATWG URL §1.3 percent-encoding sets**: `Controls` (`≤ 0x1F` or `> 0x7E`) encoded in all 8 sets (`0xFF`), 256-byte inclusion hierarchy (`Query ⊆ SpecialQuery`, `Query ⊆ Path ⊆ Userinfo ⊆ Component`), and ASCII alphanumeric safety (`mask = 0`).
  - **IPv4 / IPv6 kernels**: full `2^32` bidirectional bijection between `Ipv4Addr::new` and `Ipv4Addr::octets` (exact big-endian `a·2^24 + b·2^16 + c·2^8 + d`) and `Ipv6Addr::new` idempotence on `[0, 65535]`.
- **Differential cross-check**: `proofs/EvalDiff.lean` + native Pion value-comparing harness (`diff -u`, including `INT32_MIN`/`INT32_MAX`/`INT64_MIN` and out-of-range cases).

```sh
bash packages/url/proofs/run_proofs.sh
```
