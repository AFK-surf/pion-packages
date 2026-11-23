//! RT-vcard Rust oracle: stalwartlabs `calcard` 0.3.14 (lenient, Postel-style parser).
//! Prints `<id> OK {NAME|view ...}` (parameters omitted: calcard types them) or `<id> ERR <entry>`.
use calcard::vcard::{VCard, VCardProperty, VCardValue};
use calcard::{Entry, Parser};
use std::io::BufRead;

fn vis(s: &str) -> String {
    const META: &[u8] = &[92, 59, 44, 61, 124, 123, 125, 94, 34, 58, 32];
    let mut out = Vec::new();
    for &c in s.as_bytes() {
        if c < 32 || c == 127 || META.contains(&c) {
            out.extend_from_slice(format!("\\x{:02x}", c).as_bytes());
        } else {
            out.push(c);
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn one(v: &VCardValue) -> String {
    match v {
        VCardValue::Text(s) => vis(s),
        VCardValue::Component(items) => items.iter().map(|s| vis(s)).collect::<Vec<_>>().join(","),
        VCardValue::Binary(d) => format!("bin:{}", d.data.len()),
        other => format!("?{}", vis(&format!("{:?}", other))),
    }
}

fn view(name: &VCardProperty, values: &[VCardValue]) -> String {
    match name {
        VCardProperty::N | VCardProperty::Adr => {
            let n = if *name == VCardProperty::N { 5 } else { 7 };
            let mut parts: Vec<String> = values.iter().map(one).collect();
            while parts.len() < n {
                parts.push(String::new());
            }
            parts.join(";")
        }
        VCardProperty::Org => values.iter().map(one).collect::<Vec<_>>().join(";"),
        VCardProperty::Photo | VCardProperty::Logo | VCardProperty::Key | VCardProperty::Sound => {
            match values.first() {
                Some(VCardValue::Binary(d)) => format!("bin:{}", d.data.len()),
                Some(VCardValue::Text(s)) => format!("uri:{}", vis(s)),
                Some(o) => format!("?{}", vis(&format!("{:?}", o))),
                None => "uri:".into(),
            }
        }
        _ => values.iter().map(one).collect::<Vec<_>>().join(","),
    }
}

fn dump(cards: &[VCard]) -> String {
    let mut s = String::new();
    for c in cards {
        let mut views: Vec<(String, String)> = c
            .entries
            .iter()
            .map(|e| {
                let nm = e.name.as_str().to_ascii_uppercase();
                let g = e.group.as_ref().map(|g| format!("{}.", vis(g))).unwrap_or_default();
                (nm.clone(), format!("{}{}|{}", g, vis(&nm), view(&e.name, &e.values)))
            })
            .collect();
        views.sort_by(|a, b| a.0.cmp(&b.0));
        s.push('{');
        s.push_str(&views.into_iter().map(|v| v.1).collect::<Vec<_>>().join(" "));
        s.push('}');
    }
    s
}

fn unhex(h: &str) -> Vec<u8> {
    (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap_or(0)).collect()
}

fn main() {
    let f = std::fs::File::open(std::env::args().nth(1).expect("cases")).expect("open");
    for line in std::io::BufReader::new(f).lines() {
        let line = line.expect("line");
        let mut it = line.splitn(2, ' ');
        let (id, hx) = match (it.next(), it.next()) {
            (Some(a), Some(b)) => (a, b),
            _ => continue,
        };
        let raw = unhex(hx);
        let text = match std::str::from_utf8(&raw) {
            Ok(t) => t,
            Err(_) => {
                println!("{} ERR utf8", id);
                continue;
            }
        };
        let mut p = Parser::new(text);
        let mut cards = Vec::new();
        let mut err = None;
        loop {
            match p.entry() {
                Entry::VCard(c) => cards.push(c),
                Entry::Eof => break,
                other => {
                    err = Some(format!("{:?}", other));
                    break;
                }
            }
        }
        match err {
            Some(e) => println!("{} ERR {}", id, vis(&e.chars().take(60).collect::<String>())),
            None => println!("{} OK {}", id, dump(&cards)),
        }
    }
}
