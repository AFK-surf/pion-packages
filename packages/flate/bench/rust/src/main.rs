use adler2::Adler32;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::{Compression, Crc};
use std::env;
use std::fs;
use std::io::{Read, Write};

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: flate_bench <decompress|compress6|compress1|checksum> <file> <iters> [dump_path]");
        std::process::exit(1);
    }
    let mode = args[1].as_str();
    let path = args[2].as_str();
    let iters: usize = args[3].parse().expect("valid iters");
    let data = fs::read(path).expect("read input");

    match mode {
        "decompress" => {
            let mut last_out = Vec::new();
            let mut total_bytes: u64 = 0;
            for _ in 0..iters {
                let mut dec = GzDecoder::new(data.as_slice());
                let mut out = Vec::with_capacity(data.len() * 4);
                dec.read_to_end(&mut out).expect("gzip decompress");
                total_bytes += out.len() as u64;
                last_out = out;
            }
            let stdout = std::io::stdout();
            let mut handle = stdout.lock();
            writeln!(handle, "total_bytes={}", total_bytes).unwrap();
            handle.write_all(&last_out).unwrap();
            writeln!(handle).unwrap();
        }
        "compress6" | "compress1" => {
            let lvl = if mode == "compress6" {
                Compression::new(6)
            } else {
                Compression::new(1)
            };
            let mut last_gz = Vec::new();
            for _ in 0..iters {
                let mut enc = GzEncoder::new(Vec::with_capacity(data.len() / 2), lvl);
                enc.write_all(&data).expect("gzip write");
                last_gz = enc.finish().expect("gzip finish");
            }
            if args.len() >= 5 {
                fs::write(&args[4], &last_gz).expect("write dump");
            }
            println!("mode={} input_bytes={} iters={}", mode, data.len(), iters);
        }
        "checksum" => {
            let mut crc = Crc::new();
            let mut adler = Adler32::new();
            for _ in 0..iters {
                crc.update(&data);
                adler.write_slice(&data);
            }
            println!("crc32={}", crc.sum() as i64);
            println!("adler32={}", adler.checksum() as i64);
        }
        _ => {
            eprintln!("unknown mode: {}", mode);
            std::process::exit(1);
        }
    }
}
