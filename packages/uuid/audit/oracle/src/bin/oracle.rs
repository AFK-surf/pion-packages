//! Rust reference oracle (uuid =1.29.3, ulid =1.2.1) for the red-team differential.
//!
//! Reads a tab-separated corpus (one case per line, see `audit/gen_corpus.py`) and
//! prints `<line_no>\t<op>\t<result>` for every case. The Pion driver
//! (`audit/driver`) prints the same format; `audit/diff.py` compares them.

#[path = "../common.rs"]
mod common;

use common::{fnv_pairs, gen_pair, splitmix64};
use std::io::Write;
use ulid::Ulid;
use uuid::{Builder, Uuid, Variant, Version};

fn unhex(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    (0..b.len() / 2)
        .map(|i| u8::from_str_radix(std::str::from_utf8(&b[2 * i..2 * i + 2]).unwrap(), 16).unwrap())
        .collect()
}

fn arr16(s: &str) -> [u8; 16] {
    let v = unhex(s);
    let mut a = [0u8; 16];
    a.copy_from_slice(&v);
    a
}

fn gen_name(len: usize, seed: u64) -> Vec<u8> {
    (0..len as u64)
        .map(|k| (splitmix64(seed.wrapping_mul(7919).wrapping_add(k)) & 0xFF) as u8)
        .collect()
}

fn hyph(u: &Uuid) -> String {
    u.hyphenated().to_string()
}

fn ver_name(v: Option<Version>) -> &'static str {
    match v {
        Some(Version::Nil) => "Nil",
        Some(Version::Mac) => "Mac",
        Some(Version::Dce) => "Dce",
        Some(Version::Md5) => "Md5",
        Some(Version::Random) => "Random",
        Some(Version::Sha1) => "Sha1",
        Some(Version::SortMac) => "SortMac",
        Some(Version::SortRand) => "SortRand",
        Some(Version::Custom) => "Custom",
        Some(Version::Max) => "Max",
        Some(_) => "Other",
        None => "none",
    }
}

fn var_name(v: Variant) -> &'static str {
    match v {
        Variant::NCS => "Ncs",
        Variant::RFC4122 => "Rfc4122",
        Variant::Microsoft => "Microsoft",
        Variant::Future => "Future",
        _ => "Other",
    }
}

fn sorted_hash(kind: &str, n: u64, seed: u64, ulid: bool) -> String {
    let mut pairs: Vec<(u64, u64)> = Vec::with_capacity(n as usize);
    if ulid {
        let mut v: Vec<Ulid> = (0..n)
            .map(|i| {
                let (h, l) = gen_pair(kind, i, n, seed);
                Ulid(((h as u128) << 64) | l as u128)
            })
            .collect();
        v.sort_unstable();
        for u in v {
            pairs.push(((u.0 >> 64) as u64, u.0 as u64));
        }
    } else {
        let mut v: Vec<Uuid> = (0..n)
            .map(|i| {
                let (h, l) = gen_pair(kind, i, n, seed);
                Uuid::from_u64_pair(h, l)
            })
            .collect();
        v.sort_unstable();
        for u in v {
            pairs.push(u.as_u64_pair());
        }
    }
    format!("n={} h={:016x}", n, fnv_pairs(&pairs))
}

fn lines_uuid(content: &[u8]) -> String {
    let Ok(s) = std::str::from_utf8(content) else { return "err".into() };
    let mut pairs = Vec::new();
    for line in s.lines() {
        if line.is_empty() {
            continue;
        }
        match Uuid::parse_str(line) {
            Ok(u) => pairs.push(u.as_u64_pair()),
            Err(_) => return "err".into(),
        }
    }
    format!("ok n={} h={:016x}", pairs.len(), fnv_pairs(&pairs))
}

fn lines_ulid(content: &[u8]) -> String {
    let Ok(s) = std::str::from_utf8(content) else { return "err".into() };
    let mut pairs = Vec::new();
    for line in s.lines() {
        if line.is_empty() {
            continue;
        }
        match Ulid::from_string(line) {
            Ok(u) => pairs.push(((u.0 >> 64) as u64, u.0 as u64)),
            Err(_) => return "err".into(),
        }
    }
    format!("ok n={} h={:016x}", pairs.len(), fnv_pairs(&pairs))
}

fn run(op: &str, a: &[&str]) -> String {
    match op {
        "uparse" => match Uuid::try_parse_ascii(&unhex(a[0])) {
            Ok(u) => format!("ok {}", hyph(&u)),
            Err(_) => "err".into(),
        },
        "v3" => hyph(&Uuid::new_v3(&Uuid::from_bytes(arr16(a[0])), &unhex(a[1]))),
        "v5" => hyph(&Uuid::new_v5(&Uuid::from_bytes(arr16(a[0])), &unhex(a[1]))),
        "v3len" | "v5len" => {
            let ns = Uuid::from_bytes(arr16(a[0]));
            let name = gen_name(a[1].parse().unwrap(), a[2].parse().unwrap());
            if op == "v3len" {
                hyph(&Uuid::new_v3(&ns, &name))
            } else {
                hyph(&Uuid::new_v5(&ns, &name))
            }
        }
        "v7" => {
            let ts: u64 = a[0].parse().unwrap();
            let r = unhex(a[1]);
            let mut r10 = [0u8; 10];
            r10.copy_from_slice(&r);
            hyph(&Builder::from_unix_timestamp_millis(ts, &r10).into_uuid())
        }
        "v1" | "v6" => {
            let ticks: u64 = a[0].parse().unwrap();
            let cs: u16 = a[1].parse().unwrap();
            let n = unhex(a[2]);
            let mut node = [0u8; 6];
            node.copy_from_slice(&n);
            let b = if op == "v1" {
                Builder::from_gregorian_timestamp(ticks, cs, &node)
            } else {
                Builder::from_sorted_gregorian_timestamp(ticks, cs, &node)
            };
            hyph(&b.into_uuid())
        }
        "v4" => hyph(&Builder::from_random_bytes(arr16(a[0])).into_uuid()),
        "v8" => hyph(&Builder::from_custom_bytes(arr16(a[0])).into_uuid()),
        "uinfo" => {
            let u = Uuid::from_bytes(arr16(a[0]));
            let ts = match u.get_timestamp() {
                Some(t) => {
                    let (s, ns) = t.to_unix();
                    format!("{}", s * 1000 + (ns as u64) / 1_000_000)
                }
                None => "none".into(),
            };
            format!(
                "vnum={} var={} ver={} ts={}",
                u.get_version_num(),
                var_name(u.get_variant()),
                ver_name(u.get_version()),
                ts
            )
        }
        "ulparse" => {
            let b = unhex(a[0]);
            match std::str::from_utf8(&b).ok().map(Ulid::from_string) {
                Some(Ok(u)) => format!("ok {}", u),
                _ => "err".into(),
            }
        }
        "ulfmt" => Ulid(u128::from_be_bytes(arr16(a[0]))).to_string(),
        "ulinc" => match Ulid(u128::from_be_bytes(arr16(a[0]))).increment() {
            Some(u) => format!("ok {}", u),
            None => "err".into(),
        },
        "ulparts" => {
            let ts: u64 = a[0].parse().unwrap();
            let mut r = [0u8; 16];
            r[6..].copy_from_slice(&unhex(a[1]));
            format!("ok {}", Ulid::from_parts(ts, u128::from_be_bytes(r)))
        }
        "sort_uuid" | "sort_raw" | "sort_fixed" => {
            sorted_hash(a[0], a[1].parse().unwrap(), a[2].parse().unwrap(), false)
        }
        "sort_ulid" => sorted_hash(a[0], a[1].parse().unwrap(), a[2].parse().unwrap(), true),
        "lines" | "lines_fixed" => lines_uuid(&unhex(a[0])),
        "ullines" | "ullines_fixed" => lines_ulid(&unhex(a[0])),
        _ => format!("unknown-op {op}"),
    }
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: oracle <corpus.tsv>");
    let content = std::fs::read_to_string(path).expect("read corpus");
    let out = std::io::stdout();
    let mut out = std::io::BufWriter::new(out.lock());
    for (no, line) in content.lines().enumerate() {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts: Vec<&str> = line.split('\t').collect();
        let res = run(parts[0], &parts[1..]);
        writeln!(out, "{}\t{}\t{}", no + 1, parts[0], res).unwrap();
    }
}
