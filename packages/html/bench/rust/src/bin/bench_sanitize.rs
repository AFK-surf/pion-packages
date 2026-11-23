use ammonia::Builder;
use std::env;
use std::fs;

fn fnv1a_64(s: &str) -> i64 {
    let mut h: u64 = 0xcbf29ce484222325u64;
    let prime: u64 = 1099511628211u64;
    for &b in s.as_bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(prime);
    }
    h as i64
}

fn main() {
    let path = env::args()
        .nth(1)
        .unwrap_or_else(|| "/private/tmp/pion-html-bench/ugc_xss.html".to_string());
    let src = fs::read_to_string(&path).expect("failed to read input");

    let mut builder = Builder::default();
    builder.add_clean_content_tags(["iframe"]);
    let rounds = 20usize;
    let mut total_bytes: i64 = 0;
    let mut last_hash: i64 = 0;

    for r in 0..rounds {
        let clean = builder.clean(&src).to_string();
        total_bytes += clean.len() as i64;
        if r == rounds - 1 {
            last_hash = fnv1a_64(&clean);
        }
    }

    println!("rounds={}", rounds);
    println!("total_bytes={}", total_bytes);
    println!("fnv64={}", last_hash);
}
