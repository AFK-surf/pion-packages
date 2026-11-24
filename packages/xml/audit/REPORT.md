# Red-team audit: `packages/xml` (Pion) vs Rust `roxmltree` / `quick-xml`

Target: `AFK-surf/pion-packages` `origin/feat/pkg-xml` @ `98b613c`, branch `audit/redteam-xml`.
Nothing outside `packages/xml/audit/` was changed.

| reference | version | used for |
| --- | --- | --- |
| Rust `roxmltree` | **=0.21.2** | DOM oracle (acceptance + tree), DOM benchmarks |
| Rust `quick-xml` | **=0.42.0** | pull-Reader benchmarks |
| W3C XML Conformance Test Suite | `xmlts20130923` | 1,662 XML 1.0 5th-ed. + Namespaces 1.0 cases (`ENTITIES="none"`, UTF-8 only) |
| roxmltree's own `tests/files` | 0.21.2 | 92 upstream oracle documents |

Machine: Apple M5 Max (18 cores, Darwin arm64), pionc 0.1.0, cargo 1.100, node 24.22.
The machine was shared (load average 12-16). Benchmarks are interleaved `scripts/bench_compare.py`
runs (warmup 1, 5 rounds, stdout SHA-256 identical across implementations). Conclusions rely only on
gaps far larger than run-to-run spread.

## Reproduce

```sh
export PATH="$HOME/.pion/bin:$HOME/.cargo/bin:$PATH"
sh packages/xml/audit/run_audit.sh           # build, tests, differential, wasm32, scaling, bench (~1 min)
sh packages/xml/audit/run_audit.sh --quick   # without the head-to-head bench section (~15 s)
SECTIONS="build diff" sh packages/xml/audit/run_audit.sh
pionc test --json packages/xml/audit         # only the red-team tests (~1 s)
```

All builds, the W3C download, corpora and logs go to `$AUDIT_OUT` (default `/tmp/pion-xml-audit`);
`git status --porcelain --ignored` stays clean.

## What is in `packages/xml/audit/`

| path | what |
| --- | --- |
| `redteam_{dos,ns,dtd,wf,writer}_test.pion` | 44 tests: **26 `p0_/p1_/p2_` tests assert the correct behaviour and FAIL today**; 18 `control_` tests pass (attacks pion already resists) |
| `src/lib.pion` | test helpers (`dom_ok`, `dtd_ok`, `reader_ok`, ...) |
| `tools/pion_dump` / `tools/rust_ref/src/bin/rust_dump.rs` | canonical tree dump of the same case pack by pion (DOM / Reader) and roxmltree |
| `diff/gen_corpus.py` | 994 hand-written + generated adversarial cases (namespaces, normalisation, every C0/C1/non-char in every construct, bad UTF-8, char-ref overflow, name-char boundaries, DTD/entities), plus the roxmltree and W3C packs |
| `diff/run_diff.py` | runs the matrix below, writes every mismatch with its input to `logs/*.txt` |
| `tools/pion_perf` / `tools/rust_ref/src/bin/rust_perf.rs`, `perf/` | adversarial inputs, complexity probe, head-to-head benches |

Test result today: `44 audit tests: 18 pass, 26 fail (0 of the failures are controls)`; the
upstream `packages/xml` suite still passes 35/35.

## Summary

| id | sev | finding | evidence |
| --- | --- | --- | --- |
| P0-1 | **P0** | Text/CDATA merging is O(n²) in time **and retained memory**, default options: a 640 KB document takes 6.5-6.7 GiB RSS natively and crashes the wasm32 build | `p0_text_cdata_merge_retains_quadratic_memory`, scaling table |
| P1-1 | P1 | Internal-entity replacement text is never parsed as content: markup becomes literal text; unbalanced / ill-formed replacement text is accepted; a valid CDATA-in-entity document is rejected | 4 tests, 6 roxmltree + 5 W3C cases |
| P1-2 | P1 | Char refs in entity values are not expanded at declaration time (§4.5): `<` reaches attribute values, whitespace from char refs escapes §3.3.3 normalisation | 2 tests, W3C not-wf-sa-090, valid-sa-110, roxmltree entity_003 |
| P1-3 | P1 | Entity values are not validated against `Char`: U+0001 reaches the DOM | `p1_entity_value_illegal_char_rejected` |
| P1-4 | P1 | `Reader` does no Namespaces 1.0 processing: 13/18 namespace violations the DOM rejects stream through `Reader` (38 corpus documents) | 4 tests, matrix C/D |
| P1-5 | P1 | `Writer` emits duplicate attributes (`<a k="1" k="2"/>`) | `p1_writer_duplicate_attribute_rejected` |
| P1-6 | P1 | `Writer` leaves a dangling `<item ok="1"` in its buffer when it rejects a later attribute | `p1_writer_error_leaves_no_partial_output` |
| P2-1..12 | P2 | empty text node from empty entity; unreferenced external/unparsed/parameter entity *declarations* reject 34 valid W3C documents; DTD subset scanner accepts unknown/lowercase/conditional/space-less declarations (13 W3C not-wf); two-level escaping; 5th-ed. `version="1.x"`; Reader emits `StartElement` for an unterminated tag; Writer: namespace well-formedness, text CR round-trip, PI value round-trip, document structure, indent byte injection, pretty-print alters mixed content | 12 tests |
| PERF | P2 | adversarial head-to-head: 0.04x (P0-1), 0.12x Reader with 1,000 attrs, 0.19x 1,000 cycling prefixes, 0.31x 20k entities; 0.62x DOM through the public Node API (shipped bench measures internal indexed accessors, 0.88x); pion wins 93x on deep namespace scopes and 1.61x on a 16 MiB text node | bench tables |

## Differential matrix (2,748 documents)

`diff/run_diff.py`: redteam 994 + roxmltree 92 + W3C 1,662 cases. "same" = both reject, or both
accept with a byte-identical canonical tree (expanded names, attributes, text, comments, PIs).
roxmltree's quirks that are not pion bugs are normalised in `rust_dump` (it reports `xmlns=""` as
`Some("")` and surfaces internal-subset comments/PIs as document children).

| comparison | cases | same | pion-only accepts | other-only accepts | tree differs |
| --- | ---: | ---: | ---: | ---: | ---: |
| A pion DOM vs roxmltree (DTD off) | 2748 | 2698 | 1 | 40 | 9 |
| B pion DOM vs roxmltree (`allow_dtd`) | 2748 | 2541 | 32 | 138 | 37 |
| C pion DOM vs pion Reader (DTD off) | 2748 | 2710 | 0 | **38** (Reader) | 0 |
| D pion DOM vs pion Reader (`allow_dtd`) | 2748 | 2700 | 0 | **45** (Reader) | 3 |
| wasm32 vs native, all packs x {dom, dom_dtd, rd, rd_dtd} | 12 runs | 12 byte-identical | - | - | - |

W3C conformance (`allow_dtd = true`):

| | wf accepted | not-wf rejected | total |
| --- | ---: | ---: | ---: |
| pion | 723/762 | 655/900 | 1378/1662 (82.9%) |
| roxmltree 0.21.2 | 754/762 | 600/900 | 1354/1662 (81.5%) |

pion is wrong where roxmltree is right in **53** cases: 34 valid documents rejected with
`ExternalEntityNotAllowed` (P2-2), 13 not-wf DTDs accepted (P2-3), 4 not-wf entity replacement
texts accepted (P1-1/P1-2), valid-sa-114 (P1-1), x-rmt-008b (P2-5). roxmltree is wrong where pion is
right in **77** cases (reserved namespace prefixes, `xmlns:p=""`, PI targets `xml`/`XmL`/`a:b`,
surrogate and > U+10FFFF char refs, bad `standalone`/`version`/encoding names, EOL normalisation in
comments and PIs, char-ref CR in entities). Most of the remaining shared failures are DTD content
models that neither parser validates.

Areas the brief asked about where pion is **correct** (controls pass, no differential against it):
`xmlns:xml` rebinding, `xmlns:xmlns`, prefixes bound to either reserved URI, `xmlns:a=""`,
duplicate expanded attribute names (also via entity/char-ref URIs), the 1-entry prefix cache under
shadowing / sibling re-declaration / empty elements / prefix-of-prefix, `]]>` in text, `<` in
attribute values, char-ref vs literal whitespace in attributes, CR/CRLF in text, CDATA, comments,
PIs and attributes, `<?xml` after whitespace or comment, encoding names, `standalone`, multiple roots,
text outside the root, `--->`, PI targets, decimal/hex char-ref overflow (`&#99999999999999999999;`,
`2^32+65`, `2^64+65`: no wrap-around), `&#x110000;`, surrogates, U+0300/U+00B7 as NameChar but not
NameStartChar, overlong/surrogate/truncated UTF-8, billion laughs, quadratic blow-up, entity cycles,
XXE (`SYSTEM`/`PUBLIC` references), DTD off by default, 50,000-level nesting (DOM, Reader, Writer
round-trip) without recursion, and Writer refusal of names containing space/`<`/`>`/`"`/`=`/`/`,
digit-initial names, `]]>` in CDATA, `--`/trailing `-` in comments, `?>` and `xml` in PIs.

---

## P0-1 Text/CDATA merge: quadratic time and retained memory (DoS, no DTD needed)

`src/dom.pion:115` `append_or_merge_text_slow` merges a text chunk into the previous Text node by
`span_to_string(prev) + span_to_string(new)` and `strings.push(merged)` (lines 131-138). The previous
pool entry is never released, so a run of k chunks allocates and *retains* 1+2+...+k chunk copies.
Any element whose content alternates text and CDATA triggers it with `Document::parse` defaults
(`max_nodes` does not help: it is one node).

```
python3 -c 'print("<a>"+"xx<![CDATA[yy]]>"*40000+"</a>", end="")' > merge.xml   # 640 KB
```

| input | bytes | pion ms | pion peak RSS | roxmltree ms | roxmltree peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| `merge_5000.xml` | 80,007 | 33 | 145 MiB | 12 | 2.4 MiB |
| `merge_10000.xml` | 160,007 | 74 | 516 MiB | 7 | 2.7 MiB |
| `merge_20000.xml` | 320,007 | 202 | 1,814 MiB | 6 | 3.4 MiB |
| `merge_40000.xml` | 640,007 | 1,447 | **6,701 MiB** | 5 | 6.0 MiB |

RSS grows 3.5-3.7x per doubling (quadratic); an 1.3 MB document needs ~27 GiB. On wasm32
(`pionc run --release --target wasm32 tools/pion_perf -- dom merge_40000.xml 1`) the process dies with
`RangeError: WebAssembly.Memory.grow(): Unable to grow instance memory` — an uncatchable crash, not an
`XmlError`. bench_compare (`merge_20000`): pion 245.98 ms / 1,814 MiB vs roxmltree 9.80 ms / 3.42 MiB (**0.04x**).

Test: `p0_text_cdata_merge_retains_quadratic_memory` (4,000 chunks: the pool holds 64,007,998 bytes in
7,999 strings for a 64,007-byte input). Fix direction: accumulate the open text run in one
`StringBuilder` (or a list of spans materialised once when the node closes) and write one pool entry.

## P1-1 Entity replacement text is not parsed as content

`src/entities.pion:269` `unescape_span` splices an internal entity's value into the text/attribute
being decoded as *characters*. XML 1.0 §4.4.2 says a referenced internal parsed entity is
*included*: its replacement text is parsed as `content` and must itself be well-formed (§4.3.2).

| input (`allow_dtd`) | pion | roxmltree / spec |
| --- | --- | --- |
| `<!ENTITY p "<p a='1'>x</p>">` `<r>&p;</r>` | text `<p a='1'>x</p>` | element `p` with attribute and text |
| `<!ENTITY e "</foo><foo>">` `<d><foo>&e;</foo></d>` (W3C not-wf-sa-074) | accepted | error |
| `<!ENTITY p '</p>'>` / `'<p>'` (roxmltree entity_err_003) | accepted | error |
| `<!ENTITY e "<![CDATA[&foo;]]>">` (W3C **valid**-sa-114) | `UnknownEntity` | text `&foo;` |
| `<!ENTITY e "]]>">` `<a>&e;</a>` | accepted | error (§2.4) |
| `<!ENTITY e "<?xml encoding='UTF-8'?>">` (not-wf-sa-153) | accepted | error |

Consequence beyond conformance: a consumer that trusts the DOM to have separated markup from text
receives `<script>`-shaped strings as text, and documents that roxmltree rejects are accepted.
Tests: `p1_entity_markup_is_parsed_as_elements`, `p1_entity_unbalanced_markup_rejected`,
`p1_entity_with_cdata_section_is_valid`, `p1_entity_value_cdata_end_in_content_rejected`.

## P1-2 Char refs in entity values are not expanded at declaration time

§4.5: the replacement text of `<!ENTITY e "...">` is the literal with char refs (and PE refs)
already replaced; `parse_doctype` (`src/prolog.pion:413`) stores the raw literal, and the char refs are
only expanded when the entity is used, after the WFC checks that should have seen their result.

| input | pion | expected |
| --- | --- | --- |
| `<!ENTITY e "&#60;">` `<a k="&e;"/>` | accepted, `k="<"` | error, WFC "No < in Attribute Values" (not-wf-sa-090 shape) |
| `<!ENTITY e "&#13;&#10;">` `<doc a="x&e;y">` (W3C valid-sa-110) | `x\r\ny` | `x  y` |
| `<!ENTITY e "x&#9;y">` `<a k="&e;"/>` | `x\ty` | `x y` (roxmltree entity_003 likewise) |
| `<!ENTITY e "1 &#38;#60; 2">` `<a>&e;</a>` (spec App. D) | `1 &#60; 2` | `1 < 2` (roxmltree is wrong too: P2-4) |

Tests: `p1_entity_charref_lt_in_attribute_rejected`, `p1_entity_replacement_whitespace_normalised_in_attribute`.

## P1-3 Entity values are not validated

`scan_dtd_quoted` (`src/prolog.pion`) accepts any bytes; the entity frames in `unescape_span` never run
`is_xml_char`, so `<!DOCTYPE a [<!ENTITY e "\u{1}">]><a>&e;</a>` yields a Text node containing U+0001
(roxmltree: `NonXmlChar`). A Writer later refuses to serialise that DOM (`InvalidChar`), so
parse → write round-trips fail. Test: `p1_entity_value_illegal_char_rejected`.

## P1-4 `Reader` is not namespace-aware (DOM vs Reader inconsistency)

`src/reader.pion` never looks at `xmlns`; `RawAttribute`/`StartElement` carry only raw qualified names,
and the duplicate check (`reader.pion:379-384`) compares raw names. The package README advertises
"full XML Namespaces 1.0", but for the same bytes the DOM and the Reader disagree on 38 corpus
documents (45 with DTDs), every one "Reader accepts, DOM rejects": unbound prefixes (`<p:a/>`,
`<a p:k="1"/>`), `xmlns:xml="http://wrong"`, `xmlns:xmlns`, prefixes bound to the reserved URIs,
`xmlns:p=""`, `<xmlns:a/>`, duplicate expanded attribute names (`a:k`/`b:k` with one URI), W3C
rmt-ns10-009/010/011/013a-c ... (logs `C_dom_vs_reader.txt`, `D_dom_vs_reader_dtd.txt`).
quick-xml separates `Reader` and the namespace-resolving `NsReader`; pion has no `NsReader`
equivalent, so a streaming consumer cannot get NS-correct parsing at all.
Tests: `p1_reader_rejects_unbound_prefix`, `p1_reader_rejects_reserved_prefix_rebinding`,
`p1_reader_rejects_duplicate_expanded_attribute`, `p1_dom_reader_agree_on_namespace_violations`
(13/18 disagree).

## P1-5 Writer emits duplicate attributes

`write_start_element` / `write_empty_element` (`src/writer.pion:279`, `:318`) validate each name but not
uniqueness: `write_empty_element("a", [("k","1"),("k","2")])` returns `Ok` and writes `<a k="1" k="2"/>`,
which its own DOM rejects. Test: `p1_writer_duplicate_attribute_rejected`.

## P1-6 Writer leaves partial output on error

The same functions write `<name` and each attribute *before* validating the next one
(`writer.pion:297` / `:336` return after `sb` already holds `<item ok="1"`). After
`write_start_element("root")`, a rejected `write_empty_element("item", [("ok","1"),("bad name","x")])`
leaves `<root><item ok="1"` in the buffer, not on `tag_stack`; every following call produces corrupt
XML. Test: `p1_writer_error_leaves_no_partial_output`. Fix: validate all names/values first, or
truncate `sb` back to its length at entry on any error.

## P2 findings

| id | finding | test |
| --- | --- | --- |
| P2-1 | An entity with empty replacement text creates an empty Text node (`dom.pion:479` only skips *source* spans of length 0, not empty pool strings); roxmltree and pion's own Reader produce none (matrix D `tree_diff`, W3C valid-sa-023/086, rmt-e2e-15a) | `p2_empty_entity_creates_no_text_node` |
| P2-2 | Merely *declaring* an external, unparsed (`NDATA`) or parameter entity rejects the document (`prolog.pion:482-503`), although nothing is fetched until a reference. 34 valid W3C documents fail (valid-sa-082/083/091/094/100, o-p70..76pass1, ibm56v08, ...); roxmltree accepts them and fails only on reference. The README documents the policy, but it contradicts the "XML 1.0 compliant" claim; rejecting at reference time keeps XXE immunity (control `control_external_entity_reference_rejected` passes today and must keep passing) | `p2_unreferenced_external_entity_declaration_accepted` |
| P2-3 | The internal-subset scanner (`prolog.pion:527`) skips any `<!...>`: unknown keywords (`<!DUNNO`), lowercase/mixed-case keywords (`<!element`, `<!Attlist`), conditional sections, `<![CDATA[` in the DTD, missing whitespace (`<!ENTITY e"x">`, `<! ENTITY`, `PUBLIC"..."`): 9/9 probes and 13 W3C not-wf cases accepted | `p2_dtd_unknown_or_malformed_declarations_rejected` |
| P2-4 | Two-level escaping in entity values (spec App. D) is not re-parsed: `&#38;#60;` → `&#60;` instead of `<`. roxmltree has the same bug | `p2_entity_double_escaped_charref_reparsed` |
| P2-5 | `version="1.x"` other than 1.0 is rejected (`prolog.pion:104`); XML 1.0 *Fifth Edition* §2.8 VersionNum is `'1.' [0-9]+` and requires processing 1.x as 1.0 (W3C x-rmt-008b). roxmltree accepts | `p2_fifth_edition_version_1x_accepted` |
| P2-6 | `Reader` returns `StartElement` for `<a k="1"` at EOF (`reader.pion:462` sets `pos` without checking the tag was terminated) and errors only on the next call; the DOM rejects the document outright | `p2_reader_truncated_start_tag_errors_immediately` |
| P2-7 | Writer does not check namespace well-formedness: `xmlns:xml="http://wrong"`, `xmlns:xmlns`, `xmlns:p=""`, duplicate expanded names, unbound element prefix — all written, all rejected by pion's own DOM | `p2_writer_output_is_namespace_wellformed` |
| P2-8 | `write_text("x\ry")` writes a raw CR; re-parsing normalises it to LF (attributes do escape `&#xD;`). quick-xml's `escape` does not escape CR either, but pion's README lists CR escaping only for attributes, so text silently changes on round-trip | `p2_writer_text_cr_roundtrip` |
| P2-9 | `write_pi("t", Some("  v"))` re-reads as `"v"`; `Some("")` re-reads as `None` | `p2_writer_pi_value_roundtrip` |
| P2-10 | Writer accepts a second root element, text before the root, and an XML declaration after content; `into_string` gives no signal for unclosed tags (only `depth`) | `p2_writer_rejects_document_structure_violations` |
| P2-11 | `new_with_indent` copies any byte as indentation: `'<'` yields `<a>\n<<b/>\n</a>` (a non-ASCII byte would yield invalid UTF-8) | `p2_writer_indent_char_must_be_whitespace` |
| P2-12 | Pretty printing (`write_document` with indent) inserts whitespace into mixed content: `<a>x<b/>y</a>` → first text `"x\n  "` | `p2_writer_pretty_preserves_mixed_content` |

Behavioural differences that are **not** pion bugs (documented for API users): empty
`<![CDATA[]]>` yields no Text node (roxmltree yields an empty one); `<xml:a/>` is accepted (the `xml`
prefix is pre-bound; roxmltree rejects); comments and PIs are EOL-normalised (roxmltree keeps CR);
`&#13;` from an entity stays CR in text (W3C valid-sa-068; roxmltree turns it into LF).

## Performance and benchmark fairness

`perf/run_bench.sh` (bench_compare, warmup 1, 5 rounds, SHA-256 verified). Baseline = Rust.
A second full `run_audit.sh` on a fresh `$AUDIT_OUT` reproduced every ratio within the load spread
(e.g. public API 0.64x, cycling prefixes 0.18x, Reader attributes 0.13x, 20k entities 0.30x,
deep scopes 77.7x, P0-1 0.04x / 1,814 MiB).

| workload | pion median | pion RSS | Rust median | Rust RSS | pion vs Rust |
| --- | ---: | ---: | ---: | ---: | ---: |
| mixed corpus x10, DOM, indexed accessors (what `bench/` measures) | 25.72 ms | 6.92 MiB | 22.72 ms (roxmltree) | 5.00 MiB | 0.88x |
| mixed corpus x10, DOM, **public Node API** (`descendants`/`attributes`/`text`) | 36.16 ms | 7.30 MiB | 22.49 ms (roxmltree) | 5.00 MiB | **0.62x** |
| mixed corpus x10, Reader (quick-xml with `check_end_names`) | 26.36 ms | 3.11 MiB | 18.04 ms | 2.59 MiB | 0.68x |
| P0-1 Text/CDATA x20,000 (DOM) | 245.98 ms | 1,814 MiB | 9.80 ms | 3.42 MiB | **0.04x** |
| 1,000 prefixes, 200k elements cycling prefixes (DOM) | 798.54 ms | 36.80 MiB | 152.02 ms | 17.47 MiB | **0.19x** |
| 2,000-deep scopes, leaf uses outermost prefix (DOM) | 15.88 ms | 3.17 MiB | 1,482.63 ms | 8.56 MiB | **93.39x (pion wins)** |
| 200 elements x 1,000 attributes (DOM) | 180.40 ms | 21.16 MiB | 146.19 ms | 17.86 MiB | 0.81x |
| 200 elements x 1,000 attributes (**Reader**) | 155.03 ms | 5.86 MiB | 19.19 ms | 4.23 MiB | **0.12x** |
| 20,000 internal entities + 20,000 refs (DOM, `allow_dtd`) | 1,253.09 ms | 5.41 MiB | 394.53 ms | 4.19 MiB | **0.31x** |
| 16 MiB text dense in refs (DOM) | 62.55 ms | 35.95 MiB | 51.18 ms | 38.02 MiB | 0.82x |
| 16 MiB text dense in refs (Reader) | 62.93 ms | 35.84 MiB | 43.67 ms | 18.56 MiB | 0.69x |
| 16 MiB single text node (DOM) | 15.22 ms | 33.77 MiB | 24.59 ms | 17.95 MiB | 1.61x (pion wins) |
| 100k siblings (DOM) | 12.13 ms | 19.08 MiB | 9.34 ms | 9.16 MiB | 0.77x |
| 50,000-deep nesting (DOM, limits raised) | 11.49 ms | 13.61 MiB | 9.07 ms | 6.75 MiB | 0.79x |

Root causes of the large gaps:

- **1,000 cycling prefixes (0.19x)**: the 1-entry cache (`dom.pion:1200`) misses on every element and
  `resolve_ns_prefix` (`dom.pion:31`) scans the whole active-namespace stack with byte compares.
- **Reader with wide attribute lists (0.12x)**: `reader.pion:379-384` allocates each attribute name
  (`src.slice`) and compares it as a `String` against every previous one; the DOM path (0.81x) uses
  length/first-byte prefilters on spans.
- **20k entities (0.31x)**: `parse_doctype` checks "first definition wins" against all earlier
  entities (`prolog.pion:512`, O(n²)), and `lookup_custom_entity` (`entities.pion:136`) is a linear
  scan per reference; a hash map makes both O(1).
- **RSS** is ~2x roxmltree / quick-xml on node-heavy inputs (14-int `NodeData` of 64-bit `Int`s, as
  the README already notes) and on the 16 MiB inputs (input string + an unescaped copy).

Fairness review of `packages/xml/bench/`:

1. Bench 1 walks the pion DOM through `Document::node_kind_at` / `attrs_range_at` /
   `attr_value_len_raw` / `text_len_at` (zero-allocation internal indices), while roxmltree is
   walked through its normal public API. Through pion's public API (`descendants()`,
   `attributes()`, `text()`, which allocate `Array`s and `String`s) the same work is **0.62x**, not
   0.88x. The README should report the public-API number or say which API was measured.
2. The only corpus is one 645 KB synthetic ASCII document with few attributes and namespaces; none of
   the adversarial shapes above (alternating CDATA, many prefixes, wide attribute lists, DTD entities)
   are exercised, so the README's "within ~3-12% of roxmltree" does not carry over to them.
3. The README text "Bench 2 ... 0.77x" reproduces here as 0.68x against quick-xml with
   `check_end_names = true` (pion always checks end names); both sides unescape attributes and
   normalise text, so this comparison is otherwise fair.
4. `Limits::default().max_depth = 256` is a pion-only cap; benches and comparisons that go deeper must
   raise it (the audit tools do), roxmltree has no such limit.
5. wasm32: all four parse modes over all 2,748 documents are byte-identical to native; the only
   wasm-specific failure is the P0-1 crash at 640 KB.

## Log index (after `run_audit.sh`)

`$AUDIT_OUT/logs/`: `tests.json` + `tests.stderr` (failure messages), `A_dom.txt`, `B_dom_dtd.txt`,
`C_dom_vs_reader.txt`, `D_dom_vs_reader_dtd.txt`, `W_w3c.txt` (every mismatch with escaped input and
both outputs), `summary.txt`, `scaling.md`; `$AUDIT_OUT/bench/*.md|json`.
