use std::env;
use std::fs;
use std::process;
use std::str::FromStr;

fn mix(h: i64, v: i64) -> i64 {
    ((h * 131) + v) % 1_000_000_007
}

fn hash_str(h0: i64, s: &str) -> i64 {
    let b = s.as_bytes();
    let mut h = mix(h0, b.len() as i64);
    for &c in b {
        h = mix(h, c as i64);
    }
    h
}

fn bench_headers_mt(data: &[u8]) {
    let text = std::str::from_utf8(data).unwrap_or_else(|_| process::exit(1));
    let lines: Vec<&str> = text
        .lines()
        .map(|l| l.trim_end_matches('\r'))
        .filter(|l| !l.is_empty())
        .collect();
    let mut ops: i64 = 0;
    let mut checksum: i64 = 0;
    for _ in 0..200 {
        for &ln in &lines {
            let m = mime::Mime::from_str(ln).unwrap_or_else(|_| process::exit(1));
            checksum = hash_str(checksum, m.essence_str());
            if let Some(cs) = m.get_param(mime::CHARSET) {
                checksum = hash_str(checksum, cs.as_str());
            }
            ops += 1;
        }
    }
    println!("mode=headers_mt");
    println!("ops={}", ops);
    println!("checksum={}", checksum);
}

fn canonicalize_infer(kind: infer::Type) -> &'static str {
    match kind.extension() {
        "woff2" => "font/woff2",
        "woff" => "font/woff",
        "wav" => "audio/wav",
        "flac" => "audio/flac",
        "ogg" => "application/ogg",
        "sqlite" => "application/vnd.sqlite3",
        "ico" => "image/x-icon",
        "gz" => "application/gzip",
        "zst" => "application/zstd",
        "tar" => "application/x-tar",
        _ => kind.mime_type(),
    }
}

fn bench_sniff(data: &[u8]) {
    let mut samples: Vec<&[u8]> = Vec::new();
    let mut pos = 0usize;
    while pos + 4 <= data.len() {
        let slen = u32::from_le_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]]) as usize;
        pos += 4;
        if pos + slen > data.len() {
            process::exit(1);
        }
        samples.push(&data[pos..pos + slen]);
        pos += slen;
    }
    let mut ops: i64 = 0;
    let mut checksum: i64 = 0;
    for _ in 0..1000 {
        for &s in &samples {
            let m = match infer::get(s) {
                Some(k) => canonicalize_infer(k),
                None => "application/octet-stream",
            };
            checksum = hash_str(checksum, m);
            ops += 1;
        }
    }
    println!("mode=sniff");
    println!("ops={}", ops);
    println!("checksum={}", checksum);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rust_mime_bench <mode> <corpus_path>");
        process::exit(1);
    }
    let data = fs::read(&args[2]).unwrap_or_else(|_| process::exit(1));
    match args[1].as_str() {
        "headers_mt" => bench_headers_mt(&data),
        "sniff" => bench_sniff(&data),
        other => {
            eprintln!("unknown mode: {}", other);
            process::exit(1);
        }
    }
}
