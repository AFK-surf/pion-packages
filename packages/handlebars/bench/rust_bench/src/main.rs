use handlebars::Handlebars;
use serde_json::Value;
use std::env;
use std::fs;
use std::path::Path;

fn fnv1a_str(seed: u64, s: &str) -> u64 {
    let mut h = seed;
    for b in s.as_bytes() {
        h = ((h ^ (*b as u64)).wrapping_mul(16777619)) & 0xFFFF_FFFF;
    }
    h
}

fn run_w1(dir: &str, iters: usize) {
    let badge = fs::read_to_string(Path::new(dir).join("w1_badge.hbs")).unwrap();
    let card = fs::read_to_string(Path::new(dir).join("w1_card.hbs")).unwrap();
    let page = fs::read_to_string(Path::new(dir).join("w1_page.hbs")).unwrap();
    let data_src = fs::read_to_string(Path::new(dir).join("w1_data.json")).unwrap();
    let data: Value = serde_json::from_str(&data_src).unwrap();

    let mut reg = Handlebars::new();
    reg.register_partial("badge", badge).unwrap();
    reg.register_partial("card", card).unwrap();
    reg.register_template_string("page", page).unwrap();

    let mut total_bytes: u64 = 0;
    let mut checksum: u64 = 2166136261;
    let mut first_out = String::new();
    for i in 0..iters {
        let out = reg.render("page", &data).unwrap();
        if i == 0 {
            first_out = out.clone();
        }
        total_bytes += out.len() as u64;
        checksum = fnv1a_str(checksum, &out);
    }
    println!("{}", first_out);
    println!(
        "W1 iters={} total_bytes={} checksum={}",
        iters, total_bytes, checksum
    );
}

fn run_w2(dir: &str, iters: usize) {
    let tmpl_src = fs::read_to_string(Path::new(dir).join("w2_tmpl.hbs")).unwrap();
    let data_src = fs::read_to_string(Path::new(dir).join("w2_data.json")).unwrap();
    let data: Value = serde_json::from_str(&data_src).unwrap();

    let reg = Handlebars::new();

    let mut total_bytes: u64 = 0;
    let mut checksum: u64 = 2166136261;
    let mut first_out = String::new();
    for i in 0..iters {
        let out = reg.render_template(&tmpl_src, &data).unwrap();
        if i == 0 {
            first_out = out.clone();
        }
        total_bytes += out.len() as u64;
        checksum = fnv1a_str(checksum, &out);
    }
    println!("{}", first_out);
    println!(
        "W2 iters={} total_bytes={} checksum={}",
        iters, total_bytes, checksum
    );
}

fn run_w3(dir: &str, iters: usize) {
    let tmpl_src = fs::read_to_string(Path::new(dir).join("w3_tmpl.hbs")).unwrap();
    let data_src = fs::read_to_string(Path::new(dir).join("w3_data.json")).unwrap();
    let data: Value = serde_json::from_str(&data_src).unwrap();

    let mut reg = Handlebars::new();
    reg.register_template_string("table", tmpl_src).unwrap();

    let mut total_bytes: u64 = 0;
    let mut checksum: u64 = 2166136261;
    let mut first_out = String::new();
    for i in 0..iters {
        let out = reg.render("table", &data).unwrap();
        if i == 0 {
            first_out = out.clone();
        }
        total_bytes += out.len() as u64;
        checksum = fnv1a_str(checksum, &out);
    }
    println!("{}", first_out);
    println!(
        "W3 iters={} total_bytes={} checksum={}",
        iters, total_bytes, checksum
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: handlebars_bench_rust <w1|w2|w3> <data_dir> <iters>");
        std::process::exit(1);
    }
    let mode = args[1].as_str();
    let dir = args[2].as_str();
    let iters: usize = args[3].parse().unwrap_or(100);
    match mode {
        "w1" => run_w1(dir, iters),
        "w2" => run_w2(dir, iters),
        "w3" => run_w3(dir, iters),
        _ => {
            eprintln!("unknown mode: {}", mode);
            std::process::exit(1);
        }
    }
}
