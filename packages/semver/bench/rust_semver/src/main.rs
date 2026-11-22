use semver::{Version, VersionReq};
use std::env;
use std::fs;
use std::process;

fn read_lines(path: &str) -> Vec<String> {
    let raw = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("error: failed to read {}: {}", path, e);
        process::exit(1);
    });
    raw.split('\n')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect()
}

fn fnv_str(mut h: u64, s: &str) -> u64 {
    const PRIME: u64 = 1099511628211;
    for &b in s.as_bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(PRIME);
    }
    h
}

fn run_version_bench(versions_file: &str, iters: usize) {
    let lines = read_lines(versions_file);
    let n = lines.len();
    let mut parsed_total: u64 = 0;
    let mut formatted_bytes: u64 = 0;
    let mut checksum: u64 = 14695981039346656037;
    let mut first_s = String::new();
    let mut mid_s = String::new();
    let mut last_s = String::new();

    for it in 0..iters {
        let mut parsed = Vec::with_capacity(n);
        for line in &lines {
            if let Ok(v) = Version::parse(line) {
                parsed.push(v);
                parsed_total += 1;
            }
        }
        parsed.sort();
        let m = parsed.len();
        for (k, v) in parsed.iter().enumerate() {
            let s = v.to_string();
            formatted_bytes += s.len() as u64;
            checksum = fnv_str(checksum, &s);
            if it == iters - 1 {
                if k == 0 {
                    first_s = s;
                } else if k == m / 2 {
                    mid_s = s;
                } else if k == m - 1 {
                    last_s = s;
                }
            }
        }
    }

    println!("bench=version_pipeline");
    println!("versions={}", n);
    println!("iters={}", iters);
    println!("parsed={}", parsed_total);
    println!("formatted_bytes={}", formatted_bytes);
    println!("first={}", first_s);
    println!("mid={}", mid_s);
    println!("last={}", last_s);
    println!("checksum={}", checksum);
}

fn run_req_bench(reqs_file: &str, versions_file: &str, ver_limit: usize, iters: usize) {
    let req_lines = read_lines(reqs_file);
    let ver_lines = read_lines(versions_file);
    let nr = req_lines.len();
    let nv = ver_limit.min(ver_lines.len());

    let mut total_checks: u64 = 0;
    let mut matched: u64 = 0;
    let mut checksum: u64 = 14695981039346656037;
    const PRIME: u64 = 1099511628211;

    for _ in 0..iters {
        let mut reqs = Vec::with_capacity(nr);
        for line in &req_lines {
            if let Ok(r) = VersionReq::parse(line) {
                reqs.push(r);
            }
        }
        let mut vers = Vec::with_capacity(nv);
        for line in &ver_lines[..nv] {
            if let Ok(v) = Version::parse(line) {
                vers.push(v);
            }
        }
        for (ri, req) in reqs.iter().enumerate() {
            for (vi, ver) in vers.iter().enumerate() {
                total_checks += 1;
                if req.matches(ver) {
                    matched += 1;
                    let tag = ((ri + 1) * 131 + (vi + 1)) as u64;
                    checksum = (checksum ^ tag).wrapping_mul(PRIME);
                }
            }
        }
    }

    println!("bench=req_matrix");
    println!("reqs={}", nr);
    println!("versions={}", nv);
    println!("iters={}", iters);
    println!("total_checks={}", total_checks);
    println!("matched={}", matched);
    println!("checksum={}", checksum);
}

fn run_req32_bench(reqs_file: &str, ver_text: &str, iters: usize) {
    let lines = read_lines(reqs_file);
    let ver = Version::parse(ver_text).unwrap_or_else(|_| Version::new(1, 5, 5));
    let mut ok: u64 = 0;
    let mut matched: u64 = 0;
    let mut bytes: u64 = 0;
    for _ in 0..iters {
        for line in &lines {
            if let Ok(r) = VersionReq::parse(line) {
                ok += 1;
                if r.matches(&ver) {
                    matched += 1;
                }
                bytes += r.to_string().len() as u64;
            }
        }
    }
    println!("bench=req32");
    println!("lines={}", lines.len());
    println!("iters={}", iters);
    println!("ok={}", ok);
    println!("matched={}", matched);
    println!("bytes={}", bytes);
}

fn run_dirty_bench(dirty_file: &str, iters: usize) {
    let lines = read_lines(dirty_file);
    let mut ver_err: u64 = 0;
    let mut req_err: u64 = 0;
    let mut err_bytes: u64 = 0;
    for _ in 0..iters {
        for line in &lines {
            if let Err(e) = Version::parse(line) {
                ver_err += 1;
                err_bytes += e.to_string().len() as u64;
            }
            if let Err(e) = VersionReq::parse(line) {
                req_err += 1;
                err_bytes += e.to_string().len() as u64;
            }
        }
    }
    println!("bench=dirty_reject");
    println!("lines={}", lines.len());
    println!("iters={}", iters);
    println!("ver_err={}", ver_err);
    println!("req_err={}", req_err);
    println!("err_bytes={}", err_bytes);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: semver-bench-rust <version|req|req32|dirty> ...");
        process::exit(1);
    }
    match args[1].as_str() {
        "version" => {
            let versions_file = args
                .get(2)
                .map(|s| s.as_str())
                .unwrap_or("/tmp/pion-semver-bench/versions_20k.txt");
            let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(20);
            run_version_bench(versions_file, iters);
        }
        "req" => {
            let reqs_file = args
                .get(2)
                .map(|s| s.as_str())
                .unwrap_or("/tmp/pion-semver-bench/reqs_2k.txt");
            let versions_file = args
                .get(3)
                .map(|s| s.as_str())
                .unwrap_or("/tmp/pion-semver-bench/versions_20k.txt");
            let ver_limit: usize = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(500);
            let iters: usize = args.get(5).and_then(|s| s.parse().ok()).unwrap_or(5);
            run_req_bench(reqs_file, versions_file, ver_limit, iters);
        }
        "req32" => {
            let reqs_file = args
                .get(2)
                .map(|s| s.as_str())
                .unwrap_or("/tmp/pion-semver-bench/req32_20k.txt");
            let ver_text = args.get(3).map(|s| s.as_str()).unwrap_or("1.5.5");
            let iters: usize = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(3);
            run_req32_bench(reqs_file, ver_text, iters);
        }
        "dirty" => {
            let dirty_file = args
                .get(2)
                .map(|s| s.as_str())
                .unwrap_or("/tmp/pion-semver-bench/dirty_100k.txt");
            let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(5);
            run_dirty_bench(dirty_file, iters);
        }
        other => {
            eprintln!("unknown mode: {}", other);
            process::exit(1);
        }
    }
}
