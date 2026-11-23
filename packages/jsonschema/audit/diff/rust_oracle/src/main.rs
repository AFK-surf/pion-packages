//! Reference oracle: Rust `jsonschema =0.29.1` (offline, no retrieval features).
//! Usage: jsonschema-audit-oracle <cases.jsonl>
//! Output per line: id \t IS \t VAL \t ms \t nerr  (same contract as the Pion driver)
//!   IS = V | I | E:<msg-class> | P (panic); ms = compile/is_valid/iter_errors
use jsonschema::Draft;
use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::time::Instant;

fn main() {
    let path = std::env::args().nth(1).expect("usage: oracle <cases.jsonl>");
    let f = std::fs::File::open(&path).expect("open cases");
    let out = std::io::stdout();
    let mut out = out.lock();
    std::panic::set_hook(Box::new(|_| {}));
    for (li, line) in BufReader::new(f).lines().enumerate() {
        let line = line.expect("read line");
        if line.is_empty() {
            continue;
        }
        // serde_json's default recursion limit is 128; disable it so deep probes reach the validator.
        let mut de = serde_json::Deserializer::from_str(&line);
        de.disable_recursion_limit();
        let case: Value = match serde::Deserialize::deserialize(&mut de) {
            Ok(v) => v,
            Err(e) => {
                writeln!(out, "line{}\tX:{}\t-\t0\t0", li, e).unwrap();
                continue;
            }
        };
        let id = case["id"].as_str().map(|s| s.to_string()).unwrap_or(format!("line{}", li));
        let draft = match case["draft"].as_str() {
            Some("7") => Some(Draft::Draft7),
            Some("auto") => None,
            _ => Some(Draft::Draft202012),
        };
        let fmt = case["fmt"].as_bool().unwrap_or(false);
        let schema = &case["schema"];
        let instance = &case["instance"];
        let t0 = Instant::now();
        let r = catch_unwind(AssertUnwindSafe(|| {
            let mut o = jsonschema::options().should_validate_formats(fmt);
            if let Some(d) = draft {
                o = o.with_draft(d);
            }
            match o.build(schema) {
                Ok(v) => {
                    let t1 = Instant::now();
                    let ok = v.is_valid(instance);
                    let t2 = Instant::now();
                    let n = v.iter_errors(instance).count();
                    let t3 = Instant::now();
                    format!(
                        "{}\t{}\t{}/{}/{}\t@{}",
                        if ok { "V" } else { "I" },
                        if n == 0 { "V" } else { "I" },
                        (t1 - t0).as_millis(),
                        (t2 - t1).as_millis(),
                        (t3 - t2).as_millis(),
                        n
                    )
                }
                Err(e) => {
                    let msg = e.to_string().replace(['\t', '\n'], " ");
                    let short: String = msg.chars().take(60).collect();
                    format!("E:{}\t-\t{}\t@0", short, t0.elapsed().as_millis())
                }
            }
        }));
        let ms = t0.elapsed().as_millis();
        match r {
            Ok(s) => {
                let (head, n) = s.rsplit_once("\t@").unwrap();
                writeln!(out, "{}\t{}\t{}", id, head, n).unwrap()
            }
            Err(_) => writeln!(out, "{}\tP\t-\t{}\t0", id, ms).unwrap(),
        }
    }
}
