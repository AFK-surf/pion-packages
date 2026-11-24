use idna::uts46::{AsciiDenyList, DnsLength, Hyphens, Uts46};
use std::env;
use std::fs;
use std::process;

fn fnv1a_bytes(mut h: u64, data: &[u8]) -> u64 {
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(1099511628211);
    }
    h ^= 255;
    h.wrapping_mul(1099511628211)
}

fn run_diff(path: &str) {
    let content = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("read {}: {}", path, e);
        process::exit(1);
    });
    let uts46 = Uts46::new();
    for line in content.lines() {
        if line.is_empty() {
            continue;
        }
        let mut parts = line.splitn(2, '\t');
        let mode = parts.next().unwrap();
        let domain = parts.next().unwrap_or("");
        let (deny_list, hyphens, dns_len) = match mode {
            "url" => (AsciiDenyList::EMPTY, Hyphens::Allow, DnsLength::Ignore),
            "strict" => (
                AsciiDenyList::STD3,
                Hyphens::CheckFirstLast,
                DnsLength::VerifyAllowRootDot,
            ),
            "strict_hyphens" => (
                AsciiDenyList::STD3,
                Hyphens::Check,
                DnsLength::VerifyAllowRootDot,
            ),
            _ => (AsciiDenyList::EMPTY, Hyphens::Allow, DnsLength::Ignore),
        };
        let a_res = uts46.to_ascii(domain.as_bytes(), deny_list, hyphens, dns_len);
        let a_str = match a_res {
            Ok(cow) => format!("OK:{}", cow),
            Err(_) => "ERR".to_string(),
        };
        let (u_cow, u_res) = uts46.to_unicode(domain.as_bytes(), deny_list, hyphens);
        let u_str = if u_res.is_ok() {
            format!("OK:{}", u_cow)
        } else {
            "ERR".to_string()
        };
        println!("{}\t{}\tA={}\tU={}", mode, domain, a_str, u_str);
    }
}

fn run_bench(path: &str, iters: usize) {
    let content = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("read {}: {}", path, e);
        process::exit(1);
    });
    let domains: Vec<&str> = content.lines().filter(|l| !l.is_empty()).collect();
    let uts46 = Uts46::new();
    let mut h: u64 = 14695981039346656037;
    let mut ok_ascii: usize = 0;
    let mut ok_uni: usize = 0;
    for _ in 0..iters {
        for &d in &domains {
            match uts46.to_ascii(
                d.as_bytes(),
                AsciiDenyList::STD3,
                Hyphens::Check,
                DnsLength::VerifyAllowRootDot,
            ) {
                Ok(cow) => {
                    ok_ascii += 1;
                    h = fnv1a_bytes(h, cow.as_bytes());
                }
                Err(_) => {
                    h = fnv1a_bytes(h, b"ERR");
                }
            }
            let (u_cow, u_res) =
                uts46.to_unicode(d.as_bytes(), AsciiDenyList::STD3, Hyphens::Check);
            if u_res.is_ok() {
                ok_uni += 1;
            }
            h = fnv1a_bytes(h, u_cow.as_bytes());
        }
    }
    println!(
        "idna_bench: domains={} iters={} ok_ascii={} ok_uni={} fnv64={}",
        domains.len(),
        iters,
        ok_ascii,
        ok_uni,
        h
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: idna_rust_bench <diff|bench> <path> [iters]");
        process::exit(2);
    }
    match args[1].as_str() {
        "diff" => run_diff(&args[2]),
        "bench" => {
            let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(100);
            run_bench(&args[2], iters);
        }
        _ => {
            eprintln!("unknown subcommand: {}", args[1]);
            process::exit(2);
        }
    }
}
