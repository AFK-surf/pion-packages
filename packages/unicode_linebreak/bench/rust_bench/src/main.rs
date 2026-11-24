use icu_segmenter::options::{LineBreakOptions, LineBreakStrictness, LineBreakWordOption};
use icu_segmenter::LineSegmenter;
use std::env;
use std::fs;
use std::io::{self, BufWriter, Write};

fn fnv1a_int(h0: u64, v: usize) -> u64 {
    (h0 ^ (v as u64)).wrapping_mul(1099511628211u64)
}

fn unescape_line(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            match bytes[i + 1] {
                b'n' => {
                    out.push(b'\n');
                    i += 2;
                    continue;
                }
                b'r' => {
                    out.push(b'\r');
                    i += 2;
                    continue;
                }
                b't' => {
                    out.push(b'\t');
                    i += 2;
                    continue;
                }
                b'\\' => {
                    out.push(b'\\');
                    i += 2;
                    continue;
                }
                _ => {}
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).expect("valid utf-8 in diff corpus")
}

fn make_segmenter() -> icu_segmenter::LineSegmenterBorrowed<'static> {
    let mut opts = LineBreakOptions::default();
    opts.strictness = Some(LineBreakStrictness::Strict);
    opts.word_option = Some(LineBreakWordOption::Normal);
    LineSegmenter::new_auto(opts)
}

fn run_diff(path: &str) -> i32 {
    let text = fs::read_to_string(path).expect("failed to read diff corpus");
    let seg = make_segmenter();
    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    for raw_line in text.lines() {
        let s = unescape_line(raw_line);
        let mut first = true;
        if !s.is_empty() {
            for off in seg.segment_str(&s).skip(1) {
                if !first {
                    let _ = out.write_all(b",");
                }
                first = false;
                let _ = write!(out, "{}", off);
            }
        }
        let _ = out.write_all(b"\n");
    }
    0
}

fn run_bench(path: &str, iters: usize) -> i32 {
    let text = fs::read_to_string(path).expect("failed to read bench corpus");
    let seg = make_segmenter();
    let mut h: u64 = 14695981039346656037u64;
    let mut total_opps: usize = 0;
    for _ in 0..iters {
        if !text.is_empty() {
            for off in seg.segment_str(&text).skip(1) {
                total_opps += 1;
                h = fnv1a_int(h, off);
            }
        }
    }
    println!(
        "linebreak_bench: bytes={} iters={} opps={} fnv64={}",
        text.len(),
        iters,
        total_opps,
        h
    );
    0
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rust_linebreak <diff|bench> <path> [iters]");
        std::process::exit(2);
    }
    let code = match args[1].as_str() {
        "diff" => run_diff(&args[2]),
        "bench" => {
            let iters = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(100);
            run_bench(&args[2], iters)
        }
        other => {
            eprintln!("unknown subcommand: {}", other);
            2
        }
    };
    std::process::exit(code);
}
