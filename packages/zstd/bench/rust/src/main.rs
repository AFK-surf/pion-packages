use std::env;
use std::fs;
use std::io::Read;

fn fnv1a_64(data: &[u8]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for &b in data {
        h = (h ^ (b as u64)).wrapping_mul(1099511628211);
    }
    h
}

fn decompress_ruzstd(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let mut slice = data;
    while !slice.is_empty() {
        // Handle skippable frames before handing to FrameDecoder
        if slice.len() >= 8 {
            let magic = u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]);
            if (0x184D2A50..=0x184D2A5F).contains(&magic) {
                let sz = u32::from_le_bytes([slice[4], slice[5], slice[6], slice[7]]) as usize;
                if 8 + sz > slice.len() {
                    return Err("truncated skippable frame".to_string());
                }
                slice = &slice[8 + sz..];
                continue;
            }
        }
        let mut decoder = ruzstd::StreamingDecoder::new(&mut slice)
            .map_err(|e| format!("ruzstd init: {e:?}"))?;
        let mut frame_buf = Vec::new();
        decoder
            .read_to_end(&mut frame_buf)
            .map_err(|e| format!("ruzstd read: {e}"))?;
        out.extend_from_slice(&frame_buf);
    }
    Ok(out)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: zstd-bench-rust <ruzstd_dec|zstd_dec|zstd_comp> ...");
        std::process::exit(1);
    }
    let mode = args[1].as_str();
    match mode {
        "ruzstd_dec" => {
            let path = &args[2];
            let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1);
            let data = fs::read(path).expect("read input");
            let mut last = Vec::new();
            let mut total: u64 = 0;
            for _ in 0..iters {
                let dec = decompress_ruzstd(&data).expect("ruzstd decompress");
                total += dec.len() as u64;
                last = dec;
            }
            if let Some(dump) = args.get(4) {
                fs::write(dump, &last).expect("write dump");
            }
            println!(
                "mode=decompress iters={} out_len={} total_out={} fnv64={:016x}",
                iters,
                last.len(),
                total,
                fnv1a_64(&last)
            );
        }
        "zstd_dec" => {
            let path = &args[2];
            let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1);
            let data = fs::read(path).expect("read input");
            let mut last = Vec::new();
            let mut total: u64 = 0;
            for _ in 0..iters {
                let dec = zstd::stream::decode_all(&data[..]).expect("zstd decompress");
                total += dec.len() as u64;
                last = dec;
            }
            if let Some(dump) = args.get(4) {
                fs::write(dump, &last).expect("write dump");
            }
            println!(
                "mode=decompress iters={} out_len={} total_out={} fnv64={:016x}",
                iters,
                last.len(),
                total,
                fnv1a_64(&last)
            );
        }
        "zstd_comp" => {
            let level: i32 = args[2].parse().expect("level");
            let path = &args[3];
            let iters: usize = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(1);
            let data = fs::read(path).expect("read input");
            let mut last = Vec::new();
            for _ in 0..iters {
                last = zstd::stream::encode_all(&data[..], level).expect("zstd compress");
            }
            if let Some(dump) = args.get(5) {
                fs::write(dump, &last).expect("write dump");
            }
            println!(
                "mode=compress level={} iters={} in_len={} in_fnv64={:016x}",
                level,
                iters,
                data.len(),
                fnv1a_64(&data)
            );
        }
        _ => {
            eprintln!("unknown mode: {mode}");
            std::process::exit(1);
        }
    }
}
