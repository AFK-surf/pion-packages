use std::env;
use std::fs;
use std::io::Cursor;

fn fnv1a_64_update(mut h: u64, data: &[u8]) -> u64 {
    for &b in data {
        h = (h ^ (b as u64)).wrapping_mul(1099511628211);
    }
    h
}

fn read_u32_le(b: &[u8], off: usize) -> usize {
    u32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]) as usize
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: brotli_bench <decode|batch> <file> <iters> [dump_path]");
        std::process::exit(1);
    }
    let mode = args[1].as_str();
    let path = args[2].as_str();
    let iters: usize = args[3].parse().expect("valid iters");
    let data = fs::read(path).expect("read input");

    match mode {
        "decode" => {
            let mut last_out = Vec::new();
            let mut total_bytes: u64 = 0;
            for _ in 0..iters {
                let mut out = Vec::with_capacity(data.len() * 4);
                let mut reader = Cursor::new(data.as_slice());
                brotli::BrotliDecompress(&mut reader, &mut out).expect("brotli decompress");
                total_bytes += out.len() as u64;
                last_out = out;
            }
            if args.len() >= 5 {
                fs::write(&args[4], &last_out).expect("write dump");
            }
            let h = fnv1a_64_update(14695981039346656037, &last_out);
            println!(
                "mode=decode iters={} total_bytes={} last_len={} fnv64={:016x}",
                iters,
                total_bytes,
                last_out.len(),
                h
            );
        }
        "batch" => {
            let count = read_u32_le(&data, 0);
            let mut packets: Vec<&[u8]> = Vec::with_capacity(count);
            let mut off = 4usize;
            for _ in 0..count {
                let plen = read_u32_le(&data, off);
                off += 4;
                packets.push(&data[off..off + plen]);
                off += plen;
            }
            let mut total_bytes: u64 = 0;
            let mut total_packets: u64 = 0;
            let mut last_hash: u64 = 14695981039346656037;
            for r in 0..iters {
                let mut h: u64 = 14695981039346656037;
                for pkt in &packets {
                    let mut out = Vec::with_capacity(pkt.len() * 4);
                    let mut reader = Cursor::new(*pkt);
                    brotli::BrotliDecompress(&mut reader, &mut out).expect("brotli decompress");
                    total_bytes += out.len() as u64;
                    total_packets += 1;
                    if r == iters - 1 {
                        h = fnv1a_64_update(h, &out);
                    }
                }
                if r == iters - 1 {
                    last_hash = h;
                }
            }
            println!(
                "mode=batch iters={} packets={} total_bytes={} fnv64={:016x}",
                iters, total_packets, total_bytes, last_hash
            );
        }
        _ => {
            eprintln!("unknown mode: {}", mode);
            std::process::exit(1);
        }
    }
}
