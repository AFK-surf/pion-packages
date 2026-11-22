//! Counter-capacity probe for Rust `uuid::ContextV7`: generate N UUIDv7 at one fixed millisecond and report
//! how far the embedded timestamp drifts forward (compare with Pion `V7Context`, 12-bit counter).
//! Usage: v7ctx <n>
use uuid::{ContextV7, Timestamp, Uuid};

fn main() {
    let n: u64 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(100_000);
    let ctx = ContextV7::new();
    let (secs, nanos) = (1_700_000_000u64, 0u32);
    let mut prev = Uuid::nil();
    let mut max_ms = 0u64;
    for _ in 0..n {
        let u = Uuid::new_v7(Timestamp::from_unix(&ctx, secs, nanos));
        assert!(u > prev, "not monotonic");
        prev = u;
        let (s, ns) = u.get_timestamp().unwrap().to_unix();
        max_ms = max_ms.max(s * 1000 + ns as u64 / 1_000_000);
    }
    println!("n={} drift_ms={}", n, max_ms - secs * 1000);
}
