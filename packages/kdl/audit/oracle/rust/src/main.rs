//! Differential oracle for the `packages/kdl` red-team audit (Rust `kdl` 6.7.1).
//!
//! `count <list>`: parse only, prints node/entry counts (timing comparisons).
//! `dump <list>`: every line of <list> is `id<TAB>v2|v1<TAB>path`; prints one line per case:
//!   `id<TAB>OK<TAB><canonical AST>` or `id<TAB>ERR`.
//! The canonical AST format is shared byte-for-byte with `audit/src/main.pion` (`canon_doc`):
//! properties are de-duplicated last-wins (value *and* type of the last occurrence) and sorted
//! by key bytes, an empty children block is treated like no children block, floats are IEEE-754
//! bit patterns (NaN collapses to `fnan`), and every non-printable/non-ASCII code point is `\u{hex}`.
use kdl::{KdlDocument, KdlEntry, KdlNode, KdlValue};
use std::fs;
use std::io::{BufWriter, Write};

fn esc(out: &mut String, s: &str) {
    out.push('"');
    for ch in s.chars() {
        let c = ch as u32;
        if ch == '"' {
            out.push_str("\\\"");
        } else if ch == '\\' {
            out.push_str("\\\\");
        } else if c < 0x20 || c >= 0x7f {
            out.push_str(&format!("\\u{{{:x}}}", c));
        } else {
            out.push(ch);
        }
    }
    out.push('"');
}

fn val(out: &mut String, v: &KdlValue) {
    match v {
        KdlValue::String(s) => {
            out.push('s');
            esc(out, s)
        }
        KdlValue::Integer(i) => out.push_str(&format!("i{}", i)),
        KdlValue::Float(f) => {
            if f.is_nan() {
                out.push_str("fnan")
            } else {
                out.push_str(&format!("f{:016x}", f.to_bits()))
            }
        }
        KdlValue::Bool(b) => out.push_str(if *b { "b1" } else { "b0" }),
        KdlValue::Null => out.push('n'),
    }
}

fn ty(out: &mut String, t: Option<&kdl::KdlIdentifier>) {
    if let Some(t) = t {
        out.push('(');
        esc(out, t.value());
        out.push(')');
    }
}

fn node(out: &mut String, n: &KdlNode) {
    ty(out, n.ty());
    esc(out, n.name().value());
    out.push('[');
    let mut first = true;
    for e in n.entries().iter().filter(|e| e.name().is_none()) {
        if !first {
            out.push(',');
        }
        first = false;
        ty(out, e.ty());
        val(out, e.value());
    }
    out.push_str("][");
    let mut props: Vec<(String, &KdlEntry)> = Vec::new();
    for e in n.entries() {
        if let Some(k) = e.name() {
            let k = k.value().to_string();
            if let Some(slot) = props.iter_mut().find(|(pk, _)| *pk == k) {
                slot.1 = e;
            } else {
                props.push((k, e));
            }
        }
    }
    props.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    let mut first = true;
    for (k, e) in &props {
        if !first {
            out.push(',');
        }
        first = false;
        esc(out, k);
        out.push('=');
        ty(out, e.ty());
        val(out, e.value());
    }
    out.push(']');
    if let Some(ch) = n.children() {
        if !ch.nodes().is_empty() {
            out.push('{');
            doc(out, ch);
            out.push('}');
        }
    }
}

fn doc(out: &mut String, d: &KdlDocument) {
    for (i, n) in d.nodes().iter().enumerate() {
        if i > 0 {
            out.push(';');
        }
        node(out, n);
    }
}

fn run() -> i32 {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 || (args[1] != "dump" && args[1] != "count") {
        eprintln!("usage: kdl-audit-oracle-rust dump|count <list>");
        return 2;
    }
    let list = match fs::read_to_string(&args[2]) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("cannot read {}: {}", args[2], e);
            return 2;
        }
    };
    let stdout = std::io::stdout();
    let mut w = BufWriter::new(stdout.lock());
    for line in list.split('\n') {
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.splitn(3, '\t').collect();
        if parts.len() != 3 {
            continue;
        }
        let (id, mode, path) = (parts[0], parts[1], parts[2]);
        let bytes = fs::read(path).unwrap_or_default();
        let res = match std::str::from_utf8(&bytes) {
            Err(_) => None,
            Ok(src) => {
                let r = if mode == "v1" {
                    KdlDocument::parse_v1(src)
                } else {
                    KdlDocument::parse_v2(src)
                };
                r.ok()
            }
        };
        if args[1] == "count" {
            // Parse only (no canonicalisation): used for timing comparisons.
            match res {
                Some(d) => {
                    let n: usize = d.nodes().iter().map(|n| n.entries().len()).sum();
                    let _ = writeln!(w, "{}\tOK\tnodes={} entries={}", id, d.nodes().len(), n);
                }
                None => {
                    let _ = writeln!(w, "{}\tERR", id);
                }
            }
            continue;
        }
        match res {
            Some(d) => {
                let mut s = String::new();
                doc(&mut s, &d);
                let _ = writeln!(w, "{}\tOK\t{}", id, s);
            }
            None => {
                let _ = writeln!(w, "{}\tERR", id);
            }
        }
    }
    0
}

fn main() {
    // The CST parser recurses; give it a large stack so deep inputs report OK/ERR instead of aborting.
    let h = std::thread::Builder::new()
        .stack_size(1 << 30)
        .spawn(run)
        .expect("spawn");
    std::process::exit(h.join().unwrap_or(3));
}
