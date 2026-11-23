use regex::{Regex, RegexSet};
use std::env;
use std::fs;
use std::process;

fn run_find_iter(data: &str, iters: usize) {
    let pat = r"(?:ERROR|WARN) \[[a-z0-9_-]+\] req_id=[0-9a-f]{8,16}|https?://[A-Za-z0-9._/-]+";
    let re = Regex::new(pat).expect("compile");
    let mut total_matches: i64 = 0;
    let mut checksum: i64 = 0;
    for _ in 0..iters {
        for m in re.find_iter(data) {
            total_matches += 1;
            checksum = (checksum * 131 + m.start() as i64 + (m.end() as i64) * 7) % 1_000_000_007;
        }
    }
    println!("mode=find_iter");
    println!("iters={}", iters);
    println!("matches={}", total_matches);
    println!("checksum={}", checksum);
}

fn run_captures_iter(data: &str, iters: usize) {
    let pat = r"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) (INFO|WARN|ERROR) \[([a-z0-9_-]+)\] req_id=([0-9a-f]+) path=[^ ]+ status=([0-9]{3}) latency=([0-9]+)ms";
    let re = Regex::new(pat).expect("compile");
    let mut locs = re.capture_locations();
    let mut total_matches: i64 = 0;
    let mut checksum: i64 = 0;
    let n = data.len();
    for _ in 0..iters {
        let mut pos = 0;
        while pos <= n {
            if re.captures_read_at(&mut locs, data, pos).is_none() {
                break;
            }
            total_matches += 1;
            for g in 1..=6 {
                let (s, e) = locs.get(g).unwrap();
                checksum = (checksum * 131 + (e - s) as i64 + s as i64) % 1_000_000_007;
            }
            let (ms, me) = locs.get(0).unwrap();
            if ms == me {
                if me >= n {
                    break;
                }
                pos = me + 1;
            } else {
                pos = me;
            }
        }
    }
    println!("mode=captures_iter");
    println!("iters={}", iters);
    println!("matches={}", total_matches);
    println!("checksum={}", checksum);
}

fn run_regex_set(data: &str, iters: usize) {
    let rules = [
        "ERROR",
        "FATAL",
        "status=50[0-9]",
        "status=429",
        "latency=[5-9][0-9]{2}ms",
        "latency=[0-9]{4,}ms",
        "timeout",
        "connection refused",
        "SELECT .* FROM",
        r"\.\./\.\./",
        "OOMKilled",
        "panic:",
        "tls: handshake",
        "rate_limit",
        "^2026-11-23T00:",
        r"\[auth-api\]",
    ];
    let set = RegexSet::new(&rules).expect("compile_set");
    let lines: Vec<&str> = data.split('\n').filter(|l| !l.is_empty()).collect();
    let mut matched_lines: i64 = 0;
    let mut total_hits: i64 = 0;
    let mut checksum: i64 = 0;
    for _ in 0..iters {
        for line in &lines {
            let m = set.matches(line);
            if m.matched_any() {
                matched_lines += 1;
                for idx in m.iter() {
                    total_hits += 1;
                    checksum = (checksum * 131 + (idx as i64 + 1)) % 1_000_000_007;
                }
            }
        }
    }
    println!("mode=regex_set");
    println!("rules={}", rules.len());
    println!("lines={}", lines.len());
    println!("iters={}", iters);
    println!("matched_lines={}", matched_lines);
    println!("total_hits={}", total_hits);
    println!("checksum={}", checksum);
}

fn run_redos(iters: usize) {
    let pat1 = format!("{}{}", "a?".repeat(40), "a".repeat(40));
    let re1 = Regex::new(&pat1).expect("re1");
    let re2 = Regex::new("(a+)+$").expect("re2");
    let re3 = Regex::new("(a|aa)+$").expect("re3");
    let re4 = Regex::new("^([a-zA-Z]+)*$").expect("re4");

    let s_a40 = "a".repeat(40);
    let s_a39 = "a".repeat(39);
    let s_evil_b = format!("{}b", "a".repeat(4000));
    let s_evil_bang = format!("{}!", "a".repeat(4000));

    let mut hits: i64 = 0;
    for _ in 0..iters {
        if re1.is_match(&s_a40) {
            hits += 1;
        }
        if re1.is_match(&s_a39) {
            hits += 10;
        }
        if re2.is_match(&s_evil_b) {
            hits += 100;
        }
        if re3.is_match(&s_evil_b) {
            hits += 1000;
        }
        if re4.is_match(&s_evil_bang) {
            hits += 10000;
        }
    }
    println!("mode=redos");
    println!("iters={}", iters);
    println!("hits={}", hits);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rust_regex <mode> <data_file> [iters]");
        process::exit(1);
    }
    let mode = args[1].as_str();
    let data_file = args[2].as_str();
    let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(5);
    if mode == "redos" {
        run_redos(iters);
        return;
    }
    let data = fs::read_to_string(data_file).expect("read data");
    match mode {
        "find_iter" => run_find_iter(&data, iters),
        "captures_iter" => run_captures_iter(&data, iters),
        "regex_set" => run_regex_set(&data, iters),
        _ => {
            eprintln!("unknown mode: {}", mode);
            process::exit(1);
        }
    }
}
