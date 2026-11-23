# RT-proxy: red-team audit of `packages/proxy` v0.1.0

- **Baseline:** `origin/feat/pkg-proxy` @ `d4fb097` (`src/` 3 110 lines: `proxy_url.pion`, `socks5.pion`, `http_proxy.pion`, `types.pion`)
- **References:** RFC 1928, RFC 1929, RFC 9110, RFC 9112; `AFK-surf/monoid-login@886d08e` `src/proxy-bridge.ts` (the code this package replaces); Go `golang.org/x/net/http/httpproxy` v0.62.0 (Go's `ProxyFromEnvironment`)
- **Toolchain:** `pionc` 0.1.0 (`AFK-surf/pion@66d2b4b`), Go 1.27.3, Node 24.22, macOS arm64
- **Scope rule:** this branch only adds files under `packages/proxy/audit/`. Nothing else in the package changes.

```sh
sh packages/proxy/audit/run_audit.sh            # all: build, tests, fuzz, diff, dos, bench (about 35 s)
sh packages/proxy/audit/run_audit.sh tests      # just the red-team unit tests
```

`run_audit.sh` exits **1** while any `p0_`/`p1_`/`p2_` test fails, any `control_` test fails, the fuzzer reports a violation, or the four build modes disagree. It exits **0** once a fix branch closes every finding, with no change to `audit/`. Each assertion accepts any reasonable fix: rejecting the input or producing the safe result both pass. To check that the suite is satisfiable, I applied `audit/reference_fix.patch` (+142/−22 in `src/` plus one line of `proxy_url_test.pion`; a sketch, not a required design) to a scratch copy. With it applied, all 15 findings close, the 10 controls and the 13 package tests still pass, the fuzzer reports `violations=0` and the 4-mode SHA-256 values still match.

## Verdict

| ID | Sev | Finding | Test |
| --- | --- | --- | --- |
| P0-1 | **P0** | A `Connection: Content-Length` header strips `Content-Length` from the forwarded head, but `content_length` is still reported, so the request desyncs (CL.0 smuggling) | `p0_connection_nominated_content_length_stripped_body_desync` |
| P0-2 | **P0** | A `Connection: Transfer-Encoding` header strips TE, but `is_chunked = true` is still reported, so the request desyncs (TE.0 smuggling) | `p0_connection_nominated_transfer_encoding_stripped_body_desync` |
| P1-1 | **P1** | `UnsupportedScheme` repeats everything before the first `://`, so a scheme-less `user:pass@host` URL puts the credentials in the error message | `p1_unsupported_scheme_error_echoes_userinfo` |
| P1-2 | **P1** | `redacted()` prints a username when there is no password (token-in-username proxies); monoid-login prints `***@` | `p1_redacted_echoes_username_only_userinfo` |
| P2-1 | P2 | The ssh username in `redacted()` is not escaped (allows host spoofing, ESC/BEL injection), and C0 control bytes are accepted in credentials | `p2_redacted_ssh_username_unescaped_log_spoofing` |
| P2-2 | P2 | `\` in the authority: this parser connects to a different host than WHATWG/monoid-login | `p2_backslash_userinfo_parser_differential` |
| P2-3 | P2 | The proxy host accepts `% \ < > ^ \|`; `%6d` is kept literally instead of being decoded | `p2_proxy_host_accepts_non_rfc3986_characters` |
| P2-4 | P2 | NO_PROXY IPv4/CIDR rules never match IPv4-mapped IPv6 targets (Go's matcher does) | `p2_no_proxy_ipv4_mapped_ipv6_not_matched` |
| P2-5 | P2 | NO_PROXY `*.example.com` silently becomes a rule that can never match (Go treats it as `.example.com`) | `p2_no_proxy_star_dot_wildcard_ignored` |
| P2-6 | P2 | `Unassigned(0/256)` is encoded as REP=0x00 (Succeeded) and `Other(256)` as METHOD=0x00 (NoAuth): out-of-range values wrap with `to_byte` | `p2_socks_unassigned_codes_alias_success_and_noauth` |
| P2-7 | P2 | When a SOCKS failure reply carries a junk BND.ADDR, the real REP code is lost (an `InvalidAddressType(0)` error is reported instead) | `p2_socks_failure_reply_code_lost` |
| P2-8 | P2 | A forward-proxy request-target passes HTAB/C0/DEL bytes and `#fragment` through unchanged | `p2_forward_request_target_ctl_and_fragment_passthrough` |
| P2-9 | P2 | All three HTTP decoders return `NeedMore(0)`, which breaks the documented contract that `NeedMore(n)` is the minimum number of bytes still needed | `p2_http_decoders_need_more_zero` |
| P2-10 | P2 | With duplicate `Proxy-Authorization` headers, the last one wins silently (CONNECT and forward) | `p2_duplicate_proxy_authorization_last_wins` |
| P2-11 | P2 | `encode_connect_request` lets `extra_headers` add a second `Host` / `Proxy-Authorization` | `p2_encode_connect_extra_headers_duplicate_host_or_auth` |

There are 10 `control_*` tests: they pin the attacks the package already defeats. They are listed at the end and all of them pass.

**Overall:** the SOCKS5 codec is solid. In 60 000 fuzz cases with 1-byte prefix replay, every streaming invariant held: exact `consumed`, `NeedMore` never overshooting, a pipelined tail never swallowed, and errors staying errors on longer input. That held in all four build modes, with no panic and no wasm32 trap. HTTP framing validation (CL/TE/obs-fold/bare CR/LF/NUL/limits) is also solid. The serious defects come from two places. One is the order of the hop-by-hop pass in `parse_and_sanitize_forward_request`. The other is two leaks in URL redaction, both of which fall short of the reference that the package replaces.

## P0

### P0-1 / P0-2: `Connection`-nominated framing headers are stripped while the parsed framing is kept

`src/http_proxy.pion:994-999` drops every header whose name is listed in `Connection` (`is_nominated_hop`). That check runs **before** the `Content-Length` branch at `:1000`, and `Transfer-Encoding` has no branch at all. The first pass (`:934-963`) has already validated the framing and stored it in `content_length` / `is_chunked`. The result is a `SanitizedForwardRequest` that tells the caller "the body is 40 bytes (or chunked)" while `wire_head` carries no framing header.

```text
POST http://victim.example/upload HTTP/1.1
Connection: Content-Length
Content-Length: 40

<40 body bytes>
```

→ `content_length = Some(40)`, and `wire_head` is `POST /upload HTTP/1.1\r\nHost: victim.example\r\n\r\n`. A bridge that forwards `wire_head` and then the 40 body bytes sends the upstream a request with no body, followed by 40 bytes that the upstream parses as the **next request**: request smuggling against the upstream (and cache poisoning or request hijack where the connection is reused). `Connection: Transfer-Encoding` with a chunked body does the same thing. A client controls `Connection` completely; RFC 9110 §7.6.1 lets a proxy *ignore* nominations of fields it must keep, and Go's `ReverseProxy` cannot hit this case because its `Content-Length` never lives in the header map.

The fuzzer finds this independently: 31 of 5 405 forward cases (`framing desync: cl=true wire_cl=false …`).

**Fix:** never let a `Connection` nomination remove `Content-Length` / `Transfer-Encoding` (or `Host`, already safe), or reject such requests outright. The fuzz and unit invariant is simply that the framing in `wire_head` equals the framing reported in the returned struct.

## P1

### P1-1: `UnsupportedScheme` repeats the userinfo

`src/proxy_url.pion:144-172` treats everything before the **first** `://` as the scheme, never checks it against the RFC 3986 scheme grammar, and puts it into the error message. A scheme-less value is common and valid input: curl accepts `user:pass@proxy:3128`, and monoid-login's `withScheme` prefixes `http://`. Such a value leaks as soon as its path or query contains a URL:

```text
parse_proxy_url("alice:hunter2@proxy.example:8080/?next=http://intranet")
→ Err: "unsupported proxy scheme: alice:hunter2@proxy.example:8080/?next=http"
```

The README promises "error messages never echo credentials". **Fix:** echo the scheme only when it matches `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`, and otherwise return a constant message. Accepting scheme-less input the way monoid-login does is a separate compatibility choice.

### P1-2: `redacted()` prints a username when there is no password

`src/proxy_url.pion:411-422` replaces userinfo with `***@` only when a password is present. Many proxy providers and token gateways put the secret in the **username** (`http://<token>@proxy`). monoid-login, whose `redactProxyUrl` this package replaces, prints `***@` whenever a username exists for http/https/socks5/socks5h; only ssh user names are shown. The baseline prints `http://ghp_tok3nSECRET@proxy.example:8080`. The fuzzer flags 206 of 5 537 structured URLs, and the differential flags 191 corpus URLs (all username-only). `proxy_url_test.pion:166` pins the leaky output (`http://carol@proxy.local:3128`), so the fix must update that test as well.

## P2

- **P2-1 ssh user not escaped** (`proxy_url.pion:413-420`; `has_crlf_or_nul`, `types.pion:304`, checks only CR/LF/NUL). `ssh://admin%40evil.example%3A22%23@good.example` is redacted to `ssh://admin@evil.example:22#@good.example:22`, which parses back as host `evil.example`. `%1B[2J…%07` writes raw ESC/BEL into the "safe" log line. monoid-login uses `encodeURIComponent`. C0 bytes such as `%09`/`%1B` are also accepted in decoded credentials.
- **P2-2 backslash differential.** `http://u:p@evil.example\@good.example:8080`: `new URL` (monoid-login) connects to `evil.example:80` as `u`/`p`; this parser connects to `good.example:8080` with password `p@evil.example\`. `\` is not legal in userinfo (RFC 3986) and is a path separator for WHATWG special schemes. Reject it.
- **P2-3 host charset.** `validate_plain_host` (`proxy_url.pion:101-124`) accepts `%`, `\`, `<`, `>`, `^`, `|`, which WHATWG forbids. `http://exa%6dple.com` keeps `exa%6dple.com` (WHATWG: `example.com`). The differential shows 185 host/port disagreements with the reference, including `127.1` and `0x7f.0.0.1` (WHATWG canonicalises those to `127.0.0.1`; not scored).
- **P2-4 IPv4-mapped IPv6 in NO_PROXY.** `matches()` (`proxy_url.pion:724-766`) checks IPv4 rules only against IPv4 targets, so `10.0.0.0/8` does not cover `::ffff:10.1.2.3` (the Go matcher unmaps, so it does). The opposite direction also differs: `::/0` matches `::ffff:1.2.3.4` here but not in Go. Of 1 197 NO_PROXY cases, 38 disagree with Go: these mapped-address cases, `*.` (P2-5), and trailing-dot leniency (see Observations).
- **P2-5 `*.domain`.** `parse_single_no_proxy_rule` (`:535`) only special-cases a bare `*`, so `*.corp.example` becomes a literal domain that can never match. The rule is dropped without any signal, and those hosts keep going through the proxy.
- **P2-6 code aliasing.** `SocksReplyCode::to_byte` (`types.pion:69`) and `SocksAuthMethod::to_byte` (`socks5.pion:19`) call `v.to_byte()`, which wraps: `Unassigned(0)`/`Unassigned(256)` go on the wire as `00` (Succeeded), `Unassigned(261)` as `05`, `Other(256)` as `00` (NoAuth), `Other(258)` as `02` (UserPass), `Other(-1)` as `FF`. The encoders should reject values outside `9..255` / `3..254`.
- **P2-7 lost failure code.** `socks5_decode_reply` (`socks5.pion:497-522`) parses BND.ADDR before it looks at REP. A REP=5 reply with ATYP=0 (common on errors) yields `InvalidAddressType(0)`, so the user sees "invalid address type" instead of "connection refused". `ProxyError::SocksFailure` exists but is never produced. monoid-login checks REP first.
- **P2-8 request-target bytes.** `parse_and_sanitize_forward_request` copies the target (`http_proxy.pion:832, 873-884`) into the upstream request line without checking it. HTAB, VT, `\x01`, and DEL pass through (RFC 9112 §3.2; HTAB is a request-line separator for several servers), and so does `#frag`, even though a `#` in the authority is rejected.
- **P2-9 `NeedMore(0)`** at `http_proxy.pion:450, 580, 789`. `DecodeStatus::NeedMore(Int)` is documented as the minimum number of bytes still needed. A `read_exact(need)` loop spins on 0. `NeedMore(1)` is enough to fix it.
- **P2-10 duplicate `Proxy-Authorization`** (`:507-512`, `:932-933`). The last header wins (in the test, `alice` then `mallory` yields `mallory`). A front component that checks the first header disagrees with this parser about who the client is.
- **P2-11 encoder duplicates.** `extra_headers` can add `Host: evil.example:443` or a second `Proxy-Authorization` next to the ones `encode_connect_request` writes (`:404-438`). Two `Host` headers are a 400 under RFC 9112 §3.2.

## Observations (reported, not scored)

- **O1 Quadratic re-scan when bytes trickle in.** Every HTTP decoder rescans from byte 0 on each call and returns `NeedMore(0)` with no offset hint. With the default 64 KiB limit, a client that sends 1 byte per segment costs **1.43 s CPU** for one 65 506-byte head; the same head decoded whole 1 024 times costs 0.21 s (`run_audit.sh dos`: 8 K 0.02 s → 16 K 0.09 s → 32 K 0.37 s → 64 K 1.43 s, ×4 per doubling). The cost is bounded by `max_header_bytes`, and the bridge listens on loopback, so this is not scored. A `resume_from` offset (or a stateful scanner) would make it linear.
- **Fail-closed differences from monoid-login** (`diff`: 432 URLs rejected here but accepted by the reference, 118 the other way round). Examples: malformed or `%00`/`%0D` percent-escapes in credentials are rejected here, while the reference keeps them verbatim. `ssh://user:@host` is rejected. A scheme-less `host:port` is rejected. `host:` (empty port) is rejected. In the other direction, `h%0A.example` and `a\b` are accepted here (covered by P2-3). `:08080` is accepted as 8080, like WHATWG.
- **`redacted()` with only a password** (`http://:secret@host`) prints `***@`, where the reference prints no userinfo. Both are safe.
- **NO_PROXY trailing dot.** `example.com` matches `EXAMPLE.com.` and `EXAMPLE.COM.` matches `example.com` here, but not in Go. The behaviour here is more correct for FQDNs; not scored. Go also never proxies loopback or `localhost`; this package leaves that to the rules (63 such cases were set aside in the diff).
- **RFC 1929 empty password.** The encoder and decoder reject PLEN=0, as RFC 1929's `1 to 255` field width requires. monoid-login sends PLEN=0 for `socks5://user@host`, so porting that bridge needs a policy decision.
- **SOCKS encoder/decoder asymmetry.** The decoder accepts CONNECT with DST.PORT=0 and domains containing spaces or other non-hostname bytes; the encoder rejects port 0. Both are allowed by RFC 1928; not scored.
- **`HttpConnectResponse.proxy_authenticate`** keeps only the last challenge. Every challenge is still present in `headers` (checked by a control test).
- **Reference bug found on the way:** in monoid-login@886d08e, `parseProxyUrl` and `redactProxyUrl` call each other on every unparseable URL (`proxy-bridge.ts:64` ↔ `:105`). The recursion only stops when V8 overflows the stack (depth ≈ 4 154, about 13 ms per call), which is also why the URL corpus is kept to 4 838 entries. The Pion port does not have this problem.

## Defended (control tests, all PASS)

- **Credential matrix (25 URLs):** every URL from the task (`p%40ss:w0rd`, `:secret@`, `user:@`, `evil.com@good.com`, ssh password and identity, `ftp://`, `%ZZ`/`%0`/`%00`/`%0D%0A` in credentials and host, port `0`/`65536`/20 digits/`-1`, broken brackets, zone IDs, `[1.2.3.4]`, empty and 300-byte hosts). No secret appears in `redacted()`, `to_safe_string()` or any error. Userinfo is split on the last `@`. The ssh identity is parsed but never displayed.
- **NO_PROXY:** `evil-example.com`, `example.com.evil`, `notexample.com` never match `example.com`. Case and trailing dot are normalised. `.corp.example` matches subdomains only. CIDR `/0 /8 /32 /64 /128` are correct. `/33`, `/-1`, `/129` are dropped. Port-scoped rules hold. Empty and whitespace-only entries are ignored.
- **SOCKS5:** VER≠5, NMETHODS=0, RSV≠0, ATYP 0/2/5/FF, invalid CMD, domain length 0, domains containing CR/LF/NUL, RFC 1929 VER≠1/ULEN=0/PLEN=0, `0xFF` method, auth rejection, IPv4/IPv6 addresses of the wrong length, CONNECT port 0/−1/65536, ULEN 256 and a 256-byte domain are all rejected. A 255-byte domain round-trips. All six messages give the same result whole, in 1-byte prefixes and with a 32-byte pipelined tail.
- **HTTP smuggling:** these are all rejected: TE+CL in both orders and any case, `gzip, chunked`+CL, `Transfer-Encoding : chunked`, chunked not last, duplicate chunked, unknown codings, TE on HTTP/1.0, conflicting or comma-listed CL, `-1`/`+5`/`0x5`/20-digit/empty CL, bare LF, bare CR, obs-fold (SP and HTAB), `Host : evil`, NUL or CTL in names and values, duplicate Host in origin-form, malformed request lines, `https://`, userinfo, port 0 and fragments in an absolute-form authority. Identical CL values are canonicalised to a single header.
- **Hop-by-hop:** multiple and mixed-case `Connection` headers, `, X-Custom ,keep-alive`, `Proxy-Connection`, `Proxy-Authorization`, `Proxy-Authenticate`, `Keep-Alive`, `TE`, `Trailer` and `Upgrade` are all stripped. `Connection: Host` never removes `Host` (absolute-form and origin-form).
- **CONNECT:** `[::1]:443` parses. Authorities with a path, query, userinfo, port 0/65536/overflow, a bare IPv6 address, a broken bracket or an invalid IPv6 address are refused. For `200 Connection Established` followed by a TLS ClientHello, every 1-byte prefix gives exact `consumed`. A 407 with two `Proxy-Authenticate` headers keeps both. The encoders reject CRLF, NUL, `:`, SP and HTAB in hosts, `:` in a Basic username, and CTL/DEL in header names, values and the reason phrase.
- **Limits:** forged zero or negative `ProxyLimits` fail closed. A 1 MiB unterminated head is refused at `max_header_bytes` (no OOM or hang). 101 headers exceed `max_headers`.

## 4-mode consistency

`run_audit.sh fuzz` (seed 20261124, 60 000 cases: 9 decoders + URL + NO_PROXY; for every byte buffer, all prefixes are replayed and a +32-byte tail is appended):

| mode | lines | SHA-256 |
| --- | ---: | --- |
| native_dbg | 60 239 | `11a946ac769d499a1fbc790cba79499c3e22186ad39f31c0cd16c23dd31e4aa8` |
| native_rel | 60 239 | `11a946ac…e4aa8` |
| wasm_dbg (node) | 60 239 | `11a946ac…e4aa8` |
| wasm_rel (node) | 60 239 | `11a946ac…e4aa8` |

All four outputs are byte-identical. There were no panics, out-of-bounds accesses or wasm32 traps, and every mode reached `SUMMARY`. Violations: `forward=31` (P0) and `url=206` (P1-2). All other decoders have 0. The URL differential output is also identical between native and wasm32.

## Benchmarks: re-run and fairness

These are the package's own W1–W3 benchmarks, re-run with `bench_compare.py --warmup 1 --rounds 5` on the same machine (Apple Silicon, under shared load):

| workload | pion median | go median | pion/go | README claim | stdout SHA-256 |
| --- | ---: | ---: | ---: | ---: | --- |
| W1 URL + redaction + NO_PROXY, 200 k | 138.0 ms | 83.4 ms | 0.60× | 0.60× | identical `96dfab9a…` |
| W2 SOCKS5 handshake, 500 k | 273.7 ms | 41.8 ms | 0.15× | 0.16× | identical `bd5d0f40…` |
| W3 CONNECT + forward sanitize, 100 k | 533.1 ms | 566.4 ms | 1.06× | 1.02× | identical `88bc1dee…` |

The numbers reproduce, and the README reports the slower results honestly. Two caveats about fairness:

- **The `go_stdlib` label is misleading.** Neither Go side uses a library SOCKS5 or NO_PROXY implementation (`x/net/proxy` and `httpproxy` are not used). W2 Go builds and checks byte slices inline with no codec types, so 0.15× compares a full codec with hand-inlined byte checks. W1 Go re-implements this package's NO_PROXY semantics and its username-only output (so the hashes match), rather than measuring Go's matcher.
- **W3 is not equal work in either direction.** Go runs the general-purpose `http.ReadRequest`/`ReadResponse` (URL parsing, MIME canonicalisation, map allocation), which is heavier. But its "sanitisation" only re-emits two hard-coded headers (`Accept`, `X-Trace-Id`) and does no CL/TE smuggling validation. The ~1.0× result is parity within noise (my rounds: 0.99× and 1.06×), not a win. There is also a doc mismatch: the comments say W2 runs "200,000 rounds", but both implementations and `run_bench.sh` run 500 000.

## Files

- `redteam_test.pion`, `pion.toml`: 15 finding tests and 10 controls (`pionc test packages/proxy/audit`)
- `probe/`: fuzzer with streaming invariants (`fuzz`), corpus runners (`urls`, `noproxy`), trickle-feed DoS probe (`drip`/`whole`)
- `diff/ref_monoid_login.mjs`: monoid-login@886d08e `parseProxyUrl`/`redactProxyUrl`, ported verbatim; `diff/go/`: `x/net/http/httpproxy` oracle (pinned `go.sum`); `diff/gen_corpus.py`, `diff/compare.py`
- `reference_fix.patch`: a non-normative fix sketch that takes `run_audit.sh` to exit 0
- `run_audit.sh`: one-command reproduction; all output goes to `$AUDIT_OUT` (default `/private/tmp/rt-proxy-audit`)
