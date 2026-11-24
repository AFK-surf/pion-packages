use sfv::{Dictionary, FieldType, Item, List, Parser};
use std::env;
use std::fs;
use std::io::{self, Write};
use std::process;

fn decode_hex(s: &str) -> Vec<u8> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i + 1 < bytes.len() {
        let hi = (bytes[i] as char).to_digit(16).unwrap_or(0) as u8;
        let lo = (bytes[i + 1] as char).to_digit(16).unwrap_or(0) as u8;
        out.push((hi << 4) | lo);
        i += 2;
    }
    out
}

fn roundtrip_one(kind: &str, raw: &[u8]) -> Result<String, ()> {
    match kind {
        "item" => {
            let it: Item = Parser::new(raw).parse().map_err(|_| ())?;
            Ok(it.serialize())
        }
        "list" => {
            let l: List = Parser::new(raw).parse().map_err(|_| ())?;
            Ok(l.serialize().unwrap_or_default())
        }
        _ => {
            let d: Dictionary = Parser::new(raw).parse().map_err(|_| ())?;
            Ok(d.serialize().unwrap_or_default())
        }
    }
}

fn fnv1a_32_update(mut h: u32, bytes: &[u8]) -> u32 {
    for &b in bytes {
        h ^= b as u32;
        h = h.wrapping_mul(16777619u32);
    }
    h
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: sfv-bench-rust <bench|diff> <file> [iters]");
        process::exit(1);
    }
    let mode = &args[1];
    let path = &args[2];
    let data = fs::read(path).unwrap_or_else(|e| {
        eprintln!("failed to read {}: {}", path, e);
        process::exit(1);
    });

    if mode == "diff" {
        let mut stdout = io::BufWriter::new(io::stdout().lock());
        for line in data.split(|&b| b == b'\n') {
            if line.is_empty() {
                continue;
            }
            let text = String::from_utf8_lossy(line);
            let mut parts = text.splitn(4, '\t');
            let kind = match parts.next() {
                Some(s) => s,
                None => continue,
            };
            let flags = match parts.next() {
                Some(s) => s,
                None => continue,
            };
            let raw_hex = match parts.next() {
                Some(s) => s,
                None => continue,
            };
            let name = match parts.next() {
                Some(s) => s,
                None => continue,
            };
            let raw = decode_hex(raw_hex);
            match roundtrip_one(kind, &raw) {
                Ok(canon) => {
                    writeln!(stdout, "{}|{}\tOK\t{}", flags, name, canon).unwrap();
                }
                Err(()) => {
                    writeln!(stdout, "{}|{}\tERR", flags, name).unwrap();
                }
            }
        }
        stdout.flush().unwrap();
        return;
    }

    let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1000);
    let mut cases: Vec<(String, Vec<u8>)> = Vec::new();
    for line in data.split(|&b| b == b'\n') {
        if line.is_empty() {
            continue;
        }
        if let Some(tab) = line.iter().position(|&b| b == b'\t') {
            let kind = String::from_utf8_lossy(&line[..tab]).into_owned();
            let raw = line[tab + 1..].to_vec();
            cases.push((kind, raw));
        }
    }

    let mut h: u32 = 2166136261u32;
    let mut total_bytes: i64 = 0;
    let mut ok_count: i64 = 0;
    for it in 0..iters {
        for (idx, (kind, raw)) in cases.iter().enumerate() {
            match roundtrip_one(kind, raw) {
                Ok(canon) => {
                    ok_count += 1;
                    total_bytes += canon.len() as i64;
                    if it == 0 {
                        h = fnv1a_32_update(h, canon.as_bytes());
                        h = fnv1a_32_update(h, b"\n");
                    }
                }
                Err(()) => {
                    eprintln!("ERR on case {}", idx);
                    process::exit(2);
                }
            }
        }
    }
    println!(
        "cases={} iters={} ok={} out_bytes={} fnv32={}",
        cases.len(),
        iters,
        ok_count,
        total_bytes,
        h
    );
}
