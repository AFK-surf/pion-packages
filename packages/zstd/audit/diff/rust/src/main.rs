//! RT-zstd oracle: pure safe Rust `ruzstd =0.9.0` and the official C libzstd (`zstd =0.13.3`, libzstd 1.5.7).
//!   dec <container>                     per record: `<ruzstd>\t<libzstd>`, each `OK <len> <fnv64>` or `ERR <reason>`
//!   enc <ruzstd|zstd> <level> <container> <out_container>
//!   xxh <container> <seed (i64)>        per record: twox-hash 2.1.5 XxHash64, 16 hex digits
//! A container is a sequence of `u32 LE length` + bytes records (diff/*.py).
use std::io::Write;

fn fnv64(d: &[u8]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for &b in d {
        h = (h ^ b as u64).wrapping_mul(1099511628211);
    }
    h
}

fn records(data: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut p = 0usize;
    while p + 4 <= data.len() {
        let n = u32::from_le_bytes([data[p], data[p + 1], data[p + 2], data[p + 3]]) as usize;
        p += 4;
        if p + n > data.len() {
            break;
        }
        out.push(&data[p..p + n]);
        p += n;
    }
    out
}

fn line(r: Result<Vec<u8>, String>) -> String {
    match r {
        Ok(v) => format!("OK {} {:016x}", v.len(), fnv64(&v)),
        Err(e) => {
            let e: String = e.chars().filter(|c| *c != '\t' && *c != '\n').take(120).collect();
            format!("ERR {}", e)
        }
    }
}

fn ruzstd_dec(input: &[u8]) -> Result<Vec<u8>, String> {
    let mut last = String::new();
    for cap in [1usize << 20, 1 << 27] {
        let mut out = Vec::with_capacity(cap);
        let mut d = ruzstd::decoding::FrameDecoder::new();
        match d.decode_all_to_vec(input, &mut out) {
            Ok(()) => return Ok(out),
            Err(e) => {
                last = format!("{:?}", e);
                if !last.contains("TargetTooSmall") {
                    return Err(last);
                }
            }
        }
    }
    Err(last)
}

fn libzstd_dec(input: &[u8]) -> Result<Vec<u8>, String> {
    zstd::stream::decode_all(input).map_err(|e| e.to_string())
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let out = std::io::stdout();
    let mut out = out.lock();
    match a.get(1).map(|s| s.as_str()) {
        Some("dec") => {
            let data = std::fs::read(&a[2]).expect("read");
            for r in records(&data) {
                let x = std::panic::catch_unwind(|| ruzstd_dec(r)).unwrap_or_else(|_| Err("PANIC".into()));
                let y = libzstd_dec(r);
                writeln!(out, "{}\t{}", line(x), line(y)).unwrap();
            }
        }
        Some("enc") => {
            let lvl: i32 = a[3].parse().unwrap();
            let data = std::fs::read(&a[4]).expect("read");
            let mut buf = Vec::new();
            for r in records(&data) {
                let c = if a[2] == "ruzstd" {
                    let l = match lvl {
                        0 => ruzstd::encoding::CompressionLevel::Uncompressed,
                        1 => ruzstd::encoding::CompressionLevel::Fastest,
                        2 => ruzstd::encoding::CompressionLevel::Default,
                        3 => ruzstd::encoding::CompressionLevel::Better,
                        _ => ruzstd::encoding::CompressionLevel::Best,
                    };
                    ruzstd::encoding::compress_to_vec(r, l)
                } else {
                    zstd::bulk::compress(r, lvl).unwrap()
                };
                buf.extend_from_slice(&(c.len() as u32).to_le_bytes());
                buf.extend_from_slice(&c);
            }
            std::fs::write(&a[5], buf).unwrap();
        }
        Some("xxh") => {
            let data = std::fs::read(&a[2]).expect("read");
            let seed: i64 = a[3].parse().unwrap();
            for r in records(&data) {
                writeln!(out, "{:016x}", twox_hash::XxHash64::oneshot(seed as u64, r)).unwrap();
            }
        }
        _ => {
            eprintln!("usage: zstd_audit_oracle dec <container> | enc <ruzstd|zstd> <level> <in> <out>");
            std::process::exit(2);
        }
    }
}
