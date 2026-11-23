//! Fairness variants of packages/handlebars/bench/rust_bench and the blind-spot workloads.
//!   w1ctx / w3ctx: identical to the official W1/W3 but render with a `Context` built once
//!     (`render_with_context`), as a long-running Rust server does. The official harness calls
//!     `render(name, &data)`, which re-serializes the whole JSON data tree into a fresh Context on
//!     every render (`Context::wraps` -> `serde_json::to_value`); Pion renders straight from its Value.
//!   b1 / b2 / b3: blind-spot workloads from audit/bench/gen_blind.py (same output as pion_blind).
use handlebars::{Context, Handlebars};
use serde_json::Value;
use std::fs;
use std::path::Path;

fn fnv1a_str(seed: u64, s: &str) -> u64 {
    let mut h = seed;
    for b in s.as_bytes() {
        h = ((h ^ (*b as u64)).wrapping_mul(16777619)) & 0xFFFF_FFFF;
    }
    h
}

fn rd(dir: &str, f: &str) -> String {
    fs::read_to_string(Path::new(dir).join(f)).unwrap()
}

fn report(tag: &str, iters: usize, mut f: impl FnMut() -> String) {
    let mut total: u64 = 0;
    let mut ck: u64 = 2166136261;
    let mut first = String::new();
    for i in 0..iters {
        let out = f();
        if i == 0 {
            first = out.clone();
        }
        total += out.len() as u64;
        ck = fnv1a_str(ck, &out);
    }
    println!("{}", first);
    println!("{} iters={} total_bytes={} checksum={}", tag, iters, total, ck);
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (mode, dir, iters) = (a[1].as_str(), a[2].as_str(), a[3].parse::<usize>().unwrap());
    let mut reg = Handlebars::new();
    match mode {
        "w1ctx" => {
            reg.register_partial("badge", rd(dir, "w1_badge.hbs")).unwrap();
            reg.register_partial("card", rd(dir, "w1_card.hbs")).unwrap();
            reg.register_template_string("page", rd(dir, "w1_page.hbs")).unwrap();
            let ctx = Context::from(serde_json::from_str::<Value>(&rd(dir, "w1_data.json")).unwrap());
            report("W1", iters, || reg.render_with_context("page", &ctx).unwrap());
        }
        "w3ctx" => {
            reg.register_template_string("table", rd(dir, "w3_tmpl.hbs")).unwrap();
            let ctx = Context::from(serde_json::from_str::<Value>(&rd(dir, "w3_data.json")).unwrap());
            report("W3", iters, || reg.render_with_context("table", &ctx).unwrap());
        }
        "b1" => {
            reg.register_template_string("t", rd(dir, "b1_tmpl.hbs")).unwrap();
            let ctx = Context::from(serde_json::from_str::<Value>(&rd(dir, "b1_data.json")).unwrap());
            report("B1", iters, || reg.render_with_context("t", &ctx).unwrap());
        }
        "b2" => {
            for i in 0..13 {
                reg.register_partial(&format!("p{}", i), rd(dir, &format!("b2_p{}.hbs", i))).unwrap();
            }
            reg.register_template_string("t", "{{> p0}}").unwrap();
            let ctx = Context::from(serde_json::from_str::<Value>(&rd(dir, "b2_data.json")).unwrap());
            report("B2", iters, || reg.render_with_context("t", &ctx).unwrap());
        }
        "b3" => {
            let src = rd(dir, "b3_tmpl.hbs");
            let data: Value = serde_json::from_str(&rd(dir, "b3_data.json")).unwrap();
            report("B3", iters, || reg.render_template(&src, &data).unwrap());
        }
        _ => panic!("mode"),
    }
}
