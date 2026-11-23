use serde_json::Value;
use std::env;
use std::fs;
use std::process;

#[inline]
fn fnv1a_step(h: u64, b: u64) -> u64 {
    ((h ^ b).wrapping_mul(16777619)) & 0xFFFF_FFFF
}

fn run_batch(schema_path: &str, jsonl_path: &str, iters: usize) {
    let schema_src = fs::read_to_string(schema_path).expect("read schema");
    let jsonl_src = fs::read_to_string(jsonl_path).expect("read jsonl");
    let schema_val: Value = serde_json::from_str(&schema_src).expect("parse schema");
    let validator = jsonschema::draft202012::new(&schema_val).expect("compile schema");

    let instances: Vec<Value> = jsonl_src
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| serde_json::from_str(l).expect("parse instance"))
        .collect();

    let mut valid: usize = 0;
    let mut invalid: usize = 0;
    let mut checksum: u64 = 2166136261;
    for _ in 0..iters {
        for inst in &instances {
            if validator.is_valid(inst) {
                valid += 1;
                checksum = fnv1a_step(checksum, 1);
            } else {
                invalid += 1;
                checksum = fnv1a_step(checksum, 0);
            }
        }
    }
    println!("valid={} invalid={} checksum={}", valid, invalid, checksum);
}

fn run_e2e(pairs_path: &str, iters: usize) {
    let src = fs::read_to_string(pairs_path).expect("read pairs");
    let mut schemas: Vec<Value> = Vec::new();
    let mut instances: Vec<Value> = Vec::new();
    for line in src.lines().filter(|l| !l.is_empty()) {
        let mut obj: Value = serde_json::from_str(line).expect("parse pair");
        let map = obj.as_object_mut().expect("pair object");
        schemas.push(map.remove("schema").expect("schema field"));
        instances.push(map.remove("instance").expect("instance field"));
    }

    let mut compiled_cnt: usize = 0;
    let mut valid: usize = 0;
    let mut invalid: usize = 0;
    let mut checksum: u64 = 2166136261;
    for _ in 0..iters {
        for (s, inst) in schemas.iter().zip(instances.iter()) {
            let validator = jsonschema::draft202012::new(s).expect("compile pair");
            compiled_cnt += 1;
            if validator.is_valid(inst) {
                valid += 1;
                checksum = fnv1a_step(checksum, 1);
            } else {
                invalid += 1;
                checksum = fnv1a_step(checksum, 0);
            }
        }
    }
    println!(
        "compiled={} valid={} invalid={} checksum={}",
        compiled_cnt, valid, invalid, checksum
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: rust_jsonschema batch <schema> <jsonl> <iters> | e2e <pairs> <iters>");
        process::exit(1);
    }
    match args[1].as_str() {
        "batch" => {
            let iters: usize = args[4].parse().unwrap_or(1);
            run_batch(&args[2], &args[3], iters);
        }
        "e2e" => {
            let iters: usize = args[3].parse().unwrap_or(1);
            run_e2e(&args[2], iters);
        }
        other => {
            eprintln!("unknown mode: {}", other);
            process::exit(1);
        }
    }
}
