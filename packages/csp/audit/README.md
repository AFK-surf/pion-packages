# Red-team audit: `packages/csp` v0.1.0 (`feat/pkg-csp` @ `65d3864`)

Scope: all of `packages/csp/src/{types,csp,cors}.pion` (2064 lines, read in full), `csp_test.pion`,
`wasm_smoke/`, `bench/` and the README claims. Audit code lives only in this directory; nothing in
`src/` or `csp_test.pion` was changed.

```sh
sh packages/csp/audit/run_audit.sh all     # build + unit + compare + fuzz + dos   (~6 s)
sh packages/csp/audit/run_audit.sh bench   # re-run packages/csp/bench             (~3 s)
```

All artefacts go to `$AUDIT_OUT` (default `/private/tmp/rt_csp_work`); `git status --ignored` stays clean.

| Part | What | Result on `65d3864` |
| --- | --- | --- |
| `control_test.pion` | 12 tests: attacks the package already stops, spec rules it already follows | **12/12 PASS** (must stay green) |
| `redteam_test.pion` | 20 tests, one or more per finding, asserting the spec behaviour | **20/20 FAIL** = reproduced |
| `diff/cspref.mjs` | independent reference: Node WHATWG `URL` + CSP3 §6.7.2 matching transcribed from the spec, 88,856 records | 707 bypass rows (602 raw, 105 normalised), 8,656 over-block rows, 144 origin mismatches |
| `oracle fuzz` | 3 seeds × 10,000 grammar+mutation inputs through every public API, native debug/release + wasm32 debug/release | 0 panic / 0 trap, 4 modes byte-identical per seed, `serialize_csp` fixpoint and decision-stable (0 violations) |
| `oracle dos` | floods inside and outside `ParseLimits`, `/usr/bin/time -l` | linear inside the default limits (worst case 0.58 ms / 33 KiB header, 4.8 MiB RSS); O(n²) directive lookup only when limits are lifted |
| bench re-run | `bench_compare.py`, same machine | SHA-256 parity reproduced; speed is **0.81x / 0.59x**, not the README's 0.99x / 1.02x |

## Findings (most severe first)

Trigger classes: ① default use, unconditional; ② specific but legal configuration / input;
③ attacker-controlled input crossing a trust boundary.

**Common precondition of P0-1, P0-2, P1-3, P1-4, P1-8: the caller passes the target URL as a raw
string** (an attribute value such as `<script src>`), which is what the package itself does in
`csp_test.pion`, `wasm_smoke` and the bench (e.g. `"https://api.example.com/v1/../secret"`), and what
its `..`/`%2e%2e`/`\` "path-traversal rejection" only makes sense for. A caller that always passes a
WHATWG-serialised URL (`url.href`) does not hit those five: the differential's `href` variant has no
host- or port-confusion rows. The API documents neither contract.

### P0-1 Backslash in the authority: allowlisted host bypass (`script-src https://trusted.com` loads `evil.com`)

- **Where**: `src/csp.pion:681-691` ends the authority only at `/ ? #`; `:709` then takes the first `@`
  in it as the userinfo end. The same code is in `src/cors.pion:187-207` (P1-8).
- **Cause**: for special schemes WHATWG URL treats `\` exactly like `/`. `https://evil.com\@trusted.com/x.js`
  is host **evil.com**, path `/@trusted.com/x.js` to a browser; the package sees userinfo
  `evil.com\` and host **trusted.com**.
- **Impact**: any host-source (`https://trusted.com`, `*.trusted.com`, `trusted.com:*`, ...) admits any
  other host: full script-src / connect-src / frame-src bypass, trigger ③ with the precondition above.
- **Evidence**: `p0_backslash_authority_confusion_allows_evil_host`,
  `p0_backslash_authority_confusion_wildcard_host`; the `\@` rows of `BYPASS/raw` in `compare`.
- **Fix**: do not hand-parse URLs. Take a parsed URL (the repo has `packages/url`) or parse with a
  WHATWG-conformant parser before matching; at minimum, for special schemes treat `\` as `/`, strip
  ASCII tab/LF/CR first, and take the **last** `@` of the authority. Side effect: none intended; a
  correct parser only removes mismatches.

### P0-2 Several `@` + silent port fallback: allowlisted host bypass

- **Where**: `src/csp.pion:709` (first `@`), `:727-733` (an unparsable port leaves the default port).
- **Cause**: `https://u@trusted.com:1@evil.com/x.js`: WHATWG takes the last `@` (userinfo
  `u%40trusted.com:1`, host **evil.com**); the package takes the first, gets `trusted.com:1@evil.com`,
  splits at `:` into host `trusted.com` and port `1@evil.com`, which fails to parse and is replaced by 443.
- **Impact / trigger**: as P0-1 (independent root cause: survives a fix of P0-1 alone).
- **Evidence**: `p0_multi_at_userinfo_plus_port_fallback_allows_evil_host`; differential.
- **Fix**: last `@`; and P1-3 (an unparsable port must make the URL not match, never default).

### P1-3 Unparsable URL port fails open to the default port (port-pinned allowlist bypass)

- **Where**: `src/csp.pion:86-104` (`end - start > 5` → -1, also non-digits → -1) and `:720-733`
  (`if p >= 0 { port = p }`, else the default stays).
- **Cause**: WHATWG URL accepts leading zeros and strips tabs: `:00008443` and `:8<TAB>443` are port
  8443, `:000000` is port 0. The package reads them as 443.
- **Impact**: `script-src https://trusted.com` (443 only) admits another service on the same host
  (`trusted.com:8443`, e.g. a dev server or user-content port). Trigger ③ (+ raw-URL precondition).
- **Evidence**: `p1_url_port_parse_failure_fails_open_to_default_port`, `p1_url_port_with_tab_fails_open_to_default_port`.
- **Fix**: parse the port as WHATWG does (strip leading zeros, any length, ≤ 65535); if it is invalid
  the URL is invalid and nothing matches.

### P1-4 Tab/LF/CR inside a dot-segment bypasses a path-restricted source

- **Where**: `src/csp.pion:791-840` (`csp_has_path_traversal`), `:842-853`.
- **Cause**: the `..` scan runs on the raw string; WHATWG URL removes ASCII tab/LF/CR first, so
  `/safe/.<TAB>./evil.js` is `/safe/../evil.js` → `/evil.js` to the browser, while the package sees a
  segment `.\t.` and a `/safe/` prefix.
- **Impact**: `script-src https://cdn.trusted.com/safe/` loads any script of that host (the classic
  "JSONP endpoint elsewhere on an allowlisted CDN" CSP bypass). Path restrictions are weak in CSP by
  design (ignored after redirects), hence P1 not P0. Trigger ③ + raw-URL precondition.
- **Evidence**: `p1_tab_inside_dot_segment_bypasses_path_restriction`.
- **Fix**: match on a parsed URL's normalised path (same fix as P0-1).

### P1-5 `parse_csp` merges comma-separated policies into one policy (union instead of intersection)

- **Where**: `src/csp.pion:401-516` via `:519-545`: `parse_csp` never splits on `,`; only
  `parse_csp_list` does (`:580-602`).
- **Cause**: RFC 9110 §5.3 lets intermediaries and HTTP libraries join repeated header fields with
  `", "`, and CSP3 §2.2.2 defines such a value as several policies that must all allow.
  `parse_csp("script-src 'self', script-src https://cdn.com")` yields **one** `script-src` with
  sources `'self',` (junk host), `script-src` (a host-source!) and `https://cdn.com`.
- **Impact**: a caller handing the (combined) header value to the single-header API enforces the union:
  `https://cdn.com` is allowed although the first policy forbids it, and the token `script-src`
  becomes a host-source matching `https://script-src/`. `serialize_csp` keeps the comma, so a re-emitted
  header means something else to a browser than to this package. Trigger ②.
- **Evidence**: `p1_parse_csp_merges_comma_separated_policies_into_a_union`,
  `p1_parse_csp_comma_turns_directive_name_into_host_source`.
- **Fix**: `parse_csp` must reject (or return an error for) a `,` outside a directive value, or be
  removed in favour of `parse_csp_list`; also validate source-expression grammar so a stray
  `script-src` / `'self',` token is dropped instead of becoming a host (`parse_source_expression`
  accepts any bytes as a host, `:350-372`).

### P1-6 Errors are all-or-nothing: one byte or one over-limit directive discards every policy

- **Where**: `src/csp.pion:160-175` (any byte > 0x7F or control → `InvalidHeader` for the whole header),
  `:426-433` / `:465-472` (limit → whole header), `:565-579` (one bad header → the whole list).
- **Cause**: CSP3 §2.2.1 step 2.1 skips only a non-ASCII token and keeps parsing; engines have no
  256-source cap. Here `parse_csp_list(["script-src 'none'", "report-uri https://r.example/é"])` is
  `Err`, and a `default-src 'none'` policy with 257 `img-src` hosts is `Err`.
- **Impact**: the package gives the caller no fail-closed result. A caller that treats `Err` as
  "no policy" (the easy reading of `Result`) enforces nothing; anyone able to put one byte into any
  CSP header of the response (reflected `report-uri`, a templated policy, a second header from another
  layer) switches CSP off; legitimately large allowlists silently lose their whole policy. Trigger ③/②,
  severity conditional on the caller.
- **Evidence**: `p1_one_non_ascii_byte_discards_every_policy`, `p1_limit_overflow_in_one_directive_discards_the_policy`.
- **Fix**: skip the offending token/directive (spec), keep the rest; for limit overflow either truncate
  the source list to `'none'`-equivalent (fail closed) or return the parsed policies plus an error so
  the caller cannot lose the strict part; document the required caller behaviour.

### P1-7 Unknown fetch directive name fails open (`default-src 'none'` allows `fenced-frame-src`)

- **Where**: `src/csp.pion:969-1017` (no fallback for names outside the hard-coded list) and
  `:1122-1131` (`None` → `allowed: true`).
- **Cause**: CSP3 gives `fenced-frame-src` the chain `frame-src → child-src → default-src`; any name the
  table lacks (new directives, a caller typo, upper/lower variants are handled) returns "no directive".
- **Impact**: `default-src 'none'` does not cover every fetch: a caller that asks about a directive the
  table lacks gets `allowed`. Trigger ②.
- **Evidence**: `p1_unknown_fetch_directive_fails_open_under_default_src_none`.
- **Fix**: add `fenced-frame-src`; for unknown names fall back to `default-src` (fail closed) and keep
  the explicit no-fallback list (`base-uri`, `form-action`, `frame-ancestors`, `sandbox`, ...).

### P1-8 `parse_origin` has the P0-1 authority confusion

- **Where**: `src/cors.pion:187-207` (authority ends at `/ ? #`, first `@`).
- **Impact**: `parse_origin("https://evil.com\\@trusted.com/")` is `https://trusted.com`; a caller using
  `origin_equals(parse_origin(url), self)` for same-origin decisions (credentials, CORS mode
  selection) is fooled. `check_cors_*` themselves compare raw strings and are not affected. Trigger ③.
- **Evidence**: `p1_parse_origin_backslash_reports_trusted_origin`; 143 `ORIGIN MISMATCH/raw` rows.
- **Fix**: as P0-1.

### P2-9 Opaque or empty page origin: scheme-less host-source skips the scheme check

- **Where**: `src/csp.pion:912-918` (`eff_scheme` empty → the check is skipped).
- **Impact**: in a sandboxed (`null`-origin) document `img-src trusted.com` matches `http://trusted.com`
  (downgrade), `foo://trusted.com:9999`, any scheme. CSP3 §6.7.2.8: no scheme-part match → no match.
  105 `BYPASS/href` rows are this and P2-10. Trigger ②.
- **Evidence**: `p2_opaque_page_origin_skips_scheme_check`. **Fix**: no origin scheme → no match.

### P2-10 Scheme without a default port: any port matches

- **Where**: `src/csp.pion:937-942` (`def_p < 0` skips the port check).
- **Impact**: `img-src foo://trusted.com` matches `foo://trusted.com:9999`. **Evidence**:
  `p2_scheme_without_default_port_accepts_any_port`. **Fix**: empty port-part matches only a URL with no port.

### P2-11 `'strict-dynamic'` disables `'unsafe-inline'` for styles (over-block)

- **Where**: `src/csp.pion:1019-1031`, `:1303`. CSP3 §6.7.3.3 does that only for script, script
  attribute and navigation. **Evidence**: `p2_strict_dynamic_wrongly_blocks_inline_style`.

### P2-12 Scheme-part match and `'self'` miss the WebSocket cases (over-block)

- **Where**: `src/csp.pion:743-755`, `:862-880`. CSP3 §6.7.2.6: `ws` also matches `wss`/`http`/`https`,
  `wss` matches `https`; `'self'` matches `wss:`/`ws:` of the own host.
  `connect-src 'self'` blocks `wss://app.com`. Most of the 8,656 over-block rows. **Evidence**:
  `p2_scheme_part_match_and_self_websocket_incomplete`.

### P2-13 Path parts compared without percent-decoding (over-block)

- **Where**: `src/csp.pion:842-853`; CSP3 §6.7.2.9 decodes both. `/saf%65/` ≠ `/safe/`.
  **Evidence**: `p2_path_match_not_percent_decoded`.

### P2-14 `parse_origin`: port 0 and `blob:` give `null`

- **Where**: `src/cors.pion:224-238` (`p <= 0`), `:177-184` (`blob:` → opaque; WHATWG: the inner URL's
  origin). **Evidence**: `p2_parse_origin_port_zero_and_blob`.

### P2-15 `serialize_csp` does not escape: header/directive injection for policies built in code

- **Where**: `src/csp.pion:614-642`. All `CspPolicy` / `CspDirective` / `SourceExpression` fields are
  `pub`; a policy assembled from untrusted values serialises `\r\n` and `;` verbatim
  (`img-src a.com; script-src *; report-uri ...\r\nSet-Cookie: ...`). Parsed policies are safe
  (the parser rejects those bytes), so only constructed ones are affected.
  **Evidence**: `p2_serialize_csp_does_not_escape_constructed_policies`. **Fix**: validate in
  `serialize_csp` (return `Result`) or make the types opaque with validating constructors.

### P2-16 `Access-Control-Max-Age`: no cap, wrong default

- **Where**: `src/cors.pion:102-118`, `:486-496`. 999,999,999 s (31 years) is returned as is; engines
  cap at 7200 (Chromium) / 86400 (Firefox). Absent or invalid gives 0; Fetch's default is 5.
  **Evidence**: `p2_max_age_uncapped_and_wrong_default`.

### P2-17 O(n²) first-wins directive lookup once limits are raised

- **Where**: `src/csp.pion:379-389`, `:443`. With the default `max_directives_per_policy = 64` it is
  harmless (whole worst-case 33 KiB header: 0.58 ms native, 0.97 ms wasm32, 4.8 MiB). A caller that
  lifts the limit pays 263 ms for 20,000 directives (17 ms for 5,000). Use a set if limits are raised.

### P2-18 Benchmark: not an independent reference, weak parity check, overstated numbers

- `bench/rust/src/main.rs` is a line-for-line transliteration of the Pion code, including both P0 bugs
  (`auth.find('@')` first `@` at `:391`/`:928`, the same port fallback at `:94`/`:404-415`). SHA-256
  parity therefore shows that two copies of one algorithm agree, not that either is correct; the README
  calls it a "reference implementation" with "strictly equivalent semantics".
- The digest is weak: `mix_decision` (`bench/pion_bench/src/main.pion:8-17`) folds only `allowed` and
  the **lengths** of the decision strings, so a wrong `matched_source` of the same length is invisible.
- `--ops 100000` divides a workload of 10,000 parses + 100,000 checks + process start by 100,000.
- Re-run on the same machine (`run_audit.sh bench`, 5 and 11 rounds, tight p95):
  CSP **0.81x** (Pion 63.1 ms vs Rust 51.0 ms), CORS **0.59x** (41.6 ms vs 24.4 ms), against the
  README's 0.99x / 1.02x (whose own min/p95 spread of 63–92 ms shows a loaded machine).
  The README and `BENCHMARKS.md` numbers should be replaced, and the "reference" relabelled as a mirror.

## Checked and holding (control tests, differential `agree` rows, code reading)

- `ParseLimits`: negative → `InvalidLimits`; 0 / exact / exact+1 for every field, duplicates count toward
  the directive limit, total bytes across headers, empty list members.
- CR/LF/NUL/VT/DEL rejected in `parse_csp` and `parse_csp_list` (no header injection from parsed input).
- `*.example.com` rejects `example.com`, `evilexample.com`, `a.example.com.evil.com`; `*` rejects
  `data: blob: filesystem: javascript: about:`; `https:` never matches `http:`, `wss` never `ws`;
  default ports (`http`/`ws` 80, `https`/`wss` 443) and `http:80 → https:443`; `:*`; IPv6; case.
- Single-`@` userinfo spoof (`https://trusted.com@evil.com`), `#@` / `?@`, `..` / `%2e%2e` / `.%2E` /
  `%2f` / `\` in paths, exact-file vs prefix paths.
- Nonce and digest case-sensitive, `'SHA256-'` prefix case-insensitive, empty `'nonce-'` / `'sha256-'`
  ignored; `'unsafe-inline'` ignored with nonce/hash/`'strict-dynamic'`; nonces never on attributes;
  hashes on attributes only with `'unsafe-hashes'`; `'strict-dynamic'` drops host/`'self'` allowlists for
  parser-inserted scripts and is ignored for `style-src` URL checks.
- `'none'` with other sources is ignored, alone or empty list blocks (CSP3 and all engines).
- Fallback chains; `base-uri` / `form-action` / `frame-ancestors` never fall back; first directive
  wins (case-insensitive); `parse_csp_list` intersection; `report-uri` commas split exactly as CSP3 does.
- CORS: `*` + include rejected; `TRUE`, missing or listed ACAC rejected; multi-value / leading-comma /
  case-different / path-carrying ACAO rejected; `Expose-Headers: *` not expanded with include;
  `Allow-Headers: *` never covers `Authorization`, and is literal with include (as `Allow-Methods: *`);
  methods byte-case-sensitive; negative / overflowing / non-numeric max-age → 0 without overflow;
  safelisted headers: 128/129 B, C0/DEL/`"` bytes, JSON and two-type content types.
- Not findings: `Origin: null` with `Access-Control-Allow-Origin: null` **passes** — that is Fetch §4.10
  (byte comparison of the serialised origin), the package follows it while `origin_equals` keeps
  opaque ≠ opaque. Nonce comparison is not constant-time, which is not exploitable (the nonce is in
  the page). Non-ASCII hosts are compared as UTF-8 bytes (no truncation in `csp_ascii_lower`: Pion
  strings are UTF-8, verified), which can only over-block.

## Files

```text
run_audit.sh              all | build | unit | compare | fuzz | dos | bench
control_test.pion         12 must-pass controls
redteam_test.pion         20 finding reproductions (fail on 65d3864)
src/helpers.pion          pol(), allows(), empty_policy()
oracle/                   Pion oracle: eval <corpus> | fuzz <seed> <n> | dos <kind> <n>
diff/cspref.mjs           independent reference + corpus generator + classifier (Node >= 18, no deps)
```
