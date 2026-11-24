use cookie::{Cookie, Expiration, SameSite};
use psl::Psl;
use std::env;
use std::fs;

fn fnv1a_64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for &b in bytes {
        h = (h ^ (b as u64)).wrapping_mul(1099511628211);
    }
    h
}

fn eval_parse_once(lines: &[String]) -> String {
    let mut out = String::with_capacity(lines.len() * 64);
    for line in lines {
        match Cookie::parse(line.as_str()) {
            Ok(c) => {
                out.push_str("OK|");
                out.push_str(c.name());
                out.push('|');
                out.push_str(c.value());
                out.push_str("|E=");
                match c.expires() {
                    Some(Expiration::DateTime(dt)) => {
                        out.push_str(&dt.unix_timestamp().to_string());
                    }
                    _ => out.push('-'),
                }
                out.push_str("|M=");
                match c.max_age() {
                    Some(d) => out.push_str(&d.whole_seconds().to_string()),
                    None => out.push('-'),
                }
                out.push_str("|D=");
                match c.domain() {
                    Some(d) => {
                        let trimmed = d.strip_prefix('.').unwrap_or(d);
                        out.push_str(&trimmed.to_ascii_lowercase());
                    }
                    None => out.push('-'),
                }
                out.push_str("|P=");
                match c.path() {
                    Some(p) => out.push_str(p),
                    None => out.push('-'),
                }
                out.push_str("|S=");
                out.push(if c.secure().unwrap_or(false) { '1' } else { '0' });
                out.push_str("|H=");
                out.push(if c.http_only().unwrap_or(false) { '1' } else { '0' });
                out.push_str("|SS=");
                match c.same_site() {
                    Some(SameSite::Strict) => out.push_str("Strict"),
                    Some(SameSite::Lax) => out.push_str("Lax"),
                    Some(SameSite::None) => out.push_str("None"),
                    None => out.push('-'),
                }
                out.push_str("|PT=");
                out.push(if c.partitioned().unwrap_or(false) { '1' } else { '0' });
                out.push('\n');
            }
            Err(_) => out.push_str("ERR\n"),
        }
    }
    out
}

fn is_ip_literal(s: &str) -> bool {
    s.parse::<std::net::IpAddr>().is_ok()
        || (s.starts_with('[') && s.ends_with(']') && s[1..s.len() - 1].parse::<std::net::IpAddr>().is_ok())
}

fn eval_psl_once(lines: &[String]) -> String {
    let mut out = String::with_capacity(lines.len() * 48);
    for d in lines {
        out.push_str(d);
        out.push('|');
        if is_ip_literal(d) || d.starts_with('.') || d.is_empty() {
            out.push_str("-|-\n");
            continue;
        }
        let lower = d.to_ascii_lowercase();
        let dom = psl::List.domain(lower.as_bytes());
        match dom {
            Some(r) => out.push_str(std::str::from_utf8(r.as_bytes()).unwrap_or("-")),
            None => out.push('-'),
        }
        out.push('|');
        let suf = psl::List.suffix(lower.as_bytes());
        match suf {
            Some(s) => out.push_str(std::str::from_utf8(s.as_bytes()).unwrap_or("-")),
            None => out.push('-'),
        }
        out.push('\n');
    }
    out
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: rust_cookie_bench <parse|psl> <corpus_file> <iters>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let iters: usize = args[3].parse().unwrap_or(1);
    let data = fs::read_to_string(path).expect("failed to read corpus");
    let lines: Vec<String> = data
        .lines()
        .filter(|l| !l.is_empty())
        .map(|s| s.to_string())
        .collect();

    if iters == 0 {
        let out = if mode == "parse" {
            eval_parse_once(&lines)
        } else {
            eval_psl_once(&lines)
        };
        println!("{}", out);
        return;
    }

    let mut last = String::new();
    for _ in 0..iters {
        last = if mode == "parse" {
            eval_parse_once(&lines)
        } else {
            eval_psl_once(&lines)
        };
    }
    println!(
        "mode={} cases={} iters={} bytes={} fnv64={:016x}",
        mode,
        lines.len(),
        iters,
        last.len(),
        fnv1a_64(last.as_bytes())
    );
}
