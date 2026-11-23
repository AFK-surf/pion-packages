use kdl::{KdlDocument, KdlNode, KdlValue};
use std::env;
use std::fs;
use std::process;

const MOD: i64 = 1_000_000_007;

fn poly_hash(s: &str) -> i64 {
    let mut h: i64 = 17;
    for &b in s.as_bytes() {
        h = (h * 131 + (b as i64)) % MOD;
    }
    h
}

#[derive(Default)]
struct Stats {
    nodes: i64,
    args: i64,
    props: i64,
    strings: i64,
    ints: i64,
    floats: i64,
    bools: i64,
    nulls: i64,
    int_sum: i64,
    str_bytes: i64,
    hash: i64,
}

fn walk_doc(st: &mut Stats, doc: &KdlDocument) {
    let mut stack: Vec<&KdlNode> = Vec::new();
    for n in doc.nodes().iter().rev() {
        stack.push(n);
    }
    while let Some(node) = stack.pop() {
        st.nodes += 1;
        st.hash = (st.hash + poly_hash(node.name().value())) % MOD;
        if let Some(ty) = node.ty() {
            st.hash = (st.hash + poly_hash(ty.value())) % MOD;
        }
        for entry in node.entries() {
            if let Some(k) = entry.name() {
                st.props += 1;
                st.hash = (st.hash + poly_hash(k.value())) % MOD;
            } else {
                st.args += 1;
            }
            if let Some(ty) = entry.ty() {
                st.hash = (st.hash + poly_hash(ty.value())) % MOD;
            }
            match entry.value() {
                KdlValue::String(s) => {
                    st.strings += 1;
                    st.str_bytes += s.len() as i64;
                    st.hash = (st.hash + poly_hash(s)) % MOD;
                }
                KdlValue::Integer(n) => {
                    st.ints += 1;
                    let m = ((*n % (MOD as i128)) + (MOD as i128)) % (MOD as i128);
                    st.int_sum = (st.int_sum + (m as i64)) % MOD;
                }
                KdlValue::Float(f) => {
                    st.floats += 1;
                    let tag = if f.is_nan() {
                        3
                    } else if f.is_infinite() {
                        if f.is_sign_negative() { 2 } else { 1 }
                    } else {
                        ((f * 1000.0).round() as i64).rem_euclid(MOD)
                    };
                    st.hash = (st.hash + tag) % MOD;
                }
                KdlValue::Bool(b) => {
                    st.bools += 1;
                    st.hash = (st.hash + if *b { 1 } else { 0 }) % MOD;
                }
                KdlValue::Null => {
                    st.nulls += 1;
                }
            }
        }
        if let Some(children) = node.children() {
            for c in children.nodes().iter().rev() {
                stack.push(c);
            }
        }
    }
}

fn print_stats(mode: &str, iters: usize, st: &Stats) {
    println!("mode={}", mode);
    println!("iters={}", iters);
    println!("nodes={}", st.nodes);
    println!("args={}", st.args);
    println!("props={}", st.props);
    println!("strings={}", st.strings);
    println!("ints={}", st.ints);
    println!("floats={}", st.floats);
    println!("bools={}", st.bools);
    println!("nulls={}", st.nulls);
    println!("int_sum={}", st.int_sum);
    println!("str_bytes={}", st.str_bytes);
    println!("hash={}", st.hash);
}

fn run_w1(path: &str, iters: usize) {
    let src = fs::read_to_string(path).expect("read w1");
    let mut st = Stats::default();
    for _ in 0..iters {
        let doc: KdlDocument = src.parse().expect("parse w1");
        walk_doc(&mut st, &doc);
    }
    print_stats("w1_parse", iters, &st);
}

fn run_w2(path: &str, iters: usize) {
    let src = fs::read_to_string(path).expect("read w2");
    let mut st = Stats::default();
    for _ in 0..iters {
        let mut doc: KdlDocument = src.parse().expect("parse w2");
        doc.autoformat();
        let formatted = doc.to_string();
        let doc2: KdlDocument = formatted.parse().expect("reparse w2");
        walk_doc(&mut st, &doc2);
    }
    print_stats("w2_roundtrip", iters, &st);
}

fn run_w3(path: &str, iters: usize) {
    let src = fs::read_to_string(path).expect("read w3");
    let mut matched_routes: i64 = 0;
    let mut total_rate: i64 = 0;
    let mut total_weight: i64 = 0;
    let mut hash: i64 = 0;
    for _ in 0..iters {
        let doc: KdlDocument = src.parse().expect("parse w3");
        if let Some(svc) = doc.get("service") {
            if let Some(name) = svc.get(0).and_then(|v| v.as_string()) {
                hash = (hash + poly_hash(name)) % MOD;
            }
            if let Some(children) = svc.children() {
                for c in children.nodes() {
                    if c.name().value() == "route" {
                        let auth = c.get("auth").and_then(|v| v.as_bool()).unwrap_or(false);
                        if auth {
                            matched_routes += 1;
                            if let Some(rl) = c.get("rate-limit").and_then(|v| v.as_integer()) {
                                total_rate += rl as i64;
                            }
                            if let Some(path_arg) = c.get(0).and_then(|v| v.as_string()) {
                                hash = (hash + poly_hash(path_arg)) % MOD;
                            }
                        }
                    } else if c.name().value() == "upstream" {
                        if let Some(w) = c.get("weight").and_then(|v| v.as_integer()) {
                            total_weight += w as i64;
                        }
                    }
                }
            }
        }
    }
    println!("mode=w3_query");
    println!("iters={}", iters);
    println!("matched_routes={}", matched_routes);
    println!("total_rate={}", total_rate);
    println!("total_weight={}", total_weight);
    println!("hash={}", hash);
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: kdl_bench_rust <w1|w2|w3> <file> <iters>");
        process::exit(1);
    }
    let iters: usize = args[3].parse().expect("iters");
    match args[1].as_str() {
        "w1" => run_w1(&args[2], iters),
        "w2" => run_w2(&args[2], iters),
        "w3" => run_w3(&args[2], iters),
        other => {
            eprintln!("unknown mode: {}", other);
            process::exit(1);
        }
    }
}
