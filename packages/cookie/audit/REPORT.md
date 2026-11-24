# Red-team audit: `packages/cookie` v0.1.0 (Wave 26)

- Target: `origin/feat/pkg-cookie` @ `083024a1c6697606d66d7b38ee597b084b60f223` (`packages/cookie/src/**`, `bench/**`,
  `wasm_smoke/**`, `README.md`). This branch only adds `packages/cookie/audit/**`.
- Toolchain: `pionc 0.1.0 (arm64_apple, self-hosted)` (Pion Wave H-1 `1e609a5`), node v24.22.2 (wasm32 runtime),
  cargo 1.100.0, Darwin arm64.
- References: draft-ietf-httpbis-rfc6265bis-22 (Dec 2025; "draft-22" below), CHIPS (partition key = schemeful site of
  the top-level), WHATWG URL Standard, Mozilla PSL @ `763a4c200052` (2026-11-23) and `tests/test_psl.txt` @ `6ca11f5`
  (pinned in `psl/`, sha256 in `psl/PINNED`), Rust `cookie =0.18.3` and `psl =2.1.261` (locked `diff/oracle/Cargo.lock`).
- The whole of `src/` (types, parse, date, psl, jar; 2,787 lines without the data file) was read by hand; every finding
  below was reproduced by a case in `src/cases.pion` and, where the reference model covers it, by an attributed
  divergence in the differential corpora.

## Result

| | count | gate |
| --- | ---: | --- |
| P0 | **0** | default run `EXIT=0` |
| P1 | **6** | P1-1 … P1-6 |
| P2 | **10** | P2-1 … P2-10 |

`sh packages/cookie/audit/run_audit.sh` → `EXIT=0` (OPEN P1/P2 listed); `STRICT=1 sh packages/cookie/audit/run_audit.sh`
→ `EXIT=1` while any P1/P2 is open. Injected-bug harness: **5/5 caught**.

| id | finding | location |
| --- | --- | --- |
| P1-1 | Nameless cookie `=__Host-sid=evil` / `__Secure-x` bypasses the cookie prefixes | `src/parse.pion:258-298`, `src/jar.pion:209-217` |
| P1-2 | "Leave secure cookies alone" (draft-22 §5.7 step 16) missing: insecure origins shadow Secure cookies | `src/jar.pion:290-316` (only the exact-identity check at `:311`) |
| P1-3 | Cookie identity ignores the host-only-flag: a sibling subdomain replaces / deletes a host-only (even HttpOnly) cookie | `src/jar.pion:291-303` |
| P1-4 | Cross-site responses and cross-site non-HTTP APIs can set SameSite Lax/Strict/Default cookies (§5.7 step 18) | `src/jar.pion:219-225` (`ctx.is_same_site` never read in `store_cookie`) |
| P1-5 | `store_cookie` / `import_text` accept CTL, `;`, `=` and padded names: CRLF / cookie-pair injection into `cookie_header` | `src/jar.pion:185-213`, `:501-529`, `:695-787` |
| P1-6 | `parse_request_url` is not a WHATWG parser: `https://evil.com\@good.com/` is read as host `good.com` | `src/parse.pion:111-135` |
| P2-1 | Invalid `SameSite` keeps an earlier value (§5.6.7: Default); Lax cross-site exemption ignores non-HTTP retrievals | `src/parse.pion:461-468`, `src/jar.pion:386-395` |
| P2-2 | An invalid later `Path` does not reset the cookie-path to the default-path (§5.6.4, §5.7 step 11) | `src/parse.pion:453-456` |
| P2-3 | `Domain=..example.com` loses both dots (parse strips one, store another) and is accepted | `src/parse.pion:448`, `src/jar.pion:230-233` |
| P2-4 | `format_cookie_date` outside 1601..9999 writes wrong / non-digit years; nameless `a=b` value formatted as a named cookie | `src/date.pion:319-361`, `src/parse.pion:554-560` |
| P2-5 | `export_text` / `import_text` not lossless or validated: `-` sentinel vs partition key `-`, garbage flags accepted, duplicates, limits ignored, not atomic | `src/jar.pion:653-656`, `:695-787` |
| P2-6 | Algorithmic DoS: quadratic PSL label walk and Punycode on unbounded hosts; quadratic eviction / `clear_domain` after `import_text` | `src/psl.pion:416-459`, `:177-232`; `src/jar.pion:331-345`, `:540-553` |
| P2-7 | Per-domain limit keyed by the exact domain field: one site with many host names flushes every other site | `src/jar.pion:327-345`, `:171-181` |
| P2-8 | Hosts are not canonicalised: trailing-dot IPv4 treated as a name, no UTS #46 mapping before the PSL lookup | `src/psl.pion:343-387`, `:236-261` |
| P2-9 | PSL lookup 0.03x of `psl 2.1.261` (≈7.3 binary searches per match, 2 matches per op) | `src/psl.pion:399-462`, `:265-319` |
| P2-10 | README claims: table size in KiB wrong (167.9 KiB, not 171.9), PSL snapshot not named, "lossless" export, parser "validates" Partitioned | `README.md:9,13,19` |
| P2-11 | (re-audit of the fix) generated `src/psl_index.pion` has no generator in the repository | `src/psl_index.pion` @ `eaeb5880` |
| P2-12 | (re-audit of the fix) every combining mark is refused, so canonical IDN labels such as `ร้าน.ไทย` resolve to None | `scripts/gen_unicode_noncanon.py` @ `755d2d7f` |

Severity scale: **P0** = crash / trap / hang on any input, mode divergence, or a broken advertised guarantee with no
attacker precondition; **P1** = a security property the package advertises (prefixes, Secure / HttpOnly / SameSite
isolation, host scoping, header safety) is defeated by an attacker in a realistic position (network attacker on
http://, a sibling subdomain, a cross-site page, or a caller passing through untrusted data); **P2** = spec divergence
without a direct security consequence, robustness, performance or documentation.
Trigger tiers (security-audit convention): ① default configuration, no special input; ② specific but legitimate
configuration / timing; ③ attacker-controlled input across a trust boundary.

## SIGN-OFF: `origin/feat/pkg-cookie-fix` @ `df670114` (audit `29e39a60`)

`df670114` changes only `scripts/gen_unicode_noncanon.py` and the regenerated `src/unicode_noncanon.pion` relative to
`755d2d7f`: the hard-coded whitelist is gone and only trailing code points of canonical primary composites plus Hangul
V/T jamo are refused (P2-12 closed: `www.ร้าน.ไทย` → `ร้าน.ไทย`, `Domain=ร้าน.ไทย` stored; `x.ČÁHCESUOLO.NO`, NFD
spellings, U+0958, conjoining jamo still refused). `audit/` is byte-identical to `29e39a60`; both generators pass
`--check`.

`STRICT=1 sh packages/cookie/audit/run_audit.sh` on `df670114`: **`EXIT=0`, `RESULT: clean`, 0 P0, 0 OPEN** — 28/28
cases in native debug / release and wasm32 debug / release, package tests 15/15, all corpora 4-mode byte-identical,
reference model 0 divergences on parse / date / match / jar (psl: 8 accepted fail-closed refusals), test_psl 77/77,
`psl 2.1.261` differences only the 3 newer rules, its nested-wildcard bug and refused over-long names, every DoS bomb
< 0.33 s native / < 0.51 s wasm32, shipped bench SHA-256 identical (Set-Cookie 0.49x, PSL 0.20x of Rust), wasm_smoke
SHA-256 `0769a814…` in 4 modes, harness 5/5. Baseline `083024a1` with the same audit: `EXIT=0`, `STRICT=1` → `EXIT=1`,
all 16 original findings reproduce, harness 5/5.

**Signed off for release as `cookie` v0.1.0.** Non-blocking notes: (1) `gen_unicode_noncanon.py` reflects the Unicode
version of the Python that runs it (the committed table is Unicode 13.0 from Python 3.9); characters added later are
treated as stable and `--check` fails on a Python with a different Unicode version — pin the version in the script's
docstring when it is next touched. (2) Binary sizes measured 512 / 658 / 457 / 457 KiB vs README 496 / 625 / 448 / 448
KiB (within the 10 % gate).

## Re-audit 3: `origin/feat/pkg-cookie-fix` @ `755d2d7f`

`755d2d7f` adds `scripts/gen_unicode_noncanon.py` (`--check` passes) and `src/unicode_noncanon.pion` (980 ranges); the
IDN path now returns None for any code point in the table, and `store_cookie` / `import_text` refuse a Domain whose
PSL lookup is None. `audit/` is byte-identical to `031ea974`; with it `STRICT=1` reports `RESULT: clean` (re-run here:
`EXIT=0`, harness 5/5). P2-8 is closed: `x.ČÁHCESUOLO.NO`, the NFD spelling and `x.𝐞xample.com` are refused, and
`Domain=ČÁHCESUOLO.NO` is no longer stored.

New regression (**P2-12**, gate added): the table marks *every* code point with a non-zero combining class as
non-canonical, except four hand-picked marks that occur in PSL rules (U+094D, U+0BCD, U+0C4D, U+0E38). Marks that never
compose under NFC are canonical and IDNA2008-valid, so canonical Unicode hosts now resolve to None:
`registrable_domain("www.ร้าน.ไทย")` = None (v0.1.0: `ร้าน.ไทย`; U+0E49 THAI MAI THO has ccc 107 and composes with
nothing), and `Domain=ร้าน.ไทย` from `https://www.ร้าน.ไทย/` is refused with a misleading `PublicSuffixRejected`.
Fail-closed (no bypass), but a functional regression for every label with a Thai / Lao tone mark, Arabic harakat,
Hebrew points, etc., and the whitelist breaks as soon as a PSL refresh adds a rule with another mark. Fix (verified on
a scratch copy, which then passes every gate with `STRICT=1`): in the generator, replace the `combining(ch) != 0`
clause and the whitelist by the set of marks that are the second element of a canonical primary composite
(`unicodedata.decomposition` two-element canonical mappings that `NFC` recomposes) plus the Hangul V/T jamo
(U+1161..U+1175, U+11A8..U+11C2). That still refuses every NFD spelling of a precomposed character (U+030C, U+0301,
U+030A, …) and keeps U+093C refused (it composes with U+0928), which the gate accepts.

Gate changes in this round: `redteam_p2_12_canonical_combining_marks`; model flag `reject_all_combining` (P2-12) and
corpus inputs `ร้าน.ไทย`, `www.ร้าน.ไทย`, `x.ธุรกิจ.ไทย`; the attribution now tries accepted-alternative flags first, so a
conforming fail-closed output is never charged to a finding.

## Re-audit 2: `origin/feat/pkg-cookie-fix` @ `e4dbe752`

`e4dbe752` adds, on top of `eaeb5880`: `import_text` rejects a non-host-only cookie on a public suffix and
`matching_cookies` no longer sends one (P2-5 closed); `packages/cookie/scripts/gen_psl_index.py` regenerates
`src/psl_index.pion` byte for byte (`--check` passes; P2-11 closed); UTS #46 folding extended to basic Greek / Cyrillic
upper case and fullwidth ASCII, other U+FF00..U+FFEF forms refused; README notes `with_domain` without a leading dot.
`audit/` is byte-identical to `422a9e70`; with it, `STRICT=1` reports `RESULT: clean`.

Residual found by this review, gate extended (P2-8 stays OPEN): the fold is still a hand-written subset, so 10 of the
412 non-ASCII characters used by PSL rules have upper-case forms it leaves alone (Ā Č Ŋ Š Қ Ա Հ Յ Გ Ე) and decomposed
(NFD) input is not composed (114 rules contain a precomposed character). Neither is mapped nor refused, which makes a
non-canonical spelling of a public suffix pass the jar's PSL check: `Domain=ČÁHCESUOLO.NO` from
`https://x.ČÁHCESUOLO.NO/` is **stored** (the canonical `čáhcesuolo.no` is rejected), and
`registrable_domain("x.ČÁHCESUOLO.NO")` = `Čáhcesuolo.no`, `registrable_domain("x.c\u030Ca\u0301hcesuolo.no")` =
`čáhcesuolo.no` (both are public suffixes), `x.𝐞xample.com` → `𝐞xample.com`. Trigger tier ③ and only for hosts that
reach the jar un-canonicalised (a WHATWG URL parser would have produced Punycode), hence P2. Two ways that pass the
extended case and the model (which accepts mapping or refusing per input):
(a) generate the full mapping into a literal with `gen_psl_index.py`-style tooling from Python's `unicodedata`
(NFKC + lower case for every BMP / SMP code point that changes, plus canonical composition pairs), or
(b) fail closed: generate the set of code points that are not stable under NFKC + lower case, plus the combining marks
that take part in canonical composition, and return None when the input contains one the fold does not handle.

## Re-audit of `origin/feat/pkg-cookie-fix` @ `eaeb5880` (E-cookie-Fix-1)

Every changed file was reviewed (`parse.pion`, `date.pion`, `jar.pion`, `psl.pion`, new `psl_index.pion`, README) and
this suite was run on the merged tree (`audit/` from this branch on top of `eaeb5880`).

Audit-side correction found while running the fix: the model's `format_set_cookie` wrote a nameless value containing
`=` without the leading `=` that `redteam_p2_4_format_date_range` requires, so the fixed formatter showed up as 21
unexplained parse divergences. The model now writes `=<value>` (the conforming behaviour); the v0.1.0 behaviour is the
P2-4 emulation flag `format_nameless_raw`, and "always `=`" / "refuse" are accepted alternatives. On `083024a1` the run
is unchanged: `EXIT=0`, `STRICT=1` → `EXIT=1`, the same 16 findings, harness 5/5.

Verified fixed on `eaeb5880`: P1-1 … P1-6, P2-1, P2-2, P2-3, P2-4, P2-6 (all bombs < 0.35 s native, < 0.52 s wasm32),
P2-7, P2-9 (0.20x of `psl 2.1.261`, 6x faster; the node-flag index was decoded independently: 10,923 nodes,
byte-sorted, 0 disagreements with the rule table — gate `compare.py pslindex`), P2-10. Model divergences: parse / date /
match / jar 0; psl only P2-8 and accepted alternatives. No new P0 / P1. Residual, kept OPEN (gates extended):

- **P2-5 (reopened, pre-existing gap missed in round 1)**: `import_text` accepts a domain cookie on a public suffix
  (`sid evil co.uk host_only=0`) and `matching_cookies` sends it to every `*.co.uk` site; §5.7 step 9 never creates such
  a cookie and §5.8.3 step 3 excludes it at retrieval. `redteam_p2_5_export_import` now also asserts that an imported
  `Domain=co.uk` cookie is not sent to https://victim.co.uk/ (rejecting the record, dropping it, or filtering at
  retrieval all pass).
- **P2-8 (partially fixed)**: UTS #46 folding covers ASCII and Latin-1 only (`uts46_fold_codepoint`), so
  `registrable_domain("x.ПР.СРБ")` = `ПР.СРБ` (the public suffix `пр.срб` in upper case) and `www.ＥＸＡＭＰＬＥ.com` →
  `ＥＸＡＭＰＬＥ.com`. The case now also covers Cyrillic upper case and fullwidth Latin; mapping them (NFKC + lower
  case) or refusing non-canonical input (None) both pass.
- **P2-11 (new)**: `src/psl_index.pion` (194 KB of generated literals) has no generator in the repository, so a PSL
  refresh cannot rebuild it and nothing but this audit ties it to `psl_data.pion`. Gate: a non-documentation file
  outside `src/` / `audit/` (package or `scripts/`) that produces `psl_node_data`.
- Information (not gated): `store_cookie(Cookie::new(..).with_domain(".example.com"))` is now refused
  (`DomainMismatch`) because the store no longer strips a second dot (the P2-3 fix); worth a line in the README that
  `with_domain` takes the domain without a leading dot.

## P1 findings

### P1-1 — nameless cookies bypass `__Secure-` / `__Host-` (tier ③)
`validate_cookie_prefixes` (`src/parse.pion:258-298`) and the `__Http-` check (`src/jar.pion:209-213`) look only at
`cookie.name`. draft-22 §5.6 step 3 makes `=__Host-sid=evil` a cookie with an empty name and the value
`__Host-sid=evil`, and §5.8.3 step 6 serialises a nameless cookie as its bare value, so the server receives
`Cookie: __Host-sid=evil`. draft-22 §5.7 step 22 exists exactly for this: "If the cookie-name is empty and … the
cookie-value begins with a case-insensitive match for `__Secure-` / `__Host-`, abort".
Repro: `jar.store_set_cookie("=__Host-sid=evil", RequestContext::http("http://example.com/", t))` → `Ok(true)`;
`cookie_header(https://example.com/)` → `__Host-sid=evil` (also from a sibling subdomain with
`Domain=example.com`, and `__Secure-x` with no `=` at all).
Fix: in `store_cookie`, when `cookie.name == ""`, reject values starting (case-insensitively) with `__secure-` or
`__host-` (and, for consistency with the package's own extension, `__http-` / `__host-http-`). No side effect on
legitimate nameless cookies (`=plain` stays accepted; the case checks it).
Gate: `redteam_p1_1_nameless_prefix`; model flag `nameless_prefix`.

### P1-2 — "leave secure cookies alone" missing (tier ③, network attacker on http://)
`store_cookie` only refuses an insecure write when the *exact* identity (name, domain, path, partition) holds a Secure
cookie (`src/jar.pion:311`). draft-22 §5.7 step 16: a non-secure cookie from a non-secure origin must be ignored if a
Secure cookie with the same name exists whose domain domain-matches the new one (or vice versa) and the new path
path-matches the existing one. Without it an on-path attacker answering http://example.com/ plants `sid=evil;
Path=/app`, which §5.8.3 sorts *before* the Secure `sid` on https://example.com/app/…, or a host-only `sid` on
http://a.example.com/.
Repro: Secure `sid=good; Path=/` from https; then `sid=evil; Path=/app` from http → `Ok(true)`;
`cookie_header(https://example.com/app/x)` = `sid=evil; sid=good`.
Fix: before the identity lookup, scan for name-equal Secure cookies with a domain match in either direction and
`path_matches(new_path, old.path)`; the case also checks the spec's own counter-example (`a; Path=/foo` stays allowed
next to a Secure `a; Path=/login`), so the check must not be widened to all paths.
Gate: `redteam_p1_2_leave_secure_alone`; model flag `secure_alone`.

### P1-3 — identity without the host-only-flag (tier ③, sibling subdomain)
The duplicate lookup (`src/jar.pion:291-303`) compares (name, domain, path, partition_key) but not `host_only`.
draft-22 §5.7 step 23 identifies a cookie by (name, domain, **host-only-flag**, path). evil.example.com can therefore
send `sid=x; Domain=example.com; Path=/` and *replace* example.com's host-only cookie (HttpOnly does not help: the
attacker's response is an HTTP API), or `Max-Age=0` and *delete* it. With the spec's identity the attacker can only add
a second cookie, which the server sees next to the real one.
Repro: host-only `sid=victim; HttpOnly; Secure; Path=/` on https://example.com/; https://evil.example.com/ sets
`sid=attacker; Domain=example.com; Secure; Path=/` → jar has 1 cookie, `Cookie: sid=attacker`.
Fix: add `c.host_only == host_only` to the identity (and keep it in `export_text`'s identity for P2-5's de-duplication).
Gate: `redteam_p1_3_host_only_identity`; model flag `hostonly_identity`.

### P1-4 — cross-site responses set SameSite≠None cookies (tier ③, cross-site page)
`store_cookie` never reads `ctx.is_same_site` / `ctx.is_top_level_navigation` (`src/jar.pion:219-225` only checks
`SameSite=None` ⇒ `Secure`). draft-22 §5.7 step 18: a cookie whose same-site-flag is not "None" (Strict, Lax, or
Default when the attribute is missing) must be ignored unless the request is same-site or a top-level navigation, and
a non-HTTP API may not set it from a cross-site context. Without it a cross-site iframe / image response plants Lax
(by default!) cookies that are then sent on same-site requests — the CSRF-token / session-fixation vector SameSite is
meant to close.
Repro: `RequestContext::new("https://victim.com/api", Some("https://evil.com"), true, false, t)` (not a navigation)
stores `csrf=attacker; Path=/`; `cookie_header(https://victim.com/)` = `csrf=attacker; …`.
Fix: after computing `effective_ss`, `if !same_site_eq(effective_ss, SameSite::None) && !ctx.is_same_site &&
(!ctx.is_http_api || !ctx.is_top_level_navigation) { reject }`. Top-level navigations keep any SameSite (spec note).
Gate: `redteam_p1_4_cross_site_set`; model flag `xsite_set`.

### P1-5 — `store_cookie` / `import_text` inject into the `Cookie` header (tier ③, caller passes untrusted data)
`parse_set_cookie` rejects CTL bytes and cannot produce `;` in a value, but the public `store_cookie(Cookie, ctx)`
(`src/jar.pion:185-213`) and `import_text` (`:695-787`) store any name / value, and `cookie_header` (`:501-529`)
concatenates them verbatim. `Cookie::new("a", "b\r\nX-Injected: 1")` → `Cookie: a=b\r\nX-Injected: 1` (request
header injection); value `b; __Host-sid=evil` or name `" __Host-sid"` (leading space, not trimmed, so the prefix check
is skipped) → the server reads an extra `__Host-sid` pair; `import_text` happily unescapes `\r\n` into a value.
`format_set_cookie` / `format_cookie_header` already reject these bytes, so the jar is the only unguarded path.
Fix: apply the §5.6/§5.7 checks in `store_cookie` (CTL bytes, `;`, `=` in the name, leading/trailing WSP, empty
name+value, size) and route `import_text` records through the same validation (see P2-5).
Gate: `redteam_p1_5_store_injection`.

### P1-6 — `parse_request_url` host confusion (tier ③, URL parser differential)
The authority ends only at `/`, `?` or `#` and the host starts after the last `@` (`src/parse.pion:111-135`). In the
WHATWG URL Standard (browsers, `fetch`, and this repository's `packages/url`) a `\` in a special URL is a path
separator, so `https://evil.com\@good.com/` is a request **to evil.com** with path `/@good.com/`; the jar reads
host `good.com`, sends good.com's cookies to evil.com and lets evil.com set cookies for good.com. Any embedder that
hands the raw URL string to the jar while its HTTP stack uses a WHATWG parser is exposed. (Related, same root cause:
ASCII TAB/LF/CR are not stripped, dot segments are not removed from the path, percent-encoded hosts and IPv4 number
forms are not canonicalised — see P2-8.)
Fix: parse with `packages/url` (WHATWG, already in the repository) or at least treat `\` like `/` for special schemes
and refuse URLs the minimal parser cannot canonicalise. Refusing (Err) URLs that contain `\` is accepted by the gates
as a fail-closed alternative.
Gate: `redteam_p1_6_url_host_confusion`; model flag `url_backslash` (alternative `url_reject_backslash` = conforming).

## P2 findings

- **P2-1 — SameSite** (`src/parse.pion:461-468`): an unknown value is ignored, so `SameSite=None; SameSite=Bogus` stays
  `None`; draft-22 §5.6.7 appends `(SameSite, "Default")` and §5.7 step 17 takes the last one, i.e. Default
  (Lax-by-default) — the package keeps the *more permissive* earlier value. `cookie_should_send_samesite`
  (`src/jar.pion:386-395`) grants the Lax cross-site exemption to non-HTTP retrievals; §5.8.3 requires retrieval type
  "HTTP". Gate: `redteam_p2_1_samesite_default`; flags `samesite_keep`, `lax_nonhttp`. 422 parse-corpus lines and
  ≥ 7 jar blocks attributed.
- **P2-2 — Path** (`src/parse.pion:453-456`): an empty / non-`/` Path value is ignored instead of setting the
  default-path, so `Path=/admin; Path=admin` keeps `/admin` (§5.6.4: cookie-path = default-path; §5.7 step 11: last
  Path wins). Gate: `redteam_p2_2_path_override`; flag `path_keep`.
- **P2-3 — double leading dot** (`src/parse.pion:448` strips one `.`, `src/jar.pion:230-233` strips another):
  `Domain=..example.com` (domain `.example.com`, which no host domain-matches, so Chrome and the spec reject the cookie)
  is stored as a domain cookie for example.com; `Domain=...com` gets as far as the PSL check. Fix: strip in one place
  only. Gate: `redteam_p2_3_domain_multidot`; flag `domain_multidot`.
- **P2-4 — formatter fidelity** (`src/date.pion:319-361`): `format_cookie_date` truncates the year with `.to_int()`
  and `write_4d` keeps 4 digits, so 253402300800 (year 10000) becomes `Sat, 01 Jan 0000 …`, which re-parses as **2000**
  (a far-future `Expires` turns into an expired cookie), `Int64::MIN` writes `*+.'` as the year, years 1..1600 re-parse
  as 2001.. or fail (the Expires attribute is then silently dropped and the cookie becomes a session cookie).
  `format_set_cookie(Cookie::new("", "__Host-sid=evil"))` writes `__Host-sid=evil`, which re-parses as a *named*
  cookie (`src/parse.pion:554-560`; emitting `=__Host-sid=evil` or refusing round-trips). Clamp to
  1601-01-01 00:00:00 .. 9999-12-31 23:59:59 (§5.6.1 clamps to the representable range). Related (API sweep, not a
  separate finding): with `now_unix_secs = Int64::MIN`, `Max-Age=0` computes `now - 1` (`src/jar.pion:266`), which wraps
  to `Int64::MAX` and stores the deletion cookie forever. Gate: `redteam_p2_4_format_date_range`.
- **P2-5 — export/import** (`src/jar.pion:653-656`, `:695-787`): `-` is both "no partition key" and a legal key (a
  `top_level_site` that `parse_request_url` rejects is lower-cased into the key, `:65`), so a partitioned cookie comes
  back unpartitioned and is then sent under every top-level site; `host_only` / `secure` / `http_only` /
  `partitioned` accept anything (`cols[3] == "1"`), an unknown SameSite becomes Lax, `partitioned=1` without a key is
  accepted, records are appended without de-duplication (two cookies with one identity) or limits, and a failing
  record leaves the earlier ones imported. README calls the pair "lossless". Gate: `redteam_p2_5_export_import`.
- **P2-6 — algorithmic DoS** (`diff/dos.py`): `match_psl_internal` rebuilds `suffix` and two probe keys by
  concatenation for every label (`src/psl.pion:416-459`), O(L²) bytes in the number of labels; `encode_punycode_label`
  rescans the label for every new code point (`:177-232`), O(n²); hosts have no length limit (RFC 1035: 253 octets,
  63 per label). `matching_cookies` computes the partition key — a PSL walk — on **every** request
  (`src/jar.pion:407`). Measured (native release, one CLI run = 8 PSL calls): 128k labels / 256 KiB host 6.0 s;
  24,000 distinct CJK code points 6.4 s; 32k labels 0.36 s (quadratic: ×4 per doubling). `import_text` bypasses the
  limits, after which a single `store_cookie` runs the per-domain eviction loop once per excess cookie, each pass
  O(N) count + O(N) victim scan + O(N) `remove_at` (`:331-345`): 40k imported cookies → 11.7 s for one store;
  `clear_domain` / `purge_expired` shift the array per removal (4.7 s). Fix: refuse names > 253 octets / labels > 63
  octets before the PSL walk (accepted by the model as `psl_reject_long`), walk labels without re-concatenating, and
  enforce limits in `import_text` / compact in one pass.
- **P2-7 — eviction per domain field** (`src/jar.pion:327-345`): `max_cookies_per_domain` counts `c.domain == domain`,
  so one site with N host names (wildcard DNS) gets N × 180 cookies and the global limit evicts every other site
  (non-Secure first, then LRU). Chrome and Firefox apply the per-domain cap per registrable domain (eTLD+1).
  Gate: `redteam_p2_7_eviction_per_site` (60 host names of attacker.example evict all of victim.example's cookies with
  limits 40 / 10).
- **P2-8 — host canonicalisation** (`src/psl.pion:343-387`, `:236-261`): `is_ip_address` runs before the trailing dot
  is stripped, so `127.0.0.1.` is a domain name (`public_suffix` = `1`, `registrable_domain` = `0.1`); only ASCII is
  lower-cased and U+3002 / U+FF0E / U+FF61 are not label separators, so `www.Éxample.com` → `Éxample.com` and
  `www.example。com` → `www.example。com`. draft-22 §5.1.2 / UTS #46 map these; refusing them (None) is accepted by the
  gates as fail-closed (`psl_reject_noncanonical`). Gate: `redteam_p2_8_host_canonicalization`; flags `ip_trailing`,
  `no_uts46` (5 PSL-corpus lines).
- **P2-9 — PSL performance**: the shipped bench reproduces 0.03x of `psl 2.1.261` (548 ms vs 18.6 ms; 2,586 ns/op vs
  88 ns/op). The hypothesis "each lookup scans the 171 KiB table for newlines" is **false**: `psl_lookup_raw` scans
  only back/forward to the boundaries of the probed line (~20 bytes per step, 14 steps). Measured breakdown (scratch
  build of `src/psl.pion`): one binary search ≈ 169 ns, label split ≈ 103 ns, `registrable_domain` ≈ 1,993 ns. Each
  `match_psl_internal` probes exception + exact + wildcard for every label (on the bench corpus **7.31** binary
  searches per match, each with 1–2 string allocations) and a bench op runs two matches (`registrable_domain` +
  `public_suffix`), i.e. ≈ 14.6 × 169 ns ≈ 2.5 µs — the whole gap. Actionable: (1) store one line per PSL *node* with
  flags (rule / wildcard-child / exception-child) and stop at the first suffix that is not a node: **2.39** probes per
  match on the bench corpus (3×); (2) compare the probe in place (`"!"` / `"*."` prefixes without allocating);
  (3) a fixed-width offset index (a second generated literal) removes the boundary scans; (4) expose one call that
  returns suffix and registrable domain together. The gate opens P2-9 while the measured PSL speedup is < 0.0625x
  (i.e. until lookups are ≥ 2× faster than today).
- **P2-10 — README** (parsed at run time by `diff/readme.py`): "**171.9 KiB**" — the literal is 171,944 bytes =
  **167.9 KiB** (171.9 kB); the PSL snapshot (`763a4c200052`, 2026-11-23) is not named, so "complete official PSL"
  cannot be re-checked and the oracle (`psl 2.1.261`, 3 rules older) differs silently; "lossless `export_text` /
  `import_text`" (P2-5); the parsing bullet says Partitioned is "validated to require Secure" but `parse_set_cookie`
  accepts `a=b; Partitioned` (only the jar validates). Verified true: 10,472 / 6,950 / 3,522 rules, 15 test groups,
  200/200 and 106/106 shipped differential corpora, wasm_smoke stdout + SHA-256 `0769a814…`, binary sizes
  269/349/236/236 KiB, benchmark medians and speedups (0.49x / 0.03x measured vs 0.50x / 0.03x claimed).

## What holds (control cases, all pass in 4 modes)

- **Static red lines**: `pion.toml` has 0 dependencies; `src/` has 0 `extern "C"`, 0 `World`, 0 imports, 0
  module-level `let` (mutable or not); every public value type is `Send` (probe in `portability`).
- **4-mode determinism**: every corpus (parse 3,922, date 4,027, psl 31,486, match 2,032, jar 9,849 lines in 450
  scenario blocks, test_psl 77), 15 DoS bombs and the API sweep are byte-identical in native debug / release and
  wasm32 debug / release; `wasm_smoke` prints the README's two lines (SHA-256 `0769a814…`) in all 4 modes.
- **PSL data**: the embedded table equals the official list @ `763a4c200052` rule for rule, ICANN/Private sections
  included, strictly byte-sorted (the binary-search precondition); every rule is probed as itself, one and two labels
  deeper (31k inputs), plus first/last/neighbour/prefix keys, empty labels, IPs, IDN / invalid UTF-8: the package
  equals the independent PSL algorithm in `diff/spec_ref.py` everywhere except P2-8's 5 inputs; Mozilla
  `test_psl.txt` 77/77 (IDN and Punycode). `psl 2.1.261` agrees on 31,426 of 31,455 ASCII inputs; the rest are 7 inputs
  under the 3 rules newer than the crate (`*.airoapp.ai`, `*.host.cloud`, `sites.aspirethemes.com`) and 22 inputs where
  **the crate** is wrong (a wildcard nested under a wildcard, e.g. `ap-north-1.r.cloud.int.apple` → crate `int.apple`,
  PSL algorithm and Pion `ap-north-1.r.cloud.int.apple`).
- **PSL bypass attempts rejected**: `Domain=co.uk` / `CO.UK` / `co.uk.` / `.co.uk` / `com` / `github.io` (Private) /
  `foo.ck` (`*.ck`) / `x.kawasaki.jp`; exceptions `www.ck`, `city.kawasaki.jp` allowed; host == public suffix becomes
  host-only (§5.7 step 9); IPs never suffix-match (`1.0.0.1` vs `0.0.1`, `127.0.0.1` vs `0.0.1` / `0.1`).
- **Prefixes**: `__Host-` / `__HOST-` / `__host-` (Path, Domain, Secure, origin), `__sEcUrE-`, whitespace-padded names,
  `__Http-` and `__Host-Http-` (HttpOnly, HTTP API only).
- **CTL / CRLF**: `parse_set_cookie` and `parse_cookie_header` reject `%x00-08 / %x0A-1F / %x7F` anywhere, keep HTAB;
  `format_set_cookie` / `format_cookie_header` reject CR/LF/`;` (and `=` in names).
- **CHIPS**: Partitioned without Secure rejected; key = scheme + registrable domain of the top-level (port and
  subdomain ignored, scheme kept); a.com and b.com partitions are isolated and do not overwrite each other.
- **SameSite / HttpOnly / Secure at retrieval**; `SameSite=None` without Secure rejected.
- **Dates (§5.1.1)**: 4,027 generated / adversarial dates agree with the model exactly (2-digit years 00..69 / 70..99,
  1900 / 2000 / 2024 leap rules, Feb 30, 24:00:00, 23:59:60, < 1601, 5-digit years, tokens in any order, noise).
- **Max-Age**: `+5`, `5x`, `-`, `1.5`, `0x10` ignored; `-5` / `0` expire; 20-digit values clamp to ±(2⁶³−1) without
  wrapping; precedence over Expires; 400-day cap (Max-Age and Expires).
- **Limits**: 4,096-octet name+value (4,096 ok, 4,097 rejected), 1,024-octet attribute values (1,025 ignored), `=`,
  `; Secure`, ` = ` rejected, quoted values kept verbatim, last attribute wins.
- **Jar**: §5.8.3 order (longer path, then earlier creation), creation-time kept on update, non-HTTP API cannot set,
  overwrite or read HttpOnly, http cannot set or overwrite Secure; per-domain eviction expired → non-Secure → LRU;
  10k inserts on 10k hosts 0.28 s, 10k on one host 0.03 s, 2,720 cookies matching one request × 50 requests 0.06 s.
- **Linear parsers**: 1 MiB values, 1 MiB of `;` / `=`, 100k attributes, 1 MiB dates, 1 MiB URL, 100k-pair Cookie
  header all < 0.03 s.

## Differential oracles

- **Reference model** (`diff/spec_ref.py`, draft-22 transcription + CHIPS + PSL algorithm + WHATWG split): the Pion
  output must equal the model byte for byte; a divergence is attributed to the smallest set of finding-emulation
  flags that reproduces it exactly (`diff/compare.py spec`), otherwise it is an unexplained P0. Current tree: parse
  789 / 3,922 lines attributed to P2-1 / P2-2; psl 5 / 31,486 to P2-8; match 4 / 2,032 to P1-6; jar 184 / 450 blocks
  to P1-1, P1-2, P1-3, P1-4, P1-6, P2-1, P2-2, P2-3 (alone or combined); date 0 / 4,027; **0 unexplained**.
  Fail-closed alternatives a fix may choose (refuse `\` URLs, refuse non-UTS #46 hosts, refuse > 253 / > 63-octet
  names) are flagged "OK" and count as conforming. Self-check: a scratch copy with quick fixes for P1-1/2/3/4/6 and
  P2-1/2/3/8 (never committed) gives 0 divergences on parse / date / match / jar, only "accepted alternative" on psl,
  flips exactly those red-team cases to PASS, and the harness still catches 5/5 — the gates do not over-specify.
- **Rust `cookie =0.18.3`** is not an RFC 6265bis parser; on the parse corpus 2,421 lines are identical and every
  line where it differs while Pion equals the model is classified (cookie-rs keeps any Path, has no 4096 limit,
  accepts CTL bytes, rejects nameless cookies, keeps leading dots, clamps negative Max-Age to 0 and reads an empty
  Max-Age as `i64::MAX`, parses only 4 fixed date formats and years < 1601, ignores invalid SameSite). The shipped
  200-line bench corpus is curated to avoid these, which is why it shows 0 divergences.
- **Rust `psl =2.1.261`**: see "PSL data" above.

## Harness (`run_audit.sh harness`)

Each bug is injected into a copy of the package in `$AUDIT_OUT` (alternatives keep it injectable into a rewritten
tree; a tree with no injection point left reports SKIP):

| injected bug | caught by |
| --- | --- |
| `date_two_digit_year` (69 → 1969) | `control_dates`, model:date, model:parse |
| `psl_exception` (exception rules never match) | `control_psl_domain_rejection`, `control_psl_vectors`, model:psl, model:jar, test_psl |
| `prefix_host_path` (`__Host-` without `Path=/`) | `control_prefixes`, model:jar |
| `path_match_boundary` (`/ab` path-matches `/a`) | model:jar, model:match |
| `ctl_allows_lf` (LF accepted) | `control_ctl_injection`, model:parse |

## Running

```sh
sh packages/cookie/audit/run_audit.sh            # EXIT=0 unless a P0 reproduces; OPEN P1/P2 listed
STRICT=1 sh packages/cookie/audit/run_audit.sh   # EXIT=1 while any P1/P2 is open
sh packages/cookie/audit/run_audit.sh cases      # single section (after `build`)
```

Sections: `build portability unit cases determinism oracles psl dos api smoke bench docs harness`. Artifacts in
`$AUDIT_OUT` (default `/private/tmp/pion-cookie-audit`), the shipped bench in `/tmp/pion-cookie-bench`; nothing is
written inside the repository. README numbers are parsed at run time; the red-team cases accept every conforming
outcome (`Err` or `Ok(false)` for a refused cookie; mapped or refused non-canonical hosts), so a fixed tree passes
`STRICT=1` without touching `audit/`.

## Files

- `src/main.pion` (CLI: parse / date / psl / match / jar / time / api / list / case), `src/cases.pion` (13 red-team +
  14 control cases), `src/api.pion` (extreme-value sweep), `redteam_test.pion`, `control_test.pion`
- `diff/spec_ref.py` (reference model), `diff/gen.py` (deterministic corpora), `diff/compare.py` (comparators and
  attribution), `diff/dos.py` (bombs and budgets), `diff/readme.py` (README claims)
- `diff/oracle/` (Rust `cookie =0.18.3` + `psl =2.1.261`, locked `Cargo.lock`)
- `psl/public_suffix_list.dat`, `psl/test_psl.txt`, `psl/PINNED` (sources and sha256)
