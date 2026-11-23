//! Differential oracle: Rust croner 2.1.0 (5/6-field only, no year field, no backward search).
//! Input lines: opts<TAB>expr<TAB>start_unix<TAB>n  (same corpus as the Pion probe).
//! Output: "ERR" | "OK m=<0|1> N <next chain>" ("-" = no occurrence / TimeSearchLimitExceeded).
use chrono::{DateTime, TimeZone, Utc};
use croner::Cron;
use std::io::{BufWriter, Write};

fn unescape(s: &str) -> String {
    s.replace("\\t", "\t")
        .replace("\\n", "\n")
        .replace("\\r", "\r")
        .replace("\\\\", "\\")
}

fn build(opts: &str, expr: &str) -> Result<Cron, ()> {
    let mut b = Cron::new(expr);
    match opts {
        "std" => {}
        "and" => {
            b.with_seconds_optional();
            b.with_dom_and_dow();
        }
        _ => {
            b.with_seconds_optional();
        }
    }
    b.parse().map_err(|_| ())
}

/// Same workloads / output as the Pion probe's bench-step / bench-parse.
fn bench(mode: &str, path: &str, steps: usize, rounds: usize) {
    let data = std::fs::read_to_string(path).expect("read bench file");
    let cases: Vec<(String, String)> = data
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            (f[0].to_string(), unescape(f[1]))
        })
        .collect();
    let base = Utc.timestamp_opt(1704067200, 0).unwrap();
    let (mut ops, mut errs, mut sum, mut xor) = (0i64, 0i64, 0i64, 0i64);
    if mode == "bench-step" {
        let compiled: Vec<Cron> = cases
            .iter()
            .map(|(o, e)| build(o, e).expect("parse"))
            .collect();
        for _ in 0..rounds {
            for c in &compiled {
                let mut cur = base;
                for _ in 0..steps {
                    match c.find_next_occurrence(&cur, false) {
                        Ok(n) => {
                            let ts = n.timestamp();
                            sum = sum.wrapping_add(ts);
                            xor ^= ts;
                            cur = n;
                            ops += 1;
                        }
                        Err(_) => {
                            errs += 1;
                            break;
                        }
                    }
                }
            }
        }
    } else {
        for r in 0..rounds {
            for (o, e) in &cases {
                match build(o, std::hint::black_box(e)) {
                    Ok(c) => {
                        ops += 1;
                        if r == rounds - 1 {
                            if let Ok(n) = c.find_next_occurrence(&base, false) {
                                let ts = n.timestamp();
                                sum = sum.wrapping_add(ts);
                                xor ^= ts;
                            }
                        }
                    }
                    Err(_) => errs += 1,
                }
            }
        }
    }
    println!("ops={}", ops);
    println!("none_or_err={}", errs);
    println!("sum={}", sum);
    println!("xor={}", xor);
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() > 1 && a[1] == "bench-step" {
        return bench(&a[1], &a[2], a[3].parse().unwrap(), a[4].parse().unwrap());
    }
    if a.len() > 1 && a[1] == "bench-parse" {
        return bench(&a[1], &a[2], 0, a[3].parse().unwrap());
    }
    let path = std::env::args().nth(1).expect("corpus path");
    let data = std::fs::read_to_string(path).expect("read corpus");
    let out = std::io::stdout();
    let mut w = BufWriter::new(out.lock());
    for line in data.lines().filter(|l| !l.is_empty()) {
        let f: Vec<&str> = line.split('\t').collect();
        let expr = unescape(f[1]);
        let mut b = Cron::new(&expr);
        match f[0] {
            "std" => {}
            "and" => {
                b.with_seconds_optional();
                b.with_dom_and_dow();
            }
            _ => {
                b.with_seconds_optional();
            }
        }
        let c = match std::panic::catch_unwind(|| b.clone().parse()) {
            Ok(Ok(c)) => c,
            _ => {
                writeln!(w, "ERR").unwrap();
                continue;
            }
        };
        let start: DateTime<Utc> = Utc.timestamp_opt(f[2].parse::<i64>().unwrap(), 0).unwrap();
        let n: usize = f[3].parse().unwrap();
        let m = c.is_time_matching(&start).unwrap_or(false);
        let mut s = format!("OK m={} N", if m { 1 } else { 0 });
        let mut cur = start;
        for _ in 0..n {
            match c.find_next_occurrence(&cur, false) {
                Ok(nx) => {
                    s.push_str(&format!(" {}", nx.timestamp()));
                    cur = nx;
                }
                Err(_) => {
                    s.push_str(" -");
                    break;
                }
            }
        }
        writeln!(w, "{}", s).unwrap();
    }
}
