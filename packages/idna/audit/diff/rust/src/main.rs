//! Rust `idna 1.1.0` oracle for the packages/idna red-team audit (see ../../compare.py).
//! Reads `<name>\t<hex>` corpus lines; for profile U (uts46_url: EMPTY deny list, hyphens allowed, no DNS
//! length) and N (uts46_non_transitional: STD3, CheckHyphens, VerifyAllowRootDot) prints
//!   =<name>
//!   A <p> OK <hex> | A <p> ERR
//!   U <p> <1|0> <hex of the to_unicode output>
//! Rust idna always applies CheckBidi + CheckJoiners, never ContextO, and has no transitional mode.
use idna::uts46::{AsciiDenyList, DnsLength, Hyphens, Uts46};
use std::io::{BufRead, Write};

fn hex(b: &[u8]) -> String {
    if b.is_empty() {
        return "-".to_string();
    }
    b.iter().map(|x| format!("{:02x}", x)).collect()
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap_or(0)).collect()
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: idna_audit_oracle <corpus>");
    let f = std::io::BufReader::new(std::fs::File::open(path).expect("open corpus"));
    let out = std::io::stdout();
    let mut w = std::io::BufWriter::new(out.lock());
    let u = Uts46::new();
    for line in f.lines() {
        let line = line.unwrap();
        let Some((name, hx)) = line.split_once('\t') else { continue };
        let input = unhex(hx);
        writeln!(w, "={}", name).unwrap();
        for (p, deny, hy, dns) in [
            ("U", AsciiDenyList::EMPTY, Hyphens::Allow, DnsLength::Ignore),
            ("N", AsciiDenyList::STD3, Hyphens::Check, DnsLength::VerifyAllowRootDot),
        ] {
            match u.to_ascii(&input, deny, hy, dns) {
                Ok(a) => writeln!(w, "A {} OK {}", p, hex(a.as_bytes())).unwrap(),
                Err(_) => writeln!(w, "A {} ERR", p).unwrap(),
            }
            let (o, r) = u.to_unicode(&input, deny, hy);
            writeln!(w, "U {} {} {}", p, if r.is_ok() { 1 } else { 0 }, hex(o.as_bytes())).unwrap();
        }
    }
}
