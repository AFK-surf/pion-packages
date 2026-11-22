use std::env;
use std::fs;
use url::Url;

fn main() {
    let args: Vec<String> = env::args().collect();
    let path = args
        .get(1)
        .map(String::as_str)
        .unwrap_or("/tmp/pion-url-bench/urls_100k.txt");
    let content = fs::read_to_string(path).expect("failed to read input file");
    let base = Url::parse("https://base.example.com/a/b/c/index.html").unwrap();
    let lines: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();

    let mut count: i64 = 0;
    let mut total_bytes: i64 = 0;
    let mut hash: i64 = 0;
    let mut first_out = String::new();
    let mut last_out = String::new();

    for _round in 0..2 {
        for &line in &lines {
            let u = if line.starts_with('.') {
                base.join(line).expect("join error")
            } else {
                Url::parse(line).expect("parse error")
            };
            let s = u.as_str();
            if count == 0 {
                first_out = s.to_owned();
            }
            last_out = s.to_owned();
            count += 1;
            total_bytes += s.len() as i64;
            for &b in s.as_bytes() {
                hash = (hash * 131 + b as i64) % 1_000_000_007;
            }
        }
    }

    println!("count={count}");
    println!("total_bytes={total_bytes}");
    println!("hash={hash}");
    println!("first={first_out}");
    println!("last={last_out}");
}
