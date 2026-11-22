//! Red-team differential oracle: dtolnay/semver =1.0.28.
//! Output format is byte-for-byte the same as `audit/src/main.pion`.

use semver::{BuildMetadata, Comparator, Prerelease, Version, VersionReq};
use std::cmp::Ordering;
use std::env;
use std::fs;

fn unhex(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len() / 2);
    let v = |c: u8| -> u8 {
        match c {
            b'0'..=b'9' => c - b'0',
            b'a'..=b'f' => c - b'a' + 10,
            b'A'..=b'F' => c - b'A' + 10,
            _ => 0,
        }
    };
    let mut i = 0;
    while i + 1 < b.len() {
        out.push(v(b[i]) * 16 + v(b[i + 1]));
        i += 2;
    }
    String::from_utf8(out).expect("corpus must be valid UTF-8")
}

fn ord(o: Ordering) -> &'static str {
    match o {
        Ordering::Less => "-1",
        Ordering::Equal => "0",
        Ordering::Greater => "1",
    }
}

fn run_line(line: &str, out: &mut String) {
    let f: Vec<&str> = line.split(' ').collect();
    let k = f[0];
    let a = f.get(1).map(|s| unhex(s)).unwrap_or_default();
    let b = f.get(2).map(|s| unhex(s)).unwrap_or_default();
    match k {
        "V" => match Version::parse(&a) {
            Ok(v) => out.push_str(&format!("ok|{}|{}|{}", v, v.pre.as_str(), v.build.as_str())),
            Err(e) => out.push_str(&format!("err|{}", e)),
        },
        "R" => match VersionReq::parse(&a) {
            Ok(r) => out.push_str(&format!("ok|{}|n={}", r, r.comparators.len())),
            Err(e) => out.push_str(&format!("err|{}", e)),
        },
        "C" => match Comparator::parse(&a) {
            Ok(c) => out.push_str(&format!("ok|{}", c)),
            Err(e) => out.push_str(&format!("err|{}", e)),
        },
        "P" => match Prerelease::new(&a) {
            Ok(p) => out.push_str(&format!("ok|{}", p.as_str())),
            Err(e) => out.push_str(&format!("err|{}", e)),
        },
        "B" => match BuildMetadata::new(&a) {
            Ok(p) => out.push_str(&format!("ok|{}", p.as_str())),
            Err(e) => out.push_str(&format!("err|{}", e)),
        },
        "M" | "K" => match Version::parse(&b) {
            Err(e) => out.push_str(&format!("verr|{}", e)),
            Ok(v) => {
                if k == "M" {
                    match VersionReq::parse(&a) {
                        Err(e) => out.push_str(&format!("rerr|{}", e)),
                        Ok(r) => out.push_str(if r.matches(&v) { "1" } else { "0" }),
                    }
                } else {
                    match Comparator::parse(&a) {
                        Err(e) => out.push_str(&format!("rerr|{}", e)),
                        Ok(c) => out.push_str(if c.matches(&v) { "1" } else { "0" }),
                    }
                }
            }
        },
        "O" => match (Version::parse(&a), Version::parse(&b)) {
            (Ok(x), Ok(y)) => out.push_str(&format!(
                "{} {} {}",
                ord(x.cmp(&y)),
                ord(x.cmp_precedence(&y)),
                if x == y { "eq" } else { "ne" }
            )),
            _ => out.push_str("perr"),
        },
        _ => out.push_str("unknown"),
    }
}

fn read_lines(path: &str) -> Vec<String> {
    fs::read_to_string(path)
        .unwrap_or_default()
        .split('\n')
        .filter(|s| !s.is_empty())
        .map(String::from)
        .collect()
}

fn run_perf(mode: &str, path: &str, iters: usize, ver_text: &str) {
    let lines = read_lines(path);
    let ver = Version::parse(ver_text).unwrap_or(Version::new(1, 0, 0));
    let (mut ok, mut bytes) = (0i64, 0i64);
    for _ in 0..iters {
        for (i, s) in lines.iter().enumerate() {
            match mode {
                "version" => match Version::parse(s) {
                    Ok(v) => {
                        ok += 1;
                        bytes += v.to_string().len() as i64;
                    }
                    Err(e) => bytes += e.to_string().len() as i64,
                },
                "req" => match VersionReq::parse(s) {
                    Ok(r) => {
                        ok += 1;
                        bytes += r.to_string().len() as i64;
                    }
                    Err(e) => bytes += e.to_string().len() as i64,
                },
                "cmp" => {
                    let j = if i + 1 < lines.len() { i + 1 } else { 0 };
                    if let (Ok(x), Ok(y)) = (Version::parse(s), Version::parse(&lines[j])) {
                        ok += 1;
                        bytes += match x.cmp(&y) {
                            Ordering::Less => 0,
                            Ordering::Equal => 1,
                            Ordering::Greater => 2,
                        };
                    }
                }
                _ => {
                    if let Ok(r) = VersionReq::parse(s) {
                        if r.matches(&ver) {
                            ok += 1;
                        }
                    }
                }
            }
        }
    }
    println!("mode={} lines={} ok={} bytes={}", mode, lines.len(), ok, bytes);
}

fn run_matrix(reqs_path: &str, vers_path: &str) {
    let reqs = read_lines(reqs_path);
    let vers: Vec<Version> = read_lines(vers_path)
        .iter()
        .filter_map(|s| Version::parse(s).ok())
        .collect();
    let mut out = String::with_capacity(reqs.len() * (vers.len() + 1));
    for (i, r) in reqs.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        match VersionReq::parse(r) {
            Ok(req) => {
                for v in &vers {
                    out.push(if req.matches(v) { '1' } else { '0' });
                }
            }
            Err(_) => out.push('E'),
        }
    }
    println!("{}", out);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() >= 4 && args[1] == "matrix" {
        run_matrix(&args[2], &args[3]);
        return;
    }
    if args.len() >= 3 && args[1] == "diff" {
        let lines = read_lines(&args[2]);
        let mut out = String::with_capacity(lines.len() * 16);
        for (i, l) in lines.iter().enumerate() {
            if i > 0 {
                out.push('\n');
            }
            run_line(l, &mut out);
        }
        println!("{}", out);
        return;
    }
    if args.len() >= 5 && args[1] == "perf" {
        let v = args.get(5).map(String::as_str).unwrap_or("1.0.0");
        run_perf(&args[2], &args[3], args[4].parse().unwrap(), v);
        return;
    }
    eprintln!("usage: oracle diff <corpus> | perf <version|req|cmp|match> <file> <iters> [ver]");
    std::process::exit(2);
}
