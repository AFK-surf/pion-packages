use serde_json::Value;
use serde_json_path::JsonPath;
use std::env;
use std::fs;
use std::process;

fn fnv1a_str(mut h: i64, s: &str) -> i64 {
    for &b in s.as_bytes() {
        h = ((h ^ (b as i64)).wrapping_mul(16777619)) & 0xFFFF_FFFF;
    }
    h
}

fn fnv1a_int(h: i64, v: i64) -> i64 {
    ((h ^ (v & 0xFFFF_FFFF)).wrapping_mul(16777619)) & 0xFFFF_FFFF
}

fn run_w1(doc_path: &str, q_path: &str, iters: usize) {
    let doc_src = fs::read_to_string(doc_path).expect("read doc");
    let q_src = fs::read_to_string(q_path).expect("read queries");
    let doc: Value = serde_json::from_str(&doc_src).expect("parse doc");
    let queries: Vec<&str> = q_src.lines().filter(|l| !l.is_empty()).collect();

    let mut total_matches: i64 = 0;
    let mut checksum: i64 = 2166136261;
    for _ in 0..iters {
        for q in &queries {
            let jp = JsonPath::parse(q).expect("parse jsonpath");
            let located = jp.query_located(&doc);
            total_matches += located.len() as i64;
            for node in located.iter() {
                let loc = node.location().to_string();
                checksum = fnv1a_str(checksum, &loc);
            }
        }
    }
    println!("w1 matches={} checksum={}", total_matches, checksum);
}

fn run_w2(doc_path: &str, q_path: &str, iters: usize) {
    let doc_src = fs::read_to_string(doc_path).expect("read doc");
    let q_src = fs::read_to_string(q_path).expect("read queries");
    let doc: Value = serde_json::from_str(&doc_src).expect("parse doc");
    let compiled: Vec<JsonPath> = q_src
        .lines()
        .filter(|l| !l.is_empty())
        .map(|q| JsonPath::parse(q).expect("parse jsonpath"))
        .collect();

    let mut total_matches: i64 = 0;
    let mut checksum: i64 = 2166136261;
    for _ in 0..iters {
        for jp in &compiled {
            let nodes = jp.query(&doc);
            let n = nodes.len() as i64;
            total_matches += n;
            checksum = fnv1a_int(checksum, n);
        }
    }
    println!("w2 matches={} checksum={}", total_matches, checksum);
}

fn run_w3(pairs_path: &str, iters: usize) {
    let src = fs::read_to_string(pairs_path).expect("read pairs");
    let mut triples: Vec<(Value, Value, Value)> = Vec::new();
    for line in src.lines().filter(|l| !l.is_empty()) {
        let rec: Value = serde_json::from_str(line).expect("parse rec");
        let b = rec.pointer("/before").expect("before").clone();
        let a = rec.pointer("/after").expect("after").clone();
        let m = rec.pointer("/mpatch").expect("mpatch").clone();
        triples.push((b, a, m));
    }

    let mut ok_count: i64 = 0;
    let mut checksum: i64 = 2166136261;
    for _ in 0..iters {
        for (before, after, mpatch) in &triples {
            let patch = json_patch::diff(before, after);
            let mut doc = before.clone();
            json_patch::patch(&mut doc, &patch).expect("apply patch");
            assert_eq!(&doc, after);
            json_patch::merge(&mut doc, mpatch);
            let rev = doc
                .pointer("/meta/rev")
                .and_then(|v| v.as_i64())
                .unwrap_or(-1);
            let extra = doc
                .pointer("/extra")
                .and_then(|v| v.as_i64())
                .unwrap_or(-1);
            let tag_absent = if doc.pointer("/meta/tag").is_none() {
                1i64
            } else {
                0i64
            };
            ok_count += 1;
            checksum = fnv1a_int(checksum, rev);
            checksum = fnv1a_int(checksum, extra);
            checksum = fnv1a_int(checksum, tag_absent);
        }
    }
    println!("w3 ok={} checksum={}", ok_count, checksum);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: rust_jsonpath w1 <doc> <queries> <iters> | w2 <doc> <queries> <iters> | w3 <pairs> <iters>");
        process::exit(1);
    }
    match args[1].as_str() {
        "w1" => run_w1(&args[2], &args[3], args[4].parse().unwrap_or(1)),
        "w2" => run_w2(&args[2], &args[3], args[4].parse().unwrap_or(1)),
        "w3" => run_w3(&args[2], args[3].parse().unwrap_or(1)),
        _ => process::exit(1),
    }
}
