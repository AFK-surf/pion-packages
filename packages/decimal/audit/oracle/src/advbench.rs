//! Adversarial head-to-head workloads, Rust `rust_decimal =1.37.2` side.
//! Mirror of ../../advbench/src/main.pion: identical operand streams and byte-identical stdout.
//!
//!   rust_advbench sort <file>        parse + Vec::sort_unstable (+ checksum of the sorted column)
//!   rust_advbench mul96 <n>          full-width 96-bit x 96-bit checked_mul (mixed scales)
//!   rust_advbench div <n>            checked_div with 32/64/96-bit divisors (mixed scales)
//!   rust_advbench sci <file> <r>     Decimal::from_scientific over every line, r rounds
//!   rust_advbench sqrt <n>           MathematicalOps::sqrt on random positive decimals
use rust_decimal::prelude::*;
use std::str::FromStr;

struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0 ^ (self.0 >> 29)
    }
    /// Random decimal whose mantissa has `width` (32/64/96) significant bits at most.
    fn dec(&mut self, width: u32) -> Decimal {
        let a = self.next();
        let b = self.next();
        let lo = a as u32;
        let mid = if width > 32 { (a >> 32) as u32 } else { 0 };
        let hi = if width > 64 { (b >> 32) as u32 } else { 0 };
        let scale = (b % 29) as u32;
        let zero = (lo | mid | hi) == 0;
        Decimal::from_parts(lo, mid, hi, !zero && (b & 1) == 1, scale)
    }
}

fn fnv(h: u64, v: u64) -> u64 {
    (h ^ v).wrapping_mul(1099511628211)
}

fn mix(h: u64, r: Option<Decimal>) -> u64 {
    match r {
        Some(d) => {
            let n = d.normalize();
            let b = n.serialize();
            let w = |i: usize| u32::from_le_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]]) as u64;
            fnv(fnv(fnv(fnv(h, w(4)), w(8)), w(12)), w(0))
        }
        None => fnv(h, 0xFFFF_FFFF),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut h: u64 = 14695981039346656037;
    let mut rng = Lcg(0x5EED_1372);
    match args[1].as_str() {
        "sort" => {
            let text = std::fs::read_to_string(&args[2]).unwrap();
            let mut v: Vec<Decimal> = text.lines().map(|l| Decimal::from_str(l).unwrap()).collect();
            v.sort_unstable();
            for d in &v {
                h = mix(h, Some(*d));
            }
            println!("n={} min={} median={} max={}", v.len(), v[0], v[v.len() / 2], v[v.len() - 1]);
        }
        "mul96" => {
            let n: u64 = args[2].parse().unwrap();
            for _ in 0..n {
                let a = rng.dec(96);
                let b = rng.dec(96);
                h = mix(h, a.checked_mul(b));
            }
        }
        "div" => {
            let n: u64 = args[2].parse().unwrap();
            for i in 0..n {
                let a = rng.dec(96);
                let b = rng.dec([32, 64, 96][(i % 3) as usize]);
                h = mix(h, a.checked_div(b));
            }
        }
        "sci" => {
            let text = std::fs::read_to_string(&args[2]).unwrap();
            let rounds: u32 = args[3].parse().unwrap();
            let lines: Vec<&str> = text.lines().collect();
            for _ in 0..rounds {
                for l in &lines {
                    h = mix(h, Decimal::from_scientific(l).ok());
                }
            }
        }
        "sqrt" => {
            let n: u64 = args[2].parse().unwrap();
            for _ in 0..n {
                let a = rng.dec(96).abs();
                h = mix(h, a.sqrt());
            }
        }
        m => panic!("unknown mode {}", m),
    }
    println!("fnv1a={}", h);
}
