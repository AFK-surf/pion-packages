//! W3: ISO 8601 SignedDuration parse + format with jiff's idiomatic temporal parser / Display.
use jiff::fmt::temporal::SpanParser;
fn main() {
    let path = std::env::args().nth(1).expect("input");
    let content = std::fs::read_to_string(path).unwrap();
    let parser = SpanParser::new();
    let (mut count, mut hash, mut sum_secs, mut sum_nanos) = (0i64, 0i64, 0i64, 0i64);
    for line in content.split('\n') {
        if line.is_empty() {
            continue;
        }
        let d = parser.parse_duration(line).expect("parse error");
        let out = d.to_string();
        for &b in out.as_bytes() {
            hash = (hash * 131 + b as i64) % 1_000_000_007;
        }
        sum_secs += d.as_secs();
        sum_nanos += d.subsec_nanos() as i64;
        count += 1;
    }
    println!("count={count}");
    println!("hash={hash}");
    println!("sum_secs={sum_secs}");
    println!("sum_nanos={sum_nanos}");
}
