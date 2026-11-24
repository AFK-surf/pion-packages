use std::env;
use std::fs;
use std::io::{Read, Write};

use bzip2::read::BzDecoder;
use bzip2::write::BzEncoder;
use bzip2::Compression;

fn fnv1a_64(data: &[u8]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for &b in data {
        h = (h ^ (b as u64)).wrapping_mul(1099511628211);
    }
    h
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!(
            "usage: bzip2_bench <compress <level> <in> [iters] [dump]|decompress <in> [iters] [dump]>"
        );
        std::process::exit(1);
    }
    let mode = args[1].as_str();

    match mode {
        "compress" => {
            if args.len() < 4 {
                eprintln!("usage: bzip2_bench compress <level> <in> [iters] [dump]");
                std::process::exit(1);
            }
            let level: u32 = args[2].parse().expect("valid level");
            let path = args[3].as_str();
            let iters: usize = if args.len() >= 5 {
                args[4].parse().expect("valid iters")
            } else {
                1
            };
            let data = fs::read(path).expect("read input");
            let mut last_out = Vec::new();
            let mut total_bytes: u64 = 0;
            for _ in 0..iters {
                let mut enc = BzEncoder::new(Vec::new(), Compression::new(level));
                enc.write_all(&data).expect("bzip2 write_all");
                let out = enc.finish().expect("bzip2 finish");
                total_bytes += out.len() as u64;
                last_out = out;
            }
            if args.len() >= 6 {
                fs::write(&args[5], &last_out).expect("write dump");
            }
            let h = fnv1a_64(&last_out);
            println!(
                "mode=compress level={} iters={} in_len={} out_len={} total_out={} fnv64={:016x}",
                level,
                iters,
                data.len(),
                last_out.len(),
                total_bytes,
                h
            );
        }
        "decompress" => {
            let path = args[2].as_str();
            let iters: usize = if args.len() >= 4 {
                args[3].parse().expect("valid iters")
            } else {
                1
            };
            let data = fs::read(path).expect("read input");
            let mut last_out = Vec::new();
            let mut total_bytes: u64 = 0;
            for _ in 0..iters {
                let mut dec = BzDecoder::new(data.as_slice());
                let mut out = Vec::new();
                dec.read_to_end(&mut out).expect("bzip2 decompress");
                total_bytes += out.len() as u64;
                last_out = out;
            }
            if args.len() >= 5 {
                fs::write(&args[4], &last_out).expect("write dump");
            }
            let h = fnv1a_64(&last_out);
            println!(
                "mode=decompress iters={} in_len={} out_len={} total_out={} fnv64={:016x}",
                iters,
                data.len(),
                last_out.len(),
                total_bytes,
                h
            );
        }
        _ => {
            eprintln!("unknown mode: {}", mode);
            std::process::exit(1);
        }
    }
}
