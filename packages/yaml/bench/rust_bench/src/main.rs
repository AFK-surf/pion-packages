use std::env;
use std::fs;
use std::io::{self, Write};
use yaml_rust2::{Yaml, YamlLoader};

fn write_json_str(out: &mut String, s: &str) {
    out.push('"');
    for b in s.bytes() {
        match b {
            b'"' => out.push_str("\\\""),
            b'\\' => out.push_str("\\\\"),
            0x08 => out.push_str("\\b"),
            0x0c => out.push_str("\\f"),
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            b'\t' => out.push_str("\\t"),
            c if c < 0x20 => {
                use std::fmt::Write;
                let _ = write!(out, "\\u{:04x}", c);
            }
            _ => {
                // Multi-byte UTF-8 handled below via str slicing
                unreachable!()
            }
        }
    }
    out.push('"');
}

fn write_json_str_fast(out: &mut String, s: &str) {
    out.push('"');
    let bytes = s.as_bytes();
    let mut mark = 0;
    for (i, &b) in bytes.iter().enumerate() {
        if b == b'"' || b == b'\\' || b < 0x20 {
            if mark < i {
                out.push_str(&s[mark..i]);
            }
            match b {
                b'"' => out.push_str("\\\""),
                b'\\' => out.push_str("\\\\"),
                0x08 => out.push_str("\\b"),
                0x0c => out.push_str("\\f"),
                b'\n' => out.push_str("\\n"),
                b'\r' => out.push_str("\\r"),
                b'\t' => out.push_str("\\t"),
                c => {
                    use std::fmt::Write;
                    let _ = write!(out, "\\u{:04x}", c);
                }
            }
            mark = i + 1;
        }
    }
    if mark < bytes.len() {
        out.push_str(&s[mark..]);
    }
    out.push('"');
}

fn key_to_str(k: &Yaml) -> String {
    match k {
        Yaml::String(s) => s.clone(),
        Yaml::Null => "null".to_string(),
        Yaml::Boolean(b) => if *b { "true" } else { "false" }.to_string(),
        Yaml::Integer(n) => n.to_string(),
        Yaml::Real(s) => s.clone(),
        _ => {
            let mut tmp = String::new();
            write_canonical_json(&mut tmp, k);
            tmp
        }
    }
}

fn write_canonical_json(out: &mut String, v: &Yaml) {
    let _ = write_json_str;
    match v {
        Yaml::Null | Yaml::BadValue => out.push_str("null"),
        Yaml::Boolean(b) => out.push_str(if *b { "true" } else { "false" }),
        Yaml::Integer(n) => {
            use std::fmt::Write;
            let _ = write!(out, "{}", n);
        }
        Yaml::Real(s) => {
            if let Ok(f) = s.parse::<f64>() {
                if f.is_finite() {
                    use std::fmt::Write;
                    let _ = write!(out, "{}", f);
                } else {
                    out.push_str("null");
                }
            } else {
                out.push_str("null");
            }
        }
        Yaml::String(s) => write_json_str_fast(out, s),
        Yaml::Array(arr) => {
            out.push('[');
            for (i, item) in arr.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical_json(out, item);
            }
            out.push(']');
        }
        Yaml::Hash(map) => {
            let mut pairs: Vec<(String, &Yaml)> = Vec::with_capacity(map.len());
            for (k, val) in map {
                pairs.push((key_to_str(k), val));
            }
            pairs.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
            out.push('{');
            for (i, (k, val)) in pairs.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_json_str_fast(out, k);
                out.push(':');
                write_canonical_json(out, val);
            }
            out.push('}');
        }
        Yaml::Alias(_) => out.push_str("null"),
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: bench_rust <corpus.yaml>");
        std::process::exit(1);
    }
    let src = fs::read_to_string(&args[1]).expect("failed to read input file");
    let docs = YamlLoader::load_from_str(&src).expect("failed to parse YAML");
    let mut out = String::with_capacity(src.len());
    for doc in &docs {
        write_canonical_json(&mut out, doc);
        out.push('\n');
    }
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    handle.write_all(out.as_bytes()).expect("write failed");
}
