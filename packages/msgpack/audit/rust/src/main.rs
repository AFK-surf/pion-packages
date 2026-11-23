//! Red-team reference probe: Rust rmpv =1.3.1 (same protocol as ../probe and ../go/cmd/probe).
//!   rust_probe tree <opts> <hex-lines-file>   -> "OK <tree> <rmpv re-encoding>" | "ERR <msg>"
//!   rust_probe bench <dec|dupdec|prefix|refdec> <file> <iters>
//!   rust_probe bigenc <mib> <copies>
//!   rust_probe deepdrop <n>
//! rmpv has no Timestamp type: ext -1 is printed as x-1:<hex> (compare with Pion `ts0`).
//! rmpv accepts non-UTF-8 str: printed as s~<hex>.
use rmpv::{Value, ValueRef};
use std::collections::HashSet;
use std::env;
use std::fmt::Write as _;
use std::fs;
use std::io::Cursor;

fn hex(b: &[u8], out: &mut String) {
    for x in b {
        let _ = write!(out, "{:02x}", x);
    }
}

fn tree(v: &Value, out: &mut String) {
    match v {
        Value::Nil => out.push_str("nil"),
        Value::Boolean(b) => out.push_str(if *b { "T" } else { "F" }),
        Value::Integer(i) => {
            if let Some(u) = i.as_u64() {
                let _ = write!(out, "u{}", u);
            } else {
                let _ = write!(out, "i{}", i.as_i64().unwrap());
            }
        }
        Value::F32(f) => {
            let _ = write!(out, "f32:{:08x}", f.to_bits());
        }
        Value::F64(f) => {
            let _ = write!(out, "f64:{:016x}", f.to_bits());
        }
        Value::String(s) => {
            if s.is_str() {
                out.push_str("s:");
            } else {
                out.push_str("s~");
            }
            hex(s.as_bytes(), out);
        }
        Value::Binary(b) => {
            out.push_str("b:");
            hex(b, out);
        }
        Value::Ext(t, b) => {
            let _ = write!(out, "x{}:", t);
            hex(b, out);
        }
        Value::Array(items) => {
            out.push('[');
            for (i, x) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                tree(x, out);
            }
            out.push(']');
        }
        Value::Map(pairs) => {
            out.push('{');
            for (i, (k, x)) in pairs.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                tree(k, out);
                out.push(':');
                tree(x, out);
            }
            out.push('}');
        }
    }
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).unwrap())
        .collect()
}

fn run_one(input: &[u8], depth: Option<usize>) -> String {
    let mut cur = Cursor::new(input);
    let r = match depth {
        Some(d) => rmpv::decode::read_value_with_max_depth(&mut cur, d),
        None => rmpv::decode::read_value(&mut cur),
    };
    match r {
        Err(e) => format!("ERR {}", e),
        Ok(v) => {
            if (cur.position() as usize) != input.len() {
                return format!("ERR trailing bytes at offset {}", cur.position());
            }
            let mut out = String::from("OK ");
            tree(&v, &mut out);
            out.push(' ');
            let mut buf = Vec::new();
            rmpv::encode::write_value(&mut buf, &v).unwrap();
            hex(&buf, &mut out);
            out
        }
    }
}

fn walk(v: &Value, acc: &mut [i64; 2]) {
    acc[0] += 1;
    match v {
        Value::String(s) => acc[1] += s.as_bytes().len() as i64,
        Value::Binary(b) => acc[1] += b.len() as i64,
        Value::Ext(t, b) if *t != -1 => acc[1] += b.len() as i64,
        Value::Array(items) => items.iter().for_each(|x| walk(x, acc)),
        Value::Map(pairs) => pairs.iter().for_each(|(k, x)| {
            walk(k, acc);
            walk(x, acc)
        }),
        _ => {}
    }
}

fn walk_ref(v: &ValueRef, acc: &mut [i64; 2]) {
    acc[0] += 1;
    match v {
        ValueRef::String(s) => acc[1] += s.as_bytes().len() as i64,
        ValueRef::Binary(b) => acc[1] += b.len() as i64,
        ValueRef::Ext(t, b) if *t != -1 => acc[1] += b.len() as i64,
        ValueRef::Array(items) => items.iter().for_each(|x| walk_ref(x, acc)),
        ValueRef::Map(pairs) => pairs.iter().for_each(|(k, x)| {
            walk_ref(k, acc);
            walk_ref(x, acc)
        }),
        _ => {}
    }
}

/// Idiomatic Rust duplicate-key rejection: std HashSet (randomized SipHash) over a key fingerprint.
fn check_dups(v: &Value) -> bool {
    match v {
        Value::Array(items) => items.iter().all(check_dups),
        Value::Map(pairs) => {
            let mut seen = HashSet::with_capacity(pairs.len());
            for (k, x) in pairs {
                let mut key = String::new();
                tree(k, &mut key);
                if !seen.insert(key) || !check_dups(k) || !check_dups(x) {
                    return false;
                }
            }
            true
        }
        _ => true,
    }
}

fn bench(mode: &str, path: &str, iters: usize) {
    let data = fs::read(path).expect("read");
    let mut acc = [0i64; 2];
    for _ in 0..iters {
        match mode {
            "dec" | "dupdec" => {
                let v = rmpv::decode::read_value(&mut Cursor::new(data.as_slice())).expect("decode");
                if mode == "dupdec" && !check_dups(&v) {
                    println!("ERR duplicate map key");
                    std::process::exit(2);
                }
                walk(&v, &mut acc);
            }
            "refdec" => {
                // Zero-copy borrowing decoder (rmpv's documented fast path).
                let mut rd: &[u8] = data.as_slice();
                let v = rmpv::decode::read_value_ref(&mut rd).expect("decode");
                walk_ref(&v, &mut acc);
            }
            "prefix" => {
                let mut rd: &[u8] = data.as_slice();
                while !rd.is_empty() {
                    let v = rmpv::decode::read_value(&mut rd).expect("decode");
                    walk(&v, &mut acc);
                }
            }
            _ => panic!("mode"),
        }
    }
    println!("nodes={}", acc[0]);
    println!("payload_bytes={}", acc[1]);
}

/// Same shape as `pion_probe bigenc`: an array of `copies` borrowed refs to one `mib`-MiB blob,
/// encoded into a byte-counting sink (no 2+ GiB buffer needed to show the encoder copes).
fn bigenc(mib: usize, copies: usize) {
    struct Count(u64);
    impl std::io::Write for Count {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0 += b.len() as u64;
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let blob = vec![0u8; mib << 20];
    let v = ValueRef::Array(vec![ValueRef::Binary(&blob); copies]);
    let mut w = Count(0);
    match rmpv::encode::write_value_ref(&mut w, &v) {
        Ok(()) => println!("OK encoded {} bytes", w.0),
        Err(e) => println!("ERR {}", e),
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("tree") => {
            let depth = args[2]
                .split(',')
                .find_map(|p| p.strip_prefix("depth=").map(|d| d.parse().unwrap()));
            let src = fs::read_to_string(&args[3]).expect("read");
            let mut out = String::new();
            for line in src.split('\n') {
                if line.is_empty() {
                    continue;
                }
                out.push_str(&run_one(&unhex(line.trim()), depth));
                out.push('\n');
            }
            print!("{}", out);
        }
        Some("deepdrop") => {
            // Build an n-deep Value::Array chain, encode it, then drop it (recursive Drop).
            let n: usize = args[2].parse().unwrap();
            let mut v = Value::Nil;
            for _ in 0..n {
                v = Value::Array(vec![v]);
            }
            let mut buf = Vec::new();
            rmpv::encode::write_value(&mut buf, &v).map(|_| ()).unwrap_or(());
            drop(v);
            println!("OK built+encoded+dropped {} levels ({} bytes)", n, buf.len());
        }
        Some("bigenc") => bigenc(args[2].parse().unwrap(), args[3].parse().unwrap()),
        Some("bench") => bench(&args[2], &args[3], args[4].parse().unwrap()),
        _ => {
            eprintln!("usage: rust_probe tree <opts> <file> | bench <mode> <file> <iters>");
            std::process::exit(1);
        }
    }
}
