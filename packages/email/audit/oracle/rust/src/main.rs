//! Rust `mail-parser 0.9.4` oracle for the packages/email red-team audit.
//! Every mode prints one normalized line per case: `<id>\t<result>`.
use mail_parser::{Address, HeaderValue, MessageParser, MimeHeaders, PartType};
use std::{env, fs, process};

fn esc(s: &str) -> String {
    let mut o = String::new();
    for c in s.chars() {
        match c {
            '\r' => o.push_str("\\r"),
            '\n' => o.push_str("\\n"),
            '\t' => o.push_str("\\t"),
            '\\' => o.push_str("\\\\"),
            _ => o.push(c),
        }
    }
    o
}

fn sha8(b: &[u8]) -> String {
    // FNV-1a 64 (dependency-free, identical in Pion/Go oracles)
    let mut h: u64 = 0xcbf29ce484222325;
    for &x in b {
        h ^= x as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{:016x}", h)
}

fn cases(path: &str) -> Vec<(String, String)> {
    let data = fs::read_to_string(path).unwrap_or_else(|_| process::exit(1));
    data.lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| {
            let mut it = l.splitn(3, '\t');
            Some((it.next()?.to_string(), it.next()?.to_string()))
        })
        .collect()
}

fn fmt_addr(a: &Address) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut push = |n: Option<&str>, a: Option<&str>| {
        out.push(format!("{} <{}>", n.unwrap_or(""), a.unwrap_or("")));
    };
    match a {
        Address::List(l) => {
            for x in l {
                push(x.name.as_deref(), x.address.as_deref());
            }
        }
        Address::Group(gs) => {
            for g in gs {
                for x in &g.addresses {
                    push(x.name.as_deref(), x.address.as_deref());
                }
            }
        }
    }
    if out.is_empty() {
        "OK".to_string()
    } else {
        format!("OK {}", out.join(" | "))
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: oracle <addr|date|subj|mime> <path>");
        process::exit(1);
    }
    let parser = MessageParser::default();
    match args[1].as_str() {
        "addr" => {
            for (id, input) in cases(&args[2]) {
                let raw = format!("To: {}\r\n\r\n", input);
                let r = parser.parse(raw.as_bytes()).and_then(|m| match m.header("To") {
                    Some(HeaderValue::Address(a)) => Some(fmt_addr(a)),
                    _ => None,
                });
                println!("{}\t{}", id, r.unwrap_or_else(|| "ERR".into()));
            }
        }
        "date" => {
            for (id, input) in cases(&args[2]) {
                let raw = format!("Date: {}\r\n\r\n", input);
                let r = parser.parse(raw.as_bytes()).and_then(|m| {
                    m.date().map(|d| {
                        let off = (d.tz_hour as i64 * 3600 + d.tz_minute as i64 * 60)
                            * if d.tz_before_gmt { -1 } else { 1 };
                        format!("OK {} {}", d.to_timestamp(), off)
                    })
                });
                println!("{}\t{}", id, r.unwrap_or_else(|| "ERR".into()));
            }
        }
        "subj" => {
            for (id, input) in cases(&args[2]) {
                let raw = format!("Subject: {}\r\n\r\n", input);
                let r = parser
                    .parse(raw.as_bytes())
                    .and_then(|m| m.subject().map(|s| format!("OK {}", esc(s))));
                println!("{}\t{}", id, r.unwrap_or_else(|| "ERR".into()));
            }
        }
        "mime" => {
            let mut names: Vec<_> = fs::read_dir(&args[2])
                .unwrap_or_else(|_| process::exit(1))
                .filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|n| n.ends_with(".eml"))
                .collect();
            names.sort();
            for n in names {
                let raw = fs::read(format!("{}/{}", args[2], n)).unwrap();
                let id = n.trim_end_matches(".eml").to_string();
                let m = match parser.parse(&raw[..]) {
                    Some(m) => m,
                    None => {
                        println!("{}\tERR", id);
                        continue;
                    }
                };
                let subj = m.subject().map(esc).unwrap_or_else(|| "-".into());
                let mut text = "-".to_string();
                for &pid in &m.text_body {
                    let p = m.part(pid).unwrap();
                    if let PartType::Text(t) = &p.body {
                        text = esc(t);
                        break;
                    }
                }
                let mut html = "-".to_string();
                for &pid in &m.html_body {
                    let p = m.part(pid).unwrap();
                    if let PartType::Html(t) = &p.body {
                        html = esc(t);
                        break;
                    }
                }
                let mut atts: Vec<String> = Vec::new();
                for a in m.attachments() {
                    atts.push(format!(
                        "{}:{}",
                        esc(a.attachment_name().unwrap_or("")),
                        sha8(a.contents())
                    ));
                }
                println!(
                    "{}\tsubj={} text={} html={} atts={}[{}]",
                    id,
                    subj,
                    text,
                    html,
                    atts.len(),
                    atts.join(",")
                );
            }
        }
        _ => process::exit(1),
    }
}
