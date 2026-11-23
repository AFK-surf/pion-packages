//! Rust `rrule 0.14.0` reference expander for the RT-ical red-team differential.
//! Input lines `DTSTART|RULE|LIMIT[|CAT]` (floating) -> `OK n:occ,...` / `ERR`.
//! Floating DTSTART/UNTIL are mapped onto UTC so civil wall-clock values compare 1:1.
use rrule::RRuleSet;
use std::io::{BufRead, Write};

fn to_utc_until(rule: &str) -> String {
    rule.split(';')
        .map(|kv| {
            if let Some(v) = kv.strip_prefix("UNTIL=") {
                if v.len() == 15 { format!("UNTIL={}Z", v) } else if v.len() == 8 { format!("UNTIL={}T235959Z", v) } else { kv.to_string() }
            } else {
                kv.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(";")
}

fn expand(line: &str) -> String {
    let p: Vec<&str> = line.trim_end().split('|').collect();
    if p.len() < 3 {
        return "ERR".into();
    }
    let limit: u16 = p[2].parse().unwrap_or(40);
    let src = format!("DTSTART:{}Z\nRRULE:{}", p[0], to_utc_until(p[1]));
    let set: RRuleSet = match src.parse() {
        Ok(s) => s,
        Err(_) => return "ERR".into(),
    };
    let res = set.all(limit);
    let occ: Vec<String> = res.dates.iter().map(|d| d.format("%Y%m%dT%H%M%S").to_string()).collect();
    format!("OK {}:{}", occ.len(), occ.join(","))
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: rt-ical-rust-ref <file>");
    let f = std::fs::File::open(path).expect("open");
    let out = std::io::stdout();
    let mut out = out.lock();
    for line in std::io::BufReader::new(f).lines() {
        let line = line.unwrap();
        if line.trim().is_empty() {
            continue;
        }
        writeln!(out, "{}", expand(&line)).unwrap();
    }
}
