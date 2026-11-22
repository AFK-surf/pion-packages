use std::env;
use std::fs;
use toml::Value;

const MOD: i64 = 1_000_000_007;

#[derive(Default)]
struct Stats {
    tables: i64,
    arrays: i64,
    keys: i64,
    strings: i64,
    ints: i64,
    floats: i64,
    bools: i64,
    bool_true: i64,
    datetimes: i64,
    str_bytes: i64,
    int_sum: i64,
    key_hash: i64,
    str_hash: i64,
}

fn poly_hash(s: &str) -> i64 {
    let mut h: i64 = 17;
    for &b in s.as_bytes() {
        h = (h * 131 + b as i64) % MOD;
    }
    h
}

fn walk_val(st: &mut Stats, v: &Value) {
    match v {
        Value::String(s) => {
            st.strings += 1;
            st.str_bytes += s.len() as i64;
            st.str_hash = (st.str_hash + poly_hash(s)) % MOD;
        }
        Value::Integer(x) => {
            st.ints += 1;
            let m = ((x % MOD) + MOD) % MOD;
            st.int_sum = (st.int_sum + m) % MOD;
        }
        Value::Float(_) => {
            st.floats += 1;
        }
        Value::Boolean(b) => {
            st.bools += 1;
            if *b {
                st.bool_true += 1;
            }
        }
        Value::Datetime(_) => {
            st.datetimes += 1;
        }
        Value::Array(items) => {
            st.arrays += 1;
            for item in items {
                walk_val(st, item);
            }
        }
        Value::Table(map) => {
            st.tables += 1;
            st.keys += map.len() as i64;
            for (k, child) in map {
                st.key_hash = (st.key_hash + poly_hash(k)) % MOD;
                walk_val(st, child);
            }
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let path = args
        .get(1)
        .map(|s| s.as_str())
        .unwrap_or("/tmp/pion-toml-bench/corpus.toml");
    let iters: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(40);
    let content = fs::read_to_string(path).expect("failed to read input");
    let mut st = Stats::default();
    for _ in 0..iters {
        let parsed: Value = toml::from_str(&content).expect("parse error");
        walk_val(&mut st, &parsed);
    }
    println!("iters={}", iters);
    println!("tables={}", st.tables);
    println!("arrays={}", st.arrays);
    println!("keys={}", st.keys);
    println!("strings={}", st.strings);
    println!("ints={}", st.ints);
    println!("floats={}", st.floats);
    println!("bools={}", st.bools);
    println!("bool_true={}", st.bool_true);
    println!("datetimes={}", st.datetimes);
    println!("str_bytes={}", st.str_bytes);
    println!("int_sum={}", st.int_sum);
    println!("key_hash={}", st.key_hash);
    println!("str_hash={}", st.str_hash);
}
