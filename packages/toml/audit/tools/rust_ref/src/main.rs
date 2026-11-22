//! Red-team audit CLI: the Rust `toml` side of every differential / benchmark.
//!
//! Same modes as `../pion_cli` (see its header). Modes prefixed with `v08-`
//! (e.g. `v08-bench-parse`) use toml 0.8.23, the version pinned by
//! `packages/toml/bench/rust_bench`; unprefixed modes use the latest toml 1.2.2.

use std::fs;
use std::io::Write;

const MOD: i64 = 1_000_000_007;

fn poly_hash(s: &str) -> i64 {
    let mut h: i64 = 17;
    for &b in s.as_bytes() {
        h = (h * 131 + b as i64) % MOD;
    }
    h
}

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

fn print_stats(iters: usize, st: &Stats) {
    let mut o = String::new();
    o += &format!("iters={}\n", iters);
    o += &format!("tables={}\n", st.tables);
    o += &format!("arrays={}\n", st.arrays);
    o += &format!("keys={}\n", st.keys);
    o += &format!("strings={}\n", st.strings);
    o += &format!("ints={}\n", st.ints);
    o += &format!("floats={}\n", st.floats);
    o += &format!("bools={}\n", st.bools);
    o += &format!("bool_true={}\n", st.bool_true);
    o += &format!("datetimes={}\n", st.datetimes);
    o += &format!("str_bytes={}\n", st.str_bytes);
    o += &format!("int_sum={}\n", st.int_sum);
    o += &format!("key_hash={}\n", st.key_hash);
    o += &format!("str_hash={}\n", st.str_hash);
    print!("{}", o);
}

fn json_str(s: &str) -> String {
    serde_json::to_string(s).unwrap()
}

fn line_col(src: &str, off: usize) -> (usize, usize) {
    let off = off.min(src.len());
    let mut line = 1;
    let mut col = 1;
    for (i, ch) in src.char_indices() {
        if i >= off {
            break;
        }
        if ch == '\n' {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    (line, col)
}

macro_rules! impl_mod {
    ($modname:ident, $krate:ident) => {
        mod $modname {
            use super::*;
            use $krate::Value;

            pub fn walk(st: &mut Stats, v: &Value) {
                match v {
                    Value::String(s) => {
                        st.strings += 1;
                        st.str_bytes += s.len() as i64;
                        st.str_hash = (st.str_hash + poly_hash(s)) % MOD;
                    }
                    Value::Integer(x) => {
                        st.ints += 1;
                        st.int_sum = (st.int_sum + ((x % MOD) + MOD) % MOD) % MOD;
                    }
                    Value::Float(_) => st.floats += 1,
                    Value::Boolean(b) => {
                        st.bools += 1;
                        if *b {
                            st.bool_true += 1;
                        }
                    }
                    Value::Datetime(_) => st.datetimes += 1,
                    Value::Array(items) => {
                        st.arrays += 1;
                        for i in items {
                            walk(st, i);
                        }
                    }
                    Value::Table(m) => {
                        st.tables += 1;
                        st.keys += m.len() as i64;
                        for (k, c) in m {
                            st.key_hash = (st.key_hash + poly_hash(k)) % MOD;
                            walk(st, c);
                        }
                    }
                }
            }

            pub fn walk_table(st: &mut Stats, t: &$krate::Table) {
                st.tables += 1;
                st.keys += t.len() as i64;
                for (k, c) in t {
                    st.key_hash = (st.key_hash + poly_hash(k)) % MOD;
                    walk(st, c);
                }
            }

            pub fn parse(src: &str) -> Result<$krate::Table, $krate::de::Error> {
                $krate::from_str::<$krate::Table>(src)
            }

            fn tagged(o: &mut String, v: &Value) {
                match v {
                    Value::String(s) => {
                        o.push_str("{\"type\":\"string\",\"value\":");
                        o.push_str(&json_str(s));
                        o.push('}');
                    }
                    Value::Integer(x) => o.push_str(&format!("{{\"type\":\"integer\",\"value\":\"{}\"}}", x)),
                    Value::Float(f) => {
                        let s = if f.is_nan() {
                            "nan".to_string()
                        } else if f.is_infinite() {
                            if *f > 0.0 { "inf".into() } else { "-inf".into() }
                        } else {
                            format!("{:?}", f)
                        };
                        o.push_str(&format!("{{\"type\":\"float\",\"value\":\"{}\"}}", s));
                    }
                    Value::Boolean(b) => o.push_str(&format!("{{\"type\":\"bool\",\"value\":\"{}\"}}", b)),
                    Value::Datetime(d) => {
                        let t = match (d.date.is_some(), d.time.is_some(), d.offset.is_some()) {
                            (true, true, true) => "datetime",
                            (true, true, false) => "datetime-local",
                            (true, false, _) => "date-local",
                            _ => "time-local",
                        };
                        o.push_str(&format!("{{\"type\":\"{}\",\"value\":{}}}", t, json_str(&d.to_string())));
                    }
                    Value::Array(items) => {
                        o.push('[');
                        for (i, it) in items.iter().enumerate() {
                            if i > 0 {
                                o.push(',');
                            }
                            tagged(o, it);
                        }
                        o.push(']');
                    }
                    Value::Table(t) => table(o, t),
                }
            }

            pub fn table(o: &mut String, t: &$krate::Table) {
                o.push('{');
                for (i, (k, v)) in t.iter().enumerate() {
                    if i > 0 {
                        o.push(',');
                    }
                    o.push_str(&json_str(k));
                    o.push(':');
                    tagged(o, v);
                }
                o.push('}');
            }

            fn from_json(j: &serde_json::Value) -> Value {
                match j {
                    serde_json::Value::Array(a) => Value::Array(a.iter().map(from_json).collect()),
                    serde_json::Value::Object(m) => {
                        if m.len() == 2 && m.get("type").map_or(false, |t| t.is_string()) && m.get("value").map_or(false, |t| t.is_string()) {
                            let t = m["type"].as_str().unwrap();
                            let v = m["value"].as_str().unwrap();
                            return match t {
                                "string" => Value::String(v.to_string()),
                                "integer" => Value::Integer(v.parse().unwrap()),
                                "float" => Value::Float(match v {
                                    "nan" | "+nan" => f64::NAN,
                                    "-nan" => -f64::NAN,
                                    "inf" | "+inf" => f64::INFINITY,
                                    "-inf" => f64::NEG_INFINITY,
                                    _ => v.parse().unwrap(),
                                }),
                                "bool" => Value::Boolean(v == "true"),
                                _ => Value::Datetime(v.parse().unwrap()),
                            };
                        }
                        let mut t = $krate::Table::new();
                        for (k, v) in m {
                            t.insert(k.clone(), from_json(v));
                        }
                        Value::Table(t)
                    }
                    _ => panic!("bad json"),
                }
            }

            pub fn run(mode: &str, path: &str, iters: usize) -> i32 {
                match mode {
                    "decode" | "errpos" => {
                        let bytes = fs::read(path).expect("read");
                        let src = match String::from_utf8(bytes) {
                            Ok(s) => s,
                            Err(e) => {
                                if mode == "decode" {
                                    eprintln!("ERR invalid utf-8: {}", e);
                                    return 1;
                                }
                                println!("ERR 0 0 0 invalid utf-8");
                                return 0;
                            }
                        };
                        match parse(&src) {
                            Ok(t) => {
                                if mode == "decode" {
                                    let mut o = String::new();
                                    table(&mut o, &t);
                                    println!("{}", o);
                                } else {
                                    println!("OK");
                                }
                                0
                            }
                            Err(e) => {
                                let off = e.span().map(|r| r.start).unwrap_or(0);
                                let (l, c) = line_col(&src, off);
                                let msg = e.message().replace('\n', " ");
                                if mode == "decode" {
                                    eprintln!("ERR {} {} {} {}", l, c, off, msg);
                                    1
                                } else {
                                    println!("ERR {} {} {} {}", l, c, off, msg);
                                    0
                                }
                            }
                        }
                    }
                    "encode" => {
                        let src = fs::read_to_string(path).expect("read");
                        let j: serde_json::Value = serde_json::from_str(&src).expect("json");
                        match from_json(&j) {
                            Value::Table(t) => match $krate::to_string(&t) {
                                Ok(s) => {
                                    print!("{}", s);
                                    0
                                }
                                Err(e) => {
                                    eprintln!("ERR {}", e);
                                    1
                                }
                            },
                            _ => 1,
                        }
                    }
                    "roundtrip" => {
                        let src = fs::read_to_string(path).expect("read");
                        match parse(&src) {
                            Ok(t) => match $krate::to_string(&t) {
                                Ok(s) => {
                                    print!("{}", s);
                                    0
                                }
                                Err(e) => {
                                    eprintln!("ERR {}", e);
                                    1
                                }
                            },
                            Err(e) => {
                                eprintln!("ERR {}", e);
                                1
                            }
                        }
                    }
                    "bench-parse" => {
                        let src = fs::read_to_string(path).expect("read");
                        let mut st = Stats::default();
                        for _ in 0..iters {
                            let t = parse(&src).expect("parse error");
                            walk_table(&mut st, &t);
                        }
                        print_stats(iters, &st);
                        0
                    }
                    "bench-parse-only" => {
                        let src = fs::read_to_string(path).expect("read");
                        let mut n = 0usize;
                        for _ in 0..iters {
                            n += parse(&src).expect("parse error").len();
                        }
                        println!("iters={}", iters);
                        println!("root_keys={}", n);
                        0
                    }
                    "bench-stringify" => {
                        let src = fs::read_to_string(path).expect("read");
                        let t = parse(&src).expect("parse error");
                        let mut total = 0usize;
                        for _ in 0..iters {
                            total += $krate::to_string(&t).expect("ser").len();
                        }
                        println!("iters={}", iters);
                        println!("ok={}", total > 0);
                        0
                    }
                    "bench-lookup" => {
                        let src = fs::read_to_string(path).expect("read");
                        let t = parse(&src).expect("parse error");
                        let keys: Vec<String> = t.keys().cloned().collect();
                        let mut found: i64 = 0;
                        let mut sum: i64 = 0;
                        for _ in 0..iters {
                            for k in &keys {
                                match t.get(k) {
                                    Some(Value::Integer(x)) => {
                                        found += 1;
                                        sum = (sum + x) % MOD;
                                    }
                                    Some(_) => found += 1,
                                    None => {}
                                }
                            }
                        }
                        println!("iters={}", iters);
                        println!("found={}", found);
                        println!("sum={}", sum);
                        0
                    }
                    "bench-many" => {
                        let list = fs::read_to_string(path).expect("read");
                        let mut st = Stats::default();
                        let mut files = 0;
                        for p in list.lines().filter(|l| !l.is_empty()) {
                            let src = fs::read_to_string(p).expect("read");
                            let t = parse(&src).expect("parse error");
                            walk_table(&mut st, &t);
                            files += 1;
                        }
                        print_stats(files, &st);
                        0
                    }
                    _ => {
                        eprintln!("unknown mode {}", mode);
                        2
                    }
                }
            }
        }
    };
}

impl_mod!(latest, toml);
impl_mod!(v08, toml08);

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: rust_ref <mode> <file> [iters]");
        std::process::exit(2);
    }
    let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(1);
    let code = if let Some(m) = args[1].strip_prefix("v08-") {
        v08::run(m, &args[2], iters)
    } else {
        latest::run(&args[1], &args[2], iters)
    };
    std::io::stdout().flush().ok();
    std::process::exit(code);
}
