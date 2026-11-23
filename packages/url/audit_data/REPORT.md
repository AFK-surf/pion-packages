# Red-team audit: `packages/url/src/data.pion` (RFC 2397 / Fetch §6 `data:` URLs)

- Target: `origin/feat/enrich-url-html` @ `67385f72` — `parse_data_url`, `parse_data_url_with_limit`.
- Oracle: Node.js v24 `fetch()` (undici), i.e. WHATWG URL parser → Fetch Standard §6 *data: URL
  processor* → WHATWG Infra §4.5 *forgiving-base64 decode*. 122 handpicked cases
  (`diff/cases.py`) run through `diff/pion` and `diff/node/oracle.mjs`.
- Companion audit of `srcset.pion`: `packages/html/audit_srcset/REPORT.md`.
- Reproduce everything: `sh packages/url/audit_data/run_audit.sh` (writes only to `$AUDIT_OUT`).

## Summary

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| D-1 | **P1** | MIME-parameter dedupe is O(P²): ~0.9 MB `data:` URL with 100k distinct params takes **11.9–14.8 s** (Node: 47 ms). `max_bytes` does not bound the header. | `perf/dos_scaling.py`, `probe` (Native + wasm32) |
| D-2 | P2 | Runs the data: URL processor on the *raw* string without the URL parser's preprocessing (tab/LF/CR removal, C0/FF/non-ASCII percent-encoding) → body/MIME/base64 flag differ from browsers on raw attribute values. | 3 failing `redteam_*` tests; 8/122 differential mismatches, all this class |

**No P0.** Every case on the requested attack list that the URL parser does not rewrite agrees
with fetch() byte for byte (114/122): fragment-before-comma, multiple commas, `;base64`
case/space/quote edges, every forgiving-base64 edge (`len%4==1`, inner/excess `=`, URL-safe
`-_`, non-ASCII, `%00`, VT), percent-decode-before-base64 (`SGVs%20bG8%3D` → `Hello`), MIME
parsing. `max_bytes` is checked by a counting pre-pass *before* the body is allocated (1 MiB
base64 against a 16-byte limit is rejected without allocating); `max_bytes <= 0` behaves.
No panic on any probe shape at n = 100k on Native and wasm32; no recursion (no stack risk).

## D-1 (P1) Quadratic MIME-parameter dedupe — CPU DoS

`parse_mime_type` (`src/data.pion:276-287`) checks each new parameter name against every
earlier one with a linear scan (`while pi < params.length()`), so P distinct names cost
O(P²) string compares. The header is not covered by `max_bytes` (that only limits the
decoded body), and `default_data_url_max_bytes` does not help.

| input `data:text/plain;a0=1;a1=1;…,x` | Pion native | Pion wasm32 | Node fetch |
|---|---|---|---|
| 5,000 params | 27 ms | 41 ms | — |
| 20,000 params | 389–431 ms | 656 ms | — |
| 25,000 params (process) | 657 ms | | |
| 100,000 params (~0.9 MB) | **11,862–14,811 ms** (×18–23 for 4n) | | **47 ms** |

Repro: `sh packages/url/audit_data/run_audit.sh` (sections 3–4) or
`pionc run --release packages/url/audit_data/probe`. Duplicate names (`;a=1` ×100k) are linear
(3 ms) because the scan breaks on the first hit.

Fix: dedupe with a `Map[String, Unit]` (or keep params sorted), and/or cap the header
length / parameter count (browsers have no cap but are linear).

## D-2 (P2) Raw-string contract skips URL-parser preprocessing

Fetch runs the data: URL processor on a *parsed, serialized* URL. The URL parser first removes
every ASCII tab/LF/CR, and percent-encodes C0 controls (incl. U+000C FF) and non-ASCII in the
opaque path. `parse_data_url` takes the raw string, so for raw attribute values it disagrees
with what a browser renders:

| input | Pion | fetch / browsers |
|---|---|---|
| `data:,a\tb\nc\rd` | body `a\tb\nc\rd` | body `abcd` |
| `data:te\txt/plain,x` / `data:text/\nplain,x` | `text/plain;charset=US-ASCII` (MIME parse fails) | `text/plain` |
| `data:text/plain;\x0cbase64,SGk=` / `…;base64\x0c,SGk=` | base64 → `Hi` | FF is `%0C` → not base64, body `SGk=` |
| `data:\x0ctext/plain,x`, `data:é/html,x`, `;a=é`, `;a="\x01"` | MIME differs | MIME differs (percent-encoded) |

The FF/base64 row is a content-type confusion (one input, two different bodies); also Fetch
allows only U+0020 between `;` and `base64`, Pion accepts any ASCII whitespace there.
Test `control_url_parser_then_data_processor_matches_fetch` shows
`parse_data_url(url::Url::parse(raw).href())` already gives the browser result.
Fix: either run the URL parser first inside `parse_data_url`, or document that the input must
be a serialized URL and only accept U+0020 before `base64`.

Failing tests: `redteam_tab_lf_cr_in_body_are_removed`,
`redteam_tab_lf_inside_mime_type_are_removed`, `redteam_formfeed_before_base64_is_not_base64`.

## Commands

```sh
export PATH=$HOME/.pion/bin:$PATH
(cd packages/url && pionc test --json audit_data)          # 3 FAIL (findings), 8 pass (controls)
sh packages/url/audit_data/run_audit.sh                    # full: tests, differential, Native+wasm32 probe, DoS scaling
QUICK=1 sh packages/url/audit_data/run_audit.sh            # skip DoS scaling
```

## Files

- `redteam_test.pion`, `src/lib.pion` — unit tests (`redteam_*` fail = finding, `control_*` pass).
- `diff/cases.py`, `diff/pion/`, `diff/node/oracle.mjs`, `diff/compare.py` — Pion vs fetch() differential.
- `probe/` — in-process no-panic/DoS probe, built for Native and wasm32 (`~/.pion/share/pion/pion_wasm_rt.mjs`).
- `perf/dos_scaling.py` — n vs 4n scaling over 13 shapes.
