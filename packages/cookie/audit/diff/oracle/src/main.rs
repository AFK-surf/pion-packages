//! Differential oracle for packages/cookie/audit (see ../../REPORT.md).
//!   parse <file> : Rust `cookie =0.18.3` Cookie::parse, one canonical line per input (same fields as the Pion CLI)
//!   psl <file>   : Rust `psl =2.1.261` suffix / domain / type for each (lower-case ASCII) domain
//! Inputs starting with `hex:` are hex bytes. Strings are escaped like the Pion CLI's `esc`.
use cookie::{Cookie, Expiration, SameSite};
use psl::{Psl, Type};
use std::io::Write;

fn decode(s: &str) -> Vec<u8> {
    if let Some(h) = s.strip_prefix("hex:") {
        let b = h.as_bytes();
        let v = |c: u8| match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            b'A'..=b'F' => c - b'A' + 10,
            _ => 0,
        };
        b.chunks(2).filter(|c| c.len() == 2).map(|c| (v(c[0]) << 4) | v(c[1])).collect()
    } else {
        s.as_bytes().to_vec()
    }
}

fn esc(b: &[u8]) -> String {
    let mut o = String::new();
    for &c in b {
        if c > 32 && c < 127 && c != b'%' && c != b'|' && c != b'\\' {
            o.push(c as char);
        } else {
            o.push_str(&format!("%{:02X}", c));
        }
    }
    o
}

fn parse_line(input: &[u8]) -> String {
    let s = match std::str::from_utf8(input) {
        Ok(s) => s,
        Err(_) => return "ERR utf8".into(),
    };
    match Cookie::parse(s) {
        Err(_) => "ERR".into(),
        Ok(c) => {
            let e = match c.expires() {
                Some(Expiration::DateTime(dt)) => dt.unix_timestamp().to_string(),
                _ => "-".into(),
            };
            let m = c.max_age().map(|d| d.whole_seconds().to_string()).unwrap_or("-".into());
            let d = c.domain().map(|d| esc(d.to_ascii_lowercase().as_bytes())).unwrap_or("-".into());
            let p = c.path().map(|p| esc(p.as_bytes())).unwrap_or("-".into());
            let ss = match c.same_site() {
                Some(SameSite::Strict) => "Strict",
                Some(SameSite::Lax) => "Lax",
                Some(SameSite::None) => "None",
                None => "-",
            };
            format!(
                "OK n={} v={} e={} m={} d={} p={} s={} h={} ss={} pt={}",
                esc(c.name().as_bytes()),
                esc(c.value().as_bytes()),
                e,
                m,
                d,
                p,
                c.secure().unwrap_or(false) as u8,
                c.http_only().unwrap_or(false) as u8,
                ss,
                c.partitioned().unwrap_or(false) as u8
            )
        }
    }
}

fn psl_line(input: &[u8]) -> String {
    let typ = |t: Option<Type>| match t {
        Some(Type::Icann) => "I",
        Some(Type::Private) => "P",
        None => "U",
    };
    let suf = psl::List.suffix(input);
    let dom = psl::List.domain(input);
    format!(
        "{}|{}|{}",
        suf.as_ref().map(|s| esc(s.as_bytes())).unwrap_or("-".into()),
        dom.as_ref().map(|d| esc(d.as_bytes())).unwrap_or("-".into()),
        suf.map(|s| typ(s.typ())).unwrap_or("-")
    )
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: cookie_audit_oracle parse|psl <file>");
        std::process::exit(2);
    }
    let data = std::fs::read(&args[2]).expect("read");
    let text = String::from_utf8_lossy(&data);
    let out = std::io::stdout();
    let mut out = out.lock();
    for line in text.lines() {
        let input = decode(line);
        let r = if args[1] == "parse" { parse_line(&input) } else { psl_line(&input) };
        writeln!(out, "{}", r).unwrap();
    }
}
