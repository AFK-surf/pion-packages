# `cookie` (v0.1.0)

Pure Pion **RFC 6265bis** HTTP Cookie, **CHIPS** (Cookies Having Independent Partitioned State), and embedded **Mozilla Public Suffix List (PSL)** library — 100% pure Pion, zero external dependencies, zero `extern "C"`, zero `World` dependency, and zero mutable module globals.

## Features

- **RFC 6265bis `Set-Cookie` Parsing & Formatting (`src/parse.pion`, `src/date.pion`)**:
  - Full RFC 6265 §5.1.1 cookie-date parser (`parse_cookie_date`) supporting IMF-fixdate, RFC 850, ANSI C asctime, flexible delimiters, 2-digit/4-digit years (`00..69 -> 2000..2069`, `70..99 -> 1970..1999`), leap years, `< 1601` rejection, and O(1) `Int64` civil calendar arithmetic (`format_cookie_date`).
  - Full attribute parsing: `Expires`, `Max-Age` (takes precedence over `Expires`, `<= 0` immediate expiry, overflow clamping), `Domain` (leading `.` stripped, lowercased, IP literal handling), `Path` (default-path §5.1.4), `Secure`, `HttpOnly`, `SameSite` (`Strict` / `Lax` / `None`), `Partitioned` (CHIPS §2, validated to require `Secure`).
  - Cookie name prefix enforcement (`validate_cookie_prefixes`, case-insensitive per RFC 6265bis §4.1.3 / §5.6): `__Secure-`, `__Host-`, `__Http-`, and `__Host-Http-`.
  - Defensive parsing: 4096 B name+value size limit, 1024 B attribute limit, control character rejection (`0x00..=0x08`, `0x0A..=0x1F`, `0x7F`; `0x09` HTAB allowed), last-wins duplicate attributes, quoted-string values, nameless cookies (no `=`), and injection-safe `format_set_cookie` / `parse_cookie_header` / `format_cookie_header`.
- **Embedded Read-Only Mozilla Public Suffix List (`src/psl.pion`, `src/psl_data.pion`)**:
  - Complete official Mozilla PSL (**10,472** rules: **6,950** ICANN + **3,522** Private) stored as a sorted immutable string literal (**171.9 KiB**) with zero startup allocation, zero mutable globals, and O(log N) binary search.
  - Supports normal rules, wildcard rules (`*.ck`, `*.mm`, `*.kobe.jp`), exception rules (`!www.ck`, `!city.kobe.jp`), IP literal detection (`is_ip_address`), and built-in RFC 3492 Punycode encoding so both Unicode IDN (`食狮.公司.cn`) and ASCII Punycode (`xn--85x722f.xn--55qx5d.cn`) domains resolve identically.
  - APIs: `public_suffix`, `public_suffix_icann`, `public_suffix_info`, `registrable_domain`, `registrable_domain_icann`, `is_public_suffix`, `is_public_suffix_icann`.
- **RFC 6265bis `CookieJar` with CHIPS & Eviction (`src/jar.pion`)**:
  - Policy-enforcing `store_set_cookie` / `store_cookie`: domain-match, PSL rejection (blocks setting cookies on public suffixes like `co.uk` / `github.io`), `HttpOnly` API isolation, `Secure` origin isolation, `SameSite=None` requires `Secure`, CHIPS `Partitioned` keying by normalized `top_level_site`, and `creation_time` preservation on update.
  - `matching_cookies` / `cookie_header`: domain-match, path-match, expiry filtering, `Secure`/`HttpOnly`/`SameSite` (`Strict`/`Lax` top-level safe navigation/`None`), CHIPS partition matching, and RFC 6265bis §5.8.3 ordering (longest `Path` first, then earliest `creation_time`).
  - Deterministic eviction under per-domain and global limits (expired first, then non-`Secure`, then oldest `last_access_time`), `purge_expired`, `clear_domain`, `clear`, and lossless `export_text` / `import_text`.

## Usage

```pion
import "cookie"

let jar = cookie::CookieJar::new()
let ctx = cookie::RequestContext::new(
  "https://embed.example.co.uk/app/view",
  Some("https://top-site.example"),
  true,  // is_http_api
  false, // is_same_site
  1700000000L,
)
let _ = jar.store_set_cookie(
  "__Host-sid=abc; Secure; Path=/; SameSite=None; Partitioned",
  ctx,
)
let header = jar.cookie_header(ctx)
let reg = cookie::registrable_domain("www.city.kobe.jp") // Some("city.kobe.jp")
```

## Verification & Differential Parity

```sh
sh scripts/verify.sh packages/cookie
sh packages/cookie/bench/run_bench.sh
```

- **Unit Test Suite (`packages/cookie/src/cookie_test.pion`)**: **15** test groups passing (`pionc test --json packages/cookie`), covering all official Mozilla `test_psl.txt` vectors (ICANN, Private, wildcards, exceptions, Unicode IDN & Punycode), RFC 6265bis date/attribute/prefix/domain/path/SameSite/CHIPS/eviction rules, WPT core cookie vectors, and malformed/DoS inputs.
- **Differential Parity vs Rust `cookie v0.18.3` & `psl v2.1.261` (`packages/cookie/bench/run_bench.sh`, locked `Cargo.lock`)**:
  - **Set-Cookie Parsing** (curated 200-header corpus covering RFC 6265bis attributes, dates, `Max-Age`, `Domain`, `Path`, `Secure`, `HttpOnly`, `SameSite`, `Partitioned`, quoted/multi-`=`/duplicate attributes): **200 / 200** cases, **0 divergences** (harness normalizes negative `Max-Age` to `0` to match Rust `cookie`'s `Duration::ZERO` clamping per RFC 6265 §5.2.2; `cookie::parse_set_cookie` preserves the signed `Int64`).
  - **Mozilla PSL Lookup** (curated 106-domain corpus covering all ASCII/Punycode Mozilla `test_psl.txt` vectors plus common ICANN/Private/wildcard/exception/IP domains): **106 / 106** cases, **0 divergences** vs Rust `psl v2.1.261` (Unicode IDN vectors are additionally verified in `src/cookie_test.pion`).
- **4-Mode Verification (`packages/cookie/wasm_smoke`)**:
  - `native debug` (**269 KiB**), `native --release` (**349 KiB**), `wasm32 debug` (**236 KiB**), `wasm32 --release` (**236 KiB**) all compile cleanly and emit byte-identical stdout:
  - `cookie_wasm_smoke:ok`
  - `summary=Sun, 06 Nov 1994 08:49:37 GMT|city.kobe.jp|www.ck|食狮.公司.cn|b.github.io|shared=ok; __Host-part=valA|shared=ok; __Host-part=valB|3 fnv64=7461a7bd3a5351f6`
  - SHA-256: `0769a8149bcd31b944aee1db152d40abe8bd34ea02a29936ff9d5e93caf08c4a`

### Head-to-Head Benchmark vs Rust `cookie v0.18.3` & `psl v2.1.261` (`--release`)

Measured on `Darwin arm64` (`sh packages/cookie/bench/run_bench.sh`, `scripts/bench_compare.py`, `warmup=1`, `rounds=5`, strictly interleaved, stdout SHA-256 verified identical across all implementations and rounds):

| Workload | `pion_cookie` Median (ms) | `pion_cookie` Throughput / ns/op | Rust Baseline Median (ms) | Rust Throughput / ns/op | Speedup | Peak RSS (Pion / Rust) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Set-Cookie Parsing (200 headers × 2,000 = 400,000 ops) | 126.450 | 205.62 MB/s (316.12 ns/op) | 62.764 (`cookie 0.18.3`) | 414.25 MB/s (156.91 ns/op) | 0.50x | **2.00 MiB** / 2.30 MiB |
| Mozilla PSL Lookup (106 domains × 2,000 = 212,000 ops) | 534.922 | 5.21 MB/s (2,523.22 ns/op) | 17.349 (`psl 2.1.261`) | 160.59 MB/s (81.84 ns/op) | 0.03x | **2.06 MiB** / 2.58 MiB |

Note: `rust_psl` compiles the entire Mozilla PSL into a massive Rust `match`-tree DFA at build time for ~82 ns/op lookups, whereas `pion_cookie` performs O(log N) binary search directly over a compact 171.9 KiB read-only sorted string table, keeping the full Wasm32 release binary at **236 KiB** with zero startup allocation and <1s compile time.
