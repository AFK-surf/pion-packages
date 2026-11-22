use globset::{Glob, GlobSetBuilder};
use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();
    let paths_file = args
        .get(1)
        .map(|s| s.as_str())
        .unwrap_or("/tmp/pion-glob-bench/paths_50k.txt");
    let rules_file = args
        .get(2)
        .map(|s| s.as_str())
        .unwrap_or("/tmp/pion-glob-bench/rules_80.txt");
    let iters: usize = args
        .get(3)
        .and_then(|s| s.parse().ok())
        .filter(|&v| v > 0)
        .unwrap_or(5);

    let paths_raw = fs::read_to_string(paths_file).expect("failed to read paths file");
    let rules_raw = fs::read_to_string(rules_file).expect("failed to read rules file");

    let rules: Vec<&str> = rules_raw.lines().filter(|l| !l.is_empty()).collect();
    let paths: Vec<&str> = paths_raw.lines().filter(|l| !l.is_empty()).collect();

    let mut builder = GlobSetBuilder::new();
    for r in &rules {
        builder.add(Glob::new(r).expect("valid glob"));
    }
    let set = builder.build().expect("valid globset");

    let mut buf: Vec<usize> = Vec::new();
    let mut matched_paths: i64 = 0;
    let mut total_hits: i64 = 0;
    let mut checksum: i64 = 0;

    for _ in 0..iters {
        for p in &paths {
            set.matches_into(p, &mut buf);
            if !buf.is_empty() {
                matched_paths += 1;
                total_hits += buf.len() as i64;
                for &idx in &buf {
                    checksum = (checksum * 131 + (idx as i64 + 1)) % 1_000_000_007;
                }
            }
        }
    }

    println!("rules={}", rules.len());
    println!("paths={}", paths.len());
    println!("iters={}", iters);
    println!("matched_paths={}", matched_paths);
    println!("total_hits={}", total_hits);
    println!("checksum={}", checksum);
}
