# `http_cache` v0.1.0 — independent red-team audit

Target: `AFK-surf/pion-packages` `origin/feat/pkg-http-cache` @ `124e712`
(`packages/http_cache/src/**`, 2,542 lines, read in full). Nothing under `src/` or
`http_cache_test.pion` was modified; everything here is audit-only code.

```sh
sh packages/http_cache/audit/run_audit.sh all        # or: unit | compare | fuzz | dos | bench
```

All builds go to `/tmp/rt_http_cache_work` (override with `RT_WORK`); the bench mode also
uses the package's own `/tmp/pion-http-cache-bench`. The worktree stays clean.

| Mode | What it does | Result on `124e712` |
| --- | --- | --- |
| `unit` | `control_test.pion` (properties that hold, **must PASS**) + `redteam_test.pion` (one test per finding; it asserts the RFC-correct behaviour, so **FAIL = reproduced**, PASS = fixed) | control **10/10 PASS**; redteam **20/20 reproduced** |
| `compare` | 484 cases (64 hand-written edge cases + 420 seeded random) run against Rust `http-cache-semantics =3.0.0`; every divergence is attributed to a named cause, and the mode exits 1 if any is left unexplained | 387 identical, 97 divergent, **0 unexplained** (table below) |
| `fuzz` | 50,000 deterministic iterations of mutated headers, directives, dates and extreme clocks through every public API, with invariant checks; native/wasm32 × debug/release | **0 crash / 0 trap / 0 invariant violation**, stdout SHA-256 identical in all 4 modes (`aeeab683…`); 27 hits are the known P2-16 |
| `dos` | Vary-variant scan cost, header memory, Cache-Control parse cost | P1-6 and P1-7 reproduced; parsing is linear |
| `bench` | Reruns `bench/run_bench.sh`, then the same corpus with Rust's `http::Request`/`Response` built once outside the loop | 1.33x reproduced; on equal footing Pion is **0.88–0.92x** (B-1) |

Severity: **P0** means an attacker can exploit it under the default configuration, or a
cross-user leak of credentials or session data. **P1** means a RFC MUST is violated with a
security or integrity effect, or a DoS amplification under default limits. **P2** is
compliance or robustness.

---

## Findings (most severe first)

### P0-1 — field-qualified `private="…"` / `no-cache="…"` are parsed and then ignored: a shared cache stores and replays `Set-Cookie`

- **Where**: `src/policy.pion:219` refuses only an *unqualified* `private` in a shared cache. `private_fields` and `no_cache_fields` are never used again. `src/policy.pion:499-500` (`clone_headers_lower`) stores every header. `src/policy.pion:546` uses only an unqualified `no-cache` to force revalidation. `store.pion:189` returns the full entry, `Set-Cookie` included, as `HitFresh`.
- **Chain**: the origin sends `Cache-Control: public, max-age=600, private="Set-Cookie"` and `Set-Cookie: sid=VICTIM`. `is_storable` returns `true`, the entry keeps `set-cookie`, and the next anonymous request gets `HitFresh(entry)` whose `response_headers` contain the victim's session cookie. `no-cache="Set-Cookie"` behaves the same way: the field is served on a fresh hit with no revalidation.
- **Trigger**: ① default shared configuration and an ordinary origin. Field-qualified `private`/`no-cache` exist precisely so that shared caches can store a page but must not keep its per-user cookie.
- **RFC**: 9111 §5.2.2.7 ("a shared cache MUST NOT store the specified field-name(s)") and §5.2.2.4. Rust `http-cache-semantics` refuses to store such a response in a shared cache (`compare`: `h_private_field`).
- **Repro**: `redteam_p0_1_*`, `redteam_p0_1b_*`.
- **Fix**: at `create_entry`, for a shared cache, drop every header listed in `private_fields`. Also drop `no_cache_fields` from what a fresh hit returns, or force revalidation whenever `no_cache_fields` is non-empty. The simplest fail-closed option is to treat qualified `private` in a shared cache like unqualified `private` (refuse to store), as Rust does. Side effect: a little less caching of field-qualified responses. No conflict with existing tests.

### P1-2 — `206 Partial Content` is stored and served as a complete response (cache-poisoned DoS)

- **Where**: `src/policy.pion:71` lists 206 as heuristically cacheable. Nothing records `Range`/`Content-Range` or keys on them. `store.pion:135-160` matches on URI, method and Vary only.
- **Chain**: an attacker sends `GET /video.mp4` with `Range: bytes=0-0`. The origin returns `206` with `public, max-age=3600` (or no Cache-Control at all, only `Last-Modified`: heuristic freshness). Every later full `GET` gets `HitFresh` with a 1-byte body and status 206.
- **Trigger**: ① default shared configuration; any client can send a Range request.
- **RFC**: 9111 §3.3/§3.4. A cache that does not implement range combination MUST NOT store a 206 as if it were complete. Rust leaves 206 out of `UNDERSTOOD_STATUSES` and does not store it.
- **Repro**: `redteam_p1_2_*`, `redteam_p1_2b_*`.
- **Fix**: remove 206 from `is_heuristically_cacheable_status` and refuse to store 206 in `is_storable_with_options`, unless real partial-content storage is added later.

### P1-3 — 304 merge overwrites `Content-Length` / `Content-Encoding` / `Content-Range` of the kept body

- **Where**: `src/policy.pion:655-681`. Every header named in the 304 replaces the stored one, with no exclusion list.
- **Chain**: the entry holds a 10-byte identity body. The 304 carries `Content-Length: 0` and `Content-Encoding: gzip`. The merged entry advertises length 0 and gzip for an unchanged 10-byte plaintext body. A proxy that frames from the stored metadata can desync (response splitting or truncation), and a client may try to gunzip plaintext.
- **Trigger**: ② the origin, or a misbehaving intermediary, sends body metadata on a 304, which happens in practice with frameworks that copy the 200's headers.
- **RFC**: 9111 §3.2: a cache MUST NOT update `Content-Length` (and header fields the stored response depends on) from a 304. Rust excludes `content-length`, `content-encoding`, `transfer-encoding` and `content-range`.
- **Repro**: `redteam_p1_3_*`.
- **Fix**: skip `content-length`, `content-encoding`, `transfer-encoding`, `content-range` (and hop-by-hop fields) when merging.

### P1-4 — a 304 whose strong ETag does not match still refreshes the stored entry

- **Where**: `src/policy.pion:626-725` (`merge_304`) and `store.pion:275-297` (`update_304`). There is no validator comparison; the package's own test even expects a `"w1"` entry to be refreshed by a `"w2"` 304.
- **Chain**: the stored body belongs to `"v1"`. The 304 says the current representation is `"v2"`, for example because the client's own `If-None-Match: "v2"` was forwarded. The old body is re-labelled `"v2"` and served fresh for the 304's `max-age`.
- **Trigger**: ② conditional requests that are not generated by the cache, or several variants.
- **RFC**: 9111 §4.3.4: when a 304 carries a strong validator, only stored responses with the same strong validator are updated; with none, the cache MUST NOT use the 304 to update. Rust follows this (`h_304_mismatch`).
- **Repro**: `redteam_p1_4_*`.
- **Fix**: implement the §4.3.4 selection (strong ETag, then weak ETag, then Last-Modified, then the validator-less single-entry case). On a mismatch, return `Err` or `None` and evict.

### P1-5 — a 304 carrying `no-store` neither evicts the entry nor stops it being served fresh

- **Where**: `store.pion:293` stores the merged entry unconditionally. `evaluate_lookup` (`src/policy.pion:515-623`) never looks at `response_cc.no_store`. After the merge, freshness falls back to the old `Expires`.
- **Chain**: the stored entry has `max-age=10` and `Expires: +1 day`. The 304 says `Cache-Control: no-store`. The merged CC is `no-store`, `max-age` is gone, and `Expires` remains, so the entry is served fresh for about 86,379 s (`lookup=fresh:86379`).
- **Trigger**: ② the origin revoking cacheability of an account page, for example after logout.
- **Repro**: `redteam_p1_5_*`.
- **Fix**: after `merge_304`, rerun the §3 storability check on the merged response; if it is not storable, `evict_slot`. Defence in depth: have `evaluate_lookup` refuse an entry whose `response_cc.no_store` is set.

### P1-6 — linear scan of every Vary variant on each lookup and store gives about 400–1000x CPU amplification

- **Where**: `store.pion:135-160` (`find_matching_slot`) walks every slot for the URI. Each slot costs `vary_matches`, which calls `normalized_header_value`, which scans the whole request (up to 512 headers) twice per Vary field. `store` and `update_304` call it too, so filling a URI is quadratic.
- **Measured** (`dos`, default limits, native `--release`, Apple M-series under load):
  - realistic `Vary: Accept-Encoding, User-Agent`, 1024 bot User-Agents on one hot URL: a victim's lookup goes from **5 µs → 2,130 µs** (about 430x). The 1024 attacker stores take 2.0 s.
  - worst case, 32 Vary fields and 480 request headers: **60 µs → 18,460 µs** per miss with only 256 variants. With 1024 variants it was 81.9 ms per lookup and 72.8 s to fill.
- **Trigger**: ① any URL whose response `Vary`s on a client-controlled header (User-Agent, Accept-Language, Origin, Cookie), all very common.
- **Fix**: key variants by `uri + normalized(vary values)` in a secondary map, so lookup is O(1) per URI after one normalisation of the request's Vary fields. Also cap variants per URI (for example `max_variants_per_uri`). Pre-normalise the request headers once per lookup instead of once per variant and field.

### P1-7 — `max_total_bytes` counts bodies only; stored request and response headers are unaccounted (and the requester's credentials are kept)

- **Where**: `store.pion:218-270`: `byte_size = body.length()`. `src/policy.pion:499` stores the requester's **entire** header list, including padding, `Cookie` and `Authorization`, as `request_headers`, which every later `HitFresh` hands back.
- **Measured**: default limits, 1024 entries with about 120 KB of headers each and empty bodies: `total_bytes()=0` but **peak RSS 138 MB**, against a documented 64 MiB bound. `redteam_p1_7` shows 100 entries of about 60 KB retained under `max_total_bytes=4096`. Any client can do this with cache-busting query strings on a cacheable URL. With a CDN-sized `max_entries` the memory is effectively unbounded.
- **Fix**: charge `name.length() + value.length()` of the stored request and response headers to `byte_size`. Store only the request headers named in `Vary`; they are all that `vary_matches` needs, and this also stops `Authorization`/`Cookie` of user A from being kept and returned to user B's code path.

### P2-8 — `s-maxage` does not imply `proxy-revalidate` in a shared cache

- `src/policy.pion:590-591`: `must_reval` ignores `s_maxage`. A stale `s-maxage` entry is served under request `max-stale` (`fresh:0`) or `stale-while-revalidate`. RFC 9111 §5.2.2.10. Repro: `redteam_p2_8*`. Fix: `must_reval = … || (opts.is_shared && (proxy_revalidate || s_maxage.is_some()))`.

### P2-9 — `Pragma: no-cache` is ignored (request and response, when there is no `Cache-Control`)

- There is no Pragma handling anywhere. HTTP/1.0-style clients that force a reload, and origins that send only `Pragma: no-cache` plus `Expires`, are served from cache. RFC 9111 §5.4 (deprecated, but RFC 7234 §5.4 made it a MUST; Rust honours both directions). Repro: `redteam_p2_9*`. Fix: if there is no `Cache-Control`, treat `Pragma: no-cache` as `no-cache`.

### P2-10 — `Location` / `Content-Location` resolution skips RFC 3986 §5.2: invalidation misses the real key

- `src/policy.pion:894-911`: `../other` becomes `https://shop.example/cart/items/../other`, so `/cart/other` stays cached. `?id=7` becomes `/cart/?id=7` instead of `/cart/items?id=7`. The same-origin check still holds (no cross-origin eviction), so the cost is stale data after a POST. Repro: `redteam_p2_10*`. Fix: a full §5.2.2 merge plus `remove_dot_segments`, and a query-only reference case.

### P2-11 — 1xx responses are storable with explicit freshness

- `src/policy.pion:184` accepts 100–599, and `has_explicit` short-circuits for `103` with `max-age`. RFC 9111 §3: the status must be final. Repro: `redteam_p2_11_*`. Fix: `if resp.status < 200 { return Ok(false) }`.

### P2-12 — storing a HEAD response evicts the cached GET body

- `store.pion:232-235`: `find_matching_slot(HEAD)` matches the GET entry (HEAD may be served by GET), evicts it, and inserts a body-less HEAD entry that GET cannot use. Any client can flush large cached objects with `HEAD`. Repro: `redteam_p2_12_*`. Fix: on a HEAD response, update the GET entry's headers (RFC 9111 §4.3.5) instead of replacing it; never let HEAD evict GET.

### P2-13 — when several variants match, the oldest is chosen instead of the most recent

- `store.pion:140-157` returns the first match in insertion order (which also changes after the swap-remove in `remove_from_uri_index`). RFC 9111 §4.1 says to use the most recent. Repro: `redteam_p2_13_*`. Fix: choose the match with the greatest `response_time`/`Date`.

### P2-14 — 308 is missing from the heuristically cacheable statuses

- `src/policy.pion:70-74` (RFC 9110 §15.4.9 marks 308 heuristically cacheable). A compliance gap (lost caching), not a security one. Repro: `redteam_p2_14_*`.

### P2-15 — a Date-less 304 keeps the old `Date`, so the entry never becomes fresh again

- `src/policy.pion:697` computes `apparent_age` from the stored `Date` that a Date-less 304 did not replace. Once the original `Date + lifetime` has passed, every revalidated entry is stale on arrival and every request goes to the origin. RFC 9110 §6.6.1: a recipient MUST add `Date` when caching a response that lacks one. 15 of the 97 `compare` divergences are this. Repro: `redteam_p2_15_*`. Fix: in `merge_304`, if the 304 has no `Date`, set `date = format_http_date(response_time)`.

### P2-16 — heuristic freshness overflows Int64 and gives a negative `freshness_lifetime`

- `src/policy.pion:290-317`: when `Date` is missing or invalid, `date_val = response_time`, and `(date_val - lm) * pct` overflows for clocks near `Int64::MAX`. The public `compute_freshness_lifetime` returns about −1.7e8. The cache fails closed (it treats the entry as stale), but this breaks the API invariant; the fuzz harness hits it 27 times. Fix: saturating arithmetic (`delta / 100 * pct`, clamp `delta` to `max_delta_seconds * 100 / pct` first).

### H-1 (hardening, RFC-permitted) — a shared cache reuses `Set-Cookie` responses not marked `public`

- RFC 9111 allows it, but Rust `http-cache-semantics` deliberately forces `max_age = 0` for shared caches in this case. With P0-1 fixed, consider an opt-in `CachePolicyOptions` flag that defaults to the safer Rust behaviour.

### B-1 (benchmark honesty) — the 1.34x lead comes from what the harness times, not from the policy engine

- `bench/run_bench.sh` reproduces: **1.33x** (82.0 vs 109.2 ms median). The digest is genuinely identical (`381d3742…`), and nothing in the bench is faked.
- However, `bench/rust/src/main.rs` rebuilds `http::Request` ×2 and `http::Response` ×1–2 for each case inside the timed loop: header-name hashing, `HeaderValue` validation and `HeaderMap` allocation. The Pion harness gets pre-split `Header` arrays and only wraps them. With the HTTP objects built once outside the loop (`audit/bench/make_rust_prebuilt.py`; the policy work is unchanged and the SHA-256 is identical), **Rust is faster: Pion 80.1 ms vs Rust 73.3 ms, 0.92x** (0.88x on an earlier run under load 40).
- The 12-case corpus also sits entirely inside the region where both engines agree. On the 484-case differential, 20% of cases diverge (most in Pion's favour, but including P0-1, P1-2, P1-4, P1-5 and P2-15), so "semantically equivalent" holds only for the bench corpus.
- Suggested `BENCHMARKS.md` wording: report both numbers, and say the lead disappears once the reference implementation's input construction is moved out of the loop.

---

## What held up (`control_test.pion`, all PASS)

- `no-store` in the request or the response, including when combined with `public, max-age=86400`, or in a **second** `Cache-Control` line, in any letter case. A quoted `x="no-store"` value is not mistaken for the directive.
- Shared cache: unqualified `private`, and `public` + `private` together, are refused. With `Authorization` (empty value included), storage requires `public`/`s-maxage`/`must-revalidate`. `max-age`, `Expires`, the heuristic and `proxy-revalidate` alone do not qualify.
- Duplicate or conflicting directives take the minimum (`max-age=3600, max-age=0` gives 0, also across header lines). Response `no-cache` is never `Fresh`, even under `max-stale`.
- `Vary`: separate header lines are unioned. `*` is refused whether alone, in a list or in a second line. Missing, empty and present values are all distinct. Repeated request headers are joined in order. Header names are case-insensitive.
- Invalidation: cross-origin absolute, protocol-relative (`//victim`), scheme or port changes and the userinfo trick (`https://shop@victim/`) are all refused. A 4xx/5xx/1xx response or a safe method never invalidates. Default ports are normalised. At store level, a cross-origin `Location` cannot evict a victim entry.
- HTTP-date: rejects 2025-02-29, 1900-02-29, day 0/32, Apr 31, 24:00, :60, `UTC`, 5-digit years, years below 1900, `0`, `-1`; accepts 2000-02-29 and 9999-12-31; round-trips 1900–9999 (the fuzzer checks this on every iteration).
- Delta-seconds: values above 2^31 saturate at 2147483648. `-1`, `+5`, `60abc` and empty are rejected (fail-closed: such a response is not stored). A huge `Age` or `now = Int64::MAX` saturates and never wraps to fresh.
- Stale-serving gates: `must-revalidate`, `proxy-revalidate` (shared) and `no-cache` block both `max-stale` and `stale-while-revalidate`. `stale-if-error` never serves on a normal lookup.
- `CacheStore`: an entry over `max_entry_bytes`/`max_total_bytes` is refused **without flushing** the existing entries. 500 Vary variants are held to `max_entries`. Negative limits are refused, `0` means zero, and exact boundaries are accepted. The `max_headers`/`max_header_bytes` limits fail closed in both `store` and `lookup`. Parsing a 64 KiB `Cache-Control` is linear (2 → 6 → 26 ms per 200 parses for 4/16/64 KiB).

## Differential vs Rust `http-cache-semantics 3.0.0` (484 cases)

| # | Cause | Verdict |
| ---: | --- | --- |
| 18 | Rust refuses status codes outside its "understood" list (500 etc.); Pion stores them when there is explicit freshness | RFC-permitted policy difference |
| 15 | Date-less 304 keeps the stored `Date` | **P2-15** |
| 15 | Response `no-cache` with request `max-stale`: Rust serves stale without revalidating | Pion safer (Rust bug) |
| 9 | `proxy-revalidate` in a shared cache: Rust forces freshness to 0 | Pion correct |
| 9 | ttl reporting for `no-cache` (both revalidate) | equivalent |
| 5 | Rust `after_response` drops 304 fields that the stored response lacked | Pion correct (Rust bug) |
| 2+2+1+1+1+1+1 | 206 stored; `Pragma`; `private="…"`; `no-cache="…"`; 304 ETag mismatch; 304 `no-store`; 1xx; 308 | **P1-2, P2-9, P0-1, P0-1b, P1-4, P1-5, P2-11, P2-14** |
| 2+2+2+1+1+1+1 | Vary:* storage; RFC 850/asctime dates; apparent age; invalid delta → not stored; 2^31 clamp; case-insensitive directives; dup → min | equivalent / Pion correct or safer |
| 1+1+1+1 | Rust caches POST; Rust's Set-Cookie hardening (H-1); `private` as explicit permission in a private cache; no heuristic for `public` 302 | oracle extension / policy |
| 1 | heuristic float rounding (±1 s) | noise |

`compare.py` exits 1 if any divergence is unexplained; currently there are 0.

## Not findings (checked and dismissed)

- **Byte-truncation in `ascii_slice_lower` / `trim_ows_slice` (`to_byte`)**: Pion strings are UTF-8 byte strings and `code_unit_at` returns bytes (verified), so nothing is truncated and no non-ASCII values collide.
- **The RFC 850 two-digit year pivot is fixed at 70** instead of RFC 9110's "more than 50 years in the future" rule. A Sans-IO parser has no clock; this is the common practice (Go uses 69) and only affects the years 2050–2076.
- **A strict `Cache-Control` parser returns `Err`** instead of ignoring an invalid directive. This fails closed (not stored / caller falls back to the origin); a caller must not treat `Err` from `store` as "stored".
- **No HashDoS assessment of `Map[String, …]`**: the Pion `Map` hash seeding was not reviewed; this is out of scope for the package.

## Files

```
audit/run_audit.sh            all | unit | compare | fuzz | dos | bench
audit/pion.toml, src/lib.pion audit package (public API only) + helpers
audit/control_test.pion       10 tests, must PASS
audit/redteam_test.pion       20 tests, FAIL = reproduced (P0-1 … P2-16)
audit/diff/gen_cases.py       deterministic 484-case corpus (seed 9111)
audit/diff/rust/              oracle: http-cache-semantics =3.0.0
audit/diff/pion/              subject: same line format
audit/diff/compare.py         divergence attribution, exit 1 on unexplained
audit/fuzz/                   50,000-iteration invariant fuzzer (native + wasm32)
audit/dos/                    vary / vary_ua / mem / cc probes (use with /usr/bin/time -l)
audit/bench/make_rust_prebuilt.py  equal-footing Rust bench variant (B-1)
```
