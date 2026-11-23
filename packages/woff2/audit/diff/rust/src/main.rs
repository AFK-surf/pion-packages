//! Reference harness for the `packages/woff2` red-team audit: Rust `wuff =0.2.10`.
//! Prints the same canonical line as `audit/src/main.pion` so outputs compare byte-for-byte.
//!   batch <cases.bin>      one line per `[u32 LE len][payload]` record
//!   file <in> [out]        single input
//!   bench <in> <iters>     timed loop
use std::{env, fs, panic};

fn rd16(b: &[u8], o: usize) -> usize {
    u16::from_be_bytes([b[o], b[o + 1]]) as usize
}
fn rd32(b: &[u8], o: usize) -> u32 {
    u32::from_be_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}
fn tag_str(t: u32) -> String {
    t.to_be_bytes()
        .iter()
        .map(|&c| if (33..127).contains(&c) { c as char } else { '_' })
        .collect()
}

fn canon(s: &[u8]) -> String {
    let n = s.len();
    if n < 12 {
        return format!("OK {} short", n);
    }
    let mut sum: u32 = 0;
    let mut i = 0;
    while i < n {
        let mut w: u32 = 0;
        for k in 0..4 {
            w = (w << 8) | if i + k < n { s[i + k] as u32 } else { 0 };
        }
        sum = sum.wrapping_add(w);
        i += 4;
    }
    let nt = rd16(s, 4);
    let mut out = format!("OK {} ck={}", n, if sum == 0xB1B0AFBA { "ok" } else { "bad" });
    for t in 0..nt {
        let rec = 12 + t * 16;
        if rec + 16 > n {
            out.push_str(" dirtrunc");
            return out;
        }
        let tag = rd32(s, rec);
        let off = rd32(s, rec + 8) as u64;
        let len = rd32(s, rec + 12) as u64;
        out.push_str(&format!(" {}:{}:", tag_str(tag), len));
        if off + len > n as u64 || len > i32::MAX as u64 || off > i32::MAX as u64 {
            out.push_str("oob");
        } else {
            let mut h: u64 = 14695981039346656037;
            for j in 0..len as usize {
                let v = if tag == 0x68656164 && (8..12).contains(&j) { 0 } else { s[off as usize + j] };
                h = (h ^ v as u64).wrapping_mul(1099511628211);
            }
            out.push_str(&format!("{:016x}", h));
        }
    }
    out
}

fn decode(d: &[u8]) -> Result<Vec<u8>, String> {
    let r = panic::catch_unwind(|| {
        if d.len() >= 4 && &d[0..4] == b"wOF2" {
            wuff::decompress_woff2(d)
        } else {
            wuff::decompress_woff1(d)
        }
    });
    match r {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(_)) => Err("ERR Wuff".into()),
        Err(_) => Err("PANIC".into()),
    }
}

fn line(d: &[u8]) -> String {
    match decode(d) {
        Ok(v) => canon(&v),
        Err(e) => e,
    }
}

fn main() {
    panic::set_hook(Box::new(|_| {}));
    let a: Vec<String> = env::args().collect();
    let data = fs::read(&a[2]).expect("read");
    match a[1].as_str() {
        "batch" => {
            let mut p = 0;
            let mut o = String::new();
            while p + 4 <= data.len() {
                let len = u32::from_le_bytes(data[p..p + 4].try_into().unwrap()) as usize;
                p += 4;
                o.push_str(&line(&data[p..p + len]));
                o.push('\n');
                p += len;
            }
            print!("{}", o);
        }
        "file" => {
            let r = decode(&data);
            match &r {
                Ok(v) => println!("{}", canon(v)),
                Err(e) => println!("{}", e),
            }
            if let (Some(out), Ok(v)) = (a.get(3), &r) {
                fs::write(out, v).unwrap();
            }
        }
        "bench" => {
            let iters: usize = a[3].parse().unwrap();
            let mut last = Vec::new();
            for _ in 0..iters {
                last = decode(&data).expect("decode");
            }
            println!("{}", canon(&last));
        }
        "brotli" => {
            // Brotli stage only (same slice the Pion harness feeds to `brotli::decode`).
            let iters: usize = a[3].parse().unwrap();
            let nt = rd16(&data, 12);
            let comp = rd32(&data, 20) as usize;
            let mut p = 48;
            for _ in 0..nt {
                let f = data[p];
                p += 1;
                if f & 0x3F == 0x3F {
                    p += 4;
                }
                let (idx, ver) = (f & 0x3F, f >> 6);
                let reads = if ((idx == 10 || idx == 11) && ver == 0) || (idx == 3 && ver == 1) { 2 } else { 1 };
                for _ in 0..reads {
                    while data[p] & 0x80 != 0 {
                        p += 1;
                    }
                    p += 1;
                }
            }
            let mut total = 0;
            for _ in 0..iters {
                let mut out = Vec::new();
                let mut rd = brotli_decompressor::Decompressor::new(&data[p..p + comp], 4096);
                std::io::Read::read_to_end(&mut rd, &mut out).unwrap();
                total = out.len();
            }
            println!("brotli {}", total);
        }
        _ => std::process::exit(2),
    }
}
