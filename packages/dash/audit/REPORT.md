# Red-team audit: `packages/dash` v0.1.0 (ISO/IEC 23009-1 MPEG-DASH)

Auditor: independent red team (`RT-dash`). Nothing under `packages/dash/src`, the package tests, the package
`README.md` or any repository-root file is changed by the audit; everything lives in `packages/dash/audit/`.

```sh
sh packages/dash/audit/run_audit.sh            # exit 1 while any P0 reproduces
STRICT=1 sh packages/dash/audit/run_audit.sh   # exit 1 while any finding is open
```

## Re-audit 3 of `57ecbbd` (`origin/feat/pkg-dash-fix`, P1-6 relative `../` variant)

**Verdict: NOT SIGNED (one P2 left).** P1-6 is closed: `resolve_relative_path_parsed` splits the normalised base
directory once per track and drops directory segments per leading `..`, so `b34` / `b35` / `b36` take 0.04 / 0.04 /
0.09 s native and 0.17 / 0.16 / 0.33 s wasm32 (were 27 / 56 / 27 s). Re-checking the new fast path against RFC 3986
with 108 new base x reference combinations (`refbase_*` named cases: rooted, authority-only, empty segments,
rootless with leading `..`, path without `/`, `urn:` bases, query bases) finds one divergence, now P2-11.
`STRICT=1 sh packages/dash/audit/run_audit.sh`: `EXIT=1`, 1 OPEN (P2-11), 0 P0; everything else passes (27/28 cases
in 4 modes, model named 224/225 conforming + 1 explained by P2-11, fuzz 2,000/2,000, API 387/387, 4-mode
determinism, 36 bombs: all in budget, smoke = README.md, bench 1.38x at load 41, 5/5 injections).

### P2-11 (new, from the P1-6 fix) segment URL fast path differs from RFC 3986 / `resolve_url` for bases without `/`

For a base whose path has no leading `/` (non-hierarchical, e.g. `urn:x`), RFC 3986 5.2.4 rule C leaves a leading
`/` as soon as a segment is removed, including a segment of the reference itself. `resolve_relative_path_parsed`
adds that `/` only when a *directory* segment is popped (`pops > 0 && poppable > 0`):

| base | media | segment URL (fast path) | `resolve_url` / RFC 3986 |
| --- | --- | --- | --- |
| `urn:x` | `s$Number$/..` | `urn:` | `urn:/` |
| `urn:x` | `../x$Number$/..` | `urn:` | `urn:/` |
| `urn:x` | `a/../b$Number$` | `urn:b1` | `urn:/b1` |

Hierarchical (`http`, `https`, `file`, relative) bases are not affected. Fix direction: also emit the `/` when a
segment of `tail` was popped and nothing of the base directory remains (`prefix_end == 0`, base not rootless).
`redteam_p2_11_fast_path_rfc_corner` compares the track URL with `resolve_url` for 4 bases x 4 references.

## Re-audit 2 of `3e43ddc` (`origin/feat/pkg-dash-fix`, "P1-5 O(1) namespace lookup and P1-6 pre-parsed BaseURL")

**Verdict: NOT SIGNED.** P1-5 is closed (`xp_ns_lookup` now uses a prefix -> binding-stack `Map`; `b33`
0.71 s native / 1.03 s wasm32, was 65 s). P1-6 is closed only for absolute references (`b31` 0.03 s, `b32` 0.07 s);
a second variant still reproduces. `STRICT=1 sh packages/dash/audit/run_audit.sh`: `EXIT=1`, 1 OPEN (P1-6), 0 P0;
everything else as in re-audit 1 (27/27 cases in 4 modes, model 2,216/2,216 + API 387/387 conforming, 4-mode
determinism, smoke = README.md, bench 1.29x at load 9.5, 5/5 injections).

**P1-6, relative variant.** `resolve_url_parsed` (`src/resolve.pion`) builds `pb.dir + r.path` and runs
`remove_dot_segments` (or `rootless_norm`) over it for every segment. A reference that climbs out of the directory
(`../s$Number$`, `SegmentURL media="../s"`) produces a short URL, so the 64 MiB output budget never triggers, while
each segment costs O(|BaseURL directory|):

| Bomb | Input | native `--release` |
| --- | ---: | --- |
| `b34` 1 MB absolute BaseURL directory, `media="../s$Number$"`, 99,999 segments | 976 KB | 27 s (> 20 s budget, also wasm32) |
| `b35` the same with a relative BaseURL `rel/aaa.../` | 976 KB | 56 s |
| `b36` 1 MB BaseURL directory, 99,999 `SegmentURL@media="../s"` | 3 MB | 27 s |

Fix direction: split the (already normalised) base directory into segments once per track and, per reference,
drop as many trailing segments as it has leading `../` before appending the rest; or charge the length of the
merged path, not only the output, to `max_output_bytes`.

## Re-audit of `b9cd082` (`origin/feat/pkg-dash-fix`, "resolve all 15 red-team audit findings")

**Verdict: NOT SIGNED.** All 15 original findings are closed, but the fix leaves one CPU amplification of the
P0-1 class open (P1-6) and introduces a new one (P1-5). `STRICT=1 sh packages/dash/audit/run_audit.sh`:
`EXIT=1`, 2 OPEN (P1-5, P1-6), 0 P0.

| Status | Findings |
| --- | --- |
| Closed (red-team case passes in 4 modes, model / dos gates agree) | P0-1, P1-1, P1-2, P1-3, P1-4, P2-1 ... P2-10 |
| **Open, new** | **P1-5** (introduced by the P2-9 fix), **P1-6** (CPU part of P0-1 not covered by the output budget) |

Review of the full diff `cc29e80..b9cd082` (9 files, +2,240 / -960), file by file:

- `xml_lexer.pion`: strict UTF-8 + `Char` pre-validation of the whole input (overlong, surrogates, > U+10FFFF,
  U+FFFE / U+FFFF), global end-of-line handling, XML 1.0 5th-edition `Name` tables, `XMLDecl` only at offset 0 /
  after the BOM with `VersionNum`, `EncodingDecl` (UTF-8 only), `SDDecl`, reserved `xml` PI targets, `]]>` in
  character data, lower-case `&#x` only, references of any length, attribute-value normalisation, an explicit
  heap stack instead of recursion (P1-4: 20,000 levels with `max_xml_depth = 1,000,000` now 0.02 s), Namespaces
  in XML resolution with duplicate expanded-attribute detection. Correct; see P1-5 for the lookup cost.
- `mpd.pion`: every element / attribute lookup is now namespace-qualified against the namespace of the root
  `<MPD>`; `S@r < -1` rejected; `width` / `height` accept 0; `mspr:pro` collected. Correct.
- `time.pion`: `+` on unsigned integers, no-zone date-times, `24:00:00` (only with zero minutes / seconds /
  fraction), offsets up to `+-14:00`, `.` only in durations, `T` / `Z` upper case, unsigned rationals. Correct.
- `resolve.pion`: RFC 3986 5.2 resolver (`split_uri_ref`, O(n) `remove_dot_segments`, rootless chains keep
  leading `..`), `max_output_bytes` (64 MiB) checked before each segment and bounded template expansion, checked
  segment numbers (an `Int64::MAX` last segment is now accepted), PTO in the `r="-1"` Period end, exact fractional
  ticks, Period@start inference. Correct, except P1-6.
- `format.pion`: values are validated (UTF-8 / `Char`, positive / non-negative integers, durations, rationals,
  date-time strings, `S@d`, `S@r`) and CR is written as `&#13;`; `mspr:pro` written with its namespace. Correct.
- `abr.pion`: every codec of a comma-separated `@codecs` list is matched. Correct.
- `types.pion` / `README.md`: `max_output_bytes`, `ContentProtection.pro`; the per-type `Send` list in README.md
  equals the `pionc check` probe (10 `Send`, 8 `!Send`, `move` into `spawn` works).

Audit-side changes in this commit (the fix did not touch `audit/`, as required):

- `diff/model.py` now resolves namespaces (Namespaces in XML 1.0) and models the P2-9 behaviour: DASH elements
  are those in the namespace of the root `<MPD>`; elements with an undeclared prefix are foreign; DASH attributes
  are unqualified (or qualified with the MPD namespace); `pssh` / `default_KID` in the cenc namespace or with the
  conventional `cenc` prefix; `pro` in the PlayReady namespace or with the `mspr` prefix; duplicate expanded
  attribute names are errors. It also dumps `PRO|` records; `compare.py` allows `mspr:pro` in `format_mpd` output.
  Both points reported by the fixer were audit-side gaps, not package bugs.
- 16 new named cases (namespaces, PlayReady PRO, `24:00` at a year end); random DRM now includes `mspr:pro`.
- 3 new bombs: `b31` / `b32` (P1-6), `b33` (P1-5).

Re-audit run (Darwin arm64, `pionc` Wave H-1 `1e609a5`):

| Gate | Result |
| --- | --- |
| static | all 0; `Send` probe 10 / 8 = README.md |
| unit | package 26/26 (README.md: 26); audit 26 pass, 0 open, 0 control failing |
| cases | 27/27 in each of the 4 modes |
| determinism | named 216, fuzz 2,000, API 387, `format_mpd` output, 26 bombs: 4 modes byte-identical |
| model | named 216/216 and fuzz 2,000/2,000 conforming, API 387/387 conforming: 0 unexplained |
| XML layer vs pyexpat | 2,193 agree, 2 known expat leniencies, 0 disagree |
| `format_mpd` output | 742/742 accepted documents well-formed, DASH element names only |
| dash-mpd-core | 725 both accept with identical shared fields; every other difference is dash-mpd-core leniency |
| dos | 30 bombs in budget (P0-1 `b27` / `b28` / `b29` now 0.02-0.13 s, <= 183 MB; P1-4 `b30` 0.02 s); `b31` / `b32` / `b33` > 20 s (P1-5, P1-6) |
| smoke | 4 x `2ce81a01...` = README.md; wasm32 213 / 206 KiB = README.md |
| bench | 1.33x / 133.7 MB/s, SHA-256 `a3b2d125...` identical; alt corpus 1.34x (was 1.59x-1.67x before the fix) |
| inject | 5/5 |

### P1-5 (new, introduced by the P2-9 fix) namespace prefix lookup is linear in the number of in-scope bindings

`xp_ns_lookup` (`src/xml_lexer.pion`) scans `ns_prefixes` backwards for every prefixed element and attribute.
Within default limits a document can keep 62 levels x 255 `xmlns:` bindings = 15,810 bindings in scope and then
use 1.5 M prefixed (unbound) attribute names: `b33` (15 MB) takes 65 s native `--release` (> 20 s budget in both
native and wasm32); before the fix the same input parsed in 0.03 s. Fix direction: a map from prefix to its
binding stack (O(1) lookup), or count `xmlns` declarations against a small budget.

### P1-6 (residual of P0-1) `resolve_url` re-scans the whole BaseURL for every segment

The output budget bounds bytes written, but `resolve_url(base, rel)` calls `split_uri_ref(base)` (a scan plus
slices of the base) before it looks at `rel`, also when `rel` is absolute, so a long BaseURL costs O(|BaseURL|)
per segment while each segment URL stays short: 1 MB BaseURL + `media="http://c/$Number$"` + 99,999 timeline
segments (`b31`, 1 MB) takes 49 s native; the same with 99,999 absolute `SegmentURL@media` (`b32`, 4 MB) 48 s.
Fix direction: split / normalise the base once per track (`pre_normalize_base_url` already exists) and resolve
each segment against the parsed base, returning absolute references without touching the base.

### INFO added by the re-audit

- I-9 Undeclared prefixes are accepted (not namespace-well-formed): elements with them are ignored, `cenc:` /
  `mspr:` are recognised by prefix even when undeclared or bound to another URI, the root namespace is not checked
  against `urn:mpeg:dash:schema:mpd:2011`. Lenient and harmless for real manifests.
- I-10 `README.md` does not list `max_output_bytes` among the `DashLimits` fields; the budget is per
  `resolve_segments` call (per track), not per MPD.
- I-11 `format_mpd` writes text values verbatim, so constructed `BaseURL` / `pssh` / `pro` values with leading or
  trailing whitespace come back trimmed (values from `parse` are already trimmed).

---

# Original audit of `65e82e3` (`origin/feat/pkg-dash`)

## Summary

| Severity | Open | Findings |
| --- | ---: | --- |
| P0 | 1 | P0-1 |
| P1 | 4 | P1-1, P1-2, P1-3, P1-4 |
| P2 | 10 | P2-1 ... P2-10 |
| INFO | 8 | I-1 ... I-8 (not gated) |

What holds (control cases, all 4 modes, and every one of them catches an injected bug):

- No `extern "C"`, no `World`, no imports, no module-level state, no `Double` / `Float`, MIT, zero dependencies,
  no media files, no internal machine names.
- XXE / Billion Laughs / `<!doctype` / `<!ENTITY` in any position and letter case are rejected with
  `SecurityRejected`; no entity is ever expanded.
- Under default `DashLimits`, every XML bomb (1,000,000-deep nesting, 100,000 attributes, 15.9 MB of character
  references, 15 MB comments, unterminated CDATA, 16 MiB + 1 input) and every `SegmentTimeline` bomb (`r=999999999`,
  `r=-1` up to a 100,000-day Period, `t + d * (r + 1)` beyond Int64, `timescale` x duration overflow,
  `$Number%999999999d$`) finishes in under 0.2 s with RSS of 140 MB or less on both native and wasm32.
- Every `DashLimits` field: `N` passes, `N - 1` returns `LimitExceeded`, negative values return `LimitExceeded`.
- Durations, date-times (Gregorian leap years, offsets), rationals, the template grammar, attribute-wise
  `SegmentTemplate` / `SegmentList` / `SegmentBase` inheritance, multi-DRM `ContentProtection` (4 schemes side by
  side, multiple `cenc:pssh`, `default_KID`), ABR budget / fallback / prefix (`avc1` does not match `avc10`) / ties.
- `format_mpd`: hostile `id`, `profiles`, `mimeType`, `codecs`, `schemeIdUri`, `default_KID`, `pssh`, `BaseURL`,
  `media` strings (`"/><Evil a="1"/>'&<![CDATA[]]>` TAB LF CR) never create an element or an attribute, round-trip
  exactly, and C0 control characters are refused.
- 4-mode determinism: 2,200 corpus documents, 387 API vectors, the `format_mpd` output of every accepted document
  and 26 in-budget DoS bombs are byte-identical in `native debug`, `native --release`, `wasm32 debug` and
  `wasm32 --release`.
- `wasm_smoke` SHA-256 matches `README.md` in all 4 modes; wasm32 sizes 181 / 174 KiB as claimed.
  `bench/run_bench.sh` reproduces: 60/60 parity, stdout SHA-256 `a3b2d125...` identical, 1.31x-1.33x and
  125-146 MB/s over four runs at load 7-21 (README.md: 1.31x / 131.13 MB/s, RSS 2.86 vs 2.88 MiB). The second
  corpus (`diff/altbench.py`) is not less favourable: 1.59x-1.67x, so README.md does not show a cherry-picked input.

## Method

| Gate (`run_audit.sh` section) | What it does |
| --- | --- |
| `static` | grep gates, plus a real `pionc check --json` probe that moves each of 18 public types across `spawn` |
| `unit` | `pionc fmt / check / test` of the package; `pionc test` of this audit package (`control_*` must pass) |
| `cases` | 14 red-team cases (fail while their finding is open) + 13 control cases, one process per case, 4 modes |
| `determinism` | corpora, API sweep, `format_mpd` output, DoS bombs: 4 modes byte-identical |
| `oracles` | independent Python reference model (`diff/model.py`), pyexpat cross-check of its XML layer, `urllib.parse.urljoin` cross-check of its RFC 3986 resolver, Rust `dash-mpd-core =0.1.0` (`diff/rust`, `--locked`) |
| `dos` | 30 bombs, native `--release` + wasm32 `--release`, 20 s / 1 GiB budget each, own process group |
| `smoke` | `wasm_smoke` in 4 modes vs the SHA-256 and sizes in `README.md` |
| `bench` | `bench/run_bench.sh` re-run, `README.md` claims, second corpus (`diff/altbench.py`) |
| `inject` | 5 real bug classes injected into a copy of `src/`; each must be caught by a control case |

Every number taken from `README.md` (SHA-256 values, speedup, throughput, test count, wasm sizes, the `Send` claim)
is parsed at run time (`diff/readme.py`). Red-team cases use only the public API and accept every reasonable fix
(reject the input, or produce the correct value; URLs are compared by what they resolve to). An injection whose
target text a fix rewrote is reported as SKIP.

### Reference model and canonical dump

`src/dump.pion` writes one line per record: `MPD`, `BU`/`LOC`/`UTC`, `P`, `A`, `ROLE`/`CP`/`PSSH`/`ACC`/`ACH`/
`SUPP`/`ESS`, `SB`/`LIST`/`SU`/`TPL`/`S`, `R`, then the resolved track of every Representation (`TRK` + the first 6
and last 3 `SEG`), the ABR choice for every AdaptationSet over a grid of 6 budgets x 6 codec preferences (`ABR`), and
the `format_mpd -> parse` round trip (`FMT`). Strings are `"` + `%XX`-escaped bytes, absent values `-`.

`diff/model.py` produces the same dump from the specifications: its own XML 1.0 parser (strict UTF-8 / `Char`,
XML 1.0 5th-edition `Name` tables, end-of-line handling, attribute-value normalisation, `XMLDecl` / `PITarget`,
`]]>`, character references; no DTD), xs: lexical spaces, ISO/IEC 23009-1 5.3.2 Period timing, 5.3.9 segment
addressing (with `presentationTimeOffset`), RFC 3986 5.2 reference resolution, RFC 6381 codec lists. Each document
is evaluated in two modes:

- **spec**: what a conforming implementation outputs (a set of alternatives where a fix may choose, e.g. reject
  `S@r="-5"` at parse time or at resolution time);
- **emu**: spec + the behaviour of each open finding switched on (`FLAGS`).

A Pion dump that equals a spec alternative is conforming; one that equals emu is explained, and is attributed to
the findings whose flag is needed to reproduce it; anything else is an unexplained divergence and fails the run.

The model's XML layer is itself checked against pyexpat (tree structure and every attribute / text value):
2,183 / 2,183 documents agree (plus 1 document where expat accepts `version="9.0"`, which XML 1.0 5th ed. and
quick-xml reject; 16 skipped because of the DOCTYPE policy / limits). Its RFC 3986 resolver agrees with
`urllib.parse.urljoin` on every vector except those where `urljoin` drops empty path segments (not RFC 3986).

Corpora (`diff/gen.py`, deterministic): 200 named cases, 2,000 generated documents (1/3 structured random MPDs
with multi-Period, multi-DRM, timelines with `t` / `r = -1` / PTO, duration templates, lists, bases, relative and
absolute BaseURL chains; 2/3 byte and token mutations of them), 387 API vectors.

## Results

Final run (`sh packages/dash/audit/run_audit.sh`, Darwin arm64, `pionc` Wave H-1 `1e609a5`, node 24.22,
cargo 1.100, Python 3.9): exit 1 (P0-1 reproduces); `STRICT=1`: exit 1. Wall time about 2.5 min.

| Gate | Result |
| --- | --- |
| static | all grep gates 0; `Send` probe: 10 types `Send`, 8 `!Send` (P2-3) |
| unit | package 25/25 (README.md: 25); audit `pionc test`: 13 control pass, 13 red-team open |
| cases | 13/27 pass in each of the 4 modes, identical PASS/FAIL per case; `redteam_p1_4` kills the process (exit 139 native, `RangeError` wasm32) |
| determinism | named 200 docs (1,241 lines), fuzz 2,000 docs (40,191 lines), 387 API vectors, `format_mpd` output, 26 bombs: 4 modes byte-identical |
| model, named | 200: 155 conforming, 45 explained (P1-1 6, P1-2 4, P1-3 2, P2-1 4, P2-2 2, P2-4 9, P2-5 16, P2-6 1, P2-8 1), **0 unexplained** |
| model, fuzz | 2,000: 1,454 conforming, 546 explained (P1-1 319, P1-2 44, P1-3 78, P2-1 98, P2-2 185, P2-4 95, P2-5 27, P2-6 305, P2-8 185; one document can need several), **0 unexplained** |
| model, API | 387: 321 conforming, 66 explained (P1-1 59, P2-4 7), **0 unexplained** |
| XML layer vs pyexpat | 2,183 agree, 1 known expat leniency, 0 disagree |
| RFC 3986 resolver vs `urljoin` | 86 agree, 9 differ only because `urljoin` drops empty segments, 0 other |
| `format_mpd` output | 871 accepted documents re-checked with pyexpat: 861 well-formed with DASH element names only; 10 not well-formed, all of them inputs that are not well-formed XML either (P2-5 + P2-7); 0 injected elements |
| dash-mpd-core | every accept-set and field difference classified, 0 unexplained (I-7) |
| dos | 26 bombs within budget (max 0.20 s, 137 MB RSS), `b27`-`b29` P0-1, `b30` P1-4 |
| smoke | 4 x `2ce81a01...` = README.md |
| bench | 1.32x / 145.8 MB/s, SHA-256 identical; alt corpus 1.59x (7.1 vs 11.7 MiB RSS) |
| inject | 5/5 caught: DOCTYPE classification (`control_security`), `r + 1` off by one (`control_timeline`, `control_limits`), `&quot;` escape (`control_format`), century leap year (`control_datetime`), budget `<=` (`control_abr`) |

## Findings

### P0-1 `resolve_segments` has no aggregate budget (memory and CPU amplification)

Every segment materialises `resolve_url(base, expand_template(media, ...))`. `max_segments` (100,000) bounds the
count, but nothing bounds `|BaseURL| x count`, `|media| x |RepresentationID| x count` or the per-segment
`resolve_url` work (`normalize_dot_segments` over the whole base, for every segment).

| Bomb (default limits) | Input | native `--release` | wasm32 `--release` |
| --- | ---: | --- | --- |
| `b27` 40 KB `BaseURL`, `<S d="1" r="99998"/>` | 39 KB | 4.0 GB of URLs, 4.7 GB RSS, 3.3 s | `pion panic: wasm32 out of memory` |
| `b28` 50,000 x `$RepresentationID$`, 1 KB id, 100 segments | 880 KB | 5.0 GB of URLs, 4.8 GB RSS | `pion panic: wasm32 out of memory` |
| `b29` `BaseURL` = 200,000 x `x/../`, 99,999 segments | 976 KB | > 20 s CPU (killed) | > 20 s CPU (killed) |
| `redteam_p0_1` 4 KB `BaseURL`, 99,999 segments | 4.3 KB | 402 MB of URLs | 402 MB of URLs |

An MPD is untrusted network input; a 39 KB manifest aborts a wasm32 player. Fix direction: an aggregate output
budget (e.g. `max_output_bytes` in `DashLimits`, checked before each push), resolving the base once per track and
appending the expanded template to it instead of re-normalising the base per segment.

### P1-1 `resolve_url` is not RFC 3986 reference resolution

`normalize_dot_segments` splits on `/`, drops empty and `.` segments, pops on `..` and keeps a trailing `/` only
when the input ends with one; the base query is dropped for fragment-only references.

| `resolve_url(base, ref)` | Pion | RFC 3986 5.2 |
| --- | --- | --- |
| `("http://h/a/b/c", "..")` | `http://h/a` | `http://h/a/` |
| `("http://h/a/b/", ".")` | `http://h/a/b` | `http://h/a/b/` |
| `("http://h/a/b", "x//y")` | `http://h/a/x/y` | `http://h/a/x//y` |
| `("http://h/a?q=1", "#f")` | `http://h/a#f` | `http://h/a?q=1#f` |
| `("../media/", "seg.m4s")` | `media/seg.m4s` | `../media/seg.m4s` |
| `("video/../../x/", "s.m4s")` | `x/s.m4s` | `../x/s.m4s` |

The relative rows are the common case: `parse` never sees the MPD URL, so a manifest whose BaseURLs are relative
(`<BaseURL>../media/</BaseURL>`) yields segment URLs that resolve against the MPD URL to the wrong directory, and a
`..` / `.` BaseURL silently moves every following level up one directory. Reference model: 319 of 2,000 generated
documents (and 59 API vectors) diverge because of this. The case compares what the composed reference resolves
to against a probe document URL (WHATWG `packages/url`), so any correct spelling passes.

### P1-2 Segment numbers wrap around Int64

Duration-based `SegmentTemplate` (`cur_num = cur_num + 1L`) and `SegmentList` (`start_num + i.to_int64()`) are
unchecked: `startNumber="9223372036854775807"` gives segment 2 the number `-9223372036854775808` and the URL
`s-9223372036854775808` (the timeline path checks, and even rejects a valid last segment numbered `Int64::MAX`).
Silent wrong URLs from a 1-attribute input.

### P1-3 `S@r="-1"` ignores `presentationTimeOffset` at the Period end

The repeat-until-Period-end bound is `period duration x timescale`, compared with `S@t` values that are on the
presentation timeline offset by `@presentationTimeOffset` (ISO/IEC 23009-1 5.3.9.6). With PTO = 1000, `S@t="1000"`,
`d="2"`, `r="-1"` in a 10 s Period the package returns 0 segments instead of 5; with a large PTO (live packagers use
the wall-clock epoch) every `r="-1"` entry produces no segment. 78 generated documents diverge because of it.

### P1-4 Recursion depth is bounded only by `max_xml_depth`

`xp_parse_element` recurses once per nesting level. The default (64) is safe, but `DashLimits` is public and
documented as configurable, and no value is said to be unsafe: with `max_xml_depth = 1,000,000`, 20,000 nested
elements (136 KB) kill the process (native SIGSEGV, exit -11; wasm32 `RangeError: Maximum call stack size
exceeded`; already at ~3,000 levels in wasm32). Fix: an explicit stack, or clamp `max_xml_depth` to a proven
safe bound. (`redteam_p1_4` runs only out of process: in `pionc test` it would kill the test runner.)

### P2-1 Period timing

`effective_period_duration_us` uses only explicit `@start` values: the first Period of a static MPD without
`@start` (start 0) and a Period after one with `@duration` (start = previous start + duration) get
`mediaPresentationDuration - 0` (`PT10S` + a Period starting at 4 s: 5 segments of 2 s in the first Period instead
of 2). The duration-based segment count floors fractional ticks before `ceil` (`PT2.000001S`, timescale 1,
duration 1: 2 segments instead of 3).

### P2-2 `S@r` below -1 accepted

`r="-5"`, even `r="-9223372036854775808"`, behave like `-1`. Only -1 has a meaning (5.3.9.6).

### P2-3 `README.md` claims `Send`-safe; 8 public types are not

`pionc check` rejects capturing `Mpd`, `Period`, `AdaptationSet`, `Representation`, `SegmentTemplate`,
`SegmentList`, `ContentProtection` and `ResolvedTrack` in `spawn` (`E_NOT_SEND`: they hold `Array[T]`). They can
be moved (`move v`) into a spawned task. `SegmentTimelineEntry`, `SegmentUrl`, `SegmentBase`, `Descriptor`,
`ResolvedSegment`, `DashLimits`, `DashError`, `Rational`, `MpdType`, `ContentType` are `Send`. Fix: state the
exact per-type status in `README.md` (the gate reads a `` `X` is `Send` `` list).

### P2-4 xs: lexical and value spaces

Rejected although valid (the whole MPD fails): `xs:dateTime` without a zone (`availabilityStartTime=
"2024-01-01T00:00:00"`, DASH-IF IOP: interpret as UTC) and `24:00:00`; a leading `+` on every `xs:unsigned*`
attribute (`startNumber="+5"`, `bandwidth="+1"`); `width="0"` / `height="0"` (`xs:unsignedInt`). Accepted although
invalid: `,` as decimal separator in durations, lower-case `t` / `z`, zone offsets above `14:00`.

### P2-5 XML 1.0 well-formedness constraints not enforced

The byte-level lexer checks C0 controls in text / attributes / CDATA only. Accepted (fatal errors for an XML
processor, rejected by expat and quick-xml): invalid UTF-8 (`0xFF`, overlong, encoded surrogates), non-`Char` code
points (U+FFFE, U+FFFF), non-`Name` characters in names (any byte >= 0x80, e.g. `×`), `]]>` in character data, the
XML declaration anywhere / with any version / encoding, PIs without a target or with a reserved `xml` target,
control characters inside comments and PIs, `&#X41;` (upper-case `X`). Character references longer than 24
characters are rejected although valid. CR inside CDATA is not normalised to LF. Consequence downstream:
`format_mpd` then writes these bytes back and its output is not well-formed (10 corpus documents, `oracles`).

### P2-6 Attribute-value normalisation missing

XML 1.0 3.3.3: literal TAB / LF / CR (and CRLF) in an attribute value become a space; character references keep
them. `id="a<TAB>b<LF>c<CR><LF>d"` is parsed as `"a\tb\nc\nd"` instead of `"a b c d"` (305 generated documents
diverge because of this; IDs feed `$RepresentationID$` and therefore URLs).

### P2-7 `format_mpd` returns `Ok` for values its output cannot carry

`format_mpd` checks C0 controls only. `bandwidth = -5`, an empty Representation `id`, `availabilityStartTime =
"garbage"` produce text that `parse` rejects; negative durations become `PT0S`; CR in element text is written
verbatim and re-parsed as LF; non-`Char` / invalid UTF-8 bytes (U+FFFE in `MPD@id`; reachable from `parse`
through P2-5) are written as is, so the output is not well-formed XML.
Either validate (return `Err`) or escape (`&#13;`) so that `parse(format_mpd(m)) == m` whenever the result is `Ok`.

### P2-8 ABR: only the first codec of `@codecs` is matched

`@codecs` is a comma-separated list (RFC 6381). `codecs="mp4a.40.2,avc1.640028"` does not match `"avc1"` (only the
string start is compared), so muxed / multi-codec Representations fall out of the preferred subset (185 generated
documents).

### P2-9 Namespace-unaware lookup

Elements and attributes are matched by local name in any namespace, first match wins: `<x:Period>` in a foreign
namespace is parsed as a DASH Period; `<Representation x:id="evil" id="v">` gets the id `evil`; two prefixed
attributes with the same local name are both accepted (dash-mpd-core reports a duplicate). Undeclared prefixes are
accepted.

### P2-10 PlayReady `<mspr:pro>` dropped

Only `cenc:pssh` children of `ContentProtection` are kept. PlayReady signals its header either as a `pssh` box or
as `<mspr:pro>` (the common form in PlayReady / Smooth-derived manifests); the latter disappears from the model and
from `format_mpd` output. `@robustness`, `@ref` / `@refId` (5th edition) are dropped as well.

## INFO (not gated)

- I-1 Only the first `BaseURL` of each level is used (alternatives / `@serviceLocation` failover are not exposed).
- I-2 `$SubNumber$` (ISO/IEC 23009-1 5th ed.) returns `InvalidTemplate`; `%d` / `%5d` (without the `0` flag) are
  accepted, 5 digits of width (`%00005d`) are rejected.
- I-3 `select_representation` ignores the order of `preferred_codecs` (the doc comment says so) and has no
  resolution cap.
- I-4 Design choices the model follows: `Y` = 365 d, `M` = 30 d (same as dash-mpd-core); `P1W` accepted; more than 6
  fractional digits truncated; `Representation@bandwidth` up to Int64 (schema: `xs:unsignedInt`); `frameRate="0"` /
  `"30/0"` rejected (schema pattern allows them); an `r="-1"` entry with unknown Period end yields 1 segment.
- I-5 `expand_template` with negative values (outside the DASH value space) pads after the sign: `%05d` of -5 is
  `000-5`.
- I-6 `bench/run_bench.sh` "field-by-field" parity compares a summary (counts of Role / ContentProtection / pssh /
  timeline entries, not their values) and parsing only; segment resolution, ABR and `format_mpd` are not compared
  with anything there. This audit's model / dash-mpd-core comparisons cover them.
- I-7 Rust `dash-mpd-core` (`compare.py rust`) is a lenient serde parser: it accepts DOCTYPE, invalid durations /
  date-times / numbers and missing required attributes that Pion and the model reject. Every accept-set difference
  and every field difference is classified (`oracles` section); none is unexplained.
- I-8 Repository-root `README.md`, `BENCHMARKS.md` and `catalog.json` do not list `dash` yet. Feature branches must
  not touch them; this belongs to the release integration.
