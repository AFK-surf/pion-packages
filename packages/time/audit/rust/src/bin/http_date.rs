//! W4: RFC 9110 IMF-fixdate parse (jiff::fmt::rfc2822) + format (timestamp_to_rfc9110_string).
use jiff::fmt::rfc2822::{DateTimeParser, DateTimePrinter};
fn main() {
    let path = std::env::args().nth(1).expect("input");
    let content = std::fs::read_to_string(path).unwrap();
    let parser = DateTimeParser::new();
    let printer = DateTimePrinter::new();
    let (mut count, mut hash, mut sum_secs) = (0i64, 0i64, 0i64);
    for line in content.split('\n') {
        if line.is_empty() {
            continue;
        }
        let ts = parser.parse_timestamp(line).expect("parse error");
        let out = printer.timestamp_to_rfc9110_string(&ts).unwrap();
        for &b in out.as_bytes() {
            hash = (hash * 131 + b as i64) % 1_000_000_007;
        }
        sum_secs += ts.as_second();
        count += 1;
    }
    println!("count={count}");
    println!("hash={hash}");
    println!("sum_secs={sum_secs}");
}
