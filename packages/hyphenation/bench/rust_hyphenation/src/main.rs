use hyphenation::{Hyphenator, Language, Load, Standard};
use std::env;
use std::fs;
use std::process;

fn run_words(words_file: &str, iters: usize) {
    let raw = fs::read_to_string(words_file).unwrap_or_else(|e| {
        eprintln!("error: failed to read {}: {}", words_file, e);
        process::exit(1);
    });
    let words: Vec<&str> = raw.split('\n').filter(|s| !s.is_empty()).collect();

    let dict = Standard::from_embedded(Language::EnglishUS).unwrap_or_else(|e| {
        eprintln!("error: failed to load en-us: {}", e);
        process::exit(1);
    });

    let mut hyphenated_words: i64 = 0;
    let mut total_breaks: i64 = 0;
    let mut checksum: i64 = 0;

    for _ in 0..iters {
        for &w in &words {
            let h = dict.hyphenate(w);
            let nb = h.breaks.len();
            if nb > 0 {
                hyphenated_words += 1;
                total_breaks += nb as i64;
                for &b in &h.breaks {
                    checksum = (checksum * 131 + (b as i64 + 1)) % 1_000_000_007;
                }
            }
        }
    }

    println!("words={}", words.len());
    println!("iters={}", iters);
    println!("hyphenated_words={}", hyphenated_words);
    println!("total_breaks={}", total_breaks);
    println!("checksum={}", checksum);
}

fn run_load(iters: usize) {
    let probes = [
        "hyphenation",
        "internationalization",
        "associate",
        "present",
        "typography",
        "algorithm",
    ];
    let mut total_breaks: i64 = 0;
    let mut checksum: i64 = 0;

    for _ in 0..iters {
        let dict = Standard::from_embedded(Language::EnglishUS).unwrap_or_else(|e| {
            eprintln!("error: failed to load en-us: {}", e);
            process::exit(1);
        });
        for &w in &probes {
            let h = dict.hyphenate(w);
            total_breaks += h.breaks.len() as i64;
            for &b in &h.breaks {
                checksum = (checksum * 131 + (b as i64 + 1)) % 1_000_000_007;
            }
        }
    }

    println!("loads={}", iters);
    println!("total_breaks={}", total_breaks);
    println!("checksum={}", checksum);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: rust_hyphenation <words|load> ...");
        process::exit(1);
    }
    match args[1].as_str() {
        "words" => {
            let words_file = args
                .get(2)
                .map(|s| s.as_str())
                .unwrap_or("/tmp/pion-hyphenation-bench/words_100k.txt");
            let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(10);
            run_words(words_file, iters);
        }
        "load" => {
            let iters: usize = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(20);
            run_load(iters);
        }
        other => {
            eprintln!("error: unknown mode {}", other);
            process::exit(1);
        }
    }
}
