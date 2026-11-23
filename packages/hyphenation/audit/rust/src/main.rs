//! Rust `hyphenation =0.8.4` oracle for packages/hyphenation/audit (same CLI and record format as
//! the Pion probe).
//!
//! `<pats>` = `@en_us`: `Standard::from_embedded(Language::EnglishUS)` (crate's bincode, 4,938
//! patterns + 1,441 exceptions, minima (2, 3)). Otherwise the pattern / exception files are split on
//! ASCII whitespace (the Pion `from_tex` token rule) and fed through the crate's own `Parse::pair`
//! exactly as its `build.rs` does per line, and `minima` is overwritten with `<lmin> <rmin>`.
//!   opp  <pats> <hyp> <lmin> <rmin> <in> <out>   : `hyphenate(w).breaks` as `o1,o2,...`
//!   load <pats> <hyp> <lmin> <rmin> <reps>        : build `reps` times, print `ok <patterns> <checksum of 6 probe words>`
//!   bulk <pats> <hyp> <lmin> <rmin> <in> <reps>   : `hyphenate` over every record (perf), print checksum
//!   bulkopp                                        : `opportunities` on pre-lowercased records
use hyphenation::{Hyphenator, Language, Load, Standard};
use hyphenation_commons::dictionary::{Builder, Exceptions, Patterns};
use hyphenation_commons::parse::Parse;
use std::collections::HashMap;
use std::{env, fs, process};

fn read_records(b: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let j = i + b[i..].iter().position(|&c| c == b'\n').unwrap();
        let n: usize = std::str::from_utf8(&b[i..j]).unwrap().parse().unwrap();
        out.push(String::from_utf8(b[j + 1..j + 1 + n].to_vec()).expect("records must be UTF-8"));
        i = j + 1 + n;
    }
    out
}

fn toks(s: &str) -> Vec<String> {
    s.split(|c: char| c == ' ' || c == '\n' || c == '\r' || c == '\t')
        .filter(|t| !t.is_empty())
        .map(|t| t.to_owned())
        .collect()
}

fn load(pats: &str, hyp: &str, lmin: usize, rmin: usize) -> (Standard, usize, usize) {
    if pats == "@en_us" {
        let d = Standard::from_embedded(Language::EnglishUS).unwrap();
        let ne = d.exceptions.0.len();
        return (d, 4938, ne);
    }
    let p = fs::read_to_string(pats).unwrap();
    let e = if hyp == "-" {
        String::new()
    } else {
        fs::read_to_string(hyp).unwrap()
    };
    let pt = toks(&p);
    let et = toks(&e);
    let np = pt.len();
    let patterns = Patterns::from_iter(
        pt.iter()
            .map(|l| <Patterns as Parse>::pair(l, |s| s.to_owned())),
    )
    .unwrap();
    let exceptions = Exceptions(HashMap::from_iter(
        et.iter()
            .map(|l| <Exceptions as Parse>::pair(l, |s| s.to_owned())),
    ));
    let ne = exceptions.0.len();
    let mut d = Standard::from(Builder {
        language: Language::EnglishUS,
        patterns,
        exceptions,
    });
    d.minima = (lmin, rmin);
    (d, np, ne)
}

fn ints(v: &[usize]) -> String {
    v.iter()
        .map(|x| x.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

fn main() {
    let a: Vec<String> = env::args().collect();
    if a.len() < 7 {
        eprintln!("usage: oracle opp|load|bulk <pats> <hyp> <lmin> <rmin> ...");
        process::exit(2);
    }
    let lmin: usize = a[4].parse().unwrap();
    let rmin: usize = a[5].parse().unwrap();
    match a[1].as_str() {
        "load" => {
            let reps: usize = a[6].parse().unwrap();
            let probes = [
                "hyphenation",
                "internationalization",
                "associate",
                "present",
                "typography",
                "algorithm",
            ];
            let mut last = String::new();
            for _ in 0..reps {
                let (d, np, _) = load(&a[2], &a[3], lmin, rmin);
                let mut sum: u64 = 0;
                for w in probes {
                    for b in d.hyphenate(w).breaks {
                        sum = (sum * 131 + b as u64 + 1) % 1_000_000_007;
                    }
                }
                last = format!("ok {} {}", np, sum);
            }
            println!("{}", last);
        }
        "opp" => {
            let (d, _, _) = load(&a[2], &a[3], lmin, rmin);
            let recs = read_records(&fs::read(&a[6]).unwrap());
            let mut out = Vec::new();
            for w in &recs {
                let s = ints(&d.hyphenate(w).breaks);
                out.extend_from_slice(format!("{}\n{}", s.len(), s).as_bytes());
            }
            fs::write(&a[7], out).unwrap();
        }
        "bulk" | "bulkopp" => {
            // bulk: the public `hyphenate` (soft-hyphen scan, case refold, Vec result).
            // bulkopp: words lowercased once up front, then the lower-level `opportunities`
            // (what Pion's opportunities_into does per call, minus Pion's buffer reuse).
            let (d, _, _) = load(&a[2], &a[3], lmin, rmin);
            let recs = read_records(&fs::read(&a[6]).unwrap());
            let reps: usize = a.get(7).map(|s| s.parse().unwrap()).unwrap_or(1);
            let opp = a[1] == "bulkopp";
            let lower: Vec<String> = if opp {
                recs.iter().map(|w| w.to_lowercase()).collect()
            } else {
                Vec::new()
            };
            let mut sum: u64 = 0;
            for _ in 0..reps {
                for (i, w) in recs.iter().enumerate() {
                    let br = if opp {
                        d.opportunities(&lower[i])
                    } else {
                        d.hyphenate(w).breaks
                    };
                    for &b in &br {
                        sum = (sum * 131 + b as u64 + 1) % 1_000_000_007;
                    }
                }
            }
            println!("ok {}", sum);
        }
        m => {
            eprintln!("unknown mode {}", m);
            process::exit(2);
        }
    }
}
