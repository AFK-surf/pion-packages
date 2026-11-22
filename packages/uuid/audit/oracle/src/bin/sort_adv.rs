//! Rust counterpart of `audit/bench/sort_adv`: generate the same distribution, `sort_unstable`, print hash.
//! Usage: sort_adv <kind> <n> <uuid|ulid>

#[path = "../common.rs"]
mod common;

use common::{fnv_pairs, gen_pair};
use ulid::Ulid;
use uuid::Uuid;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let kind = a[1].as_str();
    let n: u64 = a[2].parse().unwrap();
    let ulid = a.get(3).map(|s| s == "ulid").unwrap_or(false);
    let pairs: Vec<(u64, u64)> = if ulid {
        let mut v: Vec<Ulid> = (0..n)
            .map(|i| {
                let (h, l) = gen_pair(kind, i, n, 7);
                Ulid(((h as u128) << 64) | l as u128)
            })
            .collect();
        v.sort_unstable();
        v.iter().map(|u| ((u.0 >> 64) as u64, u.0 as u64)).collect()
    } else {
        let mut v: Vec<Uuid> = (0..n)
            .map(|i| {
                let (h, l) = gen_pair(kind, i, n, 7);
                Uuid::from_u64_pair(h, l)
            })
            .collect();
        v.sort_unstable();
        v.iter().map(|u| u.as_u64_pair()).collect()
    };
    println!("n={} h={:016x}", n, fnv_pairs(&pairs));
}
