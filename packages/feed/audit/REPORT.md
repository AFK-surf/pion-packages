# Red-team audit: `packages/feed` v0.1.0 @ `5c5b6fd` (`feat/pkg-feed`)

Auditor: RT-feed (independent adversarial review). Scope: format detection, RSS 2.0 / 0.91 / 0.92,
RSS 1.0 (RDF), Atom 1.0 (RFC 4287), JSON Feed 1.0 / 1.1, date parsing, `xml:base` / RFC 3986,
serializers (`to_rss2` / `to_atom` / `to_json_feed`), DoS limits, 4-mode Native/Wasm32 consistency and
fairness of `bench/` (W1/W2/W3).

| | |
| --- | --- |
| Target | `packages/feed` @ `5c5b6fd`, not modified (this branch only adds `packages/feed/audit/**`) |
| Toolchain | `pionc 0.1.0` (`$HOME/.pion/bin`, `AFK-surf/pion@66d2b4b`), node for wasm32 (`pion_wasm_rt.mjs`) |
| Oracle | Rust `feed-rs =2.4.0`, `audit/oracle/rust` (`Cargo.lock` committed, built `--locked`, no `sanitize` feature, same as `bench/rust`) |
| Specs | RFC 4287, RSS 2.0 (RSS Advisory Board) + RSS Best Practices Profile, RSS 1.0, JSON Feed 1.1, RFC 3986 §5, RFC 3339 §5.6, RFC 2822/5322 §3.3/§4.3, XML 1.0 5th ed. + Namespaces 1.0, XML Base |
| Reproduce | `sh packages/feed/audit/run_audit.sh` (~40 s on an M-series Mac; everything goes to `/private/tmp/rt-feed-audit`) |

## Verdict

No P0: across ~1,100 adversarial parse / serialize / reparse requests, 30 DoS inputs and 4 build modes there is no
crash, no trap, no unbounded recursion, no quadratic path and no markup / CDATA / JSON injection; native
and wasm32 output is byte-identical. The weaknesses are semantic: **five P1 defects** that silently
corrupt or lose data on feeds that occur in the wild (WordPress, Google Play / Podcasting 2.0 podcasts,
Netscape RSS 0.91, any RSS→Atom conversion, numeric JSON Feed ids) or make `to_atom` emit documents that
feed-rs rejects, and **nine P2 issues** (one of them the benchmark claim). The README's "matches and slightly edges out feed-rs" is a
process start-up artefact: with start-up amortised Pion is **0.91× / 0.94× / 0.57×** of feed-rs on
W1 / W2 / W3 and 0.64×–0.94× on four blind-spot workloads (§6).

| ID | Sev | Finding | Root cause | Unit tests (FAIL today) |
| --- | --- | --- | --- | --- |
| P1-1 | P1 | Element dispatch ignores namespaces: any extension element whose local name is `comments` / `image` / `title` / `description` / `id` / `rights` / `name` … overwrites the core field (`slash:comments` → comments URL `"12"`, `googleplay:image` erases the logo, channel `media:title` replaces the title, Atom `x:id` / `dc:title` replace id / title) | `rss.pion:554-645` (item), `rss.pion:653-743` (channel, no `is_media_elem` branch), `atom.pion:57-75,112-165,201-247` compare `tag_name().local` only | `p1_rss_slash_comments_clobbers_comments_url`, `p1_rss_foreign_image_erases_channel_logo`, `p1_rss_channel_media_title_overrides_title`, `p1_atom_foreign_namespace_children_override_core` |
| P1-2 | P1 | Every document with a `<!DOCTYPE>` is rejected (`XmlError`), and `detect_format` reports `unrecognized XML root element: !doctype` — this is every Netscape RSS 0.91 feed | `lib.pion:151` `allow_dtd: false`; `lib.pion:7-52` prolog skipper has no DOCTYPE case | `p1_doctype_rss091_rejected` |
| P1-3 | P1 | RSS item `<description>` typed `TextType::Text` although RSS 2.0 defines it as entity-encoded HTML; `to_atom` then writes `<summary type="text">&lt;p&gt;…` and Atom readers show literal tags | `rss.pion:578`, `rss.pion:705`; `serialize.pion:230-234` | `p1_rss_description_typed_plain_text` |
| P1-4 | P1 | JSON Feed `"id": 123` becomes `""` (spec: reader **must** coerce to string); entry identity lost, serializers then invent `urn:pion:entry:N` / index ids | `json_feed.pion:210-214` (`jf_get_str` → `as_str` only) | `p1_json_numeric_id_not_coerced` |
| P1-5 | P1 | Out-of-line Atom content (`<content type="image/png" src=…>`) loses its MIME type and `to_atom` writes `<content type="text" src=…/>`, violating RFC 4287 §4.1.3.1; feed-rs rejects the whole document (`UnknownMimeType`) | `atom.pion:33-37` (non-html types collapse to `Text`), `serialize.pion:229-240` | `p1_atom_out_of_line_content_reserialized_invalid` |
| P2-1 | P2 | `atom:link` without `rel` keeps `rel = None` (RFC 4287 §4.2.7.2: MUST be read as `alternate`; feed-rs does) — also for `atom:link` inside RSS | `rss.pion:318-339` | `p2_atom_link_rel_default_alternate` |
| P2-2 | P2 | `resolve_url` collapses empty path segments (`g//h` → `g/h`) and does not dot-normalise network-path references (`//h/p/../q`) | `url_resolve.pion:44-47`, `url_resolve.pion:117-120` | `p2_resolve_url_rfc3986_empty_segments_and_netpath` |
| P2-3 | P2 | `xml:base` on `atom:icon` / `atom:logo` (and `generator@uri`) is ignored — resolved against the feed base only | `atom.pion:231-238` | `p2_atom_icon_logo_own_xml_base_ignored` |
| P2-4 | P2 | Unchecked `Int64` parsing: `length="9999999999999999999"` → `-8446744073709551617`; negative enclosure lengths and iTunes durations (`-5`, `00:-30`, `9223372036854775807:00:00` → `-3600`) accepted; the negative `size_in_bytes` that `to_json_feed` then writes makes feed-rs reject the JSON | `xml_util.pion:128-159` (`parse_i64_trimmed`), `xml_util.pion:520-559`; used at `rss.pion:152-153,322-323,636-637` | `p2_enclosure_length_overflow_and_negative`, `p2_itunes_duration_negative_and_overflow` |
| P2-5 | P2 | Offsets `+2400` / `+24:00` accepted and shift the instant by a day (RFC 3339 `time-numoffset` hour is 00-23; feed-rs rejects) | `date.pion:521,531` call `time::Timestamp::parse_rfc3339` / `parse_rfc2822` first; `packages/time` offset parsing (`Offset::from_seconds` allows ±25:59:59). `date.pion:82`'s own parser rejects `hh > 23` | `p2_date_offset_24h_accepted` |
| P2-6 | P2 | XHTML text constructs drop namespace declarations below the wrapper `div` → prefixed XHTML (`<xh:p>`, `<m:mi>`) comes out with unbound prefixes; `to_atom` writes `TextType::Xhtml` as `type="html"` so the type is lost on a roundtrip | `xml_util.pion:305-391`; `serialize.pion:232` | `p2_xhtml_prefixes_unbound_after_serialization`, `p2_xhtml_roundtrip_becomes_html` |
| P2-7 | P2 | `to_rss2` never writes feed-level authors (`managingEditor` / channel `dc:creator`), so Atom→RSS and RSS→RSS lose them | `serialize.pion:157-221` | `p2_to_rss2_drops_feed_authors` |
| P2-8 | P2 | JSON limit errors are classified by substring; json5's `"maximum node count exceeded"` matches none of `depth`/`limit`/`nodes`, so a 2 MB JSON Feed (well under `max_bytes`) with > 1 M values returns `JsonError`, not `LimitExceeded` | `json_feed.pion:319` | `p2_json_node_cap_reported_as_json_error` |
| P2-9 | P2 | Benchmark claims are start-up artefacts (§6) | `bench/run_bench.sh` one-shot processes, 6.6 ms vs 8.0 ms start-up | — |

Unit-test summary (`pionc test packages/feed/audit`): **27 tests, 18 FAIL (findings), 9 PASS
(controls)**. Graded run summary of `run_audit.sh` today: `unit` 18 failing, `diff` 35 failing checks of
165 graded (9 findings; P2-8 is graded by `unit` and `dos`), `roundtrip` 1 failing (P1-5), `fourmode` PASS, `dos` 1 input failing in all 4 modes (P2-8, `json_nodes_1m`) → exit 1.
`sh scripts/verify.sh packages/feed` is unaffected (the audit is its own package `feed_audit`).

---

## 1. P1 findings

### P1-1 Namespace-blind element dispatch

XML Namespaces 1.0 makes an element name the pair {namespace URI, local name}. `packages/feed` does
resolve prefixes by URI for the extension namespaces it knows (`is_elem_ns`, `xml_util.pion:394`; control
`control_custom_prefixes_by_namespace_uri` passes with `a:feed`, `r:RDF`, `a10:link`, `m2:content`,
`c:encoded`), but everything that is not one of those known namespaces falls through to a comparison of
the **local name only**. Any other vocabulary therefore overwrites core fields:

| Input (minimal) | Pion | Spec / feed-rs |
| --- | --- | --- |
| WordPress item: `<comments>https://ex.com/p/1#comments</comments><slash:comments>12</slash:comments>` | `comments_url = "12"` | URL (feed-rs ignores `slash:`) |
| Podcast channel: `<image><url>…/logo.png</url>…</image><googleplay:image href=…/>` (also `podcast:image`) | `logo = None` (second "image" has no `<url>` child, `parse_rss_image_elem` returns `None` and overwrites) | `…/logo.png` |
| Channel `<title>Real</title><media:title>Fake</media:title>` (Media RSS allows channel-level elements) | title `Fake`, description `FakeD` | `Real` / `D` |
| Item `<description>D</description><googleplay:description>G</googleplay:description>` | summary `G` | `D` |
| Atom `<id>urn:feed</id><x:id>evil-feed</x:id>`, entry `<dc:title>`, `<dc:rights>`, `<author><x:name>` | id `evil-feed`, title `DC`, rights `R`, author `Mallory` | `urn:feed`, `T`, none, `Alice` (feed-rs also takes `Mallory` for the person — its person parser is namespace-blind too) |

Fix: in the RSS 2.0 fallthrough require `ch.namespace()` to be `None` (RSS 2.0) or `http://purl.org/rss/1.0/`
(RSS 1.0); in Atom require `is_atom_elem`; add a media branch at channel level.

### P1-2 DOCTYPE rejected

`parse_with_limits` passes `allow_dtd: false` to `xml::Document::parse_with_options`
(`lib.pion:151`), and `packages/xml` turns *any* `<!DOCTYPE` into `DtdDetected` (`xml/src/dom.pion:367`).
The doctype declaration is legal XML (1.0 §2.8) and the Netscape RSS 0.91 DTD line
`<!DOCTYPE rss PUBLIC "-//Netscape Communications//DTD RSS 0.91//EN" "http://my.netscape.com/publish/formats/rss-0.91.dtd">`
heads every 0.91 feed. feed-rs parses it; Pion returns `XmlError`, and `detect_format` returns
`UnknownFormat("…: !doctype")` because `skip_xml_prolog_to_root` stops at `<!DOCTYPE`.
Fix: accept DOCTYPE with no internal subset (or enable `allow_dtd` — `packages/xml` already caps entity
expansions/bytes; the DoS step's `billion_laughs` / `quadratic_blowup` / `external_entity` inputs are graded
to stay errors), and skip `<!DOCTYPE …>` in `skip_xml_prolog_to_root`.

### P1-3 RSS `<description>` typed as plain text

RSS 2.0: "An item may also be complete in itself, if so, the description contains the text
(entity-encoded HTML is allowed)"; the RSS profile documents `description` as HTML. Pion stores it as
`TextContent::plain` (`rss.pion:578`; the channel description at `rss.pion:705` likewise, not graded because
the channel element is specified as a phrase); feed-rs types the item description `text/html`. Consequence (`p1_rss_description_typed_plain_text`): `to_atom` of any RSS feed writes
`<summary type="text">&lt;p&gt;hi&lt;/p&gt;</summary>` and every Atom reader shows `<p>hi</p>` literally.

### P1-4 JSON Feed numeric id

JSON Feed 1.1, items: "id (required, string) … If the id is presented as a number or other type, a JSON
Feed reader must coerce it to a string." `jf_parse_item` uses `jf_get_str` (`as_str` only), so
`"id": 123` gives `id = ""`; `to_json_feed` then writes `"id":"0"`, `to_atom` `urn:pion:entry:0`.
Duplicate detection / read state keyed on the id breaks. (feed-rs fails the whole document on a numeric
id — also non-conforming, differently.)

### P1-5 Out-of-line Atom content reserialized invalid

`parse_atom_text_construct` maps every `type` other than `html`/`text/html`/`xhtml` to `TextType::Text`
(`atom.pion:33-37`), so `type="image/png"` is gone from the model. `write_atom_text_elem`
(`serialize.pion:229-240`) writes `<content type="text" src="http://x/a.png"/>`. RFC 4287 §4.1.3.1: with
`src`, `type` "MUST be a MIME media type, rather than "text", "html", or "xhtml"". feed-rs rejects that
document entirely (`UnknownMimeType("text")`), so a Pion-generated feed with one podcast/image entry is
unreadable for feed-rs users. Caught by `roundtrip` (`rt_atom_rich RA`) and the unit test.

## 2. P2 findings

* **P2-1** `parse_atom_link_elem` (`rss.pion:318-339`) copies `rel` verbatim; RFC 4287 §4.2.7.2 requires
  `alternate` when absent. Downstream `find_primary_link` happens to pick `rel=None` links, but API users
  filtering on `rel == "alternate"` miss them.
* **P2-2** `remove_dot_segments` (`url_resolve.pion:44-47`) skips runs of `/`, so `http://a/b/c/d;p?q` +
  `g//h` → `http://a/b/c/g/h` (RFC: `…/g//h`), `/a//b/../c` → `/a/c` (RFC: `/a//c`); a network-path
  reference is returned as `scheme + ":" + rel` without `remove_dot_segments` (`url_resolve.pion:117-120`).
  All 42 RFC 3986 §5.4.1/§5.4.2 examples pass (`control_resolve_url_rfc3986_examples`).
* **P2-3** `icon` / `logo` / `generator@uri` call `resolve_url(feed_base, …)` instead of
  `get_xml_base(ch, feed_base)` (`atom.pion:231-238`); `<icon xml:base="http://cdn.com/i/">fav.ico</icon>`
  gives `http://ex.com/a/fav.ico`. Nested bases on entry/link/content/author are correct
  (`control_nested_xml_base`).
* **P2-4** `parse_i64_trimmed` accepts 19 digits with no overflow check and a sign;
  `parse_itunes_duration` sums signed parts without range checks. RSS enclosure `length` is a byte count
  (feed-rs parses `u64`). After `to_json_feed` the negative length becomes `"size_in_bytes":-5`, which
  feed-rs rejects (`roundtrip` informational row).
* **P2-5** `parse_feed_date` tries `time::Timestamp::parse_rfc3339` / `parse_rfc2822` before its own
  parsers; those accept a 24-hour offset (`Offset::from_seconds` allows up to ±25:59:59) so
  `23 Nov 2026 12:00:00 +2400` → `1795348800` (a day early). The rest of the 49-row date matrix
  (2-digit-year window 00-49/50-99, 3-digit years +1900, 29 Feb 1900/2000, `31 Feb`, `32 Jan`, `25:00`,
  `+0530`, `-0000`, `(PST)` comments, obsolete zones, unknown zones → `-0000` per RFC 2822 §4.3, lowercase
  `t`/`z`, 12-digit fractions, leap second `:60`) is correct (`control_date_matrix`, `diff` `date_*`).
* **P2-6** `serialize_xhtml_children` (`xml_util.pion:305-391`) writes `qualified_name()` and the
  non-`xmlns` attributes; namespace declarations are not re-emitted, so
  `<xh:div xmlns:xh=…><xh:p>Hi <xh:b>B</xh:b></xh:p></xh:div>` → `<xh:p>Hi <xh:b>B</xh:b></xh:p>` (unbound
  prefix, not a well-formed fragment). The default-namespace case is fine (`diff xhtml_default_ns`).
  `write_atom_text_elem` maps `Xhtml` → `type="html"` (`serialize.pion:232`).
* **P2-7** `to_rss2` emits no `managingEditor` / channel author at all (`serialize.pion:157-221`); Atom feed
  authors and RSS `managingEditor` are lost on conversion.
* **P2-8** `parse_json_feed` (`json_feed.pion:319`) decides `LimitExceeded` vs `JsonError` by searching the
  json5 message for `depth` / `limit` / `nodes`; json5 says `maximum node count exceeded`. Callers that
  treat `LimitExceeded` as "reject, do not retry" and `JsonError` as "broken publisher" get the wrong signal.
  (DoS step `json_nodes_1m`, and `json_deep_1m` under lifted limits.)

## 3. Observations (not graded; no spec MUST, or the reference implementation behaves the same)

| # | Observation |
| --- | --- |
| O-1 | Count limits cover entries and per-entry links only. Feed-level links, per-entry categories / authors / contributors and JSON `tags` are bounded only by `max_bytes` / xml `max_nodes` (100 k of each parse linearly in ≤ 0.13 s, all modes). |
| O-2 | Only UTF-8 input. UTF-16 (XML 1.0 §4.3.3: processors MUST accept it) → `UnknownFormat` (feed-rs fails too); `encoding="ISO-8859-1"` → `XmlError` (feed-rs decodes it). |
| O-3 | Whitespace before `<?xml` is a well-formedness error and Pion rejects it, but `detect_format` says `Rss2` for the same input and the README promises "leading whitespace tolerance"; feed-rs accepts. |
| O-4 | Atom Entry Documents (RFC 4287 §4.1.2 root `<entry>`) → `UnknownFormat`; feed-rs parses them. Root namespaces are not checked (`<feed xmlns="urn:x">` parses as Atom; `<RSS>` accepted). |
| O-5 | JSON Feed: `content_text` is dropped when `content_html` is present (feed-rs moves it to `summary`); `version …/2.0` accepted. |
| O-6 | `to_atom` fabricates `<updated>1970-01-01T00:00:00Z</updated>` when the feed has no date. |
| O-7 | `to_json_feed` keeps U+2028 / U+2029 raw (valid JSON, unsafe if pasted into a JS string literal). |
| O-8 | One illegal XML character anywhere makes `to_rss2` / `to_atom` fail with `SerializationError` (safe — never malformed output — but all-or-nothing; `control_serializer_illegal_xml_chars_refused`). |
| O-9 | Lenient dates: trailing garbage after a valid RFC 2822 date is ignored (`Mon, 23 Nov 2026 12:00:00 GMT garbage`). |
| O-10 | `bench/rust/Cargo.toml` says `feed-rs = "2.3.1"` (caret); `Cargo.lock` + `--locked` do pin 2.4.0, so results are valid, the manifest is just mislabelled. |

## 4. What held up (controls)

* **Injection**: `]]>`, `<script>`, `&`, quotes, CR/LF/TAB, U+2028, astral chars through all three
  serializers → expat-well-formed XML / strict JSON, reparsed to identical values; no raw `<script>` in XML
  output (`control_serializer_injection_roundtrip`; `roundtrip`: 139 documents, 412 serializations, every
  one well-formed and semantically identical after reparse except P1-5). Illegal XML chars are refused.
* **Entity handling**: Atom `type="html"` unescaped exactly once; DTD entity bombs, quadratic blow-up and
  external entities are refused (today because DTDs are off — keep them refused when fixing P1-2).
* **Prefixes**: known namespaces are recognised by URI, not by prefix string.
* **Strict JSON**: comments, trailing commas, single quotes, trailing garbage all rejected (json5 is
  run with `allow_json5: false`); `authors` (1.1) wins over `author` (1.0); mixed-type `tags` do not crash.
* **DoS**: XHTML serialization is iterative (100 k-deep XHTML with lifted limits: 0.33 s native, 0.13 s
  wasm32, no trap); 1 M-deep XML/JSON fail closed; entries / links / text / input-size limits trip exactly at
  `limit + 1`; text split over 64 CDATA sections still counted; 200 k dot-segments, `../` bases, date tokens,
  parentheses, 8 MiB attribute — all linear; zero / negative `FeedLimits` fail closed.
* **4-mode**: `diff` (147 requests), `roundtrip` parse/serialize/reparse (147 + 417 + 412 requests) produce
  byte-identical stdout (same SHA-256) in native rel/dbg and wasm32 rel/dbg; the 30 DoS inputs give
  identical summaries in all four modes.

## 5. How the harness grades (and stays valid for a fix branch)

* `redteam_test.pion` uses only public functions and field reads — no struct literal of any `feed` type —
  so a fix that adds fields or enum variants needs no audit change. The one `FeedLimits` literal lives in
  `limits_probe/` and `run_audit.sh` reports its runs as SKIPPED if that package stops compiling.
* Every graded expectation is the specification's, not feed-rs's (feed-rs disagrees with the spec on 25 of
  165 graded `diff` checks and is printed only as a reference). Rows where no spec MUST exists are `info`.
* The probe and oracle print the same canonical dump (`key\tvalue`), so `diff/vectors.py` can grade any
  field of either implementation.

## 6. Benchmark fairness (P2-9)

Same machine (Darwin arm64), `scripts/bench_compare.py --warmup 1 --rounds 5`, SHA-256 verified for every
row. "One-shot" is the official harness (`bench/pion_bench` vs `bench/rust`, one parse per process);
"in-process" parses the same file 30× (20× for B*) inside one process (`audit/probe bench` vs
`audit/oracle bench`, identical digests).

| Workload | One-shot (official) pion / feed-rs | Speedup | In-process pion / feed-rs | Speedup |
| --- | ---: | ---: | ---: | ---: |
| start-up floor (1-item RSS) | 6.57 / 8.00 ms | 1.22× | — | — |
| W1 RSS 2.0 + ext, 1 500 items | 22.05 / 22.94 ms | 1.04× | 421.3 / 381.4 ms (30×) | **0.91×** |
| W2 Atom + XHTML, 1 500 entries | 21.21 / 21.41 ms | 1.01× | 369.5 / 348.9 ms | **0.94×** |
| W3 JSON Feed 1.1, 2 000 items | 16.78 / 14.78 ms | 0.88× | 281.8 / 161.2 ms | **0.57×** |
| B1 Atom, XHTML-heavy (500) | — | — | 310.6 / 199.1 ms (20×) | 0.64× |
| B2 RSS, 12 dirty date styles (3 000) | — | — | 104.6 / 98.0 ms | 0.94× |
| B3 RSS, 64 KiB CDATA ×150 (9.4 MiB) | — | — | 137.5 / 98.9 ms | 0.72× |
| B4 podcast extensions (1 500) | — | — | 290.6 / 270.3 ms | 0.93× |

* Process start-up is ~30 % of every official one-shot measurement and Pion's is 1.4 ms shorter; that
  difference is the whole W1/W2 "lead". With start-up amortised Pion is 6-9 % slower on W1/W2 and 43 %
  slower on W3 (README: 0.90×).
* The W1/W2/W3 corpora are canonical (RFC 822 dates with numeric offsets, one small XHTML paragraph, short
  CDATA); the blind spots above show the XHTML re-serialization and long-text paths are the slowest
  (0.64× / 0.72×). Peak RSS: Pion lower on W1/W3/B2-B4, higher on W2 (21.2 vs 16.5 MiB) and B1 (20.3 vs
  11.2 MiB).
* Work equivalence is reasonable: feed-rs is built without `sanitize` (no ammonia), both parse every
  element of the corpus, the checksums cover id / title / published / summary / authors / categories. The
  digest does not cover dates for B2 (feed-rs and Pion accept different date sets — see `diff` `date_*`), so
  B2 compares parsing cost only. feed-rs has no serializer, so `to_*` cannot be compared.
* Recommendation: report in-process numbers (or subtract the measured start-up floor) and add B1/B3-style
  rows to `BENCHMARKS.md`.

## 7. Files

| Path | Purpose |
| --- | --- |
| `run_audit.sh` | one-shot reproduction; steps `unit diff roundtrip fourmode dos bench`; exit 1 while any graded finding remains |
| `redteam_test.pion`, `pion.toml` | `feed_audit` package: 18 `p1_`/`p2_` tests + 9 `control_` tests |
| `probe/` | Pion probe: `batch` (canonical dump / serialize), `stat` (DoS summary), `bench` (in-process loop) |
| `limits_probe/` | Pion probe with explicit `FeedLimits` (lifted / zero / negative) |
| `oracle/rust/` | feed-rs =2.4.0 oracle: same dump format, `bench` loop; `Cargo.lock` committed |
| `diff/vectors.py`, `diff/diff_feed.py` | 165 spec-graded checks over 147 inputs, feed-rs as reference |
| `diff/roundtrip.py` | serializer validity (expat / strict JSON / RFC 4287 §4.1.3.1) and reparse fidelity |
| `diff/fourmode.py` | native rel/dbg + wasm32 rel/dbg SHA-256 comparison |
| `diff/gen_dos.py`, `diff/dos.py` | 30 DoS / limit inputs, graded in 4 modes + lifted limits |
| `diff/gen_bench.py` | blind-spot benchmark corpora B1-B4 |
| `diff/runner.py` | shared batch / dump helpers |
