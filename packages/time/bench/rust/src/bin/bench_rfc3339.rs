use jiff::fmt::temporal::DateTimePrinter;
use jiff::tz::Offset;
use jiff::Timestamp;
use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();
    let path = args
        .get(1)
        .map(|s| s.as_str())
        .unwrap_or("/tmp/time-bench-rfc3339.txt");
    let content = fs::read_to_string(path).expect("failed to read input file");
    let jst = Offset::constant(9);
    let printer = DateTimePrinter::new();

    let mut count: i64 = 0;
    let mut total_bytes: i64 = 0;
    let mut hash: i64 = 0;
    let mut sum_secs: i64 = 0;
    let mut sum_nanos: i64 = 0;
    let mut first_out = String::new();
    let mut last_out = String::new();

    for line in content.split('\n') {
        if line.is_empty() {
            continue;
        }
        let ts: Timestamp = line.parse().expect("parse error");
        let out = printer.timestamp_with_offset_to_string(&ts, jst);
        if count == 0 {
            first_out = out.clone();
        }
        let olen = out.len() as i64;
        total_bytes += olen;
        let mut s = ts.as_second();
        let mut ns = ts.subsec_nanosecond();
        if ns < 0 {
            s -= 1;
            ns += 1_000_000_000;
        }
        sum_secs += s;
        sum_nanos += ns as i64;
        for &b in out.as_bytes() {
            hash = (hash * 131 + b as i64) % 1_000_000_007;
        }
        last_out = out;
        count += 1;
    }

    println!("count={count}");
    println!("total_bytes={total_bytes}");
    println!("hash={hash}");
    println!("sum_secs={sum_secs}");
    println!("sum_nanos={sum_nanos}");
    println!("first={first_out}");
    println!("last={last_out}");
}
