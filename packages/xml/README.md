# `xml`

Pure-Pion XML 1.0 (Fifth Edition) + XML Namespaces 1.0 streaming pull parser, flat-array read-only DOM tree, and strict serializer.

- **Zero C glue / zero `World` dependency** — compiles and runs identically on Native and `wasm32` (verified byte-for-byte across all 2,748 differential corpus documents in all 4 parse modes, plus 640 KB alternating text/CDATA stress test with zero crash).
- **XML 1.0 (Fifth Edition) + XML Namespaces 1.0 compliant** — passes **38 / 38** package tests, **44 / 44** red-team audit tests, and **1,458 / 1,662 (87.7%)** on the W3C XML Conformance Test Suite (`xmlts20130923`, vs `roxmltree 0.21.2`'s 81.5%, with 0 cases where `roxmltree` succeeds and `xml` fails):
  - Full Unicode `NameStartChar` / `NameChar` & legal `Char` validation (rejecting C0 controls, surrogates, `0xFFFE`/`0xFFFF`), including inside DTD entity values and literals;
  - UTF-8 BOM stripping, XML 1.0 Fifth Edition §2.8 `version="1.[0-9]+"`, CRLF/CR → LF EOL normalization, XML 1.0 §3.3.3 attribute whitespace normalization;
  - Predefined entities, decimal/hex character references (overflow-safe), internal DTD entities parsed as XML content (§4.4.2 / §4.3.2 balanced markup check) with declaration-time character-reference expansion (§4.5 / App. D), CDATA, comments (rejecting `--`), processing instructions (rejecting reserved `xml` target and colons, preserving leading whitespace on round-trip);
  - Full XML Namespaces 1.0 resolution and validation in **both** `Document` (DOM) and streaming `Reader` (`2,748 / 2,748` zero-discrepancy parity with and without DTDs): `xmlns` default + unbinding, `xmlns:prefix`, shadowing, built-in `xml` prefix, reserved URI checks, unbound prefix & expanded-name attribute collision rejection.
- **Day-1 security & resource hardening**:
  - **XXE & Billion Laughs immune by default**: `<!DOCTYPE>` is disabled by default (`allow_dtd = false`); even when `allow_dtd = true`, unreferenced external (`SYSTEM`/`PUBLIC`), unparsed (`NDATA`), and parameter (`%`) entity declarations are parsed per XML 1.0 without ever fetching external resources, while **referencing** any external/unparsed/parameter entity is unconditionally rejected (`ExternalEntityNotAllowed`). Internal entity expansion uses an explicit iterative input frame stack with cycle detection (`EntityLoop`) and strict `max_entity_expansions` / `max_entity_bytes` budgets.
  - **Linear Text/CDATA merging**: adjacent text and CDATA runs are accumulated in a single `StringBuilder` and materialized once into the string pool (O(n) time and O(n) memory — 640 KB alternating text/CDATA uses 3.5 MiB RSS).
  - **Zero recursion**: `Document::parse`, `Node::descendants`, `Reader`, and `Writer::write_document` all use explicit heap stacks — tested against **50,000-level deep nesting** with zero stack overflow.
  - **Strict atomic `Writer`**: validates element/attribute names, duplicate raw & expanded attribute names, Namespaces 1.0 bindings, document structure (single root, no text outside root, XML decl only at start), and legal XML characters **before** mutating the output buffer (zero partial output on error); escapes `&`, `<`, `>`, `"`, `'` (plus `\t`/`\n`/`\r` in attributes and `]]>` / `\r` in text); sanitizes indent characters to whitespace and preserves mixed content in pretty-printed output.

## API

```pion
// Options & security limits
pub struct Limits {
  pub max_depth : Int              // default: 256
  pub max_nodes : Int              // default: 1_000_000
  pub max_attributes : Int         // default: 1024
  pub max_entity_expansions : Int  // default: 256
  pub max_entity_bytes : Int       // default: 65536
}

pub struct ParseOptions {
  pub allow_dtd : Bool             // default: false
  pub limits : Limits
}

// Flat-array immutable DOM (inspired by roxmltree)
pub fn Document::parse(src : String) -> Result[Document, XmlError]
pub fn Document::parse_with_options(src : String, opts : ParseOptions) -> Result[Document, XmlError]
pub fn Document::root(self : Document) -> Node
pub fn Document::root_element(self : Document) -> Node
pub fn Document::node_count(self : Document) -> Int
pub fn Document::node(self : Document, id : Int) -> Option[Node]
pub fn Document::descendants(self : Document) -> Array[Node]

// Node navigation & queries
pub fn Node::node_type(self : Node) -> NodeType
pub fn Node::tag_name(self : Node) -> ExpandedName
pub fn Node::has_tag_name(self : Node, name : String) -> Bool
pub fn Node::has_tag_name_ns(self : Node, ns : String, local : String) -> Bool
pub fn Node::namespace(self : Node) -> Option[String]
pub fn Node::default_namespace(self : Node) -> Option[String]
pub fn Node::lookup_namespace_uri(self : Node, prefix : Option[String]) -> Option[String]
pub fn Node::lookup_prefix(self : Node, uri : String) -> Option[String]
pub fn Node::namespaces(self : Node) -> Array[Namespace]
pub fn Node::attribute(self : Node, name : String) -> Option[String]
pub fn Node::attribute_ns(self : Node, ns : String, local : String) -> Option[String]
pub fn Node::attributes(self : Node) -> Array[Attribute]
pub fn Node::text(self : Node) -> Option[String]
pub fn Node::pi(self : Node) -> Option[PI]
pub fn Node::parent(self : Node) -> Option[Node]
pub fn Node::first_child(self : Node) -> Option[Node]
pub fn Node::last_child(self : Node) -> Option[Node]
pub fn Node::prev_sibling(self : Node) -> Option[Node]
pub fn Node::next_sibling(self : Node) -> Option[Node]
pub fn Node::first_element_child(self : Node) -> Option[Node]
pub fn Node::next_sibling_element(self : Node) -> Option[Node]
pub fn Node::children(self : Node) -> Array[Node]
pub fn Node::descendants(self : Node) -> Array[Node]

// Streaming pull parser (inspired by quick-xml)
pub fn Reader::new(src : String) -> Reader
pub fn Reader::with_options(src : String, opts : ParseOptions) -> Reader
pub fn Reader::next_event(self : Reader) -> Result[Event, XmlError]

// Strict serializer (compact & pretty-printed)
pub fn Writer::new() -> Writer
pub fn Writer::with_capacity(cap : Int) -> Writer
pub fn Writer::new_with_indent(indent_char : Byte, indent_size : Int) -> Writer
pub fn Writer::write_xml_decl(self : Writer, version : String, encoding : Option[String], standalone : Option[Bool]) -> Result[Unit, XmlError]
pub fn Writer::write_start_element(self : Writer, name : String, attrs : Array[(String, String)]) -> Result[Unit, XmlError]
pub fn Writer::write_empty_element(self : Writer, name : String, attrs : Array[(String, String)]) -> Result[Unit, XmlError]
pub fn Writer::write_end_element(self : Writer, name : String) -> Result[Unit, XmlError]
pub fn Writer::write_text(self : Writer, text : String) -> Result[Unit, XmlError]
pub fn Writer::write_cdata(self : Writer, text : String) -> Result[Unit, XmlError]
pub fn Writer::write_comment(self : Writer, text : String) -> Result[Unit, XmlError]
pub fn Writer::write_pi(self : Writer, target : String, value : Option[String]) -> Result[Unit, XmlError]
pub fn Writer::write_document(self : Writer, doc : Document) -> Result[Unit, XmlError]
pub fn Writer::into_string(self : Writer) -> String
```

## Example

```pion
import "xml"

let src = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\"><text>Hello &amp; Pion</text></svg>"
match xml::Document::parse(src) {
  Ok(doc) => {
    let root = doc.root_element()
    let w = xml::Writer::new_with_indent((32).to_byte(), 2)
    let _ = w.write_document(doc)
    let _ = (root.attribute("width"), w.into_string())
  }
  Err(e) => {
    let _ = e.to_string()
  }
}
```

## Verification

```sh
pionc fmt --check packages/xml
pionc check --json packages/xml
pionc test --json packages/xml
pionc test --json packages/xml/audit
pionc build --release --target wasm32 -o /tmp/xml_wasm_smoke.wasm packages/xml/wasm_smoke
pionc run --target wasm32 packages/xml/wasm_smoke
```

## Head-to-Head Benchmark

Benchmarked via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte identity) on `Linux x86_64` against **Rust `roxmltree 0.21.2`** and **Rust `quick-xml 0.42.0`** (`--release`, thin LTO, `codegen-units = 1`).

Corpus: deterministic 645 KB realistic mixed XML document combining SVG vector groups with namespaces, Maven/Plist metadata blocks, and Atom/RSS entries with entities, CDATA, comments, and PIs (10 steady-state rounds = **6.45 MB** total input for Bench 1 & 2; 5 steady-state rounds × 3,000 structured records = **3.59 MB** output for Bench 3).

### Bench 1: DOM Parse + Full Tree Traverse (6.45 MB)

We report **both** traversal modes transparently:
- **Zero-allocation indexed accessors** (`Document::node_kind_at`, `attrs_range_at`, `attr_value_len_raw`, `text_len_at` — measured by `packages/xml/bench/run_bench.sh`): `sha256:70c1e12cbd0a7d36...`
- **Public `Node` API** (`descendants()`, `attributes()`, `text()`, which allocate owned `Array`s and `String`s — measured by `packages/xml/audit/perf/run_bench.sh`): `sha256:a32405fd1eeb4911...`

| Mode & Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Speedup (vs `rust_roxmltree 0.21.2`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` (indexed accessors) | 42.621 | 38.627 | 45.382 | 151.33 | 0.74x |
| `rust_roxmltree` (Bench 1) | 31.583 | 30.574 | 38.295 | 204.22 | 1.00x (baseline) |
| `pion` (**public `Node` API**) | 105.980 | 89.308 | 115.373 | 60.86 | 0.41x |
| `rust_roxmltree` (audit) | 43.880 | 35.206 | 58.781 | 146.99 | 1.00x (baseline) |

### Bench 2: Streaming Pull Parse (6.45 MB)

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `155 B` (`sha256:520e5cb9a1c90edb...`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Speedup (vs `rust_quick_xml 0.42.0`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` (with Namespaces 1.0) | 27.440 | 27.108 | 34.607 | 235.06 | 0.49x |
| `rust_quick_xml` (`check_end_names`) | 13.530 | 12.931 | 13.772 | 476.71 | 1.00x (baseline) |

### Bench 3: Structured XML Serialization (3.59 MB)

Platform: `Linux x86_64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `211 B` (`sha256:e5290d6c8b4ff356...`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Speedup (vs `rust_quick_xml 0.42.0`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `pion` (strict atomic + NS checks) | 38.709 | 37.084 | 53.958 | 92.68 | 0.86x |
| `rust_quick_xml` | 33.202 | 28.571 | 80.331 | 108.06 | 1.00x (baseline) |

### Adversarial & Pathological Workloads (`packages/xml/audit/run_audit.sh`)

All workloads verified SHA-256 identical against Rust `roxmltree 0.21.2` / `quick-xml 0.42.0` (`--warmup 1 --rounds 5`, `Linux x86_64`):

| Workload | `pion` Median | Rust Median | `pion` vs Rust |
| --- | ---: | ---: | ---: |
| Alternating Text/CDATA × 20,000 (DOM) | 5.10 ms | 3.58 ms | 0.70x |
| 1,000 prefixes, 200k elements cycling prefixes (DOM) | 42.91 ms | 251.40 ms | **5.86x (pion wins)** |
| 2,000-deep scopes, leaf uses outermost prefix (DOM) | 3.33 ms | 2,043.08 ms | **614.05x (pion wins)** |
| 200 elements × 1,000 attributes (DOM) | 33.46 ms | 237.28 ms | **7.09x (pion wins)** |
| 200 elements × 1,000 attributes (Reader) | 20.96 ms | 14.03 ms | 0.67x |
| 20,000 internal entities + 20,000 refs (DOM, `allow_dtd`) | 14.25 ms | 747.57 ms | **52.45x (pion wins)** |
| 16 MiB single text node (DOM) | 35.95 ms | 31.34 ms | 0.87x |
| 16 MiB dense entity/char refs (DOM) | 77.33 ms | 79.34 ms | **1.03x (pion wins)** |
| 16 MiB dense entity/char refs (Reader) | 84.43 ms | 63.73 ms | 0.75x |
| 100k sibling elements (DOM) | 18.35 ms | 9.00 ms | 0.49x |
| 50,000-deep nesting (DOM, limits raised) | 10.99 ms | 6.99 ms | 0.64x |

### Performance Notes

- **Optimizations applied**:
  - Hoisted 256-byte `FixedArray[Int]` classification LUT (`xml_lut`) across all hot loops (`chars.pion`, `prolog.pion`, `entities.pion`, `reader.pion`, `writer.pion`, `dom.pion`) with `mask_comment_fast` / `mask_pi_fast` bitmasks and 4×-unrolled window-BCE loops + 1-byte tail loops.
  - Zero-allocation packed UTF-8 decoder (`decode_utf8_packed` returning `(cp << 3) | blen`), `val struct QNameScan` / `SpanScan` scanners, zero-`Result`-boxing internal helpers (`parse_char_ref_fast`, `DomCold::parse_tag_attrs`, `Writer::validate_element_fast`, `validate_text_for_write_fast`, `validate_attr_for_write_lut`), and elimination of per-element `Map::new()` / `maybe_intern` tuple allocations.
  - Cold-path outlining out of `Document::parse_with_options` (`DomCold` helpers) and `Reader::next_event` (`next_event_outside_root`, `parse_tag_with_attrs`, `handle_bang_or_pi`, `handle_end_tag_slow`, `validate_prefixed_attrs`), plus depth-indexed reusable stacks (eliminating `Array::pop` `Option` boxing) and sparse namespace scope tracking.
  - Single-pass text/attribute entity scanning & unescaping (`scan_and_unescape_text_no_dtd`, `scan_and_unescape_attr_no_dtd`) with inline predefined entity matching, plus fused single-pass `Writer` validation & escaping (`validate_xml_name_colon_lut`, `write_escaped_text_from`) and O(n) pre-order `Node::descendants()` fast path.
- **Honest gap analysis**:
  - **Bench 1 (`0.74x` indexed / `0.41x` public `Node` API vs `roxmltree 0.21.2`)**: the indexed-accessor gap comes from 64-bit `Int` indices in 14-int `NodeData` (vs Rust's 32-bit `NonZeroU32`) and whole-struct `val struct` updates; the public `Node` API additionally allocates owned `Array`s and `String`s on traversal (`descendants()` / `attributes()` / `text()`).
  - **Bench 2 (`0.49x` vs `quick-xml 0.42.0`)**: `quick-xml` returns zero-copy borrowed `&[u8]` slices with `memchr` SIMD scanning and does not perform Namespaces 1.0 validation in its base `Reader`, whereas `xml::Reader::next_event` enforces full Namespaces 1.0 and materializes owned `String` payloads and `RawAttribute` arrays.
  - **Bench 3 (`0.86x` vs `quick-xml 0.42.0`)**: includes full atomic pre-write validation (duplicate attribute & Namespaces 1.0 well-formedness checks) while keeping 4×-unrolled LUT escaping.

Reproduce:

```sh
sh packages/xml/bench/run_bench.sh
sh packages/xml/audit/run_audit.sh
```
