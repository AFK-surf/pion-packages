use chrono::{TimeZone, Utc};
use croner::Cron;
use std::env;
use std::fs;
use std::hint::black_box;

fn read_lines(path: &str) -> Vec<String> {
    fs::read_to_string(path)
        .expect("read exprs")
        .lines()
        .filter(|l| !l.is_empty())
        .map(|s| s.to_string())
        .collect()
}

fn bench_parse(exprs: &[String]) {
    let base = Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap();
    let rounds = 1000usize;
    let mut ok_count: i64 = 0;
    let mut sum_secs: i64 = 0;
    let mut xor_secs: i64 = 0;
    for r in 0..rounds {
        for expr in exprs {
            let c = Cron::new(black_box(expr)).parse().expect("parse");
            ok_count += 1;
            if r == rounds - 1 {
                let nxt = c.find_next_occurrence(&base, false).expect("next");
                let ts = nxt.timestamp();
                sum_secs = sum_secs.wrapping_add(ts);
                xor_secs ^= ts;
            }
        }
    }
    println!("mode=parse");
    println!("ops={}", ok_count);
    println!("sum_secs={}", sum_secs);
    println!("xor_secs={}", xor_secs);
}

fn bench_next(exprs: &[String]) {
    let base = Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap();
    let compiled: Vec<Cron> = exprs
        .iter()
        .map(|e| Cron::new(e).parse().expect("parse"))
        .collect();
    let rounds = 20usize;
    let steps = 50usize;
    let mut total_ops: i64 = 0;
    let mut sum_secs: i64 = 0;
    let mut xor_secs: i64 = 0;
    for _ in 0..rounds {
        for c in &compiled {
            let mut cur = base;
            for _ in 0..steps {
                let nxt = c.find_next_occurrence(&cur, false).expect("next");
                let ts = nxt.timestamp();
                sum_secs = sum_secs.wrapping_add(ts);
                xor_secs ^= ts;
                cur = nxt;
                total_ops += 1;
            }
        }
    }
    println!("mode=next");
    println!("ops={}", total_ops);
    println!("sum_secs={}", sum_secs);
    println!("xor_secs={}", xor_secs);
}

fn bench_sparse() {
    let base = Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap();
    let rare_exprs = [
        "0 0 29 2 *",
        "0 0 31 12 *",
        "0 0 30 4 *",
        "0 0 1 1 *",
        "0 0 31 1,3,5,7,8,10,12 *",
    ];
    let compiled: Vec<Cron> = rare_exprs
        .iter()
        .map(|e| Cron::new(e).parse().expect("parse"))
        .collect();
    let rounds = 125usize;
    let steps = 16usize;
    let mut total_ops: i64 = 0;
    let mut sum_secs: i64 = 0;
    let mut xor_secs: i64 = 0;
    for _ in 0..rounds {
        for c in &compiled {
            let mut cur = base;
            for _ in 0..steps {
                let nxt = c.find_next_occurrence(&cur, false).expect("next");
                let ts = nxt.timestamp();
                sum_secs = sum_secs.wrapping_add(ts);
                xor_secs ^= ts;
                cur = nxt;
                total_ops += 1;
            }
        }
    }
    println!("mode=sparse");
    println!("ops={}", total_ops);
    println!("sum_secs={}", sum_secs);
    println!("xor_secs={}", xor_secs);
}

fn bench_fri13() {
    let base = Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap();
    let c = Cron::new("0 0 13 * 5")
        .with_dom_and_dow()
        .parse()
        .expect("parse");
    let rounds = 100usize;
    let steps = 100usize;
    let mut total_ops: i64 = 0;
    let mut sum_secs: i64 = 0;
    let mut xor_secs: i64 = 0;
    for _ in 0..rounds {
        let mut cur = base;
        for _ in 0..steps {
            let nxt = c.find_next_occurrence(&cur, false).expect("next");
            let ts = nxt.timestamp();
            sum_secs = sum_secs.wrapping_add(ts);
            xor_secs ^= ts;
            cur = nxt;
            total_ops += 1;
        }
    }
    println!("mode=fri13");
    println!("ops={}", total_ops);
    println!("sum_secs={}", sum_secs);
    println!("xor_secs={}", xor_secs);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: cron_bench_rust <parse|next|sparse|fri13> [exprs_file]");
        std::process::exit(1);
    }
    match args[1].as_str() {
        "sparse" => bench_sparse(),
        "fri13" => bench_fri13(),
        "parse" => {
            let path = args
                .get(2)
                .map(|s| s.as_str())
                .unwrap_or("/private/tmp/pion-cron-bench/exprs_100.txt");
            let exprs = read_lines(path);
            bench_parse(&exprs);
        }
        "next" => {
            let path = args
                .get(2)
                .map(|s| s.as_str())
                .unwrap_or("/private/tmp/pion-cron-bench/exprs_100.txt");
            let exprs = read_lines(path);
            bench_next(&exprs);
        }
        other => {
            eprintln!("unknown mode: {}", other);
            std::process::exit(1);
        }
    }
}
