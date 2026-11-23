//! Red-team reference harness for packages/brotli: Rust `brotli-decompressor 4.0.3` (the decoder inside `brotli 7.0.0`).
//! Same CLI / output format as `diff/c/c_audit.c`:
//!   batch <cases.bin> <limit>  -> OK <len> <fnv64> | TRAIL <len> <fnv64> <nbytes> | ERR <code> | PANIC
//!   file <in> <limit>
//! Note: `BrotliState::new` enables Brotli *large-window* (non-RFC 7932) streams by default.
use alloc_stdlib::StandardAlloc;
use brotli_decompressor::{BrotliDecompressStream, BrotliResult, BrotliState};
use std::io::Write;

fn fnv(d: &[u8]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for &b in d {
        h = (h ^ b as u64).wrapping_mul(1099511628211);
    }
    h
}

fn decode_one(input: &[u8], limit: usize) -> String {
    let mut s = BrotliState::new(StandardAlloc::default(), StandardAlloc::default(), StandardAlloc::default());
    let mut out: Vec<u8> = Vec::new();
    let mut buf = vec![0u8; 1 << 16];
    let mut avail_in = input.len();
    let mut in_off = 0usize;
    let mut total = 0usize;
    loop {
        let mut avail_out = buf.len();
        let mut out_off = 0usize;
        let r = BrotliDecompressStream(&mut avail_in, &mut in_off, input, &mut avail_out, &mut out_off, &mut buf, &mut total, &mut s);
        out.extend_from_slice(&buf[..out_off]);
        if out.len() > limit {
            return "ERR LIMIT".to_string();
        }
        match r {
            BrotliResult::NeedsMoreOutput => continue,
            BrotliResult::ResultSuccess => {
                return if avail_in > 0 {
                    format!("TRAIL {} {} {}", out.len(), fnv(&out), avail_in)
                } else {
                    format!("OK {} {}", out.len(), fnv(&out))
                };
            }
            BrotliResult::NeedsMoreInput => return "ERR EOF".to_string(),
            BrotliResult::ResultFailure => return format!("ERR {:?}", s.error_code),
        }
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let data = std::fs::read(&a[2]).expect("read");
    let limit: usize = a.get(3).map(|x| x.parse().unwrap()).unwrap_or(16 << 20);
    std::panic::set_hook(Box::new(|_| {}));
    let mut so = std::io::BufWriter::new(std::io::stdout());
    if a[1] == "file" {
        writeln!(so, "{}", decode_one(&data, limit)).unwrap();
        return;
    }
    let mut p = 0usize;
    while p + 4 <= data.len() {
        let l = u32::from_le_bytes([data[p], data[p + 1], data[p + 2], data[p + 3]]) as usize;
        p += 4;
        let rec = &data[p..p + l];
        p += l;
        let line = std::panic::catch_unwind(|| decode_one(rec, limit)).unwrap_or_else(|_| "PANIC".to_string());
        writeln!(so, "{}", line).unwrap();
    }
}
