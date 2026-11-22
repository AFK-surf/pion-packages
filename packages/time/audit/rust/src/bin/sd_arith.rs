//! W5: SignedDuration checked add/sub/mul/div + Timestamp checked_add/duration_since.
use jiff::{SignedDuration, Timestamp};
fn main() {
    let ops: i64 = 5_000_000;
    let base = Timestamp::new(1_700_000_000, 123_456_789).unwrap();
    let (mut acc_s, mut acc_n) = (0i64, 0i64);
    for i in 0..ops {
        let a = SignedDuration::new((i % 100_000) - 50_000, ((i * 7919) % 1_000_000_000 - 500_000_000) as i32);
        let b = SignedDuration::from_millis(i % 86_400_000);
        let c = a.checked_add(b).unwrap();
        let d = c.checked_mul(3).unwrap();
        let e = d.checked_div(7).unwrap();
        let f = e.checked_sub(a).unwrap();
        let t = base.checked_add(f).unwrap();
        let g = t.duration_since(base);
        acc_s += g.as_secs();
        acc_n += g.subsec_nanos() as i64;
    }
    println!("ops={ops}");
    println!("acc_s={acc_s}");
    println!("acc_n={acc_n}");
}
