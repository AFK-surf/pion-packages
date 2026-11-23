//! sxd-xpath 0.4.2 side of the RT-xpath differential harness: same PACK input and output
//! format as `tools/pion_runner` (see its header). Escaping/truncation are byte-identical.
use std::fs;
use sxd_document::parser;
use sxd_xpath::nodeset::Node;
use sxd_xpath::{Context, Factory, Value};

fn esc(out: &mut Vec<u8>, s: &str) {
    let b = s.as_bytes();
    let lim = b.len().min(256);
    for &c in &b[..lim] {
        match c {
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            c if c < 0x20 || c == 0x7f => out.extend_from_slice(format!("\\x{:02x}", c).as_bytes()),
            c => out.push(c),
        }
    }
    if b.len() > 256 {
        out.extend_from_slice(format!("...{}", b.len()).as_bytes());
    }
}

fn kind(n: &Node) -> &'static str {
    match n {
        Node::Root(_) => "root",
        Node::Element(_) => "element",
        Node::Attribute(_) => "attribute",
        Node::Text(_) => "text",
        Node::Comment(_) => "comment",
        Node::ProcessingInstruction(_) => "pi",
        Node::Namespace(_) => "namespace",
    }
}

fn emit(out: &mut Vec<u8>, v: &Value) {
    match v {
        Value::Number(n) => out.extend_from_slice(format!("NUM {:016x}\n", n.to_bits()).as_bytes()),
        Value::String(s) => {
            out.extend_from_slice(b"STR ");
            esc(out, s);
            out.push(b'\n');
        }
        Value::Boolean(b) => out.extend_from_slice(if *b { b"BOOL true\n" } else { b"BOOL false\n" }),
        Value::Nodeset(ns) => {
            let nodes = ns.document_order();
            out.extend_from_slice(format!("NODES {}\n", nodes.len()).as_bytes());
            for n in nodes {
                out.extend_from_slice(b"  ");
                out.extend_from_slice(kind(&n).as_bytes());
                out.push(b' ');
                esc(out, &n.prefixed_name().unwrap_or_default());
                out.push(b' ');
                esc(out, &n.string_value());
                out.push(b'\n');
            }
        }
    }
}

struct Rec<'a> {
    tag: &'a str,
    body: &'a str,
}

fn records(pack: &str) -> Vec<Rec<'_>> {
    let b = pack.as_bytes();
    let mut pos = 0;
    let mut v = Vec::new();
    while pos < b.len() {
        let sp = pos + 2 + b[pos + 2..].iter().position(|&c| c == b' ').unwrap();
        let nl = sp + b[sp..].iter().position(|&c| c == b'\n').unwrap();
        let len: usize = pack[sp + 1..nl].parse().unwrap();
        v.push(Rec { tag: &pack[pos + 2..sp], body: &pack[nl + 1..nl + 1 + len] });
        pos = nl + 1 + len + 1;
    }
    v
}

fn split(s: &str) -> (&str, &str) {
    match s.find(' ') {
        Some(i) => (&s[..i], &s[i + 1..]),
        None => (s, ""),
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: rt-xpath-sxd-oracle PACK");
    let pack = fs::read_to_string(path).expect("read pack");
    let recs = records(&pack);
    let factory = Factory::new();
    let mut out = Vec::new();
    let mut qn = 0;
    let mut i = 0;
    while i < recs.len() {
        // one DOC group: DOC then NS/VARS/VARN/Q until the next DOC
        let doc_src = recs[i].body;
        let mut j = i + 1;
        while j < recs.len() && recs[j].tag != "DOC" {
            j += 1;
        }
        let group = &recs[i + 1..j];
        match parser::parse(doc_src) {
            Err(_) => {
                out.extend_from_slice(b"=== DOCERR\n");
                for r in group.iter().filter(|r| r.tag == "Q") {
                    let _ = r;
                    out.extend_from_slice(format!("=== {}\nERR\n", qn).as_bytes());
                    qn += 1;
                }
            }
            Ok(pkg) => {
                let doc = pkg.as_document();
                let mut ctx = Context::new();
                let vals: Vec<(String, String, bool)> = group
                    .iter()
                    .filter(|r| r.tag == "VARS" || r.tag == "VARN")
                    .map(|r| {
                        let (k, v) = split(r.body);
                        (k.to_owned(), v.to_owned(), r.tag == "VARN")
                    })
                    .collect();
                for r in group {
                    if r.tag == "NS" {
                        let (p, u) = split(r.body);
                        ctx.set_namespace(p, u);
                    }
                }
                for (k, v, num) in &vals {
                    if *num {
                        ctx.set_variable(k.as_str(), v.trim().parse::<f64>().unwrap_or(f64::NAN));
                    } else {
                        ctx.set_variable(k.as_str(), v.clone());
                    }
                }
                for r in group.iter().filter(|r| r.tag == "Q") {
                    out.extend_from_slice(format!("=== {}\n", qn).as_bytes());
                    qn += 1;
                    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        match factory.build(r.body) {
                            Ok(Some(xp)) => match xp.evaluate(&ctx, doc.root()) {
                                Ok(v) => {
                                    let mut o = Vec::new();
                                    emit(&mut o, &v);
                                    o
                                }
                                Err(_) => b"ERR\n".to_vec(),
                            },
                            _ => b"ERR\n".to_vec(),
                        }
                    }));
                    match res {
                        Ok(o) => out.extend_from_slice(&o),
                        Err(_) => out.extend_from_slice(b"ERR\n"),
                    }
                }
            }
        }
        i = j;
    }
    use std::io::Write;
    std::io::stdout().write_all(&out).unwrap();
}
