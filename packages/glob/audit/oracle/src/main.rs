//! Reference oracle: real BurntSushi `globset` + `ignore`.
//! `diff <cases>`: replays the case file (see ../gen_cases.py); `bench <build|match> <rules> <paths> <iters>`.
use globset::{Glob, GlobBuilder, GlobSet, GlobSetBuilder};
use ignore::gitignore::{Gitignore, GitignoreBuilder};
use ignore::Match;
use std::ffi::OsStr;
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

fn unhex(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    (0..b.len() / 2)
        .map(|i| {
            let h = |c: u8| (c as char).to_digit(16).unwrap() as u8;
            h(b[2 * i]) << 4 | h(b[2 * i + 1])
        })
        .collect()
}

fn build(pat: &str, o: u32) -> Result<Glob, globset::Error> {
    GlobBuilder::new(pat)
        .case_insensitive(o & 1 != 0)
        .literal_separator(o & 2 != 0)
        .backslash_escape(o & 4 == 0)
        .empty_alternates(o & 8 != 0)
        .allow_unclosed_class(o & 16 != 0)
        .build()
}

fn tri<T>(m: Match<T>) -> char {
    match m {
        Match::None => 'N',
        Match::Ignore(_) => 'I',
        Match::Whitelist(_) => 'W',
    }
}

enum Cur {
    None,
    Single(Option<(globset::GlobMatcher, GlobSet)>),
    Multi(Option<GlobSet>),
    Ignore(Gitignore),
}

fn diff(file: &str) {
    let text = std::fs::read_to_string(file).unwrap();
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    let tmp = std::env::temp_dir().join(format!("glob-audit-{}.gitignore", std::process::id()));
    let mut cur = Cur::None;
    for line in text.lines() {
        let f: Vec<&str> = line.split(' ').collect();
        match f[0] {
            "G" => {
                let pat = String::from_utf8(unhex(f[2])).unwrap();
                cur = Cur::Single(build(&pat, f[1].parse().unwrap()).ok().map(|g| {
                    let mut b = GlobSetBuilder::new();
                    b.add(g.clone());
                    (g.compile_matcher(), b.build().unwrap())
                }));
            }
            "M" => {
                let o: u32 = f[1].parse().unwrap();
                let mut b = GlobSetBuilder::new();
                let mut ok = true;
                for h in f[2].split(',') {
                    match build(&String::from_utf8(unhex(h)).unwrap(), o) {
                        Ok(g) => {
                            b.add(g);
                        }
                        Err(_) => ok = false,
                    }
                }
                cur = Cur::Multi(if ok { b.build().ok() } else { None });
            }
            "I" => {
                std::fs::write(&tmp, unhex(f.get(1).copied().unwrap_or(""))).unwrap();
                let mut b = GitignoreBuilder::new("");
                let _partial = b.add(&tmp); // same as Gitignore::new: bad lines are skipped
                cur = Cur::Ignore(b.build().unwrap());
            }
            "Q" => {
                let raw = unhex(f.get(1).copied().unwrap_or(""));
                let p = Path::new(OsStr::from_bytes(&raw));
                match &cur {
                    Cur::Single(None) | Cur::Multi(None) => writeln!(out, "E").unwrap(),
                    Cur::Single(Some((g, s))) => {
                        writeln!(out, "{}{}", g.is_match(p) as u8, s.is_match(p) as u8).unwrap()
                    }
                    Cur::Multi(Some(s)) => {
                        let v: Vec<String> = s.matches(p).iter().map(|x| x.to_string()).collect();
                        writeln!(out, "{}", v.join(",")).unwrap()
                    }
                    _ => panic!("Q without pattern"),
                }
            }
            "D" => {
                let raw = unhex(f[1]);
                let p = Path::new(OsStr::from_bytes(&raw));
                let d = f[2] == "1";
                if let Cur::Ignore(g) = &cur {
                    writeln!(out, "{} {}", tri(g.matched(p, d)), tri(g.matched_path_or_any_parents(p, d))).unwrap();
                }
            }
            _ => {}
        }
    }
    let _ = std::fs::remove_file(&tmp);
}

fn bench(mode: &str, rules: &str, paths: &str, iters: usize) {
    let rules = std::fs::read_to_string(rules).unwrap();
    let mut b = GlobSetBuilder::new();
    let mut n = 0;
    for r in rules.lines().filter(|l| !l.is_empty()) {
        b.add(Glob::new(r).unwrap());
        n += 1;
    }
    let set = b.build().unwrap();
    println!("rules={n}");
    if mode == "build" {
        return;
    }
    let paths = std::fs::read_to_string(paths).unwrap();
    let paths: Vec<&str> = paths.lines().filter(|l| !l.is_empty()).collect();
    let (mut buf, mut hits, mut sum) = (Vec::new(), 0i64, 0i64);
    for _ in 0..iters {
        for p in &paths {
            set.matches_into(p, &mut buf);
            hits += buf.len() as i64;
            for &i in &buf {
                sum = (sum * 131 + i as i64 + 1) % 1_000_000_007;
            }
        }
    }
    println!("hits={hits}");
    println!("checksum={sum}");
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a[1].as_str() {
        "diff" => diff(&a[2]),
        "bench" => bench(&a[2], &a[3], &a[4], a[5].parse().unwrap()),
        _ => panic!("usage"),
    }
}
