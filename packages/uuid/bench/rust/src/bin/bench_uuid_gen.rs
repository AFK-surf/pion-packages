use std::env;
use uuid::{Builder, Uuid};

fn splitmix64(mut x: u64) -> u64 {
    x = x.wrapping_add(0x9E3779B97F4A7C15);
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
    z ^ (z >> 31)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let count: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(200_000);

    let mut hash: u64 = 14695981039346656037;
    let mut total_bytes: u64 = 0;
    let mut buf = [0u8; 36];
    let mut name = *b"svc-00000000.example.com";
    let mut rand10 = [0u8; 10];
    let mut first_v5 = String::new();
    let mut last_v5 = String::new();
    let mut first_v7 = String::new();
    let mut last_v7 = String::new();

    for i in 0..count {
        let mut x = i;
        for d in (4..12).rev() {
            name[d] = b'0' + (x % 10) as u8;
            x /= 10;
        }
        let v5 = Uuid::new_v5(&Uuid::NAMESPACE_DNS, &name);

        let r1 = splitmix64(i);
        let r2 = splitmix64(i.wrapping_add(1_000_000));
        rand10[0] = ((r1 >> 8) & 0xFF) as u8;
        rand10[1] = (r1 & 0xFF) as u8;
        rand10[2..10].copy_from_slice(&r2.to_be_bytes());
        let ts_ms = 1_700_000_000_000u64 + (i / 100);
        let v7 = Builder::from_unix_timestamp_millis(ts_ms, &rand10).into_uuid();

        let s5 = v5.hyphenated().encode_lower(&mut buf);
        for &ch in s5.as_bytes() {
            hash = (hash ^ (ch as u64)).wrapping_mul(1099511628211);
        }
        total_bytes += 36;

        let s7 = v7.hyphenated().encode_lower(&mut buf);
        for &ch in s7.as_bytes() {
            hash = (hash ^ (ch as u64)).wrapping_mul(1099511628211);
        }
        total_bytes += 36;

        if i == 0 {
            first_v5 = v5.hyphenated().to_string();
            first_v7 = v7.hyphenated().to_string();
        }
        if i + 1 == count {
            last_v5 = v5.hyphenated().to_string();
            last_v7 = v7.hyphenated().to_string();
        }
    }

    println!("count={}", count);
    println!("total_bytes={}", total_bytes);
    println!("hash={}", hash);
    println!("first_v5={}", first_v5);
    println!("last_v5={}", last_v5);
    println!("first_v7={}", first_v7);
    println!("last_v7={}", last_v7);
}
