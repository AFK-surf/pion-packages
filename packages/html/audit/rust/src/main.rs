//! Red-team oracle for packages/html: Rust scraper =0.22.0 (html5ever 0.29.1) + ammonia =4.0.0.
//! Same length-framed batch protocol as audit/probe (records `<len>\n<bytes>`).
//!   oracle tree  <in> <out> doc|frag   html5lib-format tree dump
//!   oracle html  <in> <out> doc|frag   serialization
//!   oracle san   <in> <out>            ammonia::clean
//!   oracle sel   <in> <out>            (selector, html) pairs -> pre-order element indices | ERR
//!   oracle check <in> <out>            re-parse each record as a <body> fragment with html5ever and
//!                                      report anything executable (mXSS round-trip check) or `SAFE`
//!   oracle one   <in> parse|frag|san|sel:<css> [reps]   single-input timing driver
use scraper::{ElementRef, Html, Node, Selector};
use std::io::Write;

fn read_records(b: &[u8]) -> Vec<Vec<u8>> {
    let mut out = vec![];
    let mut i = 0;
    while i < b.len() {
        let ls = i;
        while b[i] != b'\n' { i += 1; }
        let n: usize = std::str::from_utf8(&b[ls..i]).unwrap().parse().unwrap();
        i += 1;
        out.push(b[i..i + n].to_vec());
        i += n;
    }
    out
}

fn emit(out: &mut Vec<u8>, s: &str) {
    out.extend_from_slice(s.len().to_string().as_bytes());
    out.push(b'\n');
    out.extend_from_slice(s.as_bytes());
}

fn ns_prefix(ns: &str) -> &'static str {
    match ns {
        "http://www.w3.org/2000/svg" => "svg ",
        "http://www.w3.org/1998/Math/MathML" => "math ",
        _ => "",
    }
}

fn dump(node: ego_tree::NodeRef<Node>, depth: usize, out: &mut String) {
    let ind = |d: usize| format!("| {}", "  ".repeat(d));
    match node.value() {
        Node::Element(e) => {
            out.push_str(&format!("{}<{}{}>\n", ind(depth), ns_prefix(&e.name.ns), &*e.name.local));
            let mut attrs: Vec<(String, String)> = e
                .attrs
                .iter()
                .map(|(k, v)| {
                    let p = match &*k.ns { "http://www.w3.org/1999/xlink" => "xlink ", "http://www.w3.org/XML/1998/namespace" => "xml ", "http://www.w3.org/2000/xmlns/" => "xmlns ", _ => "" };
                    (format!("{}{}", p, &*k.local), v.to_string())
                })
                .collect();
            attrs.sort();
            for (k, v) in attrs {
                out.push_str(&format!("{}{}=\"{}\"\n", ind(depth + 1), k, v));
            }
            if &*e.name.local == "template" {
                // scraper keeps template contents as ordinary children
                out.push_str(&format!("{}content\n", ind(depth + 1)));
                for c in node.children() { dump(c, depth + 2, out); }
                return;
            }
        }
        Node::Text(t) => out.push_str(&format!("{}\"{}\"\n", ind(depth), &**t)),
        Node::Comment(c) => out.push_str(&format!("{}<!-- {} -->\n", ind(depth), &**c)),
        Node::Doctype(d) => {
            let (p, s) = (d.public_id(), d.system_id());
            if p.is_empty() && s.is_empty() {
                out.push_str(&format!("{}<!DOCTYPE {}>\n", ind(depth), d.name()));
            } else {
                out.push_str(&format!("{}<!DOCTYPE {} \"{}\" \"{}\">\n", ind(depth), d.name(), p, s));
            }
        }
        _ => {}
    }
    for c in node.children() { dump(c, depth + 1, out); }
}

fn tree(src: &str, frag: bool) -> String {
    let mut out = String::new();
    if frag {
        let h = Html::parse_fragment(src);
        // scraper wraps fragments in a synthetic <html>; dump its children like html5lib #document-fragment
        let root = h.root_element();
        for c in root.children() { dump(c, 0, &mut out); }
    } else {
        let h = Html::parse_document(src);
        for c in h.tree.root().children() { dump(c, 0, &mut out); }
    }
    out
}

fn html_of(src: &str, frag: bool) -> String {
    if frag { Html::parse_fragment(src).root_element().inner_html() } else { Html::parse_document(src).html() }
}

const DANGEROUS_TAGS: &[&str] = &["script", "iframe", "frame", "frameset", "object", "embed", "applet", "svg", "math",
    "style", "link", "meta", "base", "form", "input", "button", "textarea", "select", "option", "noscript", "template",
    "xmp", "plaintext", "noembed", "noframes", "title", "img_onerror_dummy"];

fn url_scheme(v: &str) -> Option<String> {
    // WHATWG URL: strip leading/trailing C0 control or space, remove ASCII tab/newline anywhere.
    let t: String = v.trim_matches(|c: char| (c as u32) <= 0x20).chars().filter(|&c| c != '\t' && c != '\n' && c != '\r').collect();
    let mut chars = t.chars();
    let first = chars.next()?;
    if !first.is_ascii_alphabetic() { return None; }
    let mut s = String::new();
    s.push(first.to_ascii_lowercase());
    for c in chars {
        if c == ':' { return Some(s); }
        if c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.' { s.push(c.to_ascii_lowercase()); } else { return None; }
    }
    None
}

fn check(src: &str) -> String {
    let h = Html::parse_fragment(src);
    let mut bad = vec![];
    for n in h.tree.root().descendants() {
        if let Some(e) = ElementRef::wrap(n) {
            let el = e.value();
            let name = &*el.name.local;
            if &*el.name.ns != "http://www.w3.org/1999/xhtml" { bad.push(format!("foreign:{}{}", ns_prefix(&el.name.ns), name)); }
            if DANGEROUS_TAGS.contains(&name) && name != "html" { bad.push(format!("tag:{}", name)); }
            for (k, v) in el.attrs() {
                let kl = k.to_ascii_lowercase();
                if kl.starts_with("on") { bad.push(format!("attr:{}", kl)); }
                if kl == "style" || kl == "srcdoc" { bad.push(format!("attr:{}", kl)); }
                if ["href", "src", "cite", "action", "formaction", "poster", "data", "background", "xlink:href", "srcset", "ping"].contains(&kl.as_str()) {
                    if let Some(s) = url_scheme(v) {
                        if !["http", "https", "mailto"].contains(&s.as_str()) { bad.push(format!("url:{}={}", kl, v)); }
                    }
                }
            }
        }
    }
    if bad.is_empty() { "SAFE".into() } else { bad.join(" ") }
}

fn sel(css: &str, src: &str) -> String {
    let s = match Selector::parse(css) { Ok(s) => s, Err(_) => return "ERR".into() };
    let h = Html::parse_document(src);
    let mut idx = std::collections::HashMap::new();
    let mut i = 0;
    for n in h.tree.root().descendants() {
        if n.value().is_element() { idx.insert(n.id(), i); i += 1; }
    }
    h.select(&s).map(|e| idx[&e.id()].to_string()).collect::<Vec<_>>().join(" ")
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let mode = a[1].as_str();
    let bytes = std::fs::read(&a[2]).unwrap();
    if mode == "one" {
        let src = String::from_utf8_lossy(&bytes).into_owned();
        let sub = a[3].as_str();
        let reps: usize = a.get(4).map(|s| s.parse().unwrap()).unwrap_or(1);
        let mut total = 0usize;
        if let Some(css) = sub.strip_prefix("sel:") {
            // parse once, time only the compiled-selector queries
            let h = Html::parse_document(&src);
            let se = match Selector::parse(css) { Ok(se) => se, Err(_) => { println!("ERR"); return; } };
            for _ in 0..reps { total += h.select(&se).count(); }
            println!("ok {}", total);
            return;
        }
        for _ in 0..reps {
            total += match sub {
                "parse" => Html::parse_document(&src).tree.nodes().count(),
                "frag" => Html::parse_fragment(&src).tree.nodes().count(),
                "san" => ammonia::clean(&src).len(),
                _ => panic!("bad sub"),
            };
        }
        println!("ok {}", total);
        return;
    }
    let recs = read_records(&bytes);
    let frag = a.get(4).map(|s| s == "frag").unwrap_or(false);
    let mut out = vec![];
    if mode == "sel" {
        for p in recs.chunks(2) {
            if p.len() < 2 { break; }
            emit(&mut out, &sel(&String::from_utf8_lossy(&p[0]), &String::from_utf8_lossy(&p[1])));
        }
    } else {
        for r in recs {
            let s = String::from_utf8_lossy(&r);
            let res = match mode {
                "tree" => tree(&s, frag),
                "html" => html_of(&s, frag),
                "san" => ammonia::clean(&s),
                "check" => check(&s),
                _ => panic!("bad mode"),
            };
            emit(&mut out, &res);
        }
    }
    std::fs::File::create(&a[3]).unwrap().write_all(&out).unwrap();
}
