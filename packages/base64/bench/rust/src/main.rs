//! Head-to-head benchmark for packages/base64: Rust `base64` 0.22.1
//! (STANDARD / URL_SAFE_NO_PAD), `hex` 0.4.3 and `data-encoding` 2.11.1
//! (BASE32). Same modes, input and stdout as bench/pion_bench.
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;

fn gen(n: usize) -> Vec<u8> {
    let mut out = vec![0u8; n];
    let mut x: u32 = 0x9E37_79B9;
    for b in out.iter_mut() {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        *b = x as u8;
    }
    out
}

fn fnv1a(b: &[u8]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for &c in b {
        h = (h ^ c as u64).wrapping_mul(1099511628211);
    }
    h
}

fn encode(mode: &str, data: &[u8]) -> String {
    match mode {
        "b64_encode" | "b64_decode" => STANDARD.encode(data),
        "url_encode" | "url_decode" => URL_SAFE_NO_PAD.encode(data),
        "b32_encode" | "b32_decode" => data_encoding::BASE32.encode(data),
        _ => hex::encode(data),
    }
}

fn decode(mode: &str, s: &str) -> Result<Vec<u8>, String> {
    match mode {
        "b64_decode" => STANDARD.decode(s).map_err(|e| e.to_string()),
        "url_decode" => URL_SAFE_NO_PAD.decode(s).map_err(|e| e.to_string()),
        "b32_decode" => data_encoding::BASE32
            .decode(s.as_bytes())
            .map_err(|e| e.to_string()),
        _ => hex::decode(s).map_err(|e| e.to_string()),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        println!("usage: base64_bench <mode> [size_bytes] [rounds]");
        std::process::exit(2);
    }
    let mode = args[1].as_str();
    let size: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(4194304);
    let rounds: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(16);
    let data = gen(size);
    let (mut sample, mut out_len) = (0usize, 0usize);
    let mut last: Vec<u8> = Vec::new();
    match mode {
        "b64_encode" | "url_encode" | "b32_encode" | "hex_encode" => {
            for r in 0..rounds {
                let s = encode(mode, &data);
                out_len = s.len();
                sample += s.as_bytes()[r * 7919 % out_len] as usize;
                if r == rounds - 1 {
                    last = s.into_bytes();
                }
            }
        }
        _ => {
            let text = encode(mode, &data);
            for r in 0..rounds {
                match decode(mode, &text) {
                    Ok(b) => {
                        out_len = b.len();
                        sample += b[r * 7919 % out_len] as usize;
                        if r == rounds - 1 {
                            last = b;
                        }
                    }
                    Err(e) => {
                        println!("decode error: {e}");
                        std::process::exit(1);
                    }
                }
            }
        }
    }
    println!(
        "mode={mode}\ninput_bytes={size}\nrounds={rounds}\noutput_bytes={out_len}\nsample={sample}\nfnv1a64={}",
        fnv1a(&last)
    );
}
