use std::env;
use std::fs;
use std::io::{self, Write};
use unicode_segmentation::UnicodeSegmentation;

fn fnv1a_u64(h0: u64, v: usize) -> u64 {
    (h0 ^ (v as u64)).wrapping_mul(1099511628211u64)
}

fn format_spans(spans: &[(usize, usize)]) -> String {
    let mut out = String::new();
    for (idx, (s, e)) in spans.iter().enumerate() {
        if idx > 0 {
            out.push(',');
        }
        out.push_str(&format!("{}:{}", s, e));
    }
    out
}

fn run_diff(path: &str) -> i32 {
    let content = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("ERR: failed to read {}: {}", path, e);
            return 1;
        }
    };
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());
    for (idx, line) in content.lines().enumerate() {
        let g: Vec<(usize, usize)> = line
            .grapheme_indices(true)
            .map(|(s, sub)| (s, s + sub.len()))
            .collect();
        let w: Vec<(usize, usize)> = line
            .split_word_bound_indices()
            .map(|(s, sub)| (s, s + sub.len()))
            .collect();
        let uw: Vec<(usize, usize)> = line
            .unicode_word_indices()
            .map(|(s, sub)| (s, s + sub.len()))
            .collect();
        let sn: Vec<(usize, usize)> = line
            .split_sentence_bound_indices()
            .map(|(s, sub)| (s, s + sub.len()))
            .collect();
        writeln!(
            out,
            "{}\tG={}\tW={}\tUW={}\tS={}",
            idx,
            format_spans(&g),
            format_spans(&w),
            format_spans(&uw),
            format_spans(&sn)
        )
        .unwrap();
    }
    0
}

fn run_bench(path: &str, iters: usize) -> i32 {
    let content = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("ERR: failed to read {}: {}", path, e);
            return 1;
        }
    };
    let mut h: u64 = 14695981039346656037u64;
    let mut g_total: usize = 0;
    let mut w_total: usize = 0;
    let mut uw_total: usize = 0;
    let mut s_total: usize = 0;

    for _ in 0..iters {
        let mut gc = 0usize;
        for (s, sub) in content.grapheme_indices(true) {
            h = fnv1a_u64(h, s);
            h = fnv1a_u64(h, s + sub.len());
            gc += 1;
        }
        g_total += gc;

        let mut wc = 0usize;
        for (s, sub) in content.split_word_bound_indices() {
            h = fnv1a_u64(h, s);
            h = fnv1a_u64(h, s + sub.len());
            wc += 1;
        }
        w_total += wc;

        let mut uwc = 0usize;
        for (s, sub) in content.unicode_word_indices() {
            h = fnv1a_u64(h, s);
            h = fnv1a_u64(h, s + sub.len());
            uwc += 1;
        }
        uw_total += uwc;

        let mut sc = 0usize;
        for (s, sub) in content.split_sentence_bound_indices() {
            h = fnv1a_u64(h, s);
            h = fnv1a_u64(h, s + sub.len());
            sc += 1;
        }
        s_total += sc;
    }

    println!(
        "iters={} g={} w={} uw={} s={} fnv64={}",
        iters, g_total, w_total, uw_total, s_total, h
    );
    0
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rust_segment <diff|bench> <file> [iters]");
        std::process::exit(2);
    }
    let code = match args[1].as_str() {
        "diff" => run_diff(&args[2]),
        "bench" => {
            let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(50);
            run_bench(&args[2], iters)
        }
        _ => {
            eprintln!("unknown subcommand: {}", args[1]);
            2
        }
    };
    std::process::exit(code);
}
