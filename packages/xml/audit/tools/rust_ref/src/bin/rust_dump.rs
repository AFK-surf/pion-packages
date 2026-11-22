//! Rust oracle side of the `packages/xml` red-team differential harness.
//!
//! usage: rust_dump MODE PACK   (same PACK format / output format as tools/pion_dump)
//!   dom      roxmltree 0.21.2 Document::parse
//!   dom_dtd  roxmltree with allow_dtd = true
use std::fmt::Write as _;

fn esc(out: &mut String, s: &[u8]) {
    let mut buf: Vec<u8> = Vec::with_capacity(s.len());
    for &b in s {
        match b {
            b'\\' => buf.extend_from_slice(b"\\\\"),
            b'\n' => buf.extend_from_slice(b"\\n"),
            b'\r' => buf.extend_from_slice(b"\\r"),
            b'\t' => buf.extend_from_slice(b"\\t"),
            b if b < 0x20 || b == 0x7f => buf.extend_from_slice(format!("\\x{:02x}", b).as_bytes()),
            b => buf.push(b),
        }
    }
    out.push_str(&String::from_utf8_lossy(&buf));
}

fn depth(n: roxmltree::Node) -> usize {
    n.ancestors().count() - 1
}

fn ns_tag(out: &mut String, ns: Option<&str>, local: &str) {
    // roxmltree reports `xmlns=""` scopes as Some(""); Namespaces 1.0 says "no namespace".
    if let Some(u) = ns.filter(|u| !u.is_empty()) {
        out.push('{');
        esc(out, u.as_bytes());
        out.push('}');
    }
    esc(out, local.as_bytes());
}

/// roxmltree surfaces comments/PIs of the DTD internal subset as document children; the XML
/// Infoset (and pion) do not. Drop prolog comments/PIs that sit inside `<!DOCTYPE ...[...]>`.
fn in_internal_subset(doc: &roxmltree::Document, n: roxmltree::Node) -> bool {
    if n.parent().map(|p| p.is_root()) != Some(true) {
        return false;
    }
    let text = doc.input_text();
    let Some(dt) = text.find("<!DOCTYPE") else { return false };
    let r = n.range();
    if r.start < dt {
        return false;
    }
    let root_start = doc.root_element().range().start;
    if r.start > root_start {
        return false;
    }
    // Inside the subset iff a `]` ... `>` closing the DOCTYPE follows before the root element.
    let tail = &text[r.end..root_start];
    let mut seen_bracket = false;
    for c in tail.chars() {
        if c == ']' {
            seen_bracket = true;
        } else if c == '>' && seen_bracket {
            return true;
        } else if !c.is_whitespace() {
            seen_bracket = false;
        }
    }
    false
}

fn dump_rox(out: &mut String, doc: &roxmltree::Document) {
    for n in doc.root().descendants().skip(1) {
        if (n.is_comment() || n.is_pi()) && in_internal_subset(doc, n) {
            continue;
        }
        let d = depth(n);
        match n.node_type() {
            roxmltree::NodeType::Element => {
                let _ = write!(out, "E{} ", d);
                let tn = n.tag_name();
                ns_tag(out, tn.namespace(), tn.name());
                out.push('\n');
                for a in n.attributes() {
                    let _ = write!(out, "A{} ", d);
                    ns_tag(out, a.namespace(), a.name());
                    out.push('=');
                    esc(out, a.value().as_bytes());
                    out.push('\n');
                }
            }
            roxmltree::NodeType::Text => {
                let _ = write!(out, "T{} ", d);
                esc(out, n.text().unwrap_or("").as_bytes());
                out.push('\n');
            }
            roxmltree::NodeType::Comment => {
                let _ = write!(out, "C{} ", d);
                esc(out, n.text().unwrap_or("").as_bytes());
                out.push('\n');
            }
            roxmltree::NodeType::PI => {
                let pi = n.pi().unwrap();
                let _ = write!(out, "P{} ", d);
                esc(out, pi.target.as_bytes());
                if let Some(v) = pi.value {
                    out.push_str(" =");
                    esc(out, v.as_bytes());
                }
                out.push('\n');
            }
            roxmltree::NodeType::Root => {}
        }
    }
}

fn run_case(mode: &str, body: &[u8]) -> String {
    let mut out = String::new();
    let text = match std::str::from_utf8(body) {
        Ok(t) => t,
        Err(_) => return "ERR Utf8\n".to_string(),
    };
    let opt = roxmltree::ParsingOptions {
        allow_dtd: mode.ends_with("_dtd"),
        ..roxmltree::ParsingOptions::default()
    };
    match roxmltree::Document::parse_with_options(text, opt) {
        Ok(doc) => {
            dump_rox(&mut out, &doc);
            format!("OK\n{out}")
        }
        Err(e) => format!("ERR {}\n", err_kind(&e)),
    }
}

fn err_kind(e: &roxmltree::Error) -> String {
    let s = format!("{e:?}");
    s.split(|c: char| c == '(' || c == ' ' || c == '{').next().unwrap_or("").to_string()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rust_dump MODE PACK");
        std::process::exit(2);
    }
    let mode = args[1].as_str();
    let pack = std::fs::read(&args[2]).expect("read pack");
    let mut pos = 0;
    let mut out: Vec<u8> = Vec::new();
    while pos < pack.len() {
        let eol = pos + pack[pos..].iter().position(|&b| b == b'\n').unwrap();
        let hdr = std::str::from_utf8(&pack[pos..eol]).unwrap();
        let sp = hdr.rfind(' ').unwrap();
        let name = &hdr[7..sp];
        let blen: usize = hdr[sp + 1..].parse().unwrap();
        let body = &pack[eol + 1..eol + 1 + blen];
        pos = eol + 1 + blen + 1;
        out.extend_from_slice(format!("=== {name}\n").as_bytes());
        out.extend_from_slice(run_case(mode, body).as_bytes());
    }
    use std::io::Write;
    std::io::stdout().write_all(&out).unwrap();
}
