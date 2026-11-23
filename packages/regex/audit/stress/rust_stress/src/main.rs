//! Stress / DoS / adversarial-performance driver: Rust `regex =1.11.1` side.
//! Mirrors `audit/stress/pion_stress` mode-for-mode; stdout must be byte-identical.
use regex::{Regex, RegexBuilder, RegexSet};

fn lines_of(s: &str) -> Vec<&str> {
    let mut v: Vec<&str> = s.split('\n').collect();
    if s.ends_with('\n') || s.is_empty() {
        v.pop();
    }
    v
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let mode = a[1].as_str();
    let pat = std::fs::read_to_string(&a[2]).unwrap();
    let hay = if a.len() > 3 { std::fs::read_to_string(&a[3]).unwrap() } else { String::new() };
    let iters: usize = if a.len() > 4 { a[4].parse().unwrap() } else { 1 };
    if mode == "set" {
        let set = match RegexSet::new(lines_of(&pat)) {
            Ok(s) => s,
            Err(_) => {
                println!("compile=ERR");
                return;
            }
        };
        let lines = lines_of(&hay);
        let (mut hits, mut ck) = (0i64, 0i64);
        for _ in 0..iters {
            for (li, l) in lines.iter().enumerate() {
                for h in set.matches(l).iter() {
                    hits += 1;
                    ck = (ck * 131 + (h as i64 + 1) + li as i64) % 1000000007;
                }
            }
        }
        println!("set rules={} hits={} checksum={}", set.len(), hits, ck);
        return;
    }
    let built = if mode == "compile_nl" {
        RegexBuilder::new(&pat).nest_limit(1_000_000).build()
    } else {
        Regex::new(&pat)
    };
    let re = match built {
        Ok(r) => r,
        Err(e) => {
            println!("compile=ERR");
            eprintln!("error: {}", e.to_string().lines().last().unwrap_or(""));
            return;
        }
    };
    if mode == "compile" || mode == "compile_nl" {
        println!("compile=ok caps={}", re.captures_len());
        return;
    }
    let (mut count, mut ck) = (0i64, 0i64);
    match mode {
        "find" => {
            for _ in 0..iters {
                for m in re.find_iter(&hay) {
                    count += 1;
                    ck = (ck * 131 + m.start() as i64 + m.end() as i64 * 7) % 1000000007;
                }
            }
        }
        "caps" => {
            let mut locs = re.capture_locations();
            let n = hay.len();
            for _ in 0..iters {
                let mut pos = 0;
                while pos <= n {
                    if re.captures_read_at(&mut locs, &hay, pos).is_none() {
                        break;
                    }
                    count += 1;
                    for g in 0..locs.len() {
                        let (s, e) = match locs.get(g) {
                            Some((s, e)) => (s as i64, e as i64),
                            None => (-1, -1),
                        };
                        ck = (ck * 131 + s + 1) % 1000000007;
                        ck = (ck * 131 + e + 1) % 1000000007;
                    }
                    let (s, e) = locs.get(0).unwrap();
                    pos = if s == e { e + 1 } else { e };
                }
            }
        }
        "is_match" => {
            let lines = lines_of(&hay);
            for _ in 0..iters {
                for (li, l) in lines.iter().enumerate() {
                    if re.is_match(l) {
                        count += 1;
                        ck = (ck * 131 + li as i64) % 1000000007;
                    }
                }
            }
        }
        _ => {
            println!("unknown mode {}", mode);
            std::process::exit(2);
        }
    }
    println!("{} matches={} checksum={}", mode, count, ck);
}
