use std::env;
use std::fs;
use std::process;

fn mix(h: i64, v: i64) -> i64 {
    let m: i64 = 1_000_000_007;
    ((h.wrapping_mul(131)) + (v % m) + m) % m
}

fn hash_str(h0: i64, s: &str) -> i64 {
    let b = s.as_bytes();
    let mut h = mix(h0, b.len() as i64);
    for &byte in b {
        h = mix(h, byte as i64);
    }
    h
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: feed-bench-rust <mode> <corpus_path>");
        process::exit(1);
    }
    let mode = &args[1];
    let data = fs::read(&args[2]).unwrap_or_else(|e| {
        eprintln!("failed to read corpus: {e}");
        process::exit(1);
    });
    let parsed = feed_rs::parser::parse(&data[..]).unwrap_or_else(|e| {
        eprintln!("parse error: {e}");
        process::exit(2);
    });

    let mut checksum: i64 = 0;
    let feed_title = parsed.title.as_ref().map(|t| t.content.as_str()).unwrap_or("");
    checksum = hash_str(checksum, feed_title);

    let n = parsed.entries.len();
    let mut total_authors = 0usize;
    let mut total_cats = 0usize;
    for e in &parsed.entries {
        checksum = hash_str(checksum, &e.id);
        if let Some(t) = &e.title {
            checksum = hash_str(checksum, &t.content);
        }
        if let Some(ts) = &e.published {
            checksum = mix(checksum, ts.timestamp());
        }
        if let Some(s) = &e.summary {
            checksum = hash_str(checksum, &s.content);
        }
        total_authors += e.authors.len();
        total_cats += e.categories.len();
        for a in &e.authors {
            checksum = hash_str(checksum, &a.name);
        }
        for c in &e.categories {
            checksum = hash_str(checksum, &c.term);
        }
    }

    println!("mode={mode}");
    println!("entries={n}");
    println!("authors={total_authors}");
    println!("categories={total_cats}");
    println!("checksum={checksum}");
}
