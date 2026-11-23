use rust_decimal::Decimal;
use std::env;
use std::fs;
use std::str::FromStr;

fn fnv1a_str(mut h: u64, s: &str) -> u64 {
    for &b in s.as_bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    h
}

fn main() {
    let path = env::args()
        .nth(1)
        .unwrap_or_else(|| "/tmp/pion-decimal-bench/decimals_50k.txt".to_string());
    let content = fs::read_to_string(&path).expect("failed to read input");
    let lines: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();
    let n = lines.len();

    let mut hash: u64 = 14695981039346656037;
    let mut total_ops: i64 = 0;
    let mut total_bytes: i64 = 0;
    let mut first_out = String::new();
    let mut last_out = String::new();

    for round in 0..10 {
        for (i, line) in lines.iter().enumerate() {
            let d = Decimal::from_str(line).expect("parse failed");
            let out = d.to_string();
            hash = fnv1a_str(hash, &out);
            total_bytes += out.len() as i64;
            total_ops += 1;
            if round == 0 && i == 0 {
                first_out = out;
            } else if round == 9 && i == n - 1 {
                last_out = out;
            }
        }
    }

    println!("ops={total_ops}");
    println!("bytes={total_bytes}");
    println!("first={first_out}");
    println!("last={last_out}");
    println!("fnv1a={hash}");
}
