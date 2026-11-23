# `proxy` — Pure-Pion Zero-Dependency Sans-IO Proxy Protocol & URL Redaction Library

Pure-Pion, zero-dependency, `World`-free, `Send`-clean (zero module-level mutable state) implementation of **RFC 1928 / RFC 1929 (SOCKS5)**, **RFC 9110 / RFC 9112 (HTTP `CONNECT` & Plaintext HTTP Forward Proxy)**, and **Proxy URL Parsing with Mandatory Credential Redaction & `NO_PROXY` Matching** — designed for both Native and `wasm32` targets (including desktop local `127.0.0.1` proxy bridges such as `AFK-surf/monoid-login`).

## Capabilities & Security Guarantees

- **Zero Dependencies / No `World` / `Send`-Clean**: Pure Pion with empty `[dependencies]`, no I/O or global mutable state, verified byte-identical across Native and `wasm32` (`native_dbg`, `native_rel`, `wasm_dbg`, `wasm_rel`).
- **Proxy URL Parsing, Mandatory Credential Redaction & `NO_PROXY` (`src/proxy_url.pion`)**:
  - Schemes: `ProxyScheme::{Http, Https, Socks5, Socks5h, Ssh}` (ASCII case-insensitive; default ports `80` / `443` / `1080` / `1080` / `22`).
  - `ProxyUrl::uses_remote_dns()`: `true` for `Socks5h`, `Http`, `Https`, `Ssh`; `false` for `Socks5`.
  - Authority parsing splits on the **last** `@` and **first** `:` in userinfo, with percent-decoding (`http://alice:p%40ss:w0rd@proxy.example:8080` -> `username = "alice"`, `password = "p@ss:w0rd"`), IPv4, `[IPv6]`, and strict rejection of empty hosts, invalid ports (`<= 0` or `> 65535`), backslashes in authority, non-RFC 3986 host characters (`% \ < > ^ |`), C0/DEL control bytes in credentials, and malformed `%` escapes.
  - **Zero-credential-leak `redacted()` / `to_safe_string()`**:
    - For non-`ssh` schemes (`http`, `https`, `socks5`, `socks5h`), whenever a username **or** password is present (including token-in-username URLs like `http://<token>@proxy`), the entire userinfo is redacted to `***@` (e.g. `http://***@proxy.example:8080`).
    - For `ssh://`, username is preserved with RFC 3986 unreserved percent-encoding (`ssh://monoid@station-us:2222`), preventing log/host spoofing and terminal escape injection.
    - Query strings (including SSH `identity=/secret/key` key paths) are always stripped from `redacted()`.
  - **SSH rules**: rejects `ssh://user:pass@host` with an error that never echoes credentials; parses `ssh://user@host:port?identity=/path` into `url.query` and `url.identity` while keeping `redacted()` clean.
  - **Error message hygiene**: `ProxyError::message()` never echoes raw URLs, usernames, or passwords on any parse failure (`UnsupportedScheme` only echoes syntactically valid RFC 3986 scheme tokens and substitutes `<invalid>` otherwise).
  - **`NoProxyMatcher`**: comma-separated `*`, exact domains, `example.com` (apex + subdomains), `.example.com` / `*.example.com` (subdomains only), `host:port`, `[IPv6]:port`, IPv4/IPv6 literals (canonicalized, with IPv4-mapped IPv6 unmapping such as `::ffff:10.0.0.1`), and IPv4/IPv6 CIDR prefixes (`127.0.0.0/8`, `10.0.0.0/8`).
- **Bidirectional Sans-IO SOCKS5 Codec (`src/socks5.pion`, RFC 1928 + RFC 1929)**:
  - Streaming `DecodeStatus[T]::{ Complete(T, Int), NeedMore(Int) }` with exact `consumed` byte count (arbitrary 1-byte TCP fragmentation & pipelined trailing payload safe).
  - `SocksAddr::{ Ipv4(Bytes), Ipv6(Bytes), Domain(String) }` — `ATYP=0x03` enforces `1..=255` bytes, rejects CRLF/NUL, and preserves remote DNS (`socks5h`) semantics with zero local DNS lookups.
  - Full client & server support: greeting (`NoAuth=0x00`, `UserPass=0x02`), method selection (including `0xFF NoAcceptableAuthMethods`), RFC 1929 username/password auth (`VER=0x01`), `CONNECT`/`BIND`/`UDP_ASSOCIATE` requests, and replies covering all RFC 1928 status codes (`0x00..0x08`) with `ATYP=0x01/0x03/0x04`. Rejects out-of-range `Other`/`Unassigned` wire codes and preserves non-zero failure `REP` codes as `ProxyError::SocksFailure` even when a server sends a malformed `BND.ADDR`.
- **HTTP `CONNECT` & Plaintext HTTP Forward Proxy (`src/http_proxy.pion`, RFC 9110 / RFC 9112)**:
  - `encode_connect_request` / `decode_connect_request` / `encode_connect_response` / `decode_connect_response`:
    - Formats IPv6 targets with brackets (`[::1]:443`) on encode and strips brackets (`::1`) on decode; rejects `extra_headers` that duplicate `Host` or `Proxy-Authorization`.
    - Generates and parses `Proxy-Authorization: Basic <base64(user:pass)>`, rejecting CRLF/NUL in all fields, `:` in Basic usernames, and duplicate `Proxy-Authorization` headers.
    - Preserves `407 Proxy Authentication Required` and its `Proxy-Authenticate` challenge structurally (`resp.status == 407`, `resp.is_auth_required()`, `resp.proxy_authenticate`) instead of collapsing into a generic error.
    - Returns `NeedMore(n)` with `n >= 1` on incomplete heads and exact `consumed` offset immediately after `\r\n\r\n` so pipelined TLS ClientHello bytes are preserved verbatim.
  - `parse_and_sanitize_forward_request(buf, limits)`:
    - Rewrites absolute-form (`GET http://example.com:8080/path?q=1 HTTP/1.1`) to origin-form (`GET /path?q=1 HTTP/1.1`) with a canonical `Host` header, rejecting C0/HTAB/DEL bytes and `#fragment` in request-targets.
    - Strips all RFC 9110 §7.6.1 hop-by-hop headers (`Connection`, `Proxy-Connection`, `Proxy-Authorization`, `Proxy-Authenticate`, `Keep-Alive`, `TE`, `Trailer`, `Upgrade`) **plus every header dynamically nominated in `Connection`**, while protecting framing headers (`Host`, `Content-Length`, `Transfer-Encoding`) from `Connection` stripping and rejecting duplicate `Proxy-Authorization`.
    - Anti-smuggling enforcement: rejects `Transfer-Encoding` + `Content-Length`, conflicting `Content-Length`, `Transfer-Encoding` on HTTP/1.0, obs-fold, bare CR/LF, and NUL bytes.
    - Bounded by `ProxyLimits` (`max_header_bytes`, `max_headers`, `max_line_bytes`) to prevent unterminated-header DoS.

## Quick Start

```pion
import "proxy"

let u = match proxy::parse_proxy_url("http://alice:p%40ss:w0rd@proxy.example:8080") {
  Ok(v) => v
  Err(e) => panic(e.message()) // never contains credentials
}
let safe_for_logs = u.redacted() // "http://***@proxy.example:8080"

let no_proxy = proxy::NoProxyMatcher::parse("localhost, 127.0.0.0/8, .corp.internal")
let bypass = no_proxy.matches("api.corp.internal", 443) // true
```

## Verification

```sh
sh scripts/verify.sh packages/proxy
```

4-mode `wasm_smoke` (each with an isolated `PION_CACHE_DIR`):

```sh
PION_CACHE_DIR=/private/tmp/w18-proxy-smoke-native_dbg pionc run packages/proxy/wasm_smoke
PION_CACHE_DIR=/private/tmp/w18-proxy-smoke-native_rel pionc run --release packages/proxy/wasm_smoke
PION_CACHE_DIR=/private/tmp/w18-proxy-smoke-wasm_dbg pionc run --target wasm32 packages/proxy/wasm_smoke
PION_CACHE_DIR=/private/tmp/w18-proxy-smoke-wasm_rel pionc run --target wasm32 --release packages/proxy/wasm_smoke
```

All 4 modes exit `0` with byte-identical stdout:
`proxy_wasm_smoke: OK checks=5` (`sha256:f55443b19671d3efef568b67f2a3a147789897004ce10771f1be4961e0f26245`).

## Head-to-Head Benchmarks vs Go 1.27 Reference

Run with:

```sh
sh packages/proxy/bench/run_bench.sh
```

Measured on `Darwin arm64` (`go1.27.3 darwin/arm64`) via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 verification across all rounds and implementations).

**Methodology note**:
- **W1 (`go_ref`)**: hand-written Go reference implementation (`net/url` + `net/netip` + custom `NO_PROXY` matcher, not `x/net/http/httpproxy`) so both sides produce byte-identical stdout.
- **W2 (`go_ref`)**: hand-inlined Go byte-slice frame checks (not `x/net/proxy`), whereas Pion exercises full typed `SocksGreeting` / `SocksRequest` / `SocksReply` codec structs.
- **W3 (`go_net_http`)**: Go `net/http.ReadRequest` / `ReadResponse` paired with fixed-header re-emission (`Accept`, `X-Trace-Id`, without full CL/TE smuggling validation), whereas Pion runs the full `parse_and_sanitize_forward_request` anti-smuggling pipeline.

### W1: Proxy URL Parse + Mandatory Redaction + `NO_PROXY` Match (`200,000` ops)

SHA-256: `96dfab9a281eb5f28ff90fb48fce58432871efa657702e23f02b67803167b7bb`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_ref`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 145.185 | 141.776 | 149.054 | 725.93 | 1.92 MiB | 0.54x |
| `go_ref` | 77.739 | 76.431 | 79.299 | 388.70 | 16.48 MiB | 1.00x (baseline) |

### W2: SOCKS5 Full Bidirectional Handshake (`UserPass` + `ATYP=0x03`, `500,000` rounds)

SHA-256: `bd5d0f40fb590fb8256a99a89e1416f98ce0358b6eb65c6a4acaed42b61f51d7`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_ref`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 271.333 | 259.824 | 277.209 | 542.67 | 1.81 MiB | 0.15x |
| `go_ref` | 40.945 | 40.154 | 42.045 | 81.89 | 9.14 MiB | 1.00x (baseline) |

### W3: HTTP `CONNECT` + Plaintext Forward-Proxy Header Sanitization (`100,000` requests)

SHA-256: `88bc1dee6f226e2b2f0f26caa4449beee6cec65b48a2d12b920e94d6fbc0c800`

| Implementation | Median (ms) | Min (ms) | P95 (ms) | ns/op | Peak RSS | Speedup (vs `go_net_http`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 438.944 | 431.199 | 454.696 | 4389.44 | 2.02 MiB | 0.85x |
| `go_net_http` | 374.719 | 372.832 | 395.230 | 3747.19 | 21.84 MiB | 1.00x (baseline) |

**Honest takeaways**:
- **W3 (HTTP `CONNECT` + forward-proxy sanitization)** is near parity with Go `net/http` (**~0.85x–1.0x** depending on host load; `0.85x` here vs `0.91x` in the audit run) while using **~10.8x less peak RSS** (`2.02 MiB` vs `21.84 MiB`), and performs full CL/TE smuggling validation that the Go bench loop omits.
- **W1 (Proxy URL + `NO_PROXY`)** is `0.54x` of the hand-written Go reference (`726 ns/op` vs `389 ns/op`, **8.6x lower RSS**), primarily due to `String::to_bytes()` copies inside helper scans.
- **W2 (SOCKS5 binary framing)** is `0.15x` of the hand-inlined Go byte-slice loop (`543 ns/round` / ~1.84M full 6-step handshakes/sec, **5.0x lower RSS**), where Go avoids typed codec allocations per frame.
