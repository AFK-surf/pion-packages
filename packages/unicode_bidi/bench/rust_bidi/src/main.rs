use std::env;
use std::fs;
use unicode_bidi::BidiInfo;

#[inline]
fn fnv1a_byte(h: u64, b: u8) -> u64 {
    (h ^ (b as u64)).wrapping_mul(1099511628211)
}

fn read_lines(path: &str) -> Vec<String> {
    let raw = fs::read_to_string(path).expect("failed to read input file");
    raw.split('\n')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect()
}

fn run_levels(path: &str, iters: usize) {
    let lines = read_lines(path);
    let n = lines.len();
    let mut total_paras: u64 = 0;
    let mut rtl_paras: u64 = 0;
    let mut level_sum: u64 = 0;
    let mut hash: u64 = 14695981039346656037;

    for _ in 0..iters {
        for line in &lines {
            let info = BidiInfo::new(line, None);
            total_paras += info.paragraphs.len() as u64;
            for para in &info.paragraphs {
                if para.level.is_rtl() {
                    rtl_paras += 1;
                }
            }
            for lv in &info.levels {
                let v = lv.number();
                level_sum += v as u64;
                hash = fnv1a_byte(hash, v);
            }
        }
    }

    println!("mode=levels");
    println!("lines={}", n);
    println!("iters={}", iters);
    println!("total_paras={}", total_paras);
    println!("rtl_paras={}", rtl_paras);
    println!("level_sum={}", level_sum);
    println!("levels_fnv={}", hash);
}

fn run_reorder(path: &str, iters: usize) {
    let lines = read_lines(path);
    let n = lines.len();
    let mut total_runs: u64 = 0;
    let mut total_bytes: u64 = 0;
    let mut hash: u64 = 14695981039346656037;

    for _ in 0..iters {
        for line in &lines {
            let info = BidiInfo::new(line, None);
            for para in &info.paragraphs {
                let (_, runs) = info.visual_runs(para, para.range.clone());
                total_runs += runs.len() as u64;
                let out = info.reorder_line(para, para.range.clone());
                let bytes = out.as_bytes();
                total_bytes += bytes.len() as u64;
                for &b in bytes {
                    hash = fnv1a_byte(hash, b);
                }
            }
        }
    }

    println!("mode=reorder");
    println!("lines={}", n);
    println!("iters={}", iters);
    println!("total_runs={}", total_runs);
    println!("total_bytes={}", total_bytes);
    println!("out_fnv={}", hash);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: rust_bidi <levels|reorder> <file> <iters>");
        std::process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let iters: usize = args[3].parse().unwrap_or(1);
    match mode.as_str() {
        "levels" => run_levels(path, iters),
        "reorder" => run_reorder(path, iters),
        _ => {
            eprintln!("unknown mode: {}", mode);
            std::process::exit(1);
        }
    }
}
