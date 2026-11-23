use serde_json::Value;
use std::env;
use std::fs;
use std::process;

#[derive(Default)]
struct Stats {
    objects: i64,
    arrays: i64,
    keys: i64,
    strings: i64,
    numbers: i64,
    bools: i64,
    bool_true: i64,
    nulls: i64,
    str_bytes: i64,
    key_hash: i64,
    str_hash: i64,
}

fn poly_hash(s: &str) -> i64 {
    let mut h: i64 = 17;
    for &b in s.as_bytes() {
        h = (h * 131 + b as i64) % 1_000_000_007;
    }
    h
}

fn walk_val(st: &mut Stats, v: &Value) {
    match v {
        Value::Null => st.nulls += 1,
        Value::Bool(b) => {
            st.bools += 1;
            if *b {
                st.bool_true += 1;
            }
        }
        Value::Number(_) => st.numbers += 1,
        Value::String(s) => {
            st.strings += 1;
            st.str_bytes += s.len() as i64;
            st.str_hash = (st.str_hash + poly_hash(s)) % 1_000_000_007;
        }
        Value::Array(items) => {
            st.arrays += 1;
            for item in items {
                walk_val(st, item);
            }
        }
        Value::Object(map) => {
            st.objects += 1;
            st.keys += map.len() as i64;
            for (k, child) in map {
                st.key_hash = (st.key_hash + poly_hash(k)) % 1_000_000_007;
                walk_val(st, child);
            }
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: json5_bench_rust <parse|roundtrip|patch> ...");
        process::exit(1);
    }
    match args[1].as_str() {
        "parse" => {
            let content = fs::read_to_string(&args[2]).expect("read input");
            let iters: usize = args[3].parse().expect("iters");
            let mut st = Stats::default();
            for _ in 0..iters {
                let parsed: Value = json5::from_str(&content).expect("json5 parse");
                walk_val(&mut st, &parsed);
            }
            println!("mode=parse");
            println!("iters={}", iters);
            println!("objects={}", st.objects);
            println!("arrays={}", st.arrays);
            println!("keys={}", st.keys);
            println!("strings={}", st.strings);
            println!("numbers={}", st.numbers);
            println!("bools={}", st.bools);
            println!("bool_true={}", st.bool_true);
            println!("nulls={}", st.nulls);
            println!("str_bytes={}", st.str_bytes);
            println!("key_hash={}", st.key_hash);
            println!("str_hash={}", st.str_hash);
        }
        "roundtrip" => {
            let content = fs::read_to_string(&args[2]).expect("read input");
            let iters: usize = args[3].parse().expect("iters");
            let mut total_bytes: i64 = 0;
            let mut out_hash: i64 = 0;
            for _ in 0..iters {
                let parsed: Value = json5::from_str(&content).expect("json5 parse");
                let encoded = serde_json::to_string(&parsed).expect("json encode");
                total_bytes += encoded.len() as i64;
                out_hash = (out_hash + poly_hash(&encoded)) % 1_000_000_007;
            }
            println!("mode=roundtrip");
            println!("iters={}", iters);
            println!("total_bytes={}", total_bytes);
            println!("out_hash={}", out_hash);
        }
        "patch" => {
            let doc_src = fs::read_to_string(&args[2]).expect("read doc");
            let patch_src = fs::read_to_string(&args[3]).expect("read patch");
            let ops_each: usize = args[4].parse().expect("ops_each");
            let doc: Value = serde_json::from_str(&doc_src).expect("parse doc");
            let patch: json_patch::Patch = serde_json::from_str(&patch_src).expect("parse patch");
            let ptrs = [
                "/service",
                "/a~1b/m~0n",
                "/config/host",
                "/config/port",
                "/config/tags/2",
                "/config/limits/max_conn",
                "/routes/1/path",
                "/routes/2/enabled",
            ];
            let mut ptr_hits: i64 = 0;
            let mut ptr_hash: i64 = 0;
            for i in 0..ops_each {
                if let Some(v) = doc.pointer(ptrs[i % 8]) {
                    ptr_hits += 1;
                    match v {
                        Value::String(s) => ptr_hash = (ptr_hash + poly_hash(s)) % 1_000_000_007,
                        Value::Number(n) => {
                            if let Some(x) = n.as_i64() {
                                ptr_hash = (ptr_hash + x) % 1_000_000_007;
                            }
                        }
                        Value::Bool(b) => {
                            ptr_hash = (ptr_hash + if *b { 1 } else { 0 }) % 1_000_000_007;
                        }
                        _ => {}
                    }
                }
            }
            let mut patch_ok: i64 = 0;
            let mut patch_hash: i64 = 0;
            for _ in 0..ops_each {
                let mut cloned = doc.clone();
                json_patch::patch(&mut cloned, &patch).expect("apply patch");
                patch_ok += 1;
                if let Some(Value::String(s)) = cloned.pointer("/copied_label") {
                    patch_hash = (patch_hash + poly_hash(s)) % 1_000_000_007;
                }
            }
            println!("mode=patch");
            println!("ops_each={}", ops_each);
            println!("ptr_hits={}", ptr_hits);
            println!("ptr_hash={}", ptr_hash);
            println!("patch_ok={}", patch_ok);
            println!("patch_hash={}", patch_hash);
        }
        other => {
            eprintln!("unknown mode: {}", other);
            process::exit(1);
        }
    }
}
