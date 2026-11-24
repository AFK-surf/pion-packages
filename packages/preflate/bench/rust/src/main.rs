use std::env;
use std::fs;
use std::io::{self, Write};
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: preflate_bench_rust <deflate_file> <iters> [stats_path]");
        process::exit(1);
    }
    let path = &args[1];
    let iters: usize = match args[2].parse() {
        Ok(n) if n > 0 => n,
        _ => {
            eprintln!("iters must be > 0");
            process::exit(1);
        }
    };
    let deflate = match fs::read(path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("failed to read {}: {}", path, e);
            process::exit(1);
        }
    };

    let config = preflate_rs::PreflateConfig {
        max_chain_length: 4096,
        plain_text_limit: i32::MAX as usize,
        verify_compression: false,
    };

    let mut last_rebuilt = Vec::new();
    let mut last_corr_len = 0usize;
    let mut last_plain_len = 0usize;

    for _ in 0..iters {
        let (analysis, plain_text) =
            match preflate_rs::preflate_whole_deflate_stream(&deflate, &config) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("analyze error: {}", e);
                    process::exit(2);
                }
            };
        let rebuilt = match preflate_rs::recreate_whole_deflate_stream(
            plain_text.text(),
            &analysis.corrections,
        ) {
            Ok(b) => b,
            Err(e) => {
                eprintln!("reencode error: {}", e);
                process::exit(3);
            }
        };
        last_corr_len = analysis.corrections.len();
        last_plain_len = plain_text.text().len();
        last_rebuilt = rebuilt;
    }

    if let Some(stats_path) = args.get(3) {
        let stats = format!(
            "impl=rust_preflate_rs deflate={} plain={} corrections={}\n",
            deflate.len(),
            last_plain_len,
            last_corr_len
        );
        let _ = fs::write(stats_path, stats);
    }
    if let Err(e) = io::stdout().write_all(&last_rebuilt) {
        eprintln!("failed to write stdout: {}", e);
        process::exit(4);
    }
}
