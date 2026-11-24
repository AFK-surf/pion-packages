use encoding_rs::*;
use std::env;
use std::fs;

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    h
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: encoding_bench_rs <mode> <input_file> <iters>");
        std::process::exit(1);
    }
    let mode = args[1].as_str();
    let path = args[2].as_str();
    let iters: usize = args[3].parse().expect("valid iters");
    let is_encode = matches!(mode, "enc_big5" | "enc_gb18030" | "enc_sjis" | "enc_euckr");
    let enc = match mode {
        "utf8" => UTF_8,
        "gb18030" | "enc_gb18030" => GB18030,
        "sjis" | "enc_sjis" => SHIFT_JIS,
        "enc_big5" => BIG5,
        "enc_euckr" => EUC_KR,
        _ => {
            eprintln!("unknown mode: {}", mode);
            std::process::exit(1);
        }
    };
    let raw = fs::read(path).expect("read input");

    let mut total_bytes: u64 = 0;
    let h = if is_encode {
        let text = String::from_utf8(raw).expect("valid utf8");
        let mut last_out: Vec<u8> = Vec::new();
        for _ in 0..iters {
            let (cow, _, _) = enc.encode(&text);
            total_bytes += cow.len() as u64;
            last_out = cow.into_owned();
        }
        fnv1a64(&last_out)
    } else {
        let mut last_out = String::new();
        for _ in 0..iters {
            let mut dec = enc.new_decoder_with_bom_removal();
            let cap = dec.max_utf8_buffer_length(raw.len()).unwrap_or(raw.len() * 3);
            let mut out = String::with_capacity(cap);
            let _ = dec.decode_to_string(&raw, &mut out, true);
            total_bytes += out.len() as u64;
            last_out = out;
        }
        fnv1a64(last_out.as_bytes())
    };

    println!(
        "MODE={} ITERS={} OUT_BYTES={} FNV64={}",
        mode, iters, total_bytes, h
    );
}
