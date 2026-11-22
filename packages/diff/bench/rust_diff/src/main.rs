use std::env;
use std::fs;
use std::io::{self, Write};

use imara_diff::{Algorithm, BasicLineDiffPrinter, Diff, InternedInput, UnifiedDiffConfig};

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 5 {
        eprintln!("usage: bench_rust <before_path> <after_path> <myers|histogram> <iters>");
        std::process::exit(1);
    }
    let before_path = &args[1];
    let after_path = &args[2];
    let algo = match args[3].as_str() {
        "myers" => Algorithm::Myers,
        "histogram" => Algorithm::Histogram,
        other => {
            eprintln!("error: unknown algorithm: {other}");
            std::process::exit(1);
        }
    };
    let iters: usize = args[4].parse().unwrap_or(1).max(1);

    let before = fs::read_to_string(before_path).expect("failed to read before file");
    let after = fs::read_to_string(after_path).expect("failed to read after file");

    let mut total_bytes: u64 = 0;
    let mut last_out = String::new();
    for _ in 0..iters {
        let input = InternedInput::new(before.as_str(), after.as_str());
        let mut diff = Diff::compute(algo, &input);
        diff.postprocess_lines(&input);
        let out = diff
            .unified_diff(
                &BasicLineDiffPrinter(&input.interner),
                UnifiedDiffConfig::default(),
                &input,
            )
            .to_string();
        total_bytes += out.len() as u64;
        last_out = out;
    }

    let stdout = io::stdout();
    let mut handle = stdout.lock();
    writeln!(handle, "iters={iters} total_bytes={total_bytes}").unwrap();
    handle.write_all(last_out.as_bytes()).unwrap();
}
