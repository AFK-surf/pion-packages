use serde_json::{Map, Value};
use std::cmp::Ordering;
use std::env;
use std::fs;
use std::process;

#[derive(Default)]
struct W1Stats {
    objects: i64,
    arrays: i64,
    strings: i64,
    ints: i64,
    floats: i64,
    bools: i64,
    nulls: i64,
    int_sum: i64,
    str_bytes: i64,
}

fn fnv1a_bytes(s: &[u8]) -> u64 {
    let mut h: u64 = 14695981039346656037;
    for &b in s {
        h = (h ^ (b as u64)).wrapping_mul(1099511628211);
    }
    h
}

fn walk_w1(st: &mut W1Stats, root: &Value) {
    let mut stack = vec![root];
    while let Some(v) = stack.pop() {
        match v {
            Value::Null => st.nulls += 1,
            Value::Bool(_) => st.bools += 1,
            Value::Number(num) => {
                if let Some(i) = num.as_i64() {
                    st.ints += 1;
                    st.int_sum += i % 1000003;
                } else if num.is_u64() {
                    st.ints += 1;
                } else {
                    st.floats += 1;
                }
            }
            Value::String(s) => {
                st.strings += 1;
                st.str_bytes += s.len() as i64;
            }
            Value::Array(items) => {
                st.arrays += 1;
                for item in items {
                    stack.push(item);
                }
            }
            Value::Object(map) => {
                st.objects += 1;
                for (_, child) in map {
                    stack.push(child);
                }
            }
        }
    }
}

fn run_w1(path: &str, iters: usize) -> i32 {
    let content = fs::read_to_string(path).expect("failed to read input");
    let mut st = W1Stats::default();
    for _ in 0..iters {
        let v: Value = serde_json::from_str(&content).expect("parse error");
        walk_w1(&mut st, &v);
    }
    println!(
        "w1 objects={} arrays={} strings={} ints={} floats={} bools={} nulls={} int_sum={} str_bytes={}",
        st.objects, st.arrays, st.strings, st.ints, st.floats, st.bools, st.nulls, st.int_sum, st.str_bytes
    );
    0
}

fn run_w2(path: &str, iters: usize) -> i32 {
    let content = fs::read_to_string(path).expect("failed to read input");
    let mut total_bytes: i64 = 0;
    let mut kept_total: i64 = 0;
    let mut last_hash: u64 = 0;
    for _ in 0..iters {
        let doc: Value = serde_json::from_str(&content).expect("parse error");
        let recs = doc.get("records").and_then(Value::as_array).expect("records");
        let mut out_items = Vec::with_capacity(recs.len() / 2 + 1);
        for r in recs {
            let active = r.get("active").and_then(Value::as_bool).unwrap_or(false);
            if active {
                let id = r.get("id").and_then(Value::as_i64).unwrap_or(0);
                let score = r.get("score").and_then(Value::as_f64).unwrap_or(0.0);
                let login = r.pointer("/actor/login").and_then(Value::as_str).unwrap_or("");
                let tag0 = r.pointer("/payload/tags/0").and_then(Value::as_str).unwrap_or("");
                let mut m = Map::new();
                m.insert("id".to_string(), Value::from(id));
                m.insert("login".to_string(), Value::from(login));
                m.insert("processed".to_string(), Value::from(true));
                m.insert("score".to_string(), Value::from(score));
                m.insert("tag".to_string(), Value::from(tag0));
                out_items.push(Value::Object(m));
                kept_total += 1;
            }
        }
        let mut root = Map::new();
        root.insert("count".to_string(), Value::from(out_items.len() as i64));
        root.insert("items".to_string(), Value::Array(out_items));
        let s = serde_json::to_string(&Value::Object(root)).expect("stringify error");
        total_bytes += s.len() as i64;
        last_hash = fnv1a_bytes(s.as_bytes());
    }
    println!(
        "w2 kept={} total_bytes={} hash={}",
        kept_total, total_bytes, last_hash
    );
    0
}

fn cmp_utf16(a: &str, b: &str) -> Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}

fn make_w3_key(k_idx: usize) -> String {
    if k_idx % 500 == 0 {
        format!("k_{:05}_😀", k_idx)
    } else if k_idx % 500 == 1 {
        format!("k_{:05}_דּ", k_idx)
    } else {
        format!("field_{:05}", k_idx)
    }
}

fn run_w3(path: &str, iters: usize) -> i32 {
    let content = fs::read_to_string(path).expect("failed to read input");
    let mut lookup_sum: i64 = 0;
    let mut canon_bytes: i64 = 0;
    let mut last_hash: u64 = 0;
    for _ in 0..iters {
        let doc: Value = serde_json::from_str(&content).expect("parse error");
        let obj = doc.as_object().expect("object");
        let n = obj.len();
        for q in 0..n {
            let k_idx = (q * 7919 + 13) % n;
            let k = make_w3_key(k_idx);
            let v = obj.get(&k).expect("missing key");
            if let Some(iv) = v.as_i64() {
                lookup_sum += iv % 1000003;
            }
        }
        let mut entries: Vec<(&String, &Value)> = obj.iter().collect();
        entries.sort_by(|(a, _), (b, _)| cmp_utf16(a, b));
        let mut out = String::with_capacity(content.len());
        out.push('{');
        for (i, (k, v)) in entries.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&serde_json::to_string(k).unwrap());
            out.push(':');
            if let Some(iv) = v.as_i64() {
                if (-9007199254740991..=9007199254740991).contains(&iv) {
                    out.push_str(&iv.to_string());
                } else {
                    out.push_str(&format!("{:.0}", iv as f64));
                }
            } else {
                out.push_str(&serde_json::to_string(v).unwrap());
            }
        }
        out.push('}');
        canon_bytes += out.len() as i64;
        last_hash = fnv1a_bytes(out.as_bytes());
    }
    println!(
        "w3 lookup_sum={} canon_bytes={} hash={}",
        lookup_sum, canon_bytes, last_hash
    );
    0
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: json_bench_rust <w1|w2|w3> <file> <iters>");
        process::exit(1);
    }
    let iters: usize = args[3].parse().expect("invalid iters");
    let rc = match args[1].as_str() {
        "w1" => run_w1(&args[2], iters),
        "w2" => run_w2(&args[2], iters),
        "w3" => run_w3(&args[2], iters),
        other => {
            eprintln!("unknown mode: {}", other);
            1
        }
    };
    process::exit(rc);
}
