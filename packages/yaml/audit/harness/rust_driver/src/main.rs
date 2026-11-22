//! Red-team differential driver for Rust yaml-rust2.
//! Modes: json <file> (canonical JSON per doc or "ERR <msg>", exit 2), rt <file> (YamlEmitter round trip), rtjson <file>.
use std::fmt::Write as _;
use std::io::Write as _;
use yaml_rust2::{Yaml, YamlEmitter, YamlLoader};

fn js(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn fmt_real(s: &str) -> String {
    match parse_real(s) {
        Some(f) if f.is_finite() => format!("{}", f),
        _ => "null".to_string(),
    }
}

fn parse_real(s: &str) -> Option<f64> {
    let t = s.trim_start_matches('+');
    match t {
        ".inf" | ".Inf" | ".INF" => Some(f64::INFINITY),
        "-.inf" | "-.Inf" | "-.INF" => Some(f64::NEG_INFINITY),
        ".nan" | ".NaN" | ".NAN" => Some(f64::NAN),
        _ => t.parse::<f64>().ok(),
    }
}

fn key(k: &Yaml) -> String {
    match k {
        Yaml::String(s) => s.clone(),
        Yaml::Null => "null".into(),
        Yaml::Boolean(b) => b.to_string(),
        Yaml::Integer(n) => n.to_string(),
        Yaml::Real(s) => fmt_real(s),
        _ => {
            let mut t = String::new();
            canon(&mut t, k);
            t
        }
    }
}

fn canon(out: &mut String, v: &Yaml) {
    match v {
        Yaml::Null => out.push_str("null"),
        Yaml::BadValue => out.push_str("\"<BadValue>\""),
        Yaml::Boolean(b) => out.push_str(if *b { "true" } else { "false" }),
        Yaml::Integer(n) => {
            let _ = write!(out, "{}", n);
        }
        Yaml::Real(s) => out.push_str(&fmt_real(s)),
        Yaml::String(s) => js(out, s),
        Yaml::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canon(out, x);
            }
            out.push(']');
        }
        Yaml::Hash(h) => {
            let mut m: std::collections::BTreeMap<Vec<u8>, &Yaml> = Default::default();
            for (k, x) in h {
                m.insert(key(k).into_bytes(), x);
            }
            out.push('{');
            for (i, (k, x)) in m.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                js(out, std::str::from_utf8(k).unwrap());
                out.push(':');
                canon(out, x);
            }
            out.push('}');
        }
        Yaml::Alias(_) => out.push_str("\"<Alias>\""),
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 3 {
        println!("usage: rust_driver json|rt <file>");
        std::process::exit(1);
    }
    let src = match std::fs::read(&a[2]) {
        Ok(b) => match String::from_utf8(b) {
            Ok(s) => s,
            Err(_) => {
                println!("ERR invalid UTF-8 input");
                std::process::exit(2);
            }
        },
        Err(_) => {
            println!("ERR cannot read");
            std::process::exit(1);
        }
    };
    let docs = match YamlLoader::load_from_str(&src) {
        Ok(d) => d,
        Err(e) => {
            println!("ERR {}", e);
            std::process::exit(2);
        }
    };
    let mut out = String::new();
    if a[1] == "rtjson" {
        for d in &docs {
            let mut emitted = String::new();
            YamlEmitter::new(&mut emitted).dump(d).unwrap();
            match YamlLoader::load_from_str(&emitted) {
                Ok(again) if again.len() == 1 => canon(&mut out, &again[0]),
                Ok(_) => out.push_str("RT_ERR doc count"),
                Err(e) => {
                    let _ = write!(out, "RT_ERR {}", e);
                }
            }
            out.push('\n');
        }
        std::io::stdout().write_all(out.as_bytes()).unwrap();
        return;
    }
    if a[1] == "rt" {
        let mut bad = false;
        for (i, d) in docs.iter().enumerate() {
            let mut emitted = String::new();
            if let Err(e) = YamlEmitter::new(&mut emitted).dump(d) {
                let _ = writeln!(out, "RT_ERR doc={} emit {:?}", i, e);
                bad = true;
                continue;
            }
            match YamlLoader::load_from_str(&emitted) {
                Ok(again) if again.len() == 1 && again[0] == *d => {}
                Ok(again) => {
                    let _ = writeln!(out, "RT_DIFF doc={}\n  orig : {:?}\n  again: {:?}\n  emitted:\n{}", i, d, again, emitted);
                    bad = true;
                }
                Err(e) => {
                    let _ = writeln!(out, "RT_ERR doc={} {}\n  emitted:\n{}", i, e, emitted);
                    bad = true;
                }
            }
        }
        if !bad {
            out.push_str("RT_OK\n");
        }
        std::io::stdout().write_all(out.as_bytes()).unwrap();
        std::process::exit(if bad { 3 } else { 0 });
    }
    for d in &docs {
        canon(&mut out, d);
        out.push('\n');
    }
    std::io::stdout().write_all(out.as_bytes()).unwrap();
}
