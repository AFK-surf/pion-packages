//! Rust flate2 (rust_backend = miniz_oxide) reference side of the flate red-team differential harness.
//! Protocol is identical to `audit/src/main.pion` (batch / compress / file / cfile).
use flate2::read::{DeflateDecoder, MultiGzDecoder, ZlibDecoder};
use flate2::write::DeflateEncoder;
use flate2::Compression;
use std::io::{Read, Write};

fn records(b: &[u8]) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut p = 0;
    while p + 4 <= b.len() {
        let n = u32::from_le_bytes([b[p], b[p + 1], b[p + 2], b[p + 3]]) as usize;
        p += 4;
        out.push(&b[p..p + n]);
        p += n;
    }
    out
}

fn decode(op: &str, data: &[u8], limit: u64) -> Result<Vec<u8>, String> {
    let r: Box<dyn Read> = match op {
        "inflate" => Box::new(DeflateDecoder::new(data)),
        "zlib" => Box::new(ZlibDecoder::new(data)),
        _ => Box::new(MultiGzDecoder::new(data)),
    };
    let mut out = Vec::new();
    r.take(limit + 1).read_to_end(&mut out).map_err(|e| e.to_string())?;
    if out.len() as u64 > limit {
        return Err("OutputLimitExceeded".into());
    }
    Ok(out)
}

fn line(r: Result<Vec<u8>, String>) -> String {
    match r {
        Ok(o) => format!("OK {} {}", o.len(), crc32fast::hash(&o)),
        Err(e) => format!("ERR {}", e.replace(' ', "_")),
    }
}

fn compress(level: u32, data: &[u8]) -> Vec<u8> {
    let mut e = DeflateEncoder::new(Vec::new(), Compression::new(level));
    e.write_all(data).unwrap();
    e.finish().unwrap()
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a[1].as_str() {
        "batch" => {
            let data = std::fs::read(&a[3]).unwrap();
            let limit = a.get(4).map(|s| s.parse().unwrap()).unwrap_or(16777216u64);
            let mut s = String::new();
            for rec in records(&data) {
                s.push_str(&line(decode(&a[2], rec, limit)));
                s.push('\n');
            }
            print!("{s}");
        }
        "compress" => {
            let lvl: u32 = a[2].parse().unwrap();
            let data = std::fs::read(&a[3]).unwrap();
            let mut buf = Vec::new();
            for rec in records(&data) {
                let c = compress(lvl, rec);
                buf.extend_from_slice(&(c.len() as u32).to_le_bytes());
                buf.extend_from_slice(&c);
            }
            std::fs::write(&a[4], buf).unwrap();
        }
        "file" => {
            let data = std::fs::read(&a[3]).unwrap();
            let limit = a.get(4).map(|s| s.parse().unwrap()).unwrap_or(268435456u64);
            println!("{}", line(decode(&a[2], &data, limit)));
        }
        "bench" => {
            let data = std::fs::read(&a[3]).unwrap();
            let iters: usize = a[4].parse().unwrap();
            let op = a[2].as_str();
            let mut last = Vec::new();
            let mut c = crc32fast::Hasher::new();
            let mut ad = adler2::Adler32::new();
            for _ in 0..iters {
                match op {
                    "d" => {
                        let mut out = Vec::new();
                        MultiGzDecoder::new(&data[..]).read_to_end(&mut out).unwrap();
                        last = out;
                    }
                    "crc" => {
                        c.update(&data);
                        ad.write_slice(&data);
                    }
                    lvl => {
                        let mut e = flate2::write::GzEncoder::new(Vec::new(), Compression::new(lvl.parse().unwrap()));
                        e.write_all(&data).unwrap();
                        last = e.finish().unwrap();
                    }
                }
            }
            match op {
                "d" => println!("OK {} {}", last.len(), crc32fast::hash(&last)),
                "crc" => println!("OK {} {}", c.finalize(), ad.checksum()),
                _ => {
                    let mut out = Vec::new();
                    MultiGzDecoder::new(&last[..]).read_to_end(&mut out).unwrap();
                    println!("OK {} {}", out.len(), crc32fast::hash(&out));
                }
            }
        }
        "cfile" => {
            let lvl: u32 = a[2].parse().unwrap();
            let data = std::fs::read(&a[3]).unwrap();
            let c = compress(lvl, &data);
            if let Some(p) = a.get(4) {
                std::fs::write(p, &c).unwrap();
            }
            println!("OK {}", c.len());
        }
        _ => std::process::exit(2),
    }
}
