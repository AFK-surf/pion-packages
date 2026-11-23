//! Rust reference oracle: `json5 =1.3.8` (Unicode 17 ES5.1 identifiers), `serde_json =1.0.140`
//! (`preserve_order`), `json-patch =4.2.0`. Same CLI / line format as `audit/driver` (Pion).
use serde::de::{Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use std::fmt::Write as _;
use std::time::Instant;
use std::{env, fs};

/// A value tree that keeps +-Infinity / NaN (serde_json::Value would turn them into null)
/// and every key in document order (duplicates included, so the caller sees the policy).
enum V {
    N,
    B(bool),
    D(f64),
    S(String),
    A(Vec<V>),
    O(Vec<(String, V)>),
}

impl<'de> Deserialize<'de> for V {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<V, D::Error> {
        struct Vis;
        impl<'de> Visitor<'de> for Vis {
            type Value = V;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("any JSON5 value")
            }
            fn visit_unit<E>(self) -> Result<V, E> { Ok(V::N) }
            fn visit_none<E>(self) -> Result<V, E> { Ok(V::N) }
            fn visit_some<D2: Deserializer<'de>>(self, d: D2) -> Result<V, D2::Error> { V::deserialize(d) }
            fn visit_bool<E>(self, b: bool) -> Result<V, E> { Ok(V::B(b)) }
            fn visit_i64<E>(self, x: i64) -> Result<V, E> { Ok(V::D(x as f64)) }
            fn visit_u64<E>(self, x: u64) -> Result<V, E> { Ok(V::D(x as f64)) }
            fn visit_i128<E>(self, x: i128) -> Result<V, E> { Ok(V::D(x as f64)) }
            fn visit_u128<E>(self, x: u128) -> Result<V, E> { Ok(V::D(x as f64)) }
            fn visit_f64<E>(self, x: f64) -> Result<V, E> { Ok(V::D(x)) }
            fn visit_str<E>(self, s: &str) -> Result<V, E> { Ok(V::S(s.to_owned())) }
            fn visit_string<E>(self, s: String) -> Result<V, E> { Ok(V::S(s)) }
            fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<V, A::Error> {
                let mut v = Vec::new();
                while let Some(x) = a.next_element()? { v.push(x); }
                Ok(V::A(v))
            }
            fn visit_map<M: MapAccess<'de>>(self, mut m: M) -> Result<V, M::Error> {
                let mut v: Vec<(String, V)> = Vec::new();
                while let Some((k, x)) = m.next_entry::<String, V>()? {
                    // JSON5.parse / JS objects: last value wins, first position kept
                    if let Some(slot) = v.iter_mut().find(|(kk, _)| *kk == k) { slot.1 = x; } else { v.push((k, x)); }
                }
                Ok(V::O(v))
            }
        }
        d.deserialize_any(Vis)
    }
}

fn hexs(out: &mut String, s: &str) { for b in s.as_bytes() { let _ = write!(out, "{:02x}", b); } }
fn num(out: &mut String, x: f64) {
    if x.is_nan() { out.push_str("dNaN"); } else { let _ = write!(out, "d{:016x}", x.to_bits()); }
}
fn canon(out: &mut String, v: &V) {
    match v {
        V::N => out.push('n'),
        V::B(b) => out.push(if *b { 't' } else { 'f' }),
        V::D(x) => num(out, *x),
        V::S(s) => { out.push('s'); hexs(out, s); out.push(';'); }
        V::A(a) => { out.push('['); for (i, x) in a.iter().enumerate() { if i > 0 { out.push(','); } canon(out, x); } out.push(']'); }
        V::O(o) => { out.push('{'); for (i, (k, x)) in o.iter().enumerate() { if i > 0 { out.push(','); } hexs(out, k); out.push(':'); canon(out, x); } out.push('}'); }
    }
}
fn canon_json(out: &mut String, v: &serde_json::Value) {
    use serde_json::Value as J;
    match v {
        J::Null => out.push('n'),
        J::Bool(b) => out.push(if *b { 't' } else { 'f' }),
        J::Number(n) => num(out, n.as_f64().unwrap()),
        J::String(s) => { out.push('s'); hexs(out, s); out.push(';'); }
        J::Array(a) => { out.push('['); for (i, x) in a.iter().enumerate() { if i > 0 { out.push(','); } canon_json(out, x); } out.push(']'); }
        J::Object(o) => { out.push('{'); for (i, (k, x)) in o.iter().enumerate() { if i > 0 { out.push(','); } hexs(out, k); out.push(':'); canon_json(out, x); } out.push('}'); }
    }
}
fn unhex(h: &str) -> Vec<u8> { (0..h.len() / 2).map(|i| u8::from_str_radix(&h[2 * i..2 * i + 2], 16).unwrap()).collect() }
fn unhex_s(h: &str) -> Option<String> { String::from_utf8(unhex(h)).ok() }
fn lines(p: &str) -> Vec<String> { fs::read_to_string(p).unwrap().lines().map(str::to_owned).collect() }
fn ok(s: &str) -> bool { json5::from_str::<V>(s).is_ok() }

fn wide_src(n: usize, change: Option<usize>) -> String {
    let mut s = String::from("{");
    for i in 0..n {
        if i > 0 { s.push(','); }
        if Some(i) == change { let _ = write!(s, "\"k{}\":-1", i); } else { let _ = write!(s, "\"k{}\":{}", i, i); }
    }
    s.push('}');
    s
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("");
    let mut out = String::new();
    match mode {
        "parse" => {
            for l in lines(&args[2]) {
                let r = match unhex_s(&l) {
                    None => None,
                    Some(src) => if args[3] == "json" { serde_json::from_str::<V>(&src).ok() } else { json5::from_str::<V>(&src).ok() },
                };
                match r { Some(v) => { out.push_str("OK "); canon(&mut out, &v); } None => out.push_str("ERR") }
                out.push('\n');
            }
        }
        "idscan" => {
            let mut col = 0;
            for cp in 0x80u32..=0x10FFFF {
                let Some(c) = char::from_u32(cp) else { continue };
                let x = c.to_string();
                let mut m = 0u8;
                if ok(&format!("{{{x}:1}}")) { m |= 1; }
                if ok(&format!("{{a{x}:1}}")) { m |= 2; }
                if ok(&format!("[{x}1]")) { m |= 4; }
                if cp < 0x10000 {
                    let e = format!("\\u{:04x}", cp);
                    if ok(&format!("{{{e}:1}}")) { m |= 8; }
                    if ok(&format!("{{a{e}:1}}")) { m |= 16; }
                }
                out.push((65 + m) as char);
                col += 1;
                if col == 256 { out.push('\n'); col = 0; }
            }
            out.push('\n');
        }
        "numfmt" => {
            // serde_json (ryu) formatting + strict round trip through serde_json::from_str
            for l in lines(&args[2]) {
                let x = f64::from_bits(u64::from_str_radix(&l, 16).unwrap());
                if !x.is_finite() { out.push_str("ERR\n"); continue; }
                let s = serde_json::to_string(&x).unwrap();
                let y: f64 = serde_json::from_str(&s).unwrap();
                out.push_str(&s); out.push(' '); num(&mut out, y); out.push('\n');
            }
        }
        "ptr" => {
            for l in lines(&args[2]) {
                let (d, p) = l.split_once(' ').unwrap();
                match json5::from_str::<serde_json::Value>(&unhex_s(d).unwrap()) {
                    Err(_) => out.push_str("BADDOC"),
                    Ok(doc) => match doc.pointer(&unhex_s(p).unwrap()) {
                        Some(v) => { out.push_str("OK "); canon_json(&mut out, v); }
                        None => out.push_str("NONE"),
                    },
                }
                out.push('\n');
            }
        }
        "patch" => {
            for l in lines(&args[2]) {
                let (d, p) = l.split_once(' ').unwrap();
                match json5::from_str::<serde_json::Value>(&unhex_s(d).unwrap()) {
                    Err(_) => out.push_str("BADDOC"),
                    Ok(mut doc) => {
                        let r = json5::from_str::<serde_json::Value>(&unhex_s(p).unwrap()).ok()
                            .and_then(|pv| serde_json::from_value::<json_patch::Patch>(pv).ok())
                            .and_then(|pt| json_patch::patch(&mut doc, &pt).ok());
                        match r { Some(()) => { out.push_str("OK "); canon_json(&mut out, &doc); } None => out.push_str("ERR") }
                    }
                }
                out.push('\n');
            }
        }
        "diffcount" => {
            for l in lines(&args[2]) {
                let (a, b) = l.split_once(' ').unwrap();
                let a: serde_json::Value = serde_json::from_slice(&unhex(a)).unwrap();
                let b: serde_json::Value = serde_json::from_slice(&unhex(b)).unwrap();
                let p = json_patch::diff(&a, &b);
                let mut r = a.clone();
                let good = json_patch::patch(&mut r, &p).is_ok() && r == b;
                let _ = writeln!(out, "{} {}", if good { "RT" } else { "BAD" }, p.0.len());
            }
        }
        "adv" => {
            let rd = |p: &str| -> serde_json::Value { json5::from_str(&fs::read_to_string(p).unwrap()).unwrap() };
            let rj = |p: &str| -> serde_json::Value { serde_json::from_str(&fs::read_to_string(p).unwrap()).unwrap() };
            match args[2].as_str() {
                "unikeys" => {
                    fn walk(v: &serde_json::Value, acc: &mut (usize, usize)) {
                        match v {
                            serde_json::Value::Array(a) => a.iter().for_each(|x| walk(x, acc)),
                            serde_json::Value::Object(o) => for (k, x) in o { acc.0 += 1; acc.1 += k.len(); walk(x, acc); },
                            _ => {}
                        }
                    }
                    let mut acc = (0, 0);
                    walk(&rd(&args[3]), &mut acc);
                    let _ = writeln!(out, "keys={} key_bytes={}", acc.0, acc.1);
                }
                "numbers" => {
                    // json5 =1.3.8 parser (exact f64 FromStr), same as the JSON5 path of the other two
                    let v: V = json5::from_str(&fs::read_to_string(&args[3]).unwrap()).unwrap();
                    let V::A(items) = v else { std::process::exit(3) };
                    let x = items.iter().fold(0u64, |x, v| if let V::D(d) = v { x ^ d.to_bits() } else { x });
                    let _ = writeln!(out, "n={} xor={:016x}", items.len(), x);
                }
                "widetest" => {
                    let mut a = rj(&args[3]);
                    let b = rj(&args[4]);
                    let p: json_patch::Patch = serde_json::from_value(serde_json::json!([{ "op": "test", "path": "", "value": b }])).unwrap();
                    let _ = writeln!(out, "test={}", if json_patch::patch(&mut a, &p).is_ok() { "ok" } else { "fail" });
                }
                "diff" => { let _ = writeln!(out, "ops={}", json_patch::diff(&rj(&args[3]), &rj(&args[4])).0.len()); }
                "ptrwide" => {
                    let a = rj(&args[3]);
                    let n = a.as_object().unwrap().len();
                    let hits = (0..n).filter(|i| a.pointer(&format!("/k{i}")).is_some()).count();
                    let _ = writeln!(out, "hits={hits}");
                }
                "bigapply" => {
                    // json_patch::patch is atomic (rolls back on error), like Pion apply_patch
                    let mut doc = rj(&args[3]);
                    let iters: u64 = args[4].parse().unwrap();
                    for i in 1..=iters {
                        let p: json_patch::Patch = serde_json::from_value(serde_json::json!([{ "op": "replace", "path": "/meta/rev", "value": i }])).unwrap();
                        json_patch::patch(&mut doc, &p).unwrap();
                    }
                    let _ = writeln!(out, "rev={}", doc.pointer("/meta/rev").unwrap());
                }
                _ => std::process::exit(2),
            }
        }
        "wide" => {
            // Same digests as `driver wide <n> <kind>`
            let n: usize = args[2].parse().unwrap();
            let t0 = Instant::now();
            let a: serde_json::Value = serde_json::from_str(&wide_src(n, None)).unwrap();
            match args[3].as_str() {
                "parse" => { let _ = writeln!(out, "keys={}", a.as_object().unwrap().len()); }
                "eq" => { let b: serde_json::Value = serde_json::from_str(&wide_src(n, None)).unwrap(); let _ = writeln!(out, "eq={}", a == b); }
                "diff" => { let b: serde_json::Value = serde_json::from_str(&wide_src(n, Some(n / 2))).unwrap(); let _ = writeln!(out, "ops={}", json_patch::diff(&a, &b).0.len()); }
                "test" => {
                    let b: serde_json::Value = serde_json::from_str(&wide_src(n, None)).unwrap();
                    let mut doc = serde_json::json!({ "d": a });
                    let p: json_patch::Patch = serde_json::from_value(serde_json::json!([{ "op": "test", "path": "/d", "value": b }])).unwrap();
                    let _ = writeln!(out, "test={}", if json_patch::patch(&mut doc, &p).is_ok() { "ok" } else { "fail" });
                }
                "ptr" => { let hits = (0..n).filter(|i| a.pointer(&format!("/k{i}")).is_some()).count(); let _ = writeln!(out, "hits={hits}"); }
                _ => std::process::exit(2),
            }
            let _ = t0;
        }
        _ => { eprintln!("bad args"); std::process::exit(1); }
    }
    print!("{out}");
}
