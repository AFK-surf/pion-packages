use rust_decimal::Decimal;
use std::env;
use std::fs;
use std::str::FromStr;

#[inline(always)]
fn lo64(d: Decimal) -> u64 {
    let b = d.serialize();
    u64::from_le_bytes([b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11]])
}

fn main() {
    let path = env::args()
        .nth(1)
        .unwrap_or_else(|| "/tmp/pion-decimal-bench/decimals_50k.txt".to_string());
    let content = fs::read_to_string(&path).expect("failed to read input");
    let base: Vec<Decimal> = content
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| Decimal::from_str(l).expect("parse failed"))
        .collect();
    let n = base.len();
    let mut work = base.clone();

    let mut checksum: u64 = 14695981039346656037;
    let mut last_sum = Decimal::ZERO;
    let mut last_min = Decimal::ZERO;
    let mut last_med = Decimal::ZERO;
    let mut last_max = Decimal::ZERO;

    for _round in 0..10 {
        work.copy_from_slice(&base);
        work.sort_unstable();
        let mut sum = Decimal::ZERO;
        for &d in &work {
            let r = d.round_dp(2);
            sum = sum.checked_add(r).unwrap();
            checksum = (checksum ^ lo64(r)).wrapping_mul(1099511628211);
        }
        last_sum = sum;
        last_min = work[0];
        last_med = work[n / 2];
        last_max = work[n - 1];
    }

    println!("ops={}", n * 10);
    println!("min={last_min}");
    println!("median={last_med}");
    println!("max={last_max}");
    println!("sum_rounded={last_sum}");
    println!("checksum={checksum}");
}
