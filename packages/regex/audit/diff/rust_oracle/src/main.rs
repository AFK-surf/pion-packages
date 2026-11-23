//! Differential oracle for packages/regex: Rust `regex =1.11.1`.
//! Reads a case file (one case per line, tab separated, hex-encoded fields)
//! and prints a canonical ASCII transcript. The Pion driver
//! (`audit/diff/pion_driver`) prints the very same format; `diff` them.
//!
//! Line formats:
//!   R <hex pattern> <hex haystack> <hex replacement>
//!   S <hex haystack> <hex pat1>,<hex pat2>,...
use regex::{Regex, RegexBuilder, RegexSet, RegexSetBuilder};
use std::fmt::Write as _;

fn unhex(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    (0..b.len() / 2)
        .map(|i| u8::from_str_radix(std::str::from_utf8(&b[2 * i..2 * i + 2]).unwrap(), 16).unwrap())
        .collect()
}

fn hex(s: &str) -> String {
    let mut o = String::with_capacity(s.len() * 2);
    for b in s.bytes() {
        write!(o, "{:02x}", b).unwrap();
    }
    o
}

fn span(m: Option<regex::Match>) -> String {
    match m {
        Some(m) => format!("{}-{}", m.start(), m.end()),
        None => "none".into(),
    }
}

fn caps_str(c: &regex::Captures) -> String {
    let mut o = String::new();
    for i in 0..c.len() {
        if i > 0 {
            o.push(';');
        }
        o.push_str(&span(c.get(i)));
    }
    o
}

fn build(p: &str) -> Result<Regex, regex::Error> {
    // Same limits as Pion defaults are NOT forced: we diff against stock `Regex::new`.
    RegexBuilder::new(p).build()
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: oracle <cases>");
    let data = std::fs::read_to_string(&path).unwrap();
    let mut out = String::new();
    for (idx, line) in data.lines().enumerate() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        writeln!(out, "## {}", idx + 1).unwrap();
        if f[0] == "S" {
            let hay = String::from_utf8(unhex(f[1])).unwrap();
            let pats: Vec<String> = if f.len() > 2 && !f[2].is_empty() {
                f[2].split(',').map(|p| String::from_utf8(unhex(p)).unwrap()).collect()
            } else {
                vec![]
            };
            match RegexSetBuilder::new(&pats).build() {
                Err(_) => writeln!(out, "set=ERR").unwrap(),
                Ok(set) => {
                    let _: &RegexSet = &set;
                    let m: Vec<String> = set.matches(&hay).iter().map(|i| i.to_string()).collect();
                    writeln!(out, "set_is_match={}", set.is_match(&hay) as u8).unwrap();
                    writeln!(out, "set_matches={}", m.join(",")).unwrap();
                }
            }
            continue;
        }
        let pat = String::from_utf8(unhex(f[1])).unwrap();
        let hay = String::from_utf8(unhex(f[2])).unwrap();
        let rep = String::from_utf8(unhex(f[3])).unwrap();
        let re = match build(&pat) {
            Ok(r) => r,
            Err(_) => {
                writeln!(out, "compile=ERR").unwrap();
                continue;
            }
        };
        writeln!(out, "compile=ok caps={}", re.captures_len()).unwrap();
        writeln!(out, "is_match={}", re.is_match(&hay) as u8).unwrap();
        writeln!(out, "find={}", span(re.find(&hay))).unwrap();
        let it: Vec<String> = re.find_iter(&hay).map(|m| span(Some(m))).collect();
        writeln!(out, "find_iter={}", it.join(",")).unwrap();
        // find_at / is_match_at on every char boundary
        let mut at = Vec::new();
        for (p, _) in hay.char_indices().chain(std::iter::once((hay.len(), ' '))) {
            at.push(format!("{}:{}{}", p, span(re.find_at(&hay, p)), if re.is_match_at(&hay, p) { "" } else { "!" }));
        }
        writeln!(out, "find_at={}", at.join(",")).unwrap();
        match re.captures(&hay) {
            Some(c) => writeln!(out, "captures={}", caps_str(&c)).unwrap(),
            None => writeln!(out, "captures=none").unwrap(),
        }
        let ci: Vec<String> = re.captures_iter(&hay).map(|c| caps_str(&c)).collect();
        writeln!(out, "captures_iter={}", ci.join("|")).unwrap();
        writeln!(out, "replace={}", hex(&re.replace(&hay, rep.as_str()))).unwrap();
        writeln!(out, "replace_all={}", hex(&re.replace_all(&hay, rep.as_str()))).unwrap();
        writeln!(out, "replacen2={}", hex(&re.replacen(&hay, 2, rep.as_str()))).unwrap();
        let sp: Vec<String> = re.split(&hay).map(hex).collect();
        writeln!(out, "split={}", sp.join(",")).unwrap();
        let sp2: Vec<String> = re.splitn(&hay, 2).map(hex).collect();
        writeln!(out, "splitn2={}", sp2.join(",")).unwrap();
        let sp3: Vec<String> = re.splitn(&hay, 3).map(hex).collect();
        writeln!(out, "splitn3={}", sp3.join(",")).unwrap();
    }
    print!("{}", out);
}
