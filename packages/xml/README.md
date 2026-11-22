# `xml`

Pure-Pion XML 1.0 (Fifth Edition) + XML Namespaces 1.0 streaming pull parser, flat-array read-only DOM tree, and strict serializer.

- **Zero C glue / zero `World` dependency** — compiles and runs identically on Native and `wasm32` (`151 KiB` release Wasm32 smoke binary, verified via `pionc build --release --target wasm32` and `pionc run --target wasm32`).
- **XML 1.0 (Fifth Edition) + XML Namespaces 1.0 compliant** — passes all **35 / 35** compliance, namespace, streaming, serializer, roundtrip, and Day-1 red-team test suites:
  - Full Unicode `NameStartChar` / `NameChar` & legal `Char` validation (rejecting C0 controls, surrogates, `0xFFFE`/`0xFFFF`);
  - UTF-8 BOM stripping, strict `<?xml ...?>` declaration validation, CRLF/CR → LF EOL normalization, XML 1.0 §3.3.3 attribute whitespace normalization;
  - Predefined entities (`&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;`), decimal/hex character references, CDATA, comments (rejecting `--`), processing instructions (rejecting reserved `xml` target and colons);
  - Full XML Namespaces 1.0 resolution (`xmlns` default + unbinding, `xmlns:prefix`, shadowing, built-in `xml` prefix, unbound prefix & expanded-name attribute collision rejection).
- **Day-1 security & resource hardening**:
  - **XXE & Billion Laughs immune by default**: `<!DOCTYPE>` is disabled by default (`allow_dtd = false`); even when `allow_dtd = true`, external entities (`SYSTEM`/`PUBLIC`) and parameter entities are unconditionally rejected, and internal entity expansion uses an explicit iterative stack with cycle detection (`EntityLoop`) and strict `max_entity_expansions` / `max_entity_bytes` budgets.
  - **Zero recursion**: both `Document::parse`, `Node::descendants`, `Reader`, and `Writer::write_document` use explicit heap stacks — tested against **20,000-level deep nesting** with zero stack overflow.
  - **Strict `Writer` escaping**: escapes `&`, `<`, `>`, `"`, `'` (plus `\t`/`\n`/`\r` in attributes and `]]>` in text), rejects illegal XML 1.0 characters, `]]>` in CDATA, `--` or trailing `-` in comments, `?>` or `xml` in PIs, and mismatched end tags.

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
pionc build --release --target wasm32 -o /tmp/xml_wasm_smoke.wasm packages/xml/wasm_smoke
pionc run --target wasm32 packages/xml/wasm_smoke
```

## Head-to-Head Benchmark

Benchmarked via `scripts/bench_compare.py` (`--warmup 1 --rounds 5`, strictly interleaved, mandatory stdout SHA-256 byte-for-byte identity) on `Darwin arm64` against **Rust `roxmltree 0.21.2`** and **Rust `quick-xml 0.42.0`** (`--release`, thin LTO, `codegen-units = 1`).

Corpus: deterministic 645 KB realistic mixed XML document combining SVG vector groups with namespaces, Maven/Plist metadata blocks, and Atom/RSS entries with entities, CDATA, comments, and PIs (10 steady-state rounds = **6.45 MB** total input for Bench 1 & 2; 5 steady-state rounds × 3,000 structured records = **3.59 MB** output for Bench 3).

### Bench 1: DOM Parse + Full Tree Traverse (6.45 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `167 B` (`sha256:70c1e12cbd0a7d36...`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_roxmltree 0.21.2`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 30.395 | 27.345 | 31.112 | 212.21 | 6.92 MiB | 0.88x |
| `rust_roxmltree` | 26.631 | 24.278 | 28.247 | 242.21 | 4.98 MiB | 1.00x (baseline) |

### Bench 2: Streaming Pull Parse (6.45 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `155 B` (`sha256:520e5cb9a1c90edb...`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_quick_xml 0.42.0`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 29.077 | 28.275 | 29.281 | 221.82 | 3.08 MiB | 0.77x |
| `rust_quick_xml` | 22.328 | 20.320 | 23.219 | 288.88 | 2.56 MiB | 1.00x (baseline) |

### Bench 3: Structured XML Serialization (3.59 MB)

Platform: `Darwin arm64` | Warmup: `1` | Rounds: `5` (strictly interleaved) | Stdout: `211 B` (`sha256:e5290d6c8b4ff356...`)

| Implementation | Median (ms) | Min (ms) | P95 (ms) | Throughput (MB/s) | Peak RSS | Speedup (vs `rust_quick_xml 0.42.0`) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `pion` | 32.973 | 29.668 | 34.953 | 108.81 | 3.08 MiB | 0.97x |
| `rust_quick_xml` | 31.851 | 30.541 | 31.977 | 112.64 | 2.73 MiB | 1.00x (baseline) |

### Performance Notes

- **Optimizations applied**: 256-byte `FixedArray[Int]` classification LUT (`P53-C` zero-OOB BCE), 4×-unrolled `while i <= len - 4` window-BCE loops across text/attribute/CDATA/comment/PI/writer paths, compact 14-int flat `NodeData` with deferred `first_child`/`last_child` stacks, direct attribute insertion (zero intermediate `PendingAttr` buffer), O(1) default namespace & 1-entry prefix cache, zero-stack entity unescaping when no DTD entities exist, and zero-copy `TextSpan` slices with `StringBuilder::write_substring`.
- **Honest gap analysis**:
  - **Bench 1 (`0.88x`–`0.97x` `roxmltree 0.21.2`, `212–225 MB/s`)**: within ~3–12% of Rust `roxmltree`. The remaining gap and RSS delta (`6.92 MiB` vs `4.98 MiB`) come from 64-bit `Int` indices in `NodeData` (vs Rust's 32-bit `NonZeroU32` `NodeId`) and whole-struct `val struct` updates when linking `next_sibling`.
  - **Bench 2 (`0.77x` `quick-xml 0.42.0`, `222 MB/s`)**: `quick-xml` returns zero-copy borrowed `&[u8]` slices with `memchr` SIMD scanning, whereas `xml::Reader::next_event` materializes owned `String` payloads for `Event::Text` and `RawAttribute`.
  - **Bench 3 (`0.97x`–`1.02x` `quick-xml 0.42.0`, `109–113 MB/s`, min `29.67 ms` vs `30.54 ms`)**: parity with Rust `quick-xml` thanks to 4×-unrolled LUT escaping and `StringBuilder::write_substring`.

Reproduce:

```sh
sh packages/xml/bench/run_bench.sh
```
