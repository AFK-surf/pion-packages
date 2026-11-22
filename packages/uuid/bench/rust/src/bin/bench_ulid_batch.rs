use std::env;
use std::fs;
use ulid::Ulid;

fn main() {
    let args: Vec<String> = env::args().collect();
    let path = args.get(1).map(|s| s.as_str()).unwrap_or("/tmp/pion-uuid-bench/ulids_500000.txt");
    let content = fs::read_to_string(path).expect("failed to read input");

    let mut ulids: Vec<Ulid> = Vec::with_capacity(500_000);
    for line in content.lines() {
        if !line.is_empty() {
            ulids.push(Ulid::from_string(line).expect("parse error"));
        }
    }

    ulids.sort_unstable();

    let mut hash: u64 = 14695981039346656037;
    let mut total_bytes: u64 = 0;
    let mut buf = [0u8; 26];
    for u in &ulids {
        let s = u.array_to_str(&mut buf);
        let b = s.as_bytes();
        total_bytes += b.len() as u64;
        for &ch in b {
            hash = (hash ^ (ch as u64)).wrapping_mul(1099511628211);
        }
    }

    let n = ulids.len();
    let first = if n > 0 { ulids[0].to_string() } else { String::new() };
    let mid = if n > 0 { ulids[n / 2].to_string() } else { String::new() };
    let last = if n > 0 { ulids[n - 1].to_string() } else { String::new() };

    println!("count={}", n);
    println!("total_bytes={}", total_bytes);
    println!("hash={}", hash);
    println!("first={}", first);
    println!("mid={}", mid);
    println!("last={}", last);
}
