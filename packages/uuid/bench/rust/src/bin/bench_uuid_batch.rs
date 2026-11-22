use std::env;
use std::fs;
use uuid::Uuid;

fn main() {
    let args: Vec<String> = env::args().collect();
    let path = args.get(1).map(|s| s.as_str()).unwrap_or("/tmp/pion-uuid-bench/uuids_500000.txt");
    let content = fs::read_to_string(path).expect("failed to read input");

    let mut uuids: Vec<Uuid> = Vec::with_capacity(500_000);
    for line in content.lines() {
        if !line.is_empty() {
            uuids.push(Uuid::parse_str(line).expect("parse error"));
        }
    }

    uuids.sort_unstable();

    let mut hash: u64 = 14695981039346656037;
    let mut total_bytes: u64 = 0;
    let mut buf = [0u8; 36];
    for u in &uuids {
        let s = u.hyphenated().encode_lower(&mut buf);
        let b = s.as_bytes();
        total_bytes += b.len() as u64;
        for &ch in b {
            hash = (hash ^ (ch as u64)).wrapping_mul(1099511628211);
        }
    }

    let n = uuids.len();
    let first = if n > 0 { uuids[0].hyphenated().to_string() } else { String::new() };
    let mid = if n > 0 { uuids[n / 2].hyphenated().to_string() } else { String::new() };
    let last = if n > 0 { uuids[n - 1].hyphenated().to_string() } else { String::new() };

    println!("count={}", n);
    println!("total_bytes={}", total_bytes);
    println!("hash={}", hash);
    println!("first={}", first);
    println!("mid={}", mid);
    println!("last={}", last);
}
